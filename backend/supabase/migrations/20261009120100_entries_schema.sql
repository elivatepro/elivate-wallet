-- Blueprint 12 — conversions (W-12), adjustments (W-14), returned funds
-- (W-16) and reversals (W-15). Tables, states and guards; commands follow.

-- ── Shared edits ──────────────────────────────────────────────────────────

alter table ledger.transactions drop constraint transactions_type_check;
alter table ledger.transactions add constraint transactions_type_check
  check (type in ('income', 'withdrawal', 'pocket_transfer', 'conversion', 'adjustment', 'returned_funds',
                  'reversal'));

alter table ledger.reservations drop constraint reservations_purpose_check;
alter table ledger.reservations add constraint reservations_purpose_check
  check (purpose in ('withdrawal', 'pocket_transfer', 'conversion'));

alter table evidence.files drop constraint files_purpose_check;
alter table evidence.files add constraint files_purpose_check
  check (purpose in ('income', 'payout', 'conversion', 'adjustment', 'returned_funds'));
alter table evidence.files drop constraint files_attached_type_check;
alter table evidence.files add constraint files_attached_type_check
  check (attached_type in ('income', 'payout', 'entry'));

alter table audit.tenant_events drop constraint tenant_events_target_type_check;
alter table audit.tenant_events add constraint tenant_events_target_type_check
  check (target_type in (
    'tenant', 'office', 'membership', 'role_permission', 'access_assignment', 'reviewer_assignment',
    'invitation',
    'allocation_policy', 'income', 'evidence',
    'withdrawal', 'payout', 'pocket_transfer',
    'entry', 'reversal'
  ));

-- The one payout fix may keep the receipt of the first record (Paper U03).
alter table finance.payout_revisions drop constraint payout_revisions_evidence_id_key;
create index payout_revisions_evidence_idx on finance.payout_revisions (evidence_id);

-- ── Evidence-backed entries: conversion, adjustment, returned funds ──────

create table finance.entries (
  id uuid primary key,
  reference text not null unique references refs.issued (code) on delete restrict,
  kind text not null check (kind in ('conversion', 'adjustment', 'returned_funds')),
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  office_id uuid not null,
  membership_id uuid not null references org.memberships (id) on delete restrict,
  wallet_id uuid not null references ledger.wallets (id) on delete restrict,
  owner_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  currency text not null references ledger.currencies (code) on delete restrict,
  amount numeric(38, 18) not null check (amount > 0),
  direction text not null check (direction in ('credit', 'debit')),
  pocket_id uuid references ledger.pockets (id) on delete restrict,
  account_id uuid references ledger.accounts (id) on delete restrict,
  reservation_id uuid unique references ledger.reservations (id) on delete restrict,
  destination_currency text references ledger.currencies (code) on delete restrict,
  destination_amount numeric(38, 18) check (destination_amount is null or destination_amount > 0),
  quoted_rate numeric(38, 18) check (quoted_rate is null or quoted_rate > 0),
  provider text check (provider is null or length(btrim(provider)) between 1 and 100),
  observed_at timestamptz,
  external_reference text check (external_reference is null or length(btrim(external_reference)) between 1 and 100),
  reason text check (reason is null or length(btrim(reason)) between 3 and 500),
  notes text check (notes is null or length(btrim(notes)) between 1 and 1000),
  withdrawal_id uuid references finance.withdrawals (id) on delete restrict,
  policy_id uuid references ledger.allocation_policies (id) on delete restrict,
  status text not null default 'needs_review' check (status in ('needs_review', 'posted', 'rejected')),
  submitted_by uuid not null references identity.accounts (user_id) on delete restrict,
  reviewer_user_id uuid references identity.accounts (user_id) on delete restrict,
  reviewer_membership_id uuid references org.memberships (id) on delete restrict,
  review_reason text check (review_reason is null or length(btrim(review_reason)) between 3 and 500),
  decided_at timestamptz,
  transaction_id uuid unique references ledger.transactions (id) on delete restrict,
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  unique (submitted_by, idempotency_key),
  foreign key (tenant_id, office_id) references org.offices (tenant_id, id) on delete restrict,
  -- Shape per kind.
  check (kind <> 'conversion' or (direction = 'debit' and pocket_id is not null and account_id is not null
    and reservation_id is not null and destination_currency is not null and destination_currency <> currency
    and destination_amount is not null and provider is not null and observed_at is not null
    and withdrawal_id is null and policy_id is null)),
  check (kind <> 'adjustment' or (reason is not null and policy_id is not null and pocket_id is null
    and account_id is null and reservation_id is null and destination_currency is null and withdrawal_id is null)),
  check (kind <> 'returned_funds' or (direction = 'credit' and withdrawal_id is not null and pocket_id is not null
    and account_id is not null and observed_at is not null and reservation_id is null
    and destination_currency is null and policy_id is null)),
  check ((status = 'needs_review') = (decided_at is null and reviewer_user_id is null)),
  check (status = 'needs_review' or (reviewer_membership_id is not null and review_reason is not null)),
  check ((status = 'posted') = (transaction_id is not null))
);

