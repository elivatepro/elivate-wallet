-- Blueprint 06 — B1/B2: NIN verification, leader review, legal name lock.
-- The raw NIN never reaches the database: the Edge Function sends a keyed
-- fingerprint (HMAC) and the last 4 digits only.

create type identity.nin_method as enum ('provider', 'leader_review');

create function identity.check_person_name(p_value text, p_field text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_value is null or length(btrim(p_value)) not between 1 and 80 then
    perform identity.fail('validation_error', jsonb_build_object('field', p_field));
  end if;
  return regexp_replace(btrim(p_value), '\s+', ' ', 'g');
end;
$$;

create function identity.check_middle_names(p_value text[])
returns text[]
language plpgsql
immutable
set search_path = ''
as $$
declare
  cleaned text[] := '{}';
  part text;
begin
  if p_value is null then
    return cleaned;
  end if;
  if cardinality(p_value) > 4 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'middleNames'));
  end if;
  foreach part in array p_value loop
    cleaned := cleaned || identity.check_person_name(part, 'middleNames');
  end loop;
  return cleaned;
end;
$$;

create table identity.nin_records (
  user_id uuid primary key references identity.accounts (user_id) on delete restrict,
  nin_fingerprint text not null unique check (nin_fingerprint ~ '^[0-9a-f]{64}$'),
  nin_last4 text not null check (nin_last4 ~ '^[0-9]{4}$'),
  given_name text not null check (length(btrim(given_name)) between 1 and 80),
  middle_names text[] not null default '{}',
  surname text not null check (length(btrim(surname)) between 1 and 80),
  phone text check (phone is null or phone ~ '^\+?[0-9]{7,15}$'),
  method identity.nin_method not null,
  review_id uuid,
  verified_at timestamptz not null default now(),
  check ((method = 'leader_review') = (review_id is not null))
);

create table identity.nin_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null references identity.accounts (user_id) on delete restrict,
  nin_last4 text not null check (nin_last4 ~ '^[0-9]{4}$'),
  outcome text not null check (outcome in ('verified', 'not_found', 'in_use')),
  at timestamptz not null default now()
);
create index nin_attempts_user_idx on identity.nin_attempts (user_id, at);

create table identity.nin_reviews (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references identity.accounts (user_id) on delete restrict,
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  membership_id uuid not null references org.memberships (id) on delete restrict,
  nin_fingerprint text not null check (nin_fingerprint ~ '^[0-9a-f]{64}$'),
  nin_last4 text not null check (nin_last4 ~ '^[0-9]{4}$'),
  given_name text not null check (length(btrim(given_name)) between 1 and 80),
  middle_names text[] not null default '{}',
  surname text not null check (length(btrim(surname)) between 1 and 80),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  requested_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references identity.accounts (user_id) on delete restrict,
  decision_reason text check (decision_reason is null or length(btrim(decision_reason)) between 3 and 500),
  check ((status = 'pending') = (decided_at is null)),
  check ((status = 'pending') = (decided_by is null)),
  check ((status = 'pending') = (decision_reason is null))
);
create unique index nin_reviews_one_pending on identity.nin_reviews (user_id) where status = 'pending';
create index nin_reviews_tenant_idx on identity.nin_reviews (tenant_id, status, requested_at);

alter table identity.nin_records enable row level security;
alter table identity.nin_attempts enable row level security;
alter table identity.nin_reviews enable row level security;

create trigger nin_records_immutable
before update or delete on identity.nin_records
for each row execute function audit.reject_change();
create trigger nin_records_no_truncate
before truncate on identity.nin_records
for each statement execute function audit.reject_change();
create trigger nin_attempts_append_only
before update or delete on identity.nin_attempts
for each row execute function audit.reject_change();
create trigger nin_attempts_no_truncate
before truncate on identity.nin_attempts
for each statement execute function audit.reject_change();

-- Decided reviews are history: only the pending → decided transition is allowed.
create function identity.guard_nin_review()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' or old.status <> 'pending' or new.status = 'pending'
    or (new.user_id, new.tenant_id, new.membership_id, new.nin_fingerprint, new.nin_last4,
        new.given_name, new.middle_names, new.surname, new.requested_at)
       is distinct from
       (old.user_id, old.tenant_id, old.membership_id, old.nin_fingerprint, old.nin_last4,
        old.given_name, old.middle_names, old.surname, old.requested_at) then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'identity.nin_reviews'));
  end if;
  return new;
