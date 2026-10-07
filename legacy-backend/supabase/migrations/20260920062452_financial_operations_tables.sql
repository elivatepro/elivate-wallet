create type financial_ops.evidence_operation_status as enum (
  'submitted',
  'correction_required',
  'needs_review',
  'rejected',
  'posted'
);

create type financial_ops.evidence_operation_resolution as enum (
  'automated_match',
  'manual_clear'
);

create type financial_ops.pocket_transfer_status as enum (
  'requested',
  'approved',
  'rejected',
  'cancelled'
);

create type financial_ops.adjustment_direction as enum ('credit', 'debit');

create type financial_ops.financial_operation_result as (
  operation_id uuid,
  operation_reference text,
  status text,
  financial_transaction_id uuid,
  reused boolean
);

create or replace function financial_ops.generate_operation_reference(
  p_prefix text
)
returns text
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  if p_prefix is null or p_prefix !~ '^[A-Z]{2,4}$' then
    raise exception using
      errcode = '22023',
      message = 'financial operation reference prefix is invalid';
  end if;

  return p_prefix || '-'
    || upper(substr(encode(extensions.gen_random_bytes(10), 'hex'), 1, 16));
end;
$$;

-- Frozen authorization semantics: adjustments and reversals require fresh
-- elevation. The reversal command separately consumes a target-specific,
-- one-time action confirmation for the transaction being reversed.
update authz.permission_catalog
   set step_up_mode = 'elevated'
 where permission_key = 'manual_credit_debit_adjustment';

update authz.permission_catalog
   set step_up_mode = 'elevated'
 where permission_key = 'reverse_transaction';

create table financial_ops.tenant_financial_settings (
  tenant_id uuid primary key references public.tenants (id) on delete restrict,
  adjustment_evidence_required boolean not null default true,
  version bigint not null default 0 check (version >= 0),
  updated_by_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  updated_at timestamptz not null default clock_timestamp()
);

create index tenant_financial_settings_updated_by
  on financial_ops.tenant_financial_settings (updated_by_user_id);

create table financial_ops.income_records (
  id uuid primary key default extensions.gen_random_uuid(),
  operation_reference text not null unique
    default financial_ops.generate_operation_reference('INC'),
  idempotency_key uuid not null unique,
  request_fingerprint bytea not null check (octet_length(request_fingerprint) = 32),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  office_id uuid not null,
  membership_id uuid not null,
  wallet_id uuid not null references public.wallets (id) on delete restrict,
  owner_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  currency_code text not null
    references ledger.currency_definitions (currency_code) on delete restrict,
  gross_amount numeric(38, 18) not null check (gross_amount > 0),
  allocation_policy_version_id uuid not null,
  recorded_by_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  financial_transaction_id uuid not null unique
    references ledger.financial_transactions (id) on delete restrict,
  recorded_at timestamptz not null default clock_timestamp(),
  foreign key (tenant_id, office_id)
    references public.offices (tenant_id, id) on delete restrict,
  foreign key (tenant_id, membership_id)
    references public.memberships (tenant_id, id) on delete restrict,
  foreign key (tenant_id, allocation_policy_version_id)
    references public.allocation_policy_versions (tenant_id, id) on delete restrict
);

create index income_records_tenant_recorded
  on financial_ops.income_records (tenant_id, recorded_at desc);
create index income_records_wallet_recorded
  on financial_ops.income_records (wallet_id, recorded_at desc);
create index income_records_membership
  on financial_ops.income_records (membership_id);
create index income_records_recorded_by
  on financial_ops.income_records (recorded_by_user_id);

create table financial_ops.income_allocations (
  income_record_id uuid not null
    references financial_ops.income_records (id) on delete restrict,
  ledger_account_id uuid not null
    references ledger.ledger_accounts (id) on delete restrict,
  pocket_key text not null
    references public.pocket_definitions (pocket_key) on delete restrict,
  allocation_basis_points integer not null
    check (allocation_basis_points between 1 and 10000),
  remainder_rank smallint not null check (remainder_rank > 0),
  allocated_amount numeric(38, 18) not null check (allocated_amount >= 0),
  primary key (income_record_id, pocket_key),
  unique (income_record_id, ledger_account_id),
  unique (income_record_id, remainder_rank)
);

