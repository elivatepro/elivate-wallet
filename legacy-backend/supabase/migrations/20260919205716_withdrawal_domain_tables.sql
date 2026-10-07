create schema financial_ops;

create type financial_ops.payout_account_status as enum (
  'active',
  'deactivated',
  'replaced'
);

create type financial_ops.payout_verification_status as enum (
  'pending',
  'verified',
  'rejected'
);

create type financial_ops.withdrawal_status as enum (
  'requested',
  'approved',
  'completed',
  'cancelled',
  'rejected'
);

create type financial_ops.reservation_status as enum (
  'active',
  'consumed',
  'released'
);

create type financial_ops.withdrawal_command_result as (
  withdrawal_id uuid,
  withdrawal_reference text,
  status financial_ops.withdrawal_status,
  reused boolean
);

create or replace function financial_ops.generate_withdrawal_reference()
returns text
language sql
volatile
set search_path = ''
as $$
  select 'WR-' || upper(substr(encode(extensions.gen_random_bytes(10), 'hex'), 1, 16));
$$;

create table financial_ops.payout_accounts (
  id uuid primary key default extensions.gen_random_uuid(),
  wallet_id uuid not null references public.wallets (id) on delete restrict,
  owner_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  country_code text not null check (country_code ~ '^[A-Z]{2}$'),
  payout_currency text not null
    references ledger.currency_definitions (currency_code) on delete restrict,
  payout_rail text not null
    check (payout_rail ~ '^[a-z][a-z0-9_]*$'),
  institution_code text not null check (length(btrim(institution_code)) > 0),
  institution_name text not null check (length(btrim(institution_name)) > 0),
  account_reference text not null check (length(btrim(account_reference)) > 0),
  account_holder_name text not null check (length(btrim(account_holder_name)) > 0),
  verification_status financial_ops.payout_verification_status not null,
  verification_method text,
  provider_metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(provider_metadata) = 'object'),
  verified_at timestamptz,
  is_primary boolean not null default false,
  status financial_ops.payout_account_status not null default 'active',
  replaced_by_account_id uuid
    references financial_ops.payout_accounts (id) on delete restrict,
  deactivated_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  check (
    (verification_status = 'verified'
      and verification_method is not null
      and length(btrim(verification_method)) > 0
      and verified_at is not null)
    or (verification_status <> 'verified' and verified_at is null)
  ),
  check (verified_at is null or verified_at >= created_at),
  check (
    (status = 'active'
      and replaced_by_account_id is null
      and deactivated_at is null)
    or (status = 'deactivated'
      and replaced_by_account_id is null
      and deactivated_at is not null)
    or (status = 'replaced'
      and replaced_by_account_id is not null
      and replaced_by_account_id <> id
      and deactivated_at is not null)
  ),
  check (deactivated_at is null or deactivated_at >= created_at)
);

create unique index payout_accounts_primary_destination
  on financial_ops.payout_accounts (wallet_id, payout_currency, payout_rail)
  where is_primary and status = 'active';

create index payout_accounts_owner_user_id
  on financial_ops.payout_accounts (owner_user_id);

create index payout_accounts_payout_currency
  on financial_ops.payout_accounts (payout_currency);

create index payout_accounts_replaced_by_account_id
  on financial_ops.payout_accounts (replaced_by_account_id)
  where replaced_by_account_id is not null;

