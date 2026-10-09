-- Blueprint 14 — B1/B2: sign-in history (IP and the approximate Cloudflare
-- location per Auth session), "unusual" sign-ins and the A07 New sign-in
-- email. Owner decisions 2026-10-09: city and country are shown, the IP never;
-- records are kept (never deleted); unusual = a city/country or a device the
-- account has never used before, and never the first sign-in of the account.

create table identity.sign_ins (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references identity.accounts (user_id) on delete restrict,
  -- The Auth session. No FK: the history outlives the session.
  session_id uuid not null unique,
  created_at timestamptz not null default now(),
  method text not null check (method in ('password', 'email_link', 'recovery', 'sign_up')),
  ip inet check (ip is null or masklen(ip) = case family(ip) when 4 then 32 else 128 end),
  city text check (city is null or (length(city) between 1 and 100 and city !~ '[[:cntrl:]]')),
  -- ISO 3166-1 alpha-2, or the Cloudflare codes XX (unknown) / T1 (Tor).
  country text check (country is null or country ~ '^[A-Z][A-Z0-9]$'),
  device text not null check (length(device) between 1 and 60 and device !~ '[[:cntrl:]]'),
  user_agent text check (user_agent is null or length(user_agent) <= 300),
  unusual boolean not null,
  reasons text[] not null default '{}'
    check (reasons <@ array['new_location', 'new_device'] and unusual = (cardinality(reasons) > 0))
);

create index sign_ins_user_idx on identity.sign_ins (user_id, created_at desc);
create index sign_ins_unusual_idx on identity.sign_ins (user_id, created_at desc) where unusual;

alter table identity.sign_ins enable row level security;

-- Kept for good (Q2): rows never change or go away.
create trigger sign_ins_immutable
before update or delete on identity.sign_ins
for each row execute function audit.reject_change();
create trigger sign_ins_no_truncate
before truncate on identity.sign_ins
for each statement execute function audit.reject_change();

-- ── A07 New sign-in (Paper "Emails — Transactional v2") ────────────────────

insert into outbox.templates (key, version, duplicate_safe, params) values
  ('security.new_sign_in', 1, true, array['device', 'city', 'country', 'reason', 'path']);

insert into notify.kinds (key, task, email_template) values
  ('security.new_sign_in', false, 'security.new_sign_in');

-- ── Record a sign-in ───────────────────────────────────────────────────────

-- One host address (IPv4 or IPv6), or null when the text is not one.
create function identity.parse_ip(p_ip text)
returns inet
language plpgsql
immutable
set search_path = ''
as $$
declare
  parsed inet;
begin
  if p_ip is null or length(p_ip) > 45 then
    return null;
  end if;
  parsed := p_ip::inet;
  return case when masklen(parsed) = case family(parsed) when 4 then 32 else 128 end then parsed end;
exception when invalid_text_representation then
  return null;
end;
$$;

-- Called by the app server right after Auth created the session (before the
-- PIN). The IP and location come from Cloudflare at the edge; the device is
-- the app label for the user agent. Idempotent per session.
create function api.record_sign_in(
  p_user_id uuid,
  p_session_id uuid,
  p_method text,
  p_ip text,
  p_city text,
  p_country text,
  p_device text,
  p_user_agent text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ip inet;
  v_city text := nullif(btrim(p_city), '');
  v_country text := nullif(btrim(p_country), '');
  v_device text := btrim(p_device);
  existing identity.sign_ins;
  has_earlier boolean;
  reasons text[] := '{}'::text[];
  sign_in_id uuid;
  params jsonb;
begin
  perform identity.require_live_session(p_user_id, p_session_id);

  if p_method is null or p_method not in ('password', 'email_link', 'recovery', 'sign_up') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'method'));
  end if;
  v_ip := identity.parse_ip(p_ip);
  if p_ip is not null and v_ip is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'ip'));
  end if;
  if v_city is not null and (length(v_city) > 100 or v_city ~ '[[:cntrl:]]') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'city'));
  end if;
  if v_country is not null and v_country !~ '^[A-Z][A-Z0-9]$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'country'));
  end if;
  if v_device is null or length(v_device) not between 1 and 60 or v_device ~ '[[:cntrl:]]' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'device'));
  end if;

  -- One decision at a time per account, so two sign-ins racing each other
  -- both compare against a settled history.
  perform pg_advisory_xact_lock(hashtextextended('identity.sign_in:' || p_user_id::text, 0));

  select * into existing from identity.sign_ins where session_id = p_session_id;
  if existing.id is not null then
    if existing.user_id <> p_user_id then
      perform identity.fail('authentication_required');
    end if;
    return jsonb_build_object('unusual', existing.unusual);
  end if;

  has_earlier := exists (select 1 from identity.sign_ins where user_id = p_user_id);
  if has_earlier then
    if (v_city is not null or v_country is not null) and not exists (
      select 1 from identity.sign_ins s
      where s.user_id = p_user_id
        and lower(s.city) is not distinct from lower(v_city)
        and s.country is not distinct from v_country
    ) then
      reasons := array_append(reasons, 'new_location');
    end if;
    if not exists (select 1 from identity.sign_ins s where s.user_id = p_user_id and s.device = v_device) then
      reasons := array_append(reasons, 'new_device');
    end if;
  end if;

  insert into identity.sign_ins (user_id, session_id, method, ip, city, country, device, user_agent, unusual,
    reasons)
  values (p_user_id, p_session_id, p_method, v_ip, v_city, v_country, v_device, left(p_user_agent, 300),
    cardinality(reasons) > 0, reasons)
  returning id into sign_in_id;

  -- Never the IP: method and reasons only.
  perform audit.record('session.signed_in', p_user_id, p_session_id, p_user_id,
    p_safe_after => jsonb_build_object('method', p_method, 'reasons', to_jsonb(reasons)),
    p_request_id => p_request_id);

  if cardinality(reasons) > 0 then
    params := jsonb_build_object(
      'device', v_device,
      'city', v_city,
      'country', v_country,
      'reason', case when 'new_device' = any (reasons) then 'new_device' else 'new_location' end,
      'path', '/app/account/devices');
    perform notify.emit(p_user_id, null, 'security.new_sign_in', 'sign_in', sign_in_id, params,
      'sign_in:' || sign_in_id::text, params);
  end if;

  return jsonb_build_object('unusual', cardinality(reasons) > 0);
end;
$$;

-- Devices & sessions: each live session with its approximate location and,
-- for an unusual sign-in, why (Paper B09 "New location" chip).
create or replace function api.list_sessions(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'sessionId', s.id,
      'createdAt', s.created_at,
      'lastActiveAt', coalesce(s.refreshed_at::timestamptz, s.updated_at, s.created_at),
      'userAgent', left(s.user_agent, 300),
      'current', s.id = p_session_id,
      'city', si.city,
      'country', si.country,
      'reasons', coalesce(to_jsonb(si.reasons), '[]'::jsonb)
    ) order by coalesce(s.refreshed_at::timestamptz, s.updated_at, s.created_at) desc)
    from auth.sessions s
    left join identity.sign_ins si on si.session_id = s.id and si.user_id = s.user_id
    where s.user_id = p_user_id and (s.not_after is null or s.not_after > now())
  ), '[]'::jsonb);
end;
$$;

revoke all on function api.record_sign_in(uuid, uuid, text, text, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function api.record_sign_in(uuid, uuid, text, text, text, text, text, text, text)
  to service_role;
revoke all on function identity.parse_ip(text) from public, anon, authenticated;