create index income_allocations_account
  on financial_ops.income_allocations (ledger_account_id);

create table financial_ops.pocket_transfer_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  operation_reference text not null unique
    default financial_ops.generate_operation_reference('PTR'),
  idempotency_key uuid not null unique,
  request_fingerprint bytea not null check (octet_length(request_fingerprint) = 32),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  office_id uuid not null,
  membership_id uuid not null,
  wallet_id uuid not null references public.wallets (id) on delete restrict,
  owner_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  source_ledger_account_id uuid not null
    references ledger.ledger_accounts (id) on delete restrict,
  destination_ledger_account_id uuid not null
    references ledger.ledger_accounts (id) on delete restrict,
  currency_code text not null
    references ledger.currency_definitions (currency_code) on delete restrict,
  amount numeric(38, 18) not null check (amount > 0),
  requested_by_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  status financial_ops.pocket_transfer_status not null default 'requested',
  approved_by_user_id uuid references public.user_accounts (user_id) on delete restrict,
  approved_at timestamptz,
  rejected_by_user_id uuid references public.user_accounts (user_id) on delete restrict,
  rejected_at timestamptz,
  rejection_reason text,
  cancelled_by_user_id uuid references public.user_accounts (user_id) on delete restrict,
  cancelled_at timestamptz,
  cancellation_reason text,
  financial_transaction_id uuid unique
    references ledger.financial_transactions (id) on delete restrict,
  version bigint not null default 0 check (version >= 0),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  foreign key (tenant_id, office_id)
    references public.offices (tenant_id, id) on delete restrict,
  foreign key (tenant_id, membership_id)
    references public.memberships (tenant_id, id) on delete restrict,
  check (source_ledger_account_id <> destination_ledger_account_id),
  check (updated_at >= created_at),
  check (
    (status = 'requested' and approved_by_user_id is null and approved_at is null
      and rejected_by_user_id is null and rejected_at is null and rejection_reason is null
      and cancelled_by_user_id is null and cancelled_at is null and cancellation_reason is null
      and financial_transaction_id is null)
    or (status = 'approved' and approved_by_user_id is not null and approved_at is not null
      and rejected_by_user_id is null and rejected_at is null and rejection_reason is null
      and cancelled_by_user_id is null and cancelled_at is null and cancellation_reason is null
      and financial_transaction_id is not null)
    or (status = 'rejected' and approved_by_user_id is null and approved_at is null
      and rejected_by_user_id is not null and rejected_at is not null
      and length(btrim(rejection_reason)) > 0
      and cancelled_by_user_id is null and cancelled_at is null and cancellation_reason is null
      and financial_transaction_id is null)
    or (status = 'cancelled' and approved_by_user_id is null and approved_at is null
      and rejected_by_user_id is null and rejected_at is null and rejection_reason is null
      and cancelled_by_user_id is not null and cancelled_at is not null
      and length(btrim(cancellation_reason)) > 0
      and financial_transaction_id is null)
  )
);

create index pocket_transfers_tenant_created
  on financial_ops.pocket_transfer_requests (tenant_id, created_at desc);
create index pocket_transfers_wallet_created
  on financial_ops.pocket_transfer_requests (wallet_id, created_at desc);
create index pocket_transfers_status_created
  on financial_ops.pocket_transfer_requests (status, created_at)
  where status = 'requested';
create index pocket_transfers_requested_by
  on financial_ops.pocket_transfer_requests (requested_by_user_id);
create index pocket_transfers_approved_by
  on financial_ops.pocket_transfer_requests (approved_by_user_id)
  where approved_by_user_id is not null;
create index pocket_transfers_rejected_by
  on financial_ops.pocket_transfer_requests (rejected_by_user_id)
  where rejected_by_user_id is not null;
create index pocket_transfers_cancelled_by
  on financial_ops.pocket_transfer_requests (cancelled_by_user_id)
  where cancelled_by_user_id is not null;
create index pocket_transfers_source_account
  on financial_ops.pocket_transfer_requests (source_ledger_account_id);