create index entries_tenant_idx on finance.entries (tenant_id, status, created_at desc, id);
create index entries_owner_idx on finance.entries (owner_user_id);
create index entries_membership_idx on finance.entries (membership_id);
create index entries_wallet_idx on finance.entries (wallet_id);
create index entries_withdrawal_idx on finance.entries (withdrawal_id) where withdrawal_id is not null;
create index entries_account_idx on finance.entries (account_id);
create index entries_pocket_idx on finance.entries (pocket_id);
create index entries_policy_idx on finance.entries (policy_id);
create index entries_submitted_idx on finance.entries (submitted_by);
create index entries_reviewer_idx on finance.entries (reviewer_user_id);
create index entries_reviewer_membership_idx on finance.entries (reviewer_membership_id);

-- needs_review → posted | rejected; every fact is fixed at submission.
create function finance.guard_entry()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'needs_review' then
      perform identity.fail('invariant_violation', jsonb_build_object('table', 'finance.entries'));
    end if;
    new.created_at := now();
    return new;
  end if;
  if old.status <> 'needs_review' or new.status = 'needs_review'
    or (new.id, new.reference, new.kind, new.tenant_id, new.office_id, new.membership_id, new.wallet_id,
        new.owner_user_id, new.currency, new.amount, new.direction, new.submitted_by, new.idempotency_key,
        new.created_at)
       is distinct from
       (old.id, old.reference, old.kind, old.tenant_id, old.office_id, old.membership_id, old.wallet_id,
        old.owner_user_id, old.currency, old.amount, old.direction, old.submitted_by, old.idempotency_key,
        old.created_at)
    or (new.pocket_id, new.account_id, new.reservation_id, new.destination_currency, new.destination_amount,
        new.quoted_rate, new.provider, new.observed_at, new.external_reference, new.reason, new.notes,
        new.withdrawal_id, new.policy_id)
       is distinct from
       (old.pocket_id, old.account_id, old.reservation_id, old.destination_currency, old.destination_amount,
        old.quoted_rate, old.provider, old.observed_at, old.external_reference, old.reason, old.notes,
        old.withdrawal_id, old.policy_id) then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'finance.entries'));
  end if;
  new.decided_at := now();
  return new;
end;
$$;

create trigger entries_guard
before insert or update on finance.entries
for each row execute function finance.guard_entry();
create trigger entries_no_delete
before delete on finance.entries
for each row execute function audit.reject_change();
create trigger entries_no_truncate before truncate on finance.entries
for each statement execute function audit.reject_change();

-- The exact adjustment split, fixed at submission (W-14, F-01.6).
create table finance.entry_lines (
  entry_id uuid not null references finance.entries (id) on delete restrict,
  pocket_id uuid not null references ledger.pockets (id) on delete restrict,
  pocket_name text not null,
  sort_order int not null,
  basis_points int not null check (basis_points between 0 and 10000),
  amount numeric(38, 18) not null check (amount >= 0),
  account_id uuid references ledger.accounts (id) on delete restrict,
  primary key (entry_id, pocket_id),
  check ((amount = 0) = (account_id is null))
);

create index entry_lines_pocket_idx on finance.entry_lines (pocket_id);
create index entry_lines_account_idx on finance.entry_lines (account_id);

create trigger entry_lines_immutable
before update or delete on finance.entry_lines
for each row execute function audit.reject_change();
create trigger entry_lines_no_truncate before truncate on finance.entry_lines
for each statement execute function audit.reject_change();

-- ── Reversals (W-15) ──────────────────────────────────────────────────────

create table finance.reversals (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique references refs.issued (code) on delete restrict,
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  original_transaction_id uuid not null unique references ledger.transactions (id) on delete restrict,
  transaction_id uuid not null unique references ledger.transactions (id) on delete restrict,
  category text not null check (category in ('recorded_twice', 'wrong_member', 'wrong_amount', 'wrong_pocket',
                                             'other')),
  note text check (note is null or length(btrim(note)) between 3 and 500),
  reversed_by uuid not null references identity.accounts (user_id) on delete restrict,
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  unique (reversed_by, idempotency_key),
  check (category <> 'other' or note is not null)
);

create index reversals_tenant_idx on finance.reversals (tenant_id, created_at desc);

create trigger reversals_immutable
before update or delete on finance.reversals
for each row execute function audit.reject_change();
create trigger reversals_no_truncate before truncate on finance.reversals
for each statement execute function audit.reject_change();

alter table finance.entries enable row level security;
alter table finance.entry_lines enable row level security;
alter table finance.reversals enable row level security;
