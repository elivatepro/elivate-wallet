create schema evidence;
create schema internal;

create type evidence.verification_outcome as enum (
  'match',
  'mismatch'
);

create type evidence.review_decision as enum (
  'clear',
  'reject'
);

create type financial_ops.payout_assertion_status as enum (
  'submitted',
  'correction_required',
  'needs_review',
  'rejected',
  'posted'
);

create type financial_ops.payout_resolution as enum (
  'automated_match',
  'manual_clear'
);

create type financial_ops.payout_assertion_command_result as (
  payout_assertion_id uuid,
  payout_assertion_status financial_ops.payout_assertion_status,
  withdrawal_id uuid,
  withdrawal_status financial_ops.withdrawal_status,
  reused boolean
);

-- Reviewer routing and reviewer authority are one President-controlled
-- assignment, not an independently grantable generic access rule.
update authz.permission_catalog
   set grantable = false
 where permission_key = 'review_financial_evidence';

create table authz.financial_evidence_reviewer_assignments (
  id uuid primary key default extensions.gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  reviewer_membership_id uuid not null,
  reviewer_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  assigned_by_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  assigned_at timestamptz not null default clock_timestamp(),
  revoked_by_user_id uuid
    references public.user_accounts (user_id) on delete restrict,
  revoked_at timestamptz,
  foreign key (tenant_id, reviewer_membership_id)
    references public.memberships (tenant_id, id)
    on delete restrict,
  check (
    (revoked_at is null and revoked_by_user_id is null)
    or (revoked_at is not null and revoked_by_user_id is not null)
  ),
  check (revoked_at is null or revoked_at >= assigned_at)
);

create unique index financial_evidence_reviewers_active_membership
  on authz.financial_evidence_reviewer_assignments (
    tenant_id,
    reviewer_membership_id
  )
  where revoked_at is null;

create index financial_evidence_reviewers_active_user
  on authz.financial_evidence_reviewer_assignments (
    tenant_id,
    reviewer_user_id
  )
  where revoked_at is null;

create index financial_evidence_reviewers_assigned_by
  on authz.financial_evidence_reviewer_assignments (assigned_by_user_id);

create index financial_evidence_reviewers_revoked_by
  on authz.financial_evidence_reviewer_assignments (revoked_by_user_id)
  where revoked_by_user_id is not null;

create table evidence.financial_evidence (
  id uuid primary key default extensions.gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  evidence_type text not null
    check (evidence_type ~ '^[a-z][a-z0-9_]*$'),
  storage_bucket_id text not null
    check (length(btrim(storage_bucket_id)) > 0),
  storage_object_path text not null
    check (length(btrim(storage_object_path)) > 0),
  original_filename text not null
    check (length(btrim(original_filename)) > 0),
  mime_type text not null
    check (length(btrim(mime_type)) > 0),
  file_size_bytes bigint not null check (file_size_bytes > 0),
  sha256 bytea not null check (octet_length(sha256) = 32),
  submitted_by_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  submitted_at timestamptz not null default clock_timestamp(),
  provider text,
  observed_at timestamptz,
  provider_reference text,
  notes text,
  supersedes_evidence_id uuid
    references evidence.financial_evidence (id) on delete restrict,
  unique (storage_bucket_id, storage_object_path),
  check (provider is null or length(btrim(provider)) > 0),
  check (provider_reference is null or length(btrim(provider_reference)) > 0),
  check (notes is null or length(btrim(notes)) > 0),
  check (supersedes_evidence_id is null or supersedes_evidence_id <> id)
);

create index financial_evidence_tenant_submitted
  on evidence.financial_evidence (tenant_id, submitted_at desc);

create index financial_evidence_submitter
  on evidence.financial_evidence (submitted_by_user_id, submitted_at desc);

create index financial_evidence_supersedes
  on evidence.financial_evidence (supersedes_evidence_id)
  where supersedes_evidence_id is not null;