create table financial_ops.withdrawal_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  withdrawal_reference text not null unique
    default financial_ops.generate_withdrawal_reference(),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  office_id uuid not null,
  membership_id uuid not null,
  wallet_id uuid not null references public.wallets (id) on delete restrict,
  owner_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  source_ledger_account_id uuid not null
    references ledger.ledger_accounts (id) on delete restrict,
  source_currency_code text not null
    references ledger.currency_definitions (currency_code) on delete restrict,
  source_pocket_key text not null
    references public.pocket_definitions (pocket_key) on delete restrict,
  requested_amount numeric(38, 18) not null check (requested_amount > 0),
  payout_account_id uuid not null
    references financial_ops.payout_accounts (id) on delete restrict,
  initiated_by_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  status financial_ops.withdrawal_status not null default 'requested',
  version bigint not null default 0 check (version >= 0),
  approved_by_user_id uuid
    references public.user_accounts (user_id) on delete restrict,
  approved_at timestamptz,
  rejected_by_user_id uuid
    references public.user_accounts (user_id) on delete restrict,
  rejected_at timestamptz,
  rejection_reason text,
  cancelled_by_user_id uuid
    references public.user_accounts (user_id) on delete restrict,
  cancelled_at timestamptz,
  cancellation_reason text,
  completed_at timestamptz,
  financial_transaction_id uuid unique
    references ledger.financial_transactions (id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  foreign key (tenant_id, office_id)
    references public.offices (tenant_id, id)
    on delete restrict,
  foreign key (tenant_id, membership_id)
    references public.memberships (tenant_id, id)
    on delete restrict,
  check (updated_at >= created_at),
  check (
    (status = 'requested'
      and approved_by_user_id is null and approved_at is null
      and rejected_by_user_id is null and rejected_at is null and rejection_reason is null
      and cancelled_by_user_id is null and cancelled_at is null and cancellation_reason is null
      and completed_at is null and financial_transaction_id is null)
    or (status = 'approved'
      and approved_by_user_id is not null and approved_at is not null
      and rejected_by_user_id is null and rejected_at is null and rejection_reason is null
      and cancelled_by_user_id is null and cancelled_at is null and cancellation_reason is null
      and completed_at is null and financial_transaction_id is null)
    or (status = 'rejected'
      and approved_by_user_id is null and approved_at is null
      and rejected_by_user_id is not null and rejected_at is not null
      and length(btrim(rejection_reason)) > 0
      and cancelled_by_user_id is null and cancelled_at is null and cancellation_reason is null
      and completed_at is null and financial_transaction_id is null)
    or (status = 'cancelled'
      and rejected_by_user_id is null and rejected_at is null and rejection_reason is null
      and cancelled_by_user_id is not null and cancelled_at is not null
      and length(btrim(cancellation_reason)) > 0
      and completed_at is null and financial_transaction_id is null)
    or (status = 'completed'
      and approved_by_user_id is not null and approved_at is not null
      and rejected_by_user_id is null and rejected_at is null and rejection_reason is null
      and cancelled_by_user_id is null and cancelled_at is null and cancellation_reason is null
      and completed_at is not null and financial_transaction_id is not null)
  ),
  check (approved_at is null or approved_at >= created_at),
  check (rejected_at is null or rejected_at >= created_at),
  check (cancelled_at is null or cancelled_at >= created_at),
  check (completed_at is null or completed_at >= created_at)
);

create index withdrawal_requests_tenant_status_created
  on financial_ops.withdrawal_requests (tenant_id, status, created_at desc);

create index withdrawal_requests_tenant_office_status
  on financial_ops.withdrawal_requests (tenant_id, office_id, status);

create index withdrawal_requests_tenant_membership
  on financial_ops.withdrawal_requests (tenant_id, membership_id);

create index withdrawal_requests_wallet_created
  on financial_ops.withdrawal_requests (wallet_id, created_at desc);

create index withdrawal_requests_owner_created
  on financial_ops.withdrawal_requests (owner_user_id, created_at desc);

create index withdrawal_requests_source_ledger_account
  on financial_ops.withdrawal_requests (source_ledger_account_id);

create index withdrawal_requests_source_currency
  on financial_ops.withdrawal_requests (source_currency_code);

create index withdrawal_requests_source_pocket
  on financial_ops.withdrawal_requests (source_pocket_key);

create index withdrawal_requests_payout_account
  on financial_ops.withdrawal_requests (payout_account_id);

create index withdrawal_requests_initiated_by
  on financial_ops.withdrawal_requests (initiated_by_user_id);

create index withdrawal_requests_approved_by
  on financial_ops.withdrawal_requests (approved_by_user_id)
  where approved_by_user_id is not null;

create index withdrawal_requests_rejected_by
  on financial_ops.withdrawal_requests (rejected_by_user_id)
  where rejected_by_user_id is not null;

create index withdrawal_requests_cancelled_by
  on financial_ops.withdrawal_requests (cancelled_by_user_id)
  where cancelled_by_user_id is not null;

create table financial_ops.withdrawal_destination_snapshots (
  withdrawal_id uuid primary key
    references financial_ops.withdrawal_requests (id) on delete restrict,
  source_payout_account_id uuid not null
    references financial_ops.payout_accounts (id) on delete restrict,
  institution_code text not null check (length(btrim(institution_code)) > 0),
  institution_name text not null check (length(btrim(institution_name)) > 0),
  account_reference text not null check (length(btrim(account_reference)) > 0),
  account_holder_name text not null check (length(btrim(account_holder_name)) > 0),
  payout_rail text not null check (payout_rail ~ '^[a-z][a-z0-9_]*$'),
  payout_currency text not null
    references ledger.currency_definitions (currency_code) on delete restrict,
  country_code text not null check (country_code ~ '^[A-Z]{2}$'),
  verification_status financial_ops.payout_verification_status not null,
  verification_method text not null check (length(btrim(verification_method)) > 0),
  snapshotted_at timestamptz not null default clock_timestamp()
);

create index withdrawal_destination_snapshots_source_account
  on financial_ops.withdrawal_destination_snapshots (source_payout_account_id);