create index pocket_transfers_destination_account
  on financial_ops.pocket_transfer_requests (destination_ledger_account_id);

create table financial_ops.pocket_transfer_reservations (
  pocket_transfer_id uuid primary key
    references financial_ops.pocket_transfer_requests (id) on delete restrict,
  ledger_account_id uuid not null
    references ledger.ledger_accounts (id) on delete restrict,
  amount numeric(38, 18) not null check (amount > 0),
  status financial_ops.reservation_status not null default 'active',
  created_at timestamptz not null default clock_timestamp(),
  consumed_at timestamptz,
  released_at timestamptz,
  release_reason text,
  check (
    (status = 'active' and consumed_at is null and released_at is null and release_reason is null)
    or (status = 'consumed' and consumed_at is not null and released_at is null and release_reason is null)
    or (status = 'released' and consumed_at is null and released_at is not null
      and length(btrim(release_reason)) > 0)
  )
);

create index pocket_transfer_reservations_active_account
  on financial_ops.pocket_transfer_reservations (ledger_account_id)
  where status = 'active';

create table financial_ops.currency_conversions (
  id uuid primary key default extensions.gen_random_uuid(),
  operation_reference text not null unique
    default financial_ops.generate_operation_reference('FX'),
  idempotency_key uuid not null unique,
  request_fingerprint bytea not null check (octet_length(request_fingerprint) = 32),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  office_id uuid not null,
  membership_id uuid not null,
  wallet_id uuid not null references public.wallets (id) on delete restrict,
  owner_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  source_ledger_account_id uuid not null references ledger.ledger_accounts (id) on delete restrict,
  destination_ledger_account_id uuid not null references ledger.ledger_accounts (id) on delete restrict,
  withdrawal_id uuid references financial_ops.withdrawal_requests (id) on delete restrict,
  status financial_ops.evidence_operation_status not null default 'submitted',
  current_revision_number smallint not null default 1 check (current_revision_number in (1, 2)),
  submitted_by_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  submitted_at timestamptz not null default clock_timestamp(),
  accepted_via financial_ops.evidence_operation_resolution,
  accepted_at timestamptz,
  posted_financial_transaction_id uuid unique
    references ledger.financial_transactions (id) on delete restrict,
  version bigint not null default 0 check (version >= 0),
  updated_at timestamptz not null default clock_timestamp(),
  foreign key (tenant_id, office_id)
    references public.offices (tenant_id, id) on delete restrict,
  foreign key (tenant_id, membership_id)
    references public.memberships (tenant_id, id) on delete restrict,
  check (source_ledger_account_id <> destination_ledger_account_id),
  check (updated_at >= submitted_at),
  check (
    (status = 'posted' and accepted_via is not null and accepted_at is not null
      and posted_financial_transaction_id is not null)
    or (status <> 'posted' and accepted_via is null and accepted_at is null
      and posted_financial_transaction_id is null)
  )
);

create index currency_conversions_tenant_submitted
  on financial_ops.currency_conversions (tenant_id, submitted_at desc);
create index currency_conversions_wallet_submitted
  on financial_ops.currency_conversions (wallet_id, submitted_at desc);
create index currency_conversions_open
  on financial_ops.currency_conversions (status, submitted_at)
  where status in ('submitted', 'correction_required', 'needs_review');
create index currency_conversions_withdrawal
  on financial_ops.currency_conversions (withdrawal_id)
  where withdrawal_id is not null;
create index currency_conversions_source_account
  on financial_ops.currency_conversions (source_ledger_account_id);
create index currency_conversions_destination_account
  on financial_ops.currency_conversions (destination_ledger_account_id);
create index currency_conversions_submitter
  on financial_ops.currency_conversions (submitted_by_user_id);