create table financial_ops.payout_completion_assertions (
  id uuid primary key default extensions.gen_random_uuid(),
  withdrawal_id uuid not null
    references financial_ops.withdrawal_requests (id) on delete restrict,
  assertion_number smallint not null check (assertion_number > 0),
  status financial_ops.payout_assertion_status not null default 'submitted',
  current_revision_number smallint not null default 1
    check (current_revision_number in (1, 2)),
  submitted_by_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  submitted_at timestamptz not null default clock_timestamp(),
  accepted_via financial_ops.payout_resolution,
  accepted_at timestamptz,
  posted_financial_transaction_id uuid unique
    references ledger.financial_transactions (id) on delete restrict,
  version bigint not null default 0 check (version >= 0),
  updated_at timestamptz not null default clock_timestamp(),
  unique (withdrawal_id, assertion_number),
  check (updated_at >= submitted_at),
  check (
    (status = 'posted'
      and accepted_via is not null
      and accepted_at is not null
      and posted_financial_transaction_id is not null)
    or (status <> 'posted'
      and accepted_via is null
      and accepted_at is null
      and posted_financial_transaction_id is null)
  )
);

create unique index payout_assertions_one_open_per_withdrawal
  on financial_ops.payout_completion_assertions (withdrawal_id)
  where status in ('submitted', 'correction_required', 'needs_review');

create index payout_assertions_withdrawal_created
  on financial_ops.payout_completion_assertions (
    withdrawal_id,
    assertion_number desc
  );

create index payout_assertions_submitter
  on financial_ops.payout_completion_assertions (
    submitted_by_user_id,
    submitted_at desc
  );

create table financial_ops.payout_assertion_revisions (
  id uuid primary key default extensions.gen_random_uuid(),
  payout_assertion_id uuid not null
    references financial_ops.payout_completion_assertions (id) on delete restrict,
  revision_number smallint not null check (revision_number in (1, 2)),
  wallet_debit_amount numeric(38, 18) not null
    check (wallet_debit_amount > 0),
  beneficiary_payout_amount numeric(38, 18) not null
    check (beneficiary_payout_amount > 0),
  payout_currency text not null
    references ledger.currency_definitions (currency_code) on delete restrict,
  provider_fee_amount numeric(38, 18) not null default 0
    check (provider_fee_amount >= 0),
  provider_fee_currency text
    references ledger.currency_definitions (currency_code) on delete restrict,
  provider text not null check (length(btrim(provider)) > 0),
  provider_reference text,
  paid_at timestamptz not null,
  notes text,
  submitted_by_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  unique (payout_assertion_id, revision_number),
  check (
    (provider_fee_amount = 0 and provider_fee_currency is null)
    or (provider_fee_amount > 0 and provider_fee_currency is not null)
  ),
  check (provider_reference is null or length(btrim(provider_reference)) > 0),
  check (notes is null or length(btrim(notes)) > 0)
);

create index payout_assertion_revisions_currency
  on financial_ops.payout_assertion_revisions (payout_currency);

create index payout_assertion_revisions_fee_currency
  on financial_ops.payout_assertion_revisions (provider_fee_currency)
  where provider_fee_currency is not null;

create index payout_assertion_revisions_submitter
  on financial_ops.payout_assertion_revisions (submitted_by_user_id);

create table financial_ops.payout_assertion_evidence (
  payout_assertion_revision_id uuid not null
    references financial_ops.payout_assertion_revisions (id) on delete restrict,
  evidence_id uuid not null
    references evidence.financial_evidence (id) on delete restrict,
  linked_at timestamptz not null default clock_timestamp(),
  primary key (payout_assertion_revision_id, evidence_id)
);

create index payout_assertion_evidence_evidence_id
  on financial_ops.payout_assertion_evidence (evidence_id);

create table evidence.verification_attempts (
  id uuid primary key default extensions.gen_random_uuid(),
  verification_request_id uuid not null unique,
  payout_assertion_revision_id uuid not null unique
    references financial_ops.payout_assertion_revisions (id) on delete restrict,
  request_fingerprint bytea not null
    check (octet_length(request_fingerprint) = 32),
  outcome evidence.verification_outcome not null,
  extracted_facts jsonb not null
    check (jsonb_typeof(extracted_facts) = 'object'),
  mismatch_reasons jsonb not null
    check (jsonb_typeof(mismatch_reasons) = 'array'),
  verifier_name text not null check (length(btrim(verifier_name)) > 0),
  verifier_version text,
  created_at timestamptz not null default clock_timestamp(),
  check (verifier_version is null or length(btrim(verifier_version)) > 0),
  check (
    (outcome = 'match' and jsonb_array_length(mismatch_reasons) = 0)
    or (outcome = 'mismatch' and jsonb_array_length(mismatch_reasons) > 0)
  )
);

create index verification_attempts_created
  on evidence.verification_attempts (created_at desc);

