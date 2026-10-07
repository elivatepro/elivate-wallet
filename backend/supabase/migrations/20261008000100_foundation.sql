-- Blueprint 01 — B1/B2: schemas, error helper, audit log and public references.

-- Functions are private unless granted explicitly.
alter default privileges revoke execute on functions from public;

create schema identity;
create schema audit;
create schema refs;
create schema api;

revoke all on schema identity, audit, refs, api from public, anon, authenticated;
grant usage on schema api to service_role;

-- Raises a contract error. `message` is the wire code; `detail` carries JSON details.
create function identity.fail(p_code text, p_details jsonb default '{}'::jsonb)
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    errcode = 'P0001',
    message = p_code,
    detail = p_details::text;
end;
$$;

-- Append-only security audit (W-23). Never stores PINs, hashes, tokens or email bodies.
create table audit.security_events (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor_user_id uuid,
  session_id uuid,
  action text not null check (action ~ '^[a-z_]+(\.[a-z_]+)+$'),
  target_user_id uuid,
  reason text,
  safe_before jsonb,
  safe_after jsonb,
  request_id text check (request_id is null or length(request_id) <= 100)
);

create index security_events_actor_idx on audit.security_events (actor_user_id, at desc);
create index security_events_target_idx on audit.security_events (target_user_id, at desc);

alter table audit.security_events enable row level security;

create function audit.reject_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using errcode = 'P0001', message = 'invariant_violation',
    detail = jsonb_build_object('table', tg_table_schema || '.' || tg_table_name)::text;
end;
$$;

create trigger security_events_append_only
before update or delete on audit.security_events
for each row execute function audit.reject_change();

create trigger security_events_no_truncate
before truncate on audit.security_events
for each statement execute function audit.reject_change();

create function audit.record(
  p_action text,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_target_user_id uuid default null,
  p_reason text default null,
  p_safe_before jsonb default null,
  p_safe_after jsonb default null,
  p_request_id text default null
)
returns void
language sql
set search_path = ''
as $$
  insert into audit.security_events (
    action, actor_user_id, session_id, target_user_id, reason,
    safe_before, safe_after, request_id
  ) values (
    p_action, p_actor_user_id, p_session_id, p_target_user_id, p_reason,
    p_safe_before, p_safe_after, left(p_request_id, 100)
  );
$$;

-- Public operation references (D-01): <TYPE>-XXXX-XXXX, Crockford Base32, random,
-- unique and never reused (every issued code is kept).
create table refs.issued (
  code text primary key
    check (code ~ '^[A-Z]{3}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$'),
  type text not null
    check (type in ('WDR', 'PTR', 'RTN', 'INC', 'CNV', 'ADJ', 'REV', 'RST',
                    'PAY', 'STM', 'RPT', 'INV', 'WRQ')),
  issued_at timestamptz not null default now(),
  check (left(code, 3) = type)
);

alter table refs.issued enable row level security;

create function refs.issue(p_type text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  random_bytes bytea;
  body text;
  candidate text;
begin
  loop
    random_bytes := extensions.gen_random_bytes(8);
    body := '';
    for i in 0..7 loop
      -- 256 is a multiple of 32, so each character is uniform.
      body := body || substr(alphabet, (get_byte(random_bytes, i) % 32) + 1, 1);
    end loop;
    candidate := p_type || '-' || left(body, 4) || '-' || right(body, 4);
    begin
      insert into refs.issued (code, type) values (candidate, p_type);
      return candidate;
    exception when unique_violation then
      -- Collision: draw again.
    end;
  end loop;
end;
$$;