create index withdrawal_destination_snapshots_payout_currency
  on financial_ops.withdrawal_destination_snapshots (payout_currency);

create table financial_ops.funding_reservations (
  id uuid primary key default extensions.gen_random_uuid(),
  withdrawal_id uuid not null unique
    references financial_ops.withdrawal_requests (id) on delete restrict,
  ledger_account_id uuid not null
    references ledger.ledger_accounts (id) on delete restrict,
  amount numeric(38, 18) not null check (amount > 0),
  status financial_ops.reservation_status not null default 'active',
  created_at timestamptz not null default clock_timestamp(),
  consumed_at timestamptz,
  released_at timestamptz,
  release_reason text,
  check (
    (status = 'active'
      and consumed_at is null and released_at is null and release_reason is null)
    or (status = 'consumed'
      and consumed_at is not null and released_at is null and release_reason is null)
    or (status = 'released'
      and consumed_at is null and released_at is not null
      and length(btrim(release_reason)) > 0)
  ),
  check (consumed_at is null or consumed_at >= created_at),
  check (released_at is null or released_at >= created_at)
);

create index funding_reservations_active_account
  on financial_ops.funding_reservations (ledger_account_id)
  where status = 'active';

create table financial_ops.withdrawal_command_idempotency (
  idempotency_key uuid primary key,
  command_type text not null
    check (command_type in (
      'submit_withdrawal',
      'approve_withdrawal',
      'reject_withdrawal',
      'cancel_withdrawal'
    )),
  request_fingerprint bytea not null
    check (octet_length(request_fingerprint) = 32),
  withdrawal_id uuid not null
    references financial_ops.withdrawal_requests (id) on delete restrict,
  actor_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  result_status financial_ops.withdrawal_status not null,
  created_at timestamptz not null default clock_timestamp()
);

create index withdrawal_command_idempotency_withdrawal
  on financial_ops.withdrawal_command_idempotency (withdrawal_id, created_at);

create index withdrawal_command_idempotency_actor
  on financial_ops.withdrawal_command_idempotency (actor_user_id, created_at desc);

create or replace function financial_ops.validate_payout_account()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  wallet_owner uuid;
  owner_status public.account_status;
begin
  if tg_op = 'UPDATE' then
    raise exception using
      errcode = '55000',
      message = 'payout-account changes require a trusted lifecycle command';
  end if;

  select w.owner_user_id
    into wallet_owner
    from public.wallets w
   where w.id = new.wallet_id;

  select ua.status
    into owner_status
    from public.user_accounts ua
   where ua.user_id = new.owner_user_id;

  if wallet_owner is null
     or wallet_owner <> new.owner_user_id
     or owner_status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'payout account must match an active Wallet owner';
  end if;

  return new;
end;
$$;

create trigger payout_accounts_validate
  before insert or update on financial_ops.payout_accounts
  for each row execute function financial_ops.validate_payout_account();

create or replace function financial_ops.validate_withdrawal_request()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  source_account ledger.ledger_accounts%rowtype;
  payout_account financial_ops.payout_accounts%rowtype;
begin
  if tg_op = 'INSERT' then
    select *
      into source_account
      from ledger.ledger_accounts la
     where la.id = new.source_ledger_account_id;

    select *
      into payout_account
      from financial_ops.payout_accounts pa
     where pa.id = new.payout_account_id;

    if source_account.id is null
       or source_account.account_class <> 'member_value'
       or source_account.tenant_id <> new.tenant_id
       or source_account.office_id <> new.office_id
       or source_account.membership_id <> new.membership_id
       or source_account.wallet_id <> new.wallet_id
       or source_account.owner_user_id <> new.owner_user_id
       or source_account.currency_code <> new.source_currency_code
       or source_account.pocket_key <> new.source_pocket_key then
      raise exception using
        errcode = '23514',
        message = 'withdrawal source must match authoritative ledger provenance';
    end if;

    if payout_account.id is null
       or payout_account.wallet_id <> new.wallet_id
       or payout_account.owner_user_id <> new.owner_user_id
       or payout_account.status <> 'active'
       or payout_account.verification_status <> 'verified' then
      raise exception using
        errcode = '23514',
        message = 'withdrawal requires an active verified payout destination owned by the Wallet holder';
    end if;

    return new;
  end if;

  if current_setting('financial_ops.withdrawal_transition', true)
       is distinct from old.id::text
     or new.id is distinct from old.id
     or new.withdrawal_reference is distinct from old.withdrawal_reference
     or new.tenant_id is distinct from old.tenant_id
     or new.office_id is distinct from old.office_id
     or new.membership_id is distinct from old.membership_id
     or new.wallet_id is distinct from old.wallet_id
     or new.owner_user_id is distinct from old.owner_user_id
     or new.source_ledger_account_id is distinct from old.source_ledger_account_id
     or new.source_currency_code is distinct from old.source_currency_code
     or new.source_pocket_key is distinct from old.source_pocket_key
     or new.requested_amount is distinct from old.requested_amount
     or new.payout_account_id is distinct from old.payout_account_id
     or new.initiated_by_user_id is distinct from old.initiated_by_user_id
     or new.created_at is distinct from old.created_at
     or new.version <> old.version + 1
     or not (
       (old.status = 'requested' and new.status in ('approved', 'cancelled', 'rejected'))
       or (old.status = 'approved' and new.status in ('completed', 'cancelled'))
     ) then
    raise exception using
      errcode = '55000',
      message = 'withdrawal lifecycle may only change through a trusted command';
  end if;

  new.updated_at := clock_timestamp();
  return new;