create table evidence.review_decisions (
  id uuid primary key default extensions.gen_random_uuid(),
  payout_assertion_id uuid not null unique
    references financial_ops.payout_completion_assertions (id) on delete restrict,
  reviewer_assignment_id uuid not null
    references authz.financial_evidence_reviewer_assignments (id) on delete restrict,
  reviewer_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  decision evidence.review_decision not null,
  review_note text not null check (length(btrim(review_note)) > 0),
  decided_at timestamptz not null default clock_timestamp()
);

create index review_decisions_assignment
  on evidence.review_decisions (reviewer_assignment_id, decided_at desc);

create index review_decisions_reviewer
  on evidence.review_decisions (reviewer_user_id, decided_at desc);

create table financial_ops.payout_command_idempotency (
  idempotency_key uuid primary key,
  command_type text not null check (command_type in (
    'submit_payout_assertion',
    'correct_payout_assertion',
    'review_payout_assertion'
  )),
  request_fingerprint bytea not null
    check (octet_length(request_fingerprint) = 32),
  payout_assertion_id uuid not null
    references financial_ops.payout_completion_assertions (id) on delete restrict,
  actor_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  result_assertion_status financial_ops.payout_assertion_status not null,
  result_withdrawal_status financial_ops.withdrawal_status not null,
  created_at timestamptz not null default clock_timestamp()
);

create index payout_command_idempotency_assertion
  on financial_ops.payout_command_idempotency (
    payout_assertion_id,
    created_at
  );

create index payout_command_idempotency_actor
  on financial_ops.payout_command_idempotency (
    actor_user_id,
    created_at desc
  );

create table internal.outbox_events (
  id uuid primary key default extensions.gen_random_uuid(),
  tenant_id uuid references public.tenants (id) on delete restrict,
  aggregate_type text not null
    check (aggregate_type ~ '^[a-z][a-z0-9_]*$'),
  aggregate_id uuid not null,
  event_type text not null check (event_type ~ '^[a-z][a-z0-9_]*$'),
  payload jsonb not null default '{}'::jsonb
    check (jsonb_typeof(payload) = 'object'),
  occurred_at timestamptz not null default clock_timestamp(),
  available_at timestamptz not null default clock_timestamp()
);

create index outbox_events_available
  on internal.outbox_events (available_at, occurred_at, id);

create index outbox_events_tenant_occurred
  on internal.outbox_events (tenant_id, occurred_at desc)
  where tenant_id is not null;

create index outbox_events_aggregate
  on internal.outbox_events (aggregate_type, aggregate_id, occurred_at);

create or replace function authz.validate_financial_evidence_reviewer_assignment()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  reviewer_membership public.memberships%rowtype;
begin
  if tg_op = 'INSERT' then
    select *
      into reviewer_membership
      from public.memberships membership
     where membership.tenant_id = new.tenant_id
       and membership.id = new.reviewer_membership_id;

    if reviewer_membership.id is null
       or reviewer_membership.user_id <> new.reviewer_user_id
       or reviewer_membership.status <> 'active' then
      raise exception using
        errcode = '23514',
        message = 'financial evidence reviewer requires an active tenant membership';
    end if;

    if not exists (
      select 1
        from public.memberships membership
       where membership.tenant_id = new.tenant_id
         and membership.user_id = new.assigned_by_user_id
         and membership.role_key = 'president_team_member'
         and membership.status = 'active'
    ) then
      raise exception using
        errcode = '42501',
        message = 'financial evidence reviewers are configured by the active President';
    end if;

    return new;
  end if;

  if current_setting('authz.reviewer_assignment_transition', true)
       is distinct from old.id::text
     or old.revoked_at is not null
     or new.id is distinct from old.id
     or new.tenant_id is distinct from old.tenant_id
     or new.reviewer_membership_id is distinct from old.reviewer_membership_id
     or new.reviewer_user_id is distinct from old.reviewer_user_id
     or new.assigned_by_user_id is distinct from old.assigned_by_user_id
     or new.assigned_at is distinct from old.assigned_at
     or new.revoked_at is null
     or new.revoked_by_user_id is null then
    raise exception using
      errcode = '55000',
      message = 'financial evidence reviewer assignment may only change through a trusted command';
  end if;

  return new;
end;
$$;

create trigger financial_evidence_reviewer_assignments_validate
  before insert or update on authz.financial_evidence_reviewer_assignments
  for each row execute function authz.validate_financial_evidence_reviewer_assignment();