end;
$$;
create trigger nin_reviews_guard
before update or delete on identity.nin_reviews
for each row execute function identity.guard_nin_review();

alter table identity.profiles
  add column photo_key text,
  add column photo_updated_at timestamptz,
  add column phone_source text check (phone_source is null or phone_source in ('nin', 'self'));
alter table identity.profiles
  add constraint profiles_photo_key_owner check (
    photo_key is null
    or photo_key ~ ('^photos/' || user_id::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$')
  ),
  add constraint profiles_photo_pair check ((photo_key is null) = (photo_updated_at is null)),
  add constraint profiles_phone_source check ((phone is null) = (phone_source is null));

-- ── Rules ─────────────────────────────────────────────────────────────────

create function identity.nin_max_failures() returns int
language sql immutable set search_path = '' as $$ select 2 $$;

create function identity.nin_failures(p_user_id uuid) returns int
language sql stable set search_path = '' as $$
  select count(*)::int from identity.nin_attempts where user_id = p_user_id and outcome = 'not_found'
$$;

create function identity.lock_nin_person(p_user_id uuid) returns void
language sql set search_path = '' as $$
  select pg_advisory_xact_lock(hashtextextended('identity.nin:' || p_user_id::text, 0))
$$;

-- Blueprint 05's plug-in point, now backed by the locked record.
create or replace function identity.legal_name(p_user_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'given', r.given_name,
    'middle', to_jsonb(r.middle_names),
    'surname', r.surname,
    'verifiedAt', r.verified_at,
    'method', r.method
  )
  from identity.nin_records r
  where r.user_id = p_user_id;
$$;

create function identity.identity_state(p_user_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with record as (select * from identity.nin_records where user_id = p_user_id),
  review as (
    select * from identity.nin_reviews where user_id = p_user_id
    order by requested_at desc limit 1
  ),
  failures as (select identity.nin_failures(p_user_id) as n)
  select jsonb_build_object(
    'status', case
      when exists (select 1 from record) then 'verified'
      when exists (select 1 from review where status = 'pending') then 'review_pending'
      else 'unverified' end,
    'method', (select method from record),
    'verifiedAt', (select verified_at from record),
    'legalName', identity.legal_name(p_user_id) - 'verifiedAt' - 'method',
    'ninLast4', coalesce((select nin_last4 from record), (select nin_last4 from review where status = 'pending')),
    'failedChecks', (select n from failures),
    'checksRemaining', greatest(identity.nin_max_failures() - (select n from failures), 0),
    'review', (select jsonb_build_object('status', status, 'requestedAt', requested_at, 'decidedAt', decided_at)
               from review)
  );
$$;

-- Locks the legal name (provider or review), fills display names and the
-- NIN phone, re-checks payout accounts (W-17).
create function identity.lock_legal_name(
  p_user_id uuid,
  p_fingerprint text,
  p_last4 text,
  p_given text,
  p_middle text[],
  p_surname text,
  p_phone text,
  p_method identity.nin_method,
  p_review_id uuid
)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if exists (select 1 from identity.nin_records where nin_fingerprint = p_fingerprint and user_id <> p_user_id) then
    perform identity.fail('nin_in_use');
  end if;
  insert into identity.nin_records (user_id, nin_fingerprint, nin_last4, given_name, middle_names, surname,
    phone, method, review_id)
  values (p_user_id, p_fingerprint, p_last4, p_given, p_middle, p_surname, p_phone, p_method, p_review_id);

  update identity.profiles
  set first_name = p_given,
      last_name = p_surname,
      phone = coalesce(p_phone, phone),
      phone_source = case when p_phone is not null then 'nin' else phone_source end,
      updated_at = now()
  where user_id = p_user_id;

  perform payout.recheck_name_match(p_user_id);
end;
$$;

create function identity.check_fingerprint(p_value text) returns text
language plpgsql immutable set search_path = '' as $$
begin
  if p_value is null or p_value !~ '^[0-9a-f]{64}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'nin'));
  end if;
  return p_value;
end;
$$;

create function identity.check_last4(p_value text) returns text
language plpgsql immutable set search_path = '' as $$
begin
  if p_value is null or p_value !~ '^[0-9]{4}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'nin'));
  end if;
  return p_value;
end;
$$;

-- Shared preconditions of a provider check. Records an `in_use` attempt
-- (returned, not raised, so the row survives) when another account holds it.
create function identity.nin_check_blocker(p_user_id uuid, p_fingerprint text)
returns text
language plpgsql
set search_path = ''
as $$
begin
  if exists (select 1 from identity.nin_records where user_id = p_user_id) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'already_verified'));
  end if;
  if exists (select 1 from identity.nin_reviews where user_id = p_user_id and status = 'pending') then
    perform identity.fail('conflict', jsonb_build_object('reason', 'review_pending'));
  end if;
  if identity.nin_failures(p_user_id) >= identity.nin_max_failures() then
    perform identity.fail('nin_review_required');
  end if;
  if exists (select 1 from identity.nin_records where nin_fingerprint = p_fingerprint) then
    return 'in_use';
  end if;
  return null;