create table financial_ops.currency_conversion_revisions (
  id uuid primary key default extensions.gen_random_uuid(),
  currency_conversion_id uuid not null
    references financial_ops.currency_conversions (id) on delete restrict,
  revision_number smallint not null check (revision_number in (1, 2)),
  correction_idempotency_key uuid unique,
  source_amount numeric(38, 18) not null check (source_amount > 0),
  destination_amount numeric(38, 18) not null check (destination_amount > 0),
  source_currency_code text not null references ledger.currency_definitions (currency_code) on delete restrict,
  destination_currency_code text not null references ledger.currency_definitions (currency_code) on delete restrict,
  provider_rate numeric(38, 18) check (provider_rate is null or provider_rate > 0),
  effective_rate numeric(38, 18) not null check (effective_rate > 0),
  provider_fee_amount numeric(38, 18) not null default 0 check (provider_fee_amount >= 0),
  provider_fee_currency text references ledger.currency_definitions (currency_code) on delete restrict,
  provider text not null check (length(btrim(provider)) > 0),
  provider_reference text,
  converted_at timestamptz not null,
  notes text,
  submitted_by_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  unique (currency_conversion_id, revision_number),
  check (source_currency_code <> destination_currency_code),
  check ((revision_number = 1 and correction_idempotency_key is null)
    or (revision_number = 2 and correction_idempotency_key is not null)),
  check ((provider_fee_amount = 0 and provider_fee_currency is null)
    or (provider_fee_amount > 0 and provider_fee_currency is not null)),
  check (provider_reference is null or length(btrim(provider_reference)) > 0),
  check (notes is null or length(btrim(notes)) > 0)
);

create index currency_conversion_revisions_submitter
  on financial_ops.currency_conversion_revisions (submitted_by_user_id);
create index currency_conversion_revisions_source_currency
  on financial_ops.currency_conversion_revisions (source_currency_code);
create index currency_conversion_revisions_destination_currency
  on financial_ops.currency_conversion_revisions (destination_currency_code);
create index currency_conversion_revisions_fee_currency
  on financial_ops.currency_conversion_revisions (provider_fee_currency)
  where provider_fee_currency is not null;

create table financial_ops.administrative_adjustments (
  id uuid primary key default extensions.gen_random_uuid(),
  operation_reference text not null unique
    default financial_ops.generate_operation_reference('ADJ'),
  idempotency_key uuid not null unique,
  request_fingerprint bytea not null check (octet_length(request_fingerprint) = 32),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  office_id uuid not null,
  membership_id uuid not null,
  wallet_id uuid not null references public.wallets (id) on delete restrict,
  owner_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  currency_code text not null references ledger.currency_definitions (currency_code) on delete restrict,
  direction financial_ops.adjustment_direction not null,
  amount numeric(38, 18) not null check (amount > 0),
  reason text not null check (length(btrim(reason)) > 0),
  allocation_policy_version_id uuid not null,
  evidence_required boolean not null,
  status financial_ops.evidence_operation_status not null default 'submitted',
  current_revision_number smallint not null default 1 check (current_revision_number in (1, 2)),
  submitted_by_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  submitted_at timestamptz not null default clock_timestamp(),
  accepted_via financial_ops.evidence_operation_resolution,
  accepted_at timestamptz,
  posted_financial_transaction_id uuid unique
    references ledger.financial_transactions (id) on delete restrict,
  version bigint not null default 0 check (version >= 0),
  updated_at timestamptz not null default clock_timestamp(),
  foreign key (tenant_id, office_id)
    references public.offices (tenant_id, id) on delete restrict,
  foreign key (tenant_id, membership_id)
    references public.memberships (tenant_id, id) on delete restrict,
  foreign key (tenant_id, allocation_policy_version_id)
    references public.allocation_policy_versions (tenant_id, id) on delete restrict,
  check (updated_at >= submitted_at),
  check (
    (status = 'posted' and accepted_via is not null and accepted_at is not null
      and posted_financial_transaction_id is not null)
    or (status <> 'posted' and accepted_via is null and accepted_at is null
      and posted_financial_transaction_id is null)
  )
);

create index administrative_adjustments_tenant_submitted
  on financial_ops.administrative_adjustments (tenant_id, submitted_at desc);
create index administrative_adjustments_wallet_submitted
  on financial_ops.administrative_adjustments (wallet_id, submitted_at desc);
create index administrative_adjustments_open
  on financial_ops.administrative_adjustments (status, submitted_at)
  where status in ('submitted', 'correction_required', 'needs_review');