create or replace function financial_ops.validate_payout_completion_assertion()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
begin
  if tg_op = 'INSERT' then
    select *
      into target_withdrawal
      from financial_ops.withdrawal_requests withdrawal
     where withdrawal.id = new.withdrawal_id;

    if target_withdrawal.id is null
       or target_withdrawal.status <> 'approved'
       or target_withdrawal.approved_by_user_id <> new.submitted_by_user_id then
      raise exception using
        errcode = '23514',
        message = 'payout assertion must belong to an approved withdrawal and its approving actor';
    end if;

    return new;
  end if;

  if current_setting('financial_ops.payout_assertion_transition', true)
       is distinct from old.id::text
     or new.id is distinct from old.id
     or new.withdrawal_id is distinct from old.withdrawal_id
     or new.assertion_number is distinct from old.assertion_number
     or new.submitted_by_user_id is distinct from old.submitted_by_user_id
     or new.submitted_at is distinct from old.submitted_at
     or new.version <> old.version + 1
     or not (
       (old.status = 'submitted'
         and new.status in ('correction_required', 'needs_review', 'posted'))
       or (old.status = 'correction_required'
         and new.status = 'submitted'
         and old.current_revision_number = 1
         and new.current_revision_number = 2)
       or (old.status = 'needs_review'
         and new.status in ('rejected', 'posted'))
     ) then
    raise exception using
      errcode = '55000',
      message = 'payout assertion lifecycle may only change through a trusted command';
  end if;

  new.updated_at := clock_timestamp();
  return new;
end;
$$;

create trigger payout_completion_assertions_validate
  before insert or update on financial_ops.payout_completion_assertions
  for each row execute function financial_ops.validate_payout_completion_assertion();

create or replace function financial_ops.validate_payout_assertion_revision()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_assertion financial_ops.payout_completion_assertions%rowtype;
begin
  select *
    into target_assertion
    from financial_ops.payout_completion_assertions assertion
   where assertion.id = new.payout_assertion_id;

  if target_assertion.id is null
     or new.submitted_by_user_id <> target_assertion.submitted_by_user_id
     or not (
       (new.revision_number = 1
         and target_assertion.status = 'submitted'
         and target_assertion.current_revision_number = 1)
       or (new.revision_number = 2
         and target_assertion.status = 'correction_required'
         and target_assertion.current_revision_number = 1)
     ) then
    raise exception using
      errcode = '23514',
      message = 'payout assertion revision does not match its trusted lifecycle';
  end if;

  return new;
end;
$$;

create trigger payout_assertion_revisions_validate
  before insert on financial_ops.payout_assertion_revisions
  for each row execute function financial_ops.validate_payout_assertion_revision();

create or replace function financial_ops.validate_payout_evidence_link()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  assertion_tenant_id uuid;
  evidence_tenant_id uuid;
begin
  select withdrawal.tenant_id
    into assertion_tenant_id
    from financial_ops.payout_assertion_revisions revision
    join financial_ops.payout_completion_assertions assertion
      on assertion.id = revision.payout_assertion_id
    join financial_ops.withdrawal_requests withdrawal
      on withdrawal.id = assertion.withdrawal_id
   where revision.id = new.payout_assertion_revision_id;

  select item.tenant_id
    into evidence_tenant_id
    from evidence.financial_evidence item
   where item.id = new.evidence_id;

  if assertion_tenant_id is null
     or evidence_tenant_id is null
     or assertion_tenant_id <> evidence_tenant_id then
    raise exception using
      errcode = '23514',
      message = 'payout evidence must remain inside the assertion tenant';
  end if;

  return new;
end;
$$;

create trigger payout_assertion_evidence_validate
  before insert on financial_ops.payout_assertion_evidence
  for each row execute function financial_ops.validate_payout_evidence_link();

create or replace function evidence.prevent_evidence_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception using
    errcode = '55000',
    message = format('%I.%I is append-only', tg_table_schema, tg_table_name);
end;
$$;

create trigger financial_evidence_prevent_mutation
  before update or delete on evidence.financial_evidence
  for each row execute function evidence.prevent_evidence_mutation();

create trigger payout_assertion_revisions_prevent_mutation
  before update or delete on financial_ops.payout_assertion_revisions
  for each row execute function evidence.prevent_evidence_mutation();

create trigger payout_assertion_evidence_prevent_mutation
  before update or delete on financial_ops.payout_assertion_evidence
  for each row execute function evidence.prevent_evidence_mutation();