end;
$$;

-- ── Commands ──────────────────────────────────────────────────────────────

create function api.prepare_nin_check(
  p_user_id uuid,
  p_session_id uuid,
  p_fingerprint text,
  p_last4 text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.check_fingerprint(p_fingerprint);
  perform identity.check_last4(p_last4);
  perform identity.lock_nin_person(p_user_id);
  if identity.nin_check_blocker(p_user_id, p_fingerprint) = 'in_use' then
    insert into identity.nin_attempts (user_id, nin_last4, outcome) values (p_user_id, p_last4, 'in_use');
    perform audit.record('identity.nin_in_use', p_user_id, p_session_id, p_user_id,
      p_safe_after => jsonb_build_object('ninLast4', p_last4));
    return jsonb_build_object('ready', false, 'blocked', 'nin_in_use');
  end if;
  return jsonb_build_object('ready', true);
end;
$$;

create function api.record_nin_check(
  p_user_id uuid,
  p_session_id uuid,
  p_fingerprint text,
  p_last4 text,
  p_outcome text,
  p_given text,
  p_middle text[],
  p_surname text,
  p_phone text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  given text;
  middle text[];
  surname text;
  phone text;
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.check_fingerprint(p_fingerprint);
  perform identity.check_last4(p_last4);
  if p_outcome is null or p_outcome not in ('verified', 'not_found') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'outcome'));
  end if;
  perform identity.lock_nin_person(p_user_id);
  if identity.nin_check_blocker(p_user_id, p_fingerprint) = 'in_use' then
    insert into identity.nin_attempts (user_id, nin_last4, outcome) values (p_user_id, p_last4, 'in_use');
    return jsonb_build_object('status', 'in_use');
  end if;

  if p_outcome = 'not_found' then
    insert into identity.nin_attempts (user_id, nin_last4, outcome) values (p_user_id, p_last4, 'not_found');
    perform audit.record('identity.nin_not_verified', p_user_id, p_session_id, p_user_id,
      p_safe_after => jsonb_build_object('ninLast4', p_last4), p_request_id => p_request_id);
    return jsonb_build_object('status', 'not_verified',
      'checksRemaining', greatest(identity.nin_max_failures() - identity.nin_failures(p_user_id), 0));
  end if;

  given := identity.check_person_name(p_given, 'givenName');
  middle := identity.check_middle_names(p_middle);
  surname := identity.check_person_name(p_surname, 'surname');
  phone := case when p_phone ~ '^\+?[0-9]{7,15}$' then p_phone end;

  insert into identity.nin_attempts (user_id, nin_last4, outcome) values (p_user_id, p_last4, 'verified');
  perform identity.lock_legal_name(p_user_id, p_fingerprint, p_last4, given, middle, surname, phone,
    'provider', null);
  perform audit.record('identity.nin_verified', p_user_id, p_session_id, p_user_id,
    p_safe_after => jsonb_build_object('ninLast4', p_last4, 'method', 'provider'), p_request_id => p_request_id);
  return jsonb_build_object('status', 'verified') || jsonb_build_object('identity', identity.identity_state(p_user_id));
