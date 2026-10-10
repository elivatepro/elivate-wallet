-- Blueprint 19 — founder applications (owner decisions 2026-10-10). Founder
-- entry is apply first: a public application is reviewed by a platform admin,
-- and only an approved application's founder invitation makes an account a
-- founder. `api.start_network` refuses anyone without that grant. Accounts
-- that created a network before this rule keep it (source `existing`).

create schema founders;
revoke all on schema founders from public, anon, authenticated;

-- ── Tables ────────────────────────────────────────────────────────────────

create function founders.ranks() returns text[]
language sql immutable set search_path = '' as $$
  select array['ruby_director_4', 'ruby_director_5', 'diamond_director']
$$;

create table founders.applications (
  id uuid primary key default gen_random_uuid(),
  full_name text not null check (full_name = btrim(full_name) and length(full_name) between 2 and 100),
  email text not null check (email = lower(btrim(email)) and length(email) between 3 and 254),
  phone text not null check (phone ~ '^\+?[0-9]{7,15}$'),
  team_name text not null check (team_name = btrim(team_name) and length(team_name) between 2 and 100),
  rank text not null check (rank = any (founders.ranks())),
  status text not null default 'waiting' check (status in ('waiting', 'approved', 'rejected')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references identity.accounts (user_id) on delete restrict,
  decision_reason text check (decision_reason is null or length(btrim(decision_reason)) between 3 and 500),
  check ((status = 'waiting') = (decided_at is null)),
  check ((decided_at is null) = (decided_by is null)),
  check ((decided_at is null) = (decision_reason is null))
);

create unique index applications_one_waiting on founders.applications (email) where status = 'waiting';
create index applications_email_idx on founders.applications (email, created_at desc);
create index applications_status_idx on founders.applications (status, created_at desc, id desc);
create index applications_created_idx on founders.applications (created_at);
create index applications_decided_by_idx on founders.applications (decided_by);

create table founders.invitations (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null unique references founders.applications (id) on delete restrict,
  email text not null check (email = lower(btrim(email)) and length(email) between 3 and 254),
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  expires_at timestamptz not null,
  token_id uuid not null,
  token_digest bytea not null unique check (length(token_digest) = 32),
  issue_count int not null default 1 check (issue_count between 1 and 6),
  last_issued_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  accepted_user_id uuid references identity.accounts (user_id) on delete restrict,
  check ((status = 'accepted') = (accepted_at is not null and accepted_user_id is not null))
);

create index invitations_accepted_user_idx on founders.invitations (accepted_user_id);

-- The grant `api.start_network` checks. One row per founder account, forever.
create table founders.approved (
  user_id uuid primary key references identity.accounts (user_id) on delete restrict,
  source text not null check (source in ('application', 'existing')),
  application_id uuid references founders.applications (id) on delete restrict,
  approved_at timestamptz not null default now(),
  check ((source = 'application') = (application_id is not null))
);

create index approved_application_idx on founders.approved (application_id);

-- Verification-email requests per invitation (rate limit only).
create table founders.verifications (
  id bigint generated always as identity primary key,
  invitation_id uuid not null references founders.invitations (id) on delete restrict,
  requested_at timestamptz not null default now()
);

create index verifications_invitation_idx on founders.verifications (invitation_id, requested_at desc);

alter table founders.applications enable row level security;
alter table founders.invitations enable row level security;
alter table founders.approved enable row level security;
alter table founders.verifications enable row level security;

-- Identity columns never change, and a decided application stays decided.
create function founders.check_application()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.id, new.full_name, new.email, new.phone, new.team_name, new.rank, new.created_at)
     is distinct from (old.id, old.full_name, old.email, old.phone, old.team_name, old.rank, old.created_at)
     or old.status <> 'waiting' then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'founders.applications'));
  end if;
  return new;
end;
$$;

create trigger applications_check before update on founders.applications
for each row execute function founders.check_application();
create trigger applications_no_delete before delete on founders.applications
for each row execute function audit.reject_change();
create trigger applications_no_truncate before truncate on founders.applications
for each statement execute function audit.reject_change();