create index administrative_adjustments_submitter
  on financial_ops.administrative_adjustments (submitted_by_user_id);

create table financial_ops.administrative_adjustment_revisions (
  id uuid primary key default extensions.gen_random_uuid(),
  administrative_adjustment_id uuid not null
    references financial_ops.administrative_adjustments (id) on delete restrict,
  revision_number smallint not null check (revision_number in (1, 2)),
  correction_idempotency_key uuid unique,
  submitted_by_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  unique (administrative_adjustment_id, revision_number),
  check ((revision_number = 1 and correction_idempotency_key is null)
    or (revision_number = 2 and correction_idempotency_key is not null))
);

create index administrative_adjustment_revisions_submitter
  on financial_ops.administrative_adjustment_revisions (submitted_by_user_id);

create table financial_ops.administrative_adjustment_lines (
  administrative_adjustment_id uuid not null
    references financial_ops.administrative_adjustments (id) on delete restrict,
  ledger_account_id uuid not null references ledger.ledger_accounts (id) on delete restrict,
  pocket_key text not null references public.pocket_definitions (pocket_key) on delete restrict,
  allocation_basis_points integer not null check (allocation_basis_points between 1 and 10000),
  remainder_rank smallint not null check (remainder_rank > 0),
  amount numeric(38, 18) not null check (amount >= 0),
  primary key (administrative_adjustment_id, pocket_key),
  unique (administrative_adjustment_id, ledger_account_id),
  unique (administrative_adjustment_id, remainder_rank)
);

create index administrative_adjustment_lines_account
  on financial_ops.administrative_adjustment_lines (ledger_account_id);

create table financial_ops.financial_reversals (
  id uuid primary key default extensions.gen_random_uuid(),
  operation_reference text not null unique
    default financial_ops.generate_operation_reference('REV'),
  idempotency_key uuid not null unique,
  request_fingerprint bytea not null check (octet_length(request_fingerprint) = 32),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  original_financial_transaction_id uuid not null
    references ledger.financial_transactions (id) on delete restrict,
  reversal_financial_transaction_id uuid not null unique
    references ledger.financial_transactions (id) on delete restrict,
  reinstates_reversal_id uuid references financial_ops.financial_reversals (id) on delete restrict,
  reason text not null check (length(btrim(reason)) > 0),
  reversed_by_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  reversed_at timestamptz not null default clock_timestamp(),
  check (original_financial_transaction_id <> reversal_financial_transaction_id),
  check (reinstates_reversal_id is null or reinstates_reversal_id <> id)
);

create unique index financial_reversals_one_direct
  on financial_ops.financial_reversals (original_financial_transaction_id)
  where reinstates_reversal_id is null;
create unique index financial_reversals_one_reinstatement
  on financial_ops.financial_reversals (reinstates_reversal_id)
  where reinstates_reversal_id is not null;
create index financial_reversals_tenant_reversed
  on financial_ops.financial_reversals (tenant_id, reversed_at desc);
create index financial_reversals_reversed_by
  on financial_ops.financial_reversals (reversed_by_user_id);

create table financial_ops.returned_funds (
  id uuid primary key default extensions.gen_random_uuid(),
  operation_reference text not null unique
    default financial_ops.generate_operation_reference('RTN'),
  idempotency_key uuid not null unique,
  request_fingerprint bytea not null check (octet_length(request_fingerprint) = 32),
  withdrawal_id uuid not null references financial_ops.withdrawal_requests (id) on delete restrict,
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  office_id uuid not null,
  membership_id uuid not null,
  wallet_id uuid not null references public.wallets (id) on delete restrict,
  owner_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  destination_ledger_account_id uuid not null references ledger.ledger_accounts (id) on delete restrict,
  currency_code text not null references ledger.currency_definitions (currency_code) on delete restrict,
  amount numeric(38, 18) not null check (amount > 0),
  status financial_ops.evidence_operation_status not null default 'submitted',
  current_revision_number smallint not null default 1 check (current_revision_number in (1, 2)),
  submitted_by_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  submitted_at timestamptz not null default clock_timestamp(),
  accepted_via financial_ops.evidence_operation_resolution,
  accepted_at timestamptz,
  posted_financial_transaction_id uuid unique
    references ledger.financial_transactions (id) on delete restrict,
  version bigint not null default 0 check (version >= 0),
  updated_at timestamptz not null default clock_timestamp(),
  foreign key (tenant_id, office_id)
    references public.offices (tenant_id, id) on delete restrict,
  foreign key (tenant_id, membership_id)
    references public.memberships (tenant_id, id) on delete restrict,
  check (updated_at >= submitted_at),
  check (
    (status = 'posted' and accepted_via is not null and accepted_at is not null
      and posted_financial_transaction_id is not null)
    or (status <> 'posted' and accepted_via is null and accepted_at is null
      and posted_financial_transaction_id is null)
  )
);