create trigger verification_attempts_prevent_mutation
  before update or delete on evidence.verification_attempts
  for each row execute function evidence.prevent_evidence_mutation();

create trigger review_decisions_prevent_mutation
  before update or delete on evidence.review_decisions
  for each row execute function evidence.prevent_evidence_mutation();

create trigger payout_command_idempotency_prevent_mutation
  before update or delete on financial_ops.payout_command_idempotency
  for each row execute function evidence.prevent_evidence_mutation();

create trigger outbox_events_prevent_mutation
  before update or delete on internal.outbox_events
  for each row execute function evidence.prevent_evidence_mutation();

create or replace function financial_ops.guard_withdrawal_payout_cancellation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if old.status = 'approved'
     and new.status = 'cancelled'
     and exists (
       select 1
         from financial_ops.payout_completion_assertions assertion
        where assertion.withdrawal_id = old.id
          and assertion.status in ('submitted', 'correction_required', 'needs_review')
     ) then
    raise exception using
      errcode = '55000',
      message = 'withdrawal cannot be cancelled while payout evidence is unresolved';
  end if;

  return new;
end;
$$;

create trigger withdrawal_requests_guard_payout_cancellation
  before update on financial_ops.withdrawal_requests
  for each row execute function financial_ops.guard_withdrawal_payout_cancellation();

create trigger reviewer_assignments_prevent_delete
  before delete on authz.financial_evidence_reviewer_assignments
  for each row execute function evidence.prevent_evidence_mutation();

alter table authz.financial_evidence_reviewer_assignments enable row level security;
alter table evidence.financial_evidence enable row level security;
alter table financial_ops.payout_completion_assertions enable row level security;
alter table financial_ops.payout_assertion_revisions enable row level security;
alter table financial_ops.payout_assertion_evidence enable row level security;
alter table evidence.verification_attempts enable row level security;
alter table evidence.review_decisions enable row level security;
alter table financial_ops.payout_command_idempotency enable row level security;
alter table internal.outbox_events enable row level security;

alter table authz.financial_evidence_reviewer_assignments force row level security;
alter table evidence.financial_evidence force row level security;
alter table financial_ops.payout_completion_assertions force row level security;
alter table financial_ops.payout_assertion_revisions force row level security;
alter table financial_ops.payout_assertion_evidence force row level security;
alter table evidence.verification_attempts force row level security;
alter table evidence.review_decisions force row level security;
alter table financial_ops.payout_command_idempotency force row level security;
alter table internal.outbox_events force row level security;

revoke all on schema evidence from public, anon, authenticated, service_role;
revoke all on schema internal from public, anon, authenticated, service_role;
revoke all on authz.financial_evidence_reviewer_assignments
  from public, anon, authenticated, service_role;
revoke all on all tables in schema evidence
  from public, anon, authenticated, service_role;
revoke all on all sequences in schema evidence
  from public, anon, authenticated, service_role;
revoke all on all functions in schema evidence
  from public, anon, authenticated, service_role;
revoke all on all tables in schema internal
  from public, anon, authenticated, service_role;
revoke all on all sequences in schema internal
  from public, anon, authenticated, service_role;
revoke all on all functions in schema internal
  from public, anon, authenticated, service_role;

alter default privileges in schema evidence
  revoke all on tables from public, anon, authenticated, service_role;
alter default privileges in schema evidence
  revoke all on sequences from public, anon, authenticated, service_role;
alter default privileges in schema evidence
  revoke execute on functions from public, anon, authenticated, service_role;
alter default privileges in schema internal
  revoke all on tables from public, anon, authenticated, service_role;
alter default privileges in schema internal
  revoke all on sequences from public, anon, authenticated, service_role;
alter default privileges in schema internal
  revoke execute on functions from public, anon, authenticated, service_role;

revoke all on function authz.validate_financial_evidence_reviewer_assignment()
  from public, anon, authenticated, service_role;
revoke all on function financial_ops.validate_payout_completion_assertion()
  from public, anon, authenticated, service_role;
revoke all on function financial_ops.validate_payout_assertion_revision()
  from public, anon, authenticated, service_role;
revoke all on function financial_ops.validate_payout_evidence_link()
  from public, anon, authenticated, service_role;
revoke all on function evidence.prevent_evidence_mutation()
  from public, anon, authenticated, service_role;
revoke all on function financial_ops.guard_withdrawal_payout_cancellation()
  from public, anon, authenticated, service_role;