-- An invitation keeps its application and email; an accepted one is final.
create function founders.check_invitation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.id, new.application_id, new.email, new.created_at)
     is distinct from (old.id, old.application_id, old.email, old.created_at)
     or old.status <> 'pending' then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'founders.invitations'));
  end if;
  return new;
end;
$$;

create trigger invitations_check before update on founders.invitations
for each row execute function founders.check_invitation();
create trigger invitations_no_delete before delete on founders.invitations
for each row execute function audit.reject_change();
create trigger invitations_no_truncate before truncate on founders.invitations
for each statement execute function audit.reject_change();

create trigger approved_append_only before update or delete on founders.approved
for each row execute function audit.reject_change();
create trigger approved_no_truncate before truncate on founders.approved
for each statement execute function audit.reject_change();

-- Founders from before this rule: anyone who already created a network.
insert into founders.approved (user_id, source, approved_at)
select t.created_by, 'existing', min(t.created_at)
from org.tenants t
join identity.accounts a on a.user_id = t.created_by
group by t.created_by;

-- ── Policy and helpers ────────────────────────────────────────────────────

create function founders.invitation_ttl() returns interval
language sql immutable set search_path = '' as $$ select interval '14 days' $$;

create function founders.reapply_after() returns interval
language sql immutable set search_path = '' as $$ select interval '30 days' $$;

create function founders.hourly_cap() returns int
language sql immutable set search_path = '' as $$ select 200 $$;

create function founders.is_founder(p_user_id uuid) returns boolean
language sql stable set search_path = '' as $$
  select exists (select 1 from founders.approved where user_id = p_user_id)
$$;

-- A pending, unexpired founder invitation by digest.
create function founders.live_invitation_by_digest(p_digest bytea)
returns founders.invitations
language sql
stable
set search_path = ''
as $$
  select i.* from founders.invitations i
  where i.token_digest = p_digest and i.status = 'pending' and i.expires_at > now();
$$;

create function founders.application_json(a founders.applications)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'applicationId', a.id,
    'fullName', a.full_name,
    'email', a.email,
    'phone', a.phone,
    'teamName', a.team_name,
    'rank', a.rank,
    'status', a.status,
    'createdAt', a.created_at,
    'earlierApplications', (select count(*)::int from founders.applications x
                            where x.email = a.email and x.created_at < a.created_at),
    'decidedAt', a.decided_at,
    'decidedBy', case when a.decided_by is not null then org.person(a.decided_by) end,
    'decisionReason', a.decision_reason,
    'invitation', (
      select jsonb_build_object(
        'status', case when i.status = 'pending' and i.expires_at <= now() then 'expired' else i.status end,
        'expiresAt', i.expires_at, 'issueCount', i.issue_count, 'acceptedAt', i.accepted_at)
      from founders.invitations i where i.application_id = a.id)
  )
$$;