end;
$$;

create function api.request_nin_review(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_fingerprint text,
  p_last4 text,
  p_given text,
  p_middle text[],
  p_surname text,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  request jsonb;
  replayed jsonb;
  review identity.nin_reviews;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform identity.check_fingerprint(p_fingerprint);
  perform identity.check_last4(p_last4);
  request := jsonb_build_object('membershipId', workspace.id, 'fingerprint', p_fingerprint,
    'given', identity.check_person_name(p_given, 'givenName'),
    'middle', to_jsonb(identity.check_middle_names(p_middle)),
    'surname', identity.check_person_name(p_surname, 'surname'));
  replayed := identity.replay(p_user_id, p_idempotency_key, 'request_nin_review', request);
  if replayed is not null then
    return replayed;
  end if;

  perform identity.lock_nin_person(p_user_id);
  if exists (select 1 from identity.nin_records where user_id = p_user_id) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'already_verified'));
  end if;
  if exists (select 1 from identity.nin_reviews where user_id = p_user_id and status = 'pending') then
    perform identity.fail('conflict', jsonb_build_object('reason', 'review_pending'));
  end if;
  if identity.nin_failures(p_user_id) < 1 then
    perform identity.fail('conflict', jsonb_build_object('reason', 'check_first'));
  end if;
  if exists (select 1 from identity.nin_records where nin_fingerprint = p_fingerprint) then
    perform identity.fail('nin_in_use');
  end if;

  insert into identity.nin_reviews (user_id, tenant_id, membership_id, nin_fingerprint, nin_last4,
    given_name, middle_names, surname)
  values (p_user_id, workspace.tenant_id, workspace.id, p_fingerprint, p_last4, request->>'given',
    array(select jsonb_array_elements_text(request->'middle')), request->>'surname')
  returning * into review;

  perform audit.record('identity.nin_review_requested', p_user_id, p_session_id, p_user_id,
    p_safe_after => jsonb_build_object('reviewId', review.id, 'tenantId', review.tenant_id, 'ninLast4', p_last4),
    p_request_id => p_request_id);
  return identity.store_result(p_user_id, p_idempotency_key, 'request_nin_review', request,
    jsonb_build_object('reviewId', review.id, 'status', review.status, 'requestedAt', review.requested_at));
end;
$$;

-- May this workspace decide this review? President Team of the review's
-- network, or a World Team Member whose office is at or above the requester's
-- office. Never one's own review.
create function identity.can_review(p_workspace org.memberships, p_review identity.nin_reviews)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_review.user_id <> p_workspace.user_id
    and p_workspace.tenant_id = p_review.tenant_id
    and p_workspace.status = 'active'
    and (
      p_workspace.role = 'president_team_member'
      or (p_workspace.role = 'world_team_member' and exists (
        select 1 from org.memberships target
        join org.office_closure c on c.descendant_id = target.office_id
        where target.id = p_review.membership_id and c.ancestor_id = p_workspace.office_id
      ))
    );
$$;

create function identity.review_row(p_review identity.nin_reviews)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'reviewId', p_review.id,
    'tenantId', p_review.tenant_id,
    'requester', jsonb_build_object('uid', a.uid,
      'name', coalesce(nullif(btrim(p.display_name), ''), nullif(btrim(concat_ws(' ', p.first_name, p.last_name)), ''))),
    'officeName', o.name,
    'role', m.role,
    'ninLast4', p_review.nin_last4,
    'legalName', jsonb_build_object('given', p_review.given_name, 'middle', to_jsonb(p_review.middle_names),
      'surname', p_review.surname),
    'requestedAt', p_review.requested_at
  )
  from identity.accounts a
  left join identity.profiles p on p.user_id = a.user_id
  join org.memberships m on m.id = p_review.membership_id
  left join org.offices o on o.id = m.office_id
  where a.user_id = p_review.user_id;
$$;