end;
$$;

create trigger withdrawal_requests_validate
  before insert or update on financial_ops.withdrawal_requests
  for each row execute function financial_ops.validate_withdrawal_request();

create or replace function financial_ops.validate_funding_reservation()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
begin
  if tg_op = 'INSERT' then
    select *
      into target_withdrawal
      from financial_ops.withdrawal_requests wr
     where wr.id = new.withdrawal_id;

    if target_withdrawal.id is null
       or target_withdrawal.status <> 'requested'
       or target_withdrawal.source_ledger_account_id <> new.ledger_account_id
       or target_withdrawal.requested_amount <> new.amount then
      raise exception using
        errcode = '23514',
        message = 'funding reservation must match its requested withdrawal source and amount';
    end if;

    return new;
  end if;

  if current_setting('financial_ops.reservation_transition', true)
       is distinct from old.id::text
     or new.id is distinct from old.id
     or new.withdrawal_id is distinct from old.withdrawal_id
     or new.ledger_account_id is distinct from old.ledger_account_id
     or new.amount is distinct from old.amount
     or new.created_at is distinct from old.created_at
     or old.status <> 'active'
     or new.status not in ('consumed', 'released') then
    raise exception using
      errcode = '55000',
      message = 'funding reservation may only change through a trusted command';
  end if;

  return new;
end;
$$;

create trigger funding_reservations_validate
  before insert or update on financial_ops.funding_reservations
  for each row execute function financial_ops.validate_funding_reservation();

create or replace function financial_ops.prevent_private_financial_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    errcode = '55000',
    message = format('%I.%I is immutable', tg_table_schema, tg_table_name);
end;
$$;

create trigger payout_accounts_prevent_delete
  before delete on financial_ops.payout_accounts
  for each row execute function financial_ops.prevent_private_financial_delete();

create trigger withdrawal_requests_prevent_delete
  before delete on financial_ops.withdrawal_requests
  for each row execute function financial_ops.prevent_private_financial_delete();

create trigger withdrawal_destination_snapshots_prevent_mutation
  before update or delete on financial_ops.withdrawal_destination_snapshots
  for each row execute function financial_ops.prevent_private_financial_delete();

create trigger funding_reservations_prevent_delete
  before delete on financial_ops.funding_reservations
  for each row execute function financial_ops.prevent_private_financial_delete();

create trigger withdrawal_command_idempotency_prevent_mutation
  before update or delete on financial_ops.withdrawal_command_idempotency
  for each row execute function financial_ops.prevent_private_financial_delete();

alter table financial_ops.payout_accounts enable row level security;
alter table financial_ops.withdrawal_requests enable row level security;
alter table financial_ops.withdrawal_destination_snapshots enable row level security;
alter table financial_ops.funding_reservations enable row level security;
alter table financial_ops.withdrawal_command_idempotency enable row level security;

alter table financial_ops.payout_accounts force row level security;
alter table financial_ops.withdrawal_requests force row level security;
alter table financial_ops.withdrawal_destination_snapshots force row level security;
alter table financial_ops.funding_reservations force row level security;
alter table financial_ops.withdrawal_command_idempotency force row level security;

revoke all on schema financial_ops from public, anon, authenticated, service_role;
revoke all on all tables in schema financial_ops
  from public, anon, authenticated, service_role;
revoke all on all sequences in schema financial_ops
  from public, anon, authenticated, service_role;
revoke all on all functions in schema financial_ops
  from public, anon, authenticated, service_role;

alter default privileges in schema financial_ops
  revoke all on tables from public, anon, authenticated, service_role;
alter default privileges in schema financial_ops
  revoke all on sequences from public, anon, authenticated, service_role;
alter default privileges in schema financial_ops
  revoke execute on functions from public, anon, authenticated, service_role;