create function founders.enqueue_approval_email(inv founders.invitations)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform outbox.enqueue_email('founder.application_approved',
    'founder.application_approved:' || inv.id::text || ':' || inv.issue_count::text,
    'founder_invitation', inv.id, null, null, inv.email,
    jsonb_build_object(
      'team', (select a.team_name from founders.applications a where a.id = inv.application_id),
      'expiresAt', to_char(inv.expires_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')));
end;
$$;

-- ── Emails (Paper "Emails — Transactional v2" A17–A19) ────────────────────

insert into outbox.templates (key, version, duplicate_safe, params) values
  ('founder.application_received', 1, true, array['team']),
  ('founder.application_approved', 1, true, array['team', 'expiresAt']),
  ('founder.application_rejected', 1, true, array['team']);

-- An approval email only while its invitation is live and on its current link.
create or replace function outbox.is_relevant(p_event outbox.events)
returns boolean
language sql
stable
set search_path = ''
as $$
  select case p_event.template
    when 'invitation.issued' then exists (
      select 1 from org.invitations i
      join org.tenants t on t.id = i.tenant_id
      join org.offices o on o.id = i.office_id
      where i.id = p_event.aggregate_id and i.status = 'pending' and i.expires_at > now()
        and p_event.dedupe_key = 'invitation.issued:' || i.id::text || ':' || i.issue_count::text
        and t.status = 'active' and o.status = 'active'
    )
    when 'founder.application_approved' then exists (
      select 1 from founders.invitations i
      where i.id = p_event.aggregate_id and i.status = 'pending' and i.expires_at > now()
        and p_event.dedupe_key = 'founder.application_approved:' || i.id::text || ':' || i.issue_count::text
    )
    else true
  end;
$$;

-- Same as Blueprint 03's claim; founder approval emails also carry the token
-- id so the worker can rebuild the `/founder#t=` link.
create or replace function api.outbox_claim(p_worker_id text, p_batch_size int default 25, p_lease_seconds int default 60)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  candidate record;
  event outbox.events;
  template outbox.templates;
  recipient text;
  token uuid;
  lease uuid;
  claimed jsonb := '[]'::jsonb;
begin
  if p_worker_id is null or p_worker_id !~ '^[A-Za-z0-9_.:-]{1,100}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'workerId'));
  end if;
  if p_batch_size is null or p_batch_size not between 1 and 25 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'batchSize'));
  end if;
  if p_lease_seconds is null or p_lease_seconds not between 10 and 300 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'leaseSeconds'));
  end if;

  for candidate in
    select d.* from outbox.deliveries d
    join outbox.events e on e.id = d.event_id
    where e.available_at <= now()
      and ((d.status in ('pending', 'retry_scheduled') and d.next_attempt_at <= now())
           or (d.status = 'processing' and d.lease_expires_at <= now()))
    order by coalesce(d.next_attempt_at, d.lease_expires_at), e.occurred_at, d.event_id
    limit p_batch_size
    for update of d skip locked
  loop
    select * into event from outbox.events where id = candidate.event_id;
    select * into template from outbox.templates where key = event.template;

    if candidate.status = 'processing' then
      insert into outbox.attempts (event_id, cycle, attempt_number, lease_token, outcome, error_code, started_at)
      values (candidate.event_id, candidate.cycle, candidate.attempt_count, candidate.lease_token, 'lease_expired',
        'lease_expired', candidate.lease_expires_at);
      if not template.duplicate_safe or candidate.attempt_count >= candidate.max_attempts then
        update outbox.deliveries
        set status = 'dead_lettered', dead_lettered_at = now(), last_error_code = 'lease_expired',
            lease_token = null, lease_expires_at = null, worker_id = null, next_attempt_at = null, updated_at = now()
        where event_id = candidate.event_id;
        continue;
      end if;
    end if;

    if not outbox.is_relevant(event) then
      update outbox.deliveries
      set status = 'skipped', skipped_reason = 'not_relevant', lease_token = null, lease_expires_at = null,
          worker_id = null, next_attempt_at = null, updated_at = now()
      where event_id = candidate.event_id;
      continue;
    end if;

    recipient := coalesce(event.recipient_email,
      (select lower(btrim(u.email)) from auth.users u where u.id = event.recipient_user_id));
    if recipient is null then
      update outbox.deliveries
      set status = 'skipped', skipped_reason = 'recipient_unavailable', lease_token = null, lease_expires_at = null,
          worker_id = null, next_attempt_at = null, updated_at = now()
      where event_id = candidate.event_id;
      continue;
    end if;

    token := case event.template
      when 'invitation.issued'
        then (select i.token_id from org.invitations i where i.id = event.aggregate_id)
      when 'founder.application_approved'
        then (select i.token_id from founders.invitations i where i.id = event.aggregate_id)
    end;

    lease := gen_random_uuid();
    update outbox.deliveries
    set status = 'processing', attempt_count = attempt_count + 1, lease_token = lease,
        lease_expires_at = now() + make_interval(secs => p_lease_seconds), worker_id = p_worker_id,
        next_attempt_at = null, updated_at = now()
    where event_id = candidate.event_id;

    claimed := claimed || jsonb_build_object(
      'eventId', event.id,
      'leaseToken', lease,
      'cycle', candidate.cycle,
      'attempt', candidate.attempt_count + 1,
      'template', event.template,
      'version', event.template_version,
      'params', event.params,
      'to', recipient,
      'tokenId', token
    );
  end loop;

  return claimed;
end;
$$;