create function api.nin_reviews(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  if workspace.role not in ('president_team_member', 'world_team_member') then
    perform identity.fail('authorization_denied');
  end if;
  return coalesce((
    select jsonb_agg(identity.review_row(r) order by r.requested_at, r.id)
    from identity.nin_reviews r
    where r.tenant_id = workspace.tenant_id and r.status = 'pending' and identity.can_review(workspace, r)
  ), '[]'::jsonb);
end;
$$;

create function api.admin_nin_reviews(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  return coalesce((
    select jsonb_agg(identity.review_row(r) order by r.requested_at, r.id)
    from identity.nin_reviews r where r.status = 'pending' and r.user_id <> p_user_id
  ), '[]'::jsonb);
end;
$$;

-- p_membership_id null = deciding as an Elivate platform admin.
create function api.decide_nin_review(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_review_id uuid,
  p_decision text,
  p_reason text,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  clean_reason text;
  request jsonb;
  replayed jsonb;
  review identity.nin_reviews;
begin
  perform identity.require_session(p_user_id, p_session_id, p_step_up => true);
  if p_membership_id is null then
    perform identity.require_platform_admin(p_user_id);
  else
    workspace := authz.require_workspace(p_user_id, p_membership_id);
  end if;
  if p_decision is null or p_decision not in ('approve', 'reject') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'decision'));
  end if;
  clean_reason := identity.require_reason(p_reason);

  select * into review from identity.nin_reviews where id = p_review_id;
  if review.id is null then
    perform identity.fail('not_found');
  end if;
  if review.user_id = p_user_id then
    perform identity.fail('self_target_forbidden');
  end if;
  if p_membership_id is not null and not identity.can_review(workspace, review) then
    perform identity.fail('authorization_denied');
  end if;

  request := jsonb_build_object('membershipId', p_membership_id, 'reviewId', p_review_id,
    'decision', p_decision, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'decide_nin_review', request);
  if replayed is not null then
    return replayed;
  end if;

  perform identity.lock_nin_person(review.user_id);
  select * into review from identity.nin_reviews where id = p_review_id for update;
  if review.status <> 'pending' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'not_pending'));
  end if;

  update identity.nin_reviews
  set status = case when p_decision = 'approve' then 'approved' else 'rejected' end,
      decided_at = now(), decided_by = p_user_id, decision_reason = clean_reason
  where id = review.id
  returning * into review;

  if p_decision = 'approve' then
    if exists (select 1 from identity.nin_records where user_id = review.user_id) then
      perform identity.fail('conflict', jsonb_build_object('reason', 'already_verified'));
    end if;
    perform identity.lock_legal_name(review.user_id, review.nin_fingerprint, review.nin_last4,
      review.given_name, review.middle_names, review.surname, null, 'leader_review', review.id);
  end if;

  perform audit.record('identity.nin_review_' || review.status, p_user_id, p_session_id, review.user_id,
    clean_reason, p_safe_after => jsonb_build_object('reviewId', review.id, 'tenantId', review.tenant_id,
      'asAdmin', p_membership_id is null),
    p_request_id => p_request_id);
  return identity.store_result(p_user_id, p_idempotency_key, 'decide_nin_review', request,
    jsonb_build_object('reviewId', review.id, 'status', review.status, 'decidedAt', review.decided_at));
end;
$$;

revoke all on function
  api.prepare_nin_check(uuid, uuid, text, text),
  api.record_nin_check(uuid, uuid, text, text, text, text, text[], text, text, text),
  api.request_nin_review(uuid, uuid, uuid, text, text, text, text[], text, text, text),
  api.nin_reviews(uuid, uuid, uuid),
  api.admin_nin_reviews(uuid, uuid),
  api.decide_nin_review(uuid, uuid, uuid, uuid, text, text, text, text)
from public, anon, authenticated;
grant execute on function
  api.prepare_nin_check(uuid, uuid, text, text),
  api.record_nin_check(uuid, uuid, text, text, text, text, text[], text, text, text),
  api.request_nin_review(uuid, uuid, uuid, text, text, text, text[], text, text, text),
  api.nin_reviews(uuid, uuid, uuid),
  api.admin_nin_reviews(uuid, uuid),
  api.decide_nin_review(uuid, uuid, uuid, uuid, text, text, text, text)
to service_role;