create index returned_funds_withdrawal_submitted
  on financial_ops.returned_funds (withdrawal_id, submitted_at desc);
create index returned_funds_tenant_submitted
  on financial_ops.returned_funds (tenant_id, submitted_at desc);
create index returned_funds_open
  on financial_ops.returned_funds (status, submitted_at)
  where status in ('submitted', 'correction_required', 'needs_review');
create index returned_funds_destination_account
  on financial_ops.returned_funds (destination_ledger_account_id);
create index returned_funds_submitter
  on financial_ops.returned_funds (submitted_by_user_id);

create table financial_ops.returned_fund_revisions (
  id uuid primary key default extensions.gen_random_uuid(),
  returned_fund_id uuid not null references financial_ops.returned_funds (id) on delete restrict,
  revision_number smallint not null check (revision_number in (1, 2)),
  correction_idempotency_key uuid unique,
  provider text not null check (length(btrim(provider)) > 0),
  provider_reference text,
  returned_at timestamptz not null,
  notes text,
  submitted_by_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  unique (returned_fund_id, revision_number),
  check ((revision_number = 1 and correction_idempotency_key is null)
    or (revision_number = 2 and correction_idempotency_key is not null)),
  check (provider_reference is null or length(btrim(provider_reference)) > 0),
  check (notes is null or length(btrim(notes)) > 0)
);

create index returned_fund_revisions_submitter
  on financial_ops.returned_fund_revisions (submitted_by_user_id);

alter table financial_ops.tenant_financial_settings enable row level security;
alter table financial_ops.income_records enable row level security;
alter table financial_ops.income_allocations enable row level security;
alter table financial_ops.pocket_transfer_requests enable row level security;
alter table financial_ops.pocket_transfer_reservations enable row level security;
alter table financial_ops.currency_conversions enable row level security;
alter table financial_ops.currency_conversion_revisions enable row level security;
alter table financial_ops.administrative_adjustments enable row level security;
alter table financial_ops.administrative_adjustment_revisions enable row level security;
alter table financial_ops.administrative_adjustment_lines enable row level security;
alter table financial_ops.financial_reversals enable row level security;
alter table financial_ops.returned_funds enable row level security;
alter table financial_ops.returned_fund_revisions enable row level security;

alter table financial_ops.tenant_financial_settings force row level security;
alter table financial_ops.income_records force row level security;
alter table financial_ops.income_allocations force row level security;
alter table financial_ops.pocket_transfer_requests force row level security;
alter table financial_ops.pocket_transfer_reservations force row level security;
alter table financial_ops.currency_conversions force row level security;
alter table financial_ops.currency_conversion_revisions force row level security;
alter table financial_ops.administrative_adjustments force row level security;
alter table financial_ops.administrative_adjustment_revisions force row level security;
alter table financial_ops.administrative_adjustment_lines force row level security;
alter table financial_ops.financial_reversals force row level security;
alter table financial_ops.returned_funds force row level security;
alter table financial_ops.returned_fund_revisions force row level security;

revoke all on function financial_ops.generate_operation_reference(text)
  from public, anon, authenticated, service_role;
revoke all on type financial_ops.financial_operation_result
  from public, anon, authenticated, service_role;
revoke all on all tables in schema financial_ops
  from public, anon, authenticated, service_role;
revoke all on all sequences in schema financial_ops
  from public, anon, authenticated, service_role;