-- ── Public: apply (W-01 step 1) ───────────────────────────────────────────

-- Called only by the Wallet server after Turnstile. The reply is the same
-- whether or not a new application was stored (no enumeration): a waiting
-- application, a rejection under 30 days old, an approved application or an
-- existing founder account all end here without a row or an email.
create function api.submit_founder_application(
  p_full_name text,
  p_email text,
  p_phone text,
  p_team_name text,
  p_rank text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  clean_name text := org.require_text(p_full_name, 'fullName', 2, 100);
  clean_email text := org.clean_email(p_email);
  clean_phone text := regexp_replace(coalesce(p_phone, ''), '[\s().-]', '', 'g');
  clean_team text := org.require_text(p_team_name, 'teamName', 2, 100);
  application founders.applications;
begin
  if clean_phone !~ '^\+?[0-9]{7,15}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'phone'));
  end if;
  if p_rank is null or not (p_rank = any (founders.ranks())) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'rank'));
  end if;

  perform pg_advisory_xact_lock(hashtextextended('founders.apply:' || clean_email, 0));
  if exists (select 1 from founders.applications a where a.email = clean_email
             and (a.status in ('waiting', 'approved')
                  or (a.status = 'rejected' and a.decided_at > now() - founders.reapply_after())))
     or exists (select 1 from founders.approved f join auth.users u on u.id = f.user_id
                where lower(btrim(u.email)) = clean_email) then
    return jsonb_build_object('received', true);
  end if;

  perform pg_advisory_xact_lock(hashtextextended('founders.apply', 0));
  if (select count(*) from founders.applications where created_at > now() - interval '1 hour')
     >= founders.hourly_cap() then
    perform identity.fail('rate_limited', jsonb_build_object('retryAfterSeconds', 600));
  end if;

  insert into founders.applications (full_name, email, phone, team_name, rank)
  values (clean_name, clean_email, clean_phone, clean_team, p_rank)
  returning * into application;

  perform outbox.enqueue_email('founder.application_received',
    'founder.application_received:' || application.id::text,
    'founder_application', application.id, null, null, application.email,
    jsonb_build_object('team', application.team_name));
  return jsonb_build_object('received', true);
end;
$$;

-- ── Public: the founder invitation link (Blueprint 03 B2 pattern) ─────────

create function api.founder_invitation_preview(p_token_digest text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation founders.invitations;
begin
  invitation := founders.live_invitation_by_digest(org.token_digest(p_token_digest));
  if invitation.id is null then
    perform identity.fail('invitation_unavailable');
  end if;
  return jsonb_build_object('email', invitation.email,
    'teamName', (select a.team_name from founders.applications a where a.id = invitation.application_id));
end;
$$;

-- 60 s cooldown, 5 per 24 h per invitation; returns the bound email so the
-- Edge Function can ask Auth to send the sign-in email.
create function api.request_founder_verification(p_token_digest text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation founders.invitations;
  last_requested timestamptz;
begin
  invitation := founders.live_invitation_by_digest(org.token_digest(p_token_digest));
  if invitation.id is null then
    perform identity.fail('invitation_unavailable');
  end if;

  perform 1 from founders.invitations where id = invitation.id for update;
  select max(requested_at) into last_requested from founders.verifications where invitation_id = invitation.id;
  if last_requested > now() - interval '60 seconds' then
    perform identity.fail('rate_limited', jsonb_build_object('retryAfterSeconds',
      ceil(extract(epoch from last_requested + interval '60 seconds' - now()))::int));
  end if;
  if (select count(*) from founders.verifications
      where invitation_id = invitation.id and requested_at > now() - interval '24 hours') >= 5 then
    perform identity.fail('rate_limited', jsonb_build_object('retryAfterSeconds', 3600));
  end if;

  insert into founders.verifications (invitation_id) values (invitation.id);
  return jsonb_build_object('email', invitation.email);
end;
$$;

-- Accepting makes the signed-in account a founder. Same session rules as
-- joining a network (gate `ready` or `pin_setup_required`, confirmed email
-- that matches). Idempotent for the account that accepted.
create function api.accept_founder_invitation(
  p_user_id uuid,
  p_session_id uuid,
  p_token_digest text,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  account_email text;
  digest bytea := org.token_digest(p_token_digest);
  invitation founders.invitations;
  request jsonb;
  replayed jsonb;
  result jsonb;
begin
  account_email := org.require_join_session(p_user_id, p_session_id);
  select * into invitation from founders.invitations where token_digest = digest;
  if invitation.id is null or (invitation.status = 'accepted' and invitation.accepted_user_id <> p_user_id) then
    perform identity.fail('invitation_unavailable');
  end if;
  if invitation.email <> account_email then
    perform identity.fail('invitation_email_mismatch');
  end if;

  request := jsonb_build_object('digest', p_token_digest);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'accept_founder_invitation', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into invitation from founders.invitations where id = invitation.id for update;
  result := jsonb_build_object('applicationId', invitation.application_id, 'founder', true);
  if invitation.status = 'accepted' then
    -- Accepted on another device by this same account.
    return identity.store_result(p_user_id, p_idempotency_key, 'accept_founder_invitation', request, result);
  end if;
  if invitation.token_digest <> digest or invitation.expires_at <= now() then
    perform identity.fail('invitation_unavailable');
  end if;

  update founders.invitations
  set status = 'accepted', accepted_at = now(), accepted_user_id = p_user_id
  where id = invitation.id;
  insert into founders.approved (user_id, source, application_id)
  values (p_user_id, 'application', invitation.application_id)
  on conflict (user_id) do nothing;
  perform audit.record('founder_invitation.accepted', p_user_id, p_session_id, p_user_id, null,
    p_safe_after => jsonb_build_object('applicationId', invitation.application_id),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'accept_founder_invitation', request, result);
end;
$$;

-- ── Admin (Paper A22/A22b) ────────────────────────────────────────────────

create function api.admin_founder_applications(
  p_user_id uuid,
  p_session_id uuid,
  p_status text default 'waiting',
  p_cursor text default null,
  p_limit int default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  lim int := org.page_limit(p_limit);
  after jsonb := org.decode_cursor(p_cursor);
  wanted text := coalesce(p_status, 'waiting');
  rows jsonb;
  last_key jsonb;
  has_more boolean;
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  if wanted not in ('waiting', 'approved', 'rejected') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'status'));
  end if;

  -- Waiting: oldest first (a queue). Decided: most recent decision first.
  with found as (
    select a.id, a.created_at, a.decided_at, coalesce(a.decided_at, a.created_at) as sort_at
    from founders.applications a
    where a.status = wanted
      and (after is null
           or (wanted = 'waiting' and (a.created_at, a.id) > ((after->>'at')::timestamptz, (after->>'id')::uuid))
           or (wanted <> 'waiting' and (a.decided_at, a.id) < ((after->>'at')::timestamptz, (after->>'id')::uuid)))
    order by case when wanted = 'waiting' then a.created_at end asc,
             case when wanted <> 'waiting' then a.decided_at end desc,
             case when wanted = 'waiting' then a.id end asc,
             case when wanted <> 'waiting' then a.id end desc
    limit lim + 1
  ),
  numbered as (
    select f.*, row_number() over (
      order by case when wanted = 'waiting' then f.created_at end asc,
               case when wanted <> 'waiting' then f.decided_at end desc,
               case when wanted = 'waiting' then f.id end asc,
               case when wanted <> 'waiting' then f.id end desc) as rn
    from found f
  )
  select coalesce(jsonb_agg(founders.application_json(a) order by n.rn) filter (where n.rn <= lim), '[]'::jsonb),
         (array_agg(jsonb_build_object('at', n.sort_at, 'id', n.id) order by n.rn desc) filter (where n.rn <= lim))[1],
         count(*) > lim
  into rows, last_key, has_more
  from numbered n
  join founders.applications a on a.id = n.id;

  return jsonb_build_object(
    'items', rows,
    'nextCursor', case when has_more then org.encode_cursor(last_key) end,
    'counts', (select jsonb_build_object(
                 'waiting', count(*) filter (where status = 'waiting')::int,
                 'approved', count(*) filter (where status = 'approved')::int,
                 'rejected', count(*) filter (where status = 'rejected')::int)
               from founders.applications));
end;
$$;

create function api.admin_founder_application(p_user_id uuid, p_session_id uuid, p_application_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  application founders.applications;
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  select * into application from founders.applications where id = p_application_id;
  if application.id is null then
    perform identity.fail('not_found');
  end if;
  return founders.application_json(application);
end;
$$;

-- Approve (with the founder invitation's token from the Edge) or reject.
-- Reason + PIN step-up; idempotent; the reason never reaches the email.
create function api.admin_decide_founder_application(
  p_user_id uuid,
  p_session_id uuid,
  p_application_id uuid,
  p_decision text,
  p_reason text,
  p_token_id uuid,
  p_token_digest text,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  clean_reason text;
  application founders.applications;
  invitation founders.invitations;
  digest bytea;
  request jsonb;
  replayed jsonb;
begin
  perform identity.require_session(p_user_id, p_session_id, p_step_up => true);
  perform identity.require_platform_admin(p_user_id);
  if p_decision is null or p_decision not in ('approve', 'reject') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'decision'));
  end if;
  clean_reason := identity.require_reason(p_reason);
  if p_decision = 'approve' then
    if p_token_id is null then
      perform identity.fail('validation_error', jsonb_build_object('field', 'token'));
    end if;
    digest := org.token_digest(p_token_digest);
  end if;

  -- The token is drawn per attempt, so it is not part of the request.
  request := jsonb_build_object('applicationId', p_application_id, 'decision', p_decision, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'admin_decide_founder_application', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into application from founders.applications where id = p_application_id for update;
  if application.id is null then
    perform identity.fail('not_found');
  end if;
  if application.status <> 'waiting' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'already_decided'));
  end if;

  update founders.applications
  set status = case when p_decision = 'approve' then 'approved' else 'rejected' end,
      decided_at = now(), decided_by = p_user_id, decision_reason = clean_reason
  where id = application.id
  returning * into application;

  if p_decision = 'approve' then
    insert into founders.invitations (application_id, email, expires_at, token_id, token_digest)
    values (application.id, application.email, now() + founders.invitation_ttl(), p_token_id, digest)
    returning * into invitation;
    perform founders.enqueue_approval_email(invitation);
  else
    perform outbox.enqueue_email('founder.application_rejected',
      'founder.application_rejected:' || application.id::text,
      'founder_application', application.id, null, null, application.email,
      jsonb_build_object('team', application.team_name));
  end if;

  perform audit.record('founder_application.' || application.status, p_user_id, p_session_id, null, clean_reason,
    p_safe_after => jsonb_build_object('applicationId', application.id, 'teamName', application.team_name,
      'rank', application.rank),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'admin_decide_founder_application', request,
    jsonb_build_object('application', founders.application_json(application)));
end;
$$;

-- A new link for an approved application not yet accepted: the old link
-- stops working and a fresh A17 goes out (at most 5 resends).
create function api.admin_resend_founder_invitation(
  p_user_id uuid,
  p_session_id uuid,
  p_application_id uuid,
  p_reason text,
  p_token_id uuid,
  p_token_digest text,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  clean_reason text;
  digest bytea;
  invitation founders.invitations;
  request jsonb;
  replayed jsonb;
begin
  perform identity.require_session(p_user_id, p_session_id, p_step_up => true);
  perform identity.require_platform_admin(p_user_id);
  clean_reason := identity.require_reason(p_reason);
  if p_token_id is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'token'));
  end if;
  digest := org.token_digest(p_token_digest);

  request := jsonb_build_object('applicationId', p_application_id, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'admin_resend_founder_invitation', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into invitation from founders.invitations where application_id = p_application_id for update;
  if invitation.id is null then
    if exists (select 1 from founders.applications where id = p_application_id) then
      perform identity.fail('conflict', jsonb_build_object('reason', 'not_approved'));
    end if;
    perform identity.fail('not_found');
  end if;
  if invitation.status = 'accepted' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'already_accepted'));
  end if;
  if invitation.issue_count >= 6 then
    perform identity.fail('conflict', jsonb_build_object('reason', 'resend_limit'));
  end if;

  update founders.invitations
  set token_id = p_token_id, token_digest = digest, expires_at = now() + founders.invitation_ttl(),
      issue_count = issue_count + 1, last_issued_at = now()
  where id = invitation.id
  returning * into invitation;
  perform founders.enqueue_approval_email(invitation);

  perform audit.record('founder_application.invitation_resent', p_user_id, p_session_id, null, clean_reason,
    p_safe_after => jsonb_build_object('applicationId', invitation.application_id,
      'issueCount', invitation.issue_count),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'admin_resend_founder_invitation', request,
    jsonb_build_object('application', founders.application_json(
      (select a from founders.applications a where a.id = invitation.application_id))));
end;
$$;

-- ── Existing functions that change ────────────────────────────────────────

-- Founder applications count as account events in the platform audit.
create or replace function platform.action_group(p_action text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_action ~ '^(kill_switch|platform_admin|outbox|tenant\.activated|operations)\.' or p_action = 'tenant.activated'
      then 'controls'
    when p_action ~ '^(account|identity|pin|password|session|sign_in|security|founder)' then 'accounts'
    when p_action ~ '^(income|withdrawal|payout|pocket_transfer|entry|conversion|adjustment|returned_funds|reversal)\.'
      then 'money'
    when p_action ~ '^(restore|backup)\.' then 'backups'
    else 'network' end
$$;

create or replace function api.admin_overview(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  return jsonb_build_object(
    'networks', (
      select jsonb_build_object(
        'total', count(*)::int,
        'byState', coalesce(jsonb_object_agg(state, n) filter (where state is not null), '{}'::jsonb))
      from (
        select platform.network_state(t, s) as state, count(*)::int as n
        from org.tenants t left join billing.subscriptions s on s.tenant_id = t.id
        group by 1
      ) x
    ),
    'accounts', (
      select jsonb_build_object('total', count(*)::int,
        'byStatus', coalesce(jsonb_object_agg(status, n), '{}'::jsonb))
      from (select a.status::text as status, count(*)::int as n from identity.accounts a group by 1) x
    ),
    'recentNetworks', coalesce((
      select jsonb_agg(platform.network_row(t) order by t.created_at desc, t.id)
      from (select * from org.tenants order by created_at desc, id limit 6) t
    ), '[]'::jsonb),
    'switches', coalesce((
      select jsonb_agg(platform.switch_json(s) order by array_position(platform.switch_keys(), s.key))
      from platform.kill_switches s where s.tenant_id is null
    ), '[]'::jsonb),
    'networkStops', (select count(*)::int from platform.kill_switches where tenant_id is not null and stopped),
    'openRestores', coalesce((
      select jsonb_agg(jsonb_build_object('restoreId', r.id, 'reference', r.reference, 'status', r.status,
        'network', notify.network(r.tenant_id), 'createdAt', r.created_at) order by r.created_at, r.id)
      from backups.restore_requests r
      where r.status in ('requested', 'validating', 'in_review', 'restoring')
    ), '[]'::jsonb),
    'failedEmails', (select count(*)::int from outbox.deliveries where status = 'dead_lettered'),
    'ninReviews', (select count(*)::int from identity.nin_reviews where status = 'pending' and user_id <> p_user_id),
    'founderApplications', (select count(*)::int from founders.applications where status = 'waiting')
  );
end;
$$;

create or replace function api.billing_setup(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  return jsonb_build_object(
    'founderApproved', founders.is_founder(p_user_id),
    'trialAvailable', not exists (select 1 from billing.trials where user_id = p_user_id),
    'trialDays', extract(day from billing.trial_length())::int,
    'plans', (select jsonb_agg(billing.plan_json(p) order by p.rank) from billing.plans p
              where p.launch and p.version = (select max(version) from billing.plans x where x.key = p.key)),
    'pending', coalesce((
      select jsonb_agg(jsonb_build_object(
        'tenantId', t.id, 'name', t.name, 'membershipId', m.id,
        'plan', billing.plan_json(billing.plan_by_id(s.plan_id))) order by t.created_at)
      from org.tenants t
      join billing.subscriptions s on s.tenant_id = t.id
      join org.memberships m on m.tenant_id = t.id and m.user_id = p_user_id and m.status = 'active'
      where t.created_by = p_user_id and t.status = 'pending_payment'
    ), '[]'::jsonb)
  );
end;
$$;

-- Only an approved founder starts a network (paid or trial).
create or replace function api.start_network(
  p_user_id uuid,
  p_session_id uuid,
  p_name text,
  p_short_name text,
  p_idempotency_key text,
  p_request_id text default null,
  p_plan_key text default 'band_400',
  p_trial boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  account_status identity.account_status;
  clean_name text;
  clean_short text;
  plan billing.plans;
  request jsonb;
  replayed jsonb;
  tenant_id uuid;
  president org.memberships;
  trial_end timestamptz;
begin
  account_status := identity.require_session(p_user_id, p_session_id);
  if account_status <> 'active' then
    perform identity.fail('authorization_denied', jsonb_build_object('reason', 'account_not_active'));
  end if;
  if not founders.is_founder(p_user_id) then
    perform identity.fail('authorization_denied', jsonb_build_object('reason', 'founder_not_approved'));
  end if;
  clean_name := org.require_text(p_name, 'name', 2, 100);
  clean_short := org.require_text(p_short_name, 'shortName', 1, 30);
  if p_trial is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'trial'));
  end if;
  plan := billing.plan(coalesce(p_plan_key, ''));

  request := jsonb_build_object('name', clean_name, 'shortName', clean_short, 'planKey', plan.key,
    'trial', p_trial);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'start_network', request);
  if replayed is not null then
    return replayed;
  end if;

  if p_trial then
    if plan.key <> 'band_400' then
      perform identity.fail('conflict', jsonb_build_object('reason', 'trial_plan'));
    end if;
    perform pg_advisory_xact_lock(hashtextextended('billing.trial:' || p_user_id::text, 0));
    if exists (select 1 from billing.trials where user_id = p_user_id) then
      perform identity.fail('conflict', jsonb_build_object('reason', 'trial_used'));
    end if;
  end if;

  begin
    insert into org.tenants (name, short_name, created_by)
    values (clean_name, clean_short, p_user_id)
    returning id into tenant_id;
  exception when unique_violation then
    perform identity.fail('conflict', jsonb_build_object('reason', 'pending_network_exists'));
  end;

  if p_trial then
    trial_end := now() + billing.trial_length();
    insert into billing.subscriptions (tenant_id, status, kind, plan_id, period_start, period_end)
    values (tenant_id, 'trial', 'trial', plan.id, now(), trial_end);
    insert into billing.trials (user_id, tenant_id) values (p_user_id, tenant_id);
    insert into billing.periods (tenant_id, kind, plan_id, starts_at, ends_at, actor_user_id)
    values (tenant_id, 'trial', plan.id, now(), trial_end, p_user_id);
  else
    insert into billing.subscriptions (tenant_id, status, kind, plan_id)
    values (tenant_id, 'pending', 'paid', plan.id);
  end if;

  perform authz.seed_role_permissions(tenant_id);
  president := org.create_membership(tenant_id, null, p_user_id, 'president_team_member', p_user_id);
  insert into billing.owners (tenant_id, user_id, membership_id, assigned_by)
  values (tenant_id, p_user_id, president.id, p_user_id);
  if p_trial then
    perform billing.set_tenant_status(tenant_id, 'active', 'trial', p_user_id);
  end if;
  perform audit.record_tenant(tenant_id, p_user_id, 'tenant.created', 'tenant', tenant_id::text,
    p_safe_after => jsonb_build_object('status', case when p_trial then 'active' else 'pending_payment' end,
      'name', clean_name, 'plan', plan.key, 'trial', p_trial),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'start_network', request,
    jsonb_build_object('tenantId', tenant_id,
      'status', case when p_trial then 'active' else 'pending_payment' end,
      'membershipId', president.id, 'trial', p_trial, 'trialEndsAt', trial_end));
end;
$$;

-- ── Privileges ────────────────────────────────────────────────────────────

revoke all on all functions in schema founders from public, anon, authenticated;
do $$
declare
  fn regprocedure;
begin
  for fn in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end;
$$;
