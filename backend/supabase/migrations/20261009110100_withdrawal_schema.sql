-- Blueprint 11 — withdrawals (W-09), payout records and receipt checks
-- (W-10, E-02, E-03), evidence review (W-11) and pocket moves (W-13).
-- Tables, states and guards; commands follow in the next migrations.

-- ── Shared edits ──────────────────────────────────────────────────────────

alter table ledger.transactions drop constraint transactions_type_check;
alter table ledger.transactions add constraint transactions_type_check
  check (type in ('income', 'withdrawal', 'pocket_transfer'));

alter table evidence.files drop constraint files_purpose_check;
alter table evidence.files add constraint files_purpose_check check (purpose in ('income', 'payout'));
alter table evidence.files drop constraint files_attached_type_check;
alter table evidence.files add constraint files_attached_type_check
  check (attached_type in ('income', 'payout'));

alter table audit.tenant_events drop constraint if exists tenant_events_target_type_check;
alter table audit.tenant_events add constraint tenant_events_target_type_check
  check (target_type in (
    'tenant', 'office', 'membership', 'role_permission', 'access_assignment', 'reviewer_assignment',
    'invitation',
    'allocation_policy', 'income', 'evidence',
    'withdrawal', 'payout', 'pocket_transfer'
  ));

create function finance.max_check_attempts() returns int
language sql immutable set search_path = '' as $$ select 6 $$;
create function finance.check_lease() returns interval
language sql immutable set search_path = '' as $$ select interval '120 seconds' $$;
-- Payout dates are calendar dates in Nigeria (owner decision 2026-10-09).
create function finance.payout_zone() returns text
language sql immutable set search_path = '' as $$ select 'Africa/Lagos' $$;

-- ── Withdrawals (W-09) ────────────────────────────────────────────────────

create table finance.withdrawals (
  id uuid primary key,
  reference text not null unique references refs.issued (code) on delete restrict,
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  office_id uuid not null,
  membership_id uuid not null references org.memberships (id) on delete restrict,
  wallet_id uuid not null references ledger.wallets (id) on delete restrict,
  owner_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  account_id uuid not null references ledger.accounts (id) on delete restrict,
  pocket_id uuid not null references ledger.pockets (id) on delete restrict,
  currency text not null check (currency = 'NGN') references ledger.currencies (code) on delete restrict,
  amount numeric(38, 18) not null check (amount > 0),
  payout_account_id uuid not null references payout.accounts (id) on delete restrict,
  -- Destination snapshot, fixed at request time (W-09).
  bank_code text not null,
  bank_name text not null,
  account_last4 text not null check (account_last4 ~ '^[0-9]{4}$'),
  account_ciphertext text not null,
  key_version smallint not null,
  account_name text not null,
  requested_by uuid not null references identity.accounts (user_id) on delete restrict,
  status text not null default 'requested'
    check (status in ('requested', 'approved', 'completed', 'rejected', 'cancelled')),
  reservation_id uuid not null unique references ledger.reservations (id) on delete restrict,
  approved_by uuid references identity.accounts (user_id) on delete restrict,
  approved_at timestamptz,
  decided_by uuid references identity.accounts (user_id) on delete restrict,
  decided_at timestamptz,
  decision_reason text check (decision_reason is null or length(btrim(decision_reason)) between 3 and 500),
  completed_at timestamptz,
  transaction_id uuid unique references ledger.transactions (id) on delete restrict,
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  unique (requested_by, idempotency_key),
  foreign key (tenant_id, office_id) references org.offices (tenant_id, id) on delete restrict,
  check ((approved_by is null) = (approved_at is null)),
  check (status not in ('approved', 'completed') or approved_by is not null),
  check ((status in ('rejected', 'cancelled')) = (decided_at is not null and decided_by is not null)),
  check (status <> 'rejected' or decision_reason is not null),
  check ((status = 'completed') = (completed_at is not null and transaction_id is not null))
);

create index withdrawals_tenant_idx on finance.withdrawals (tenant_id, status, created_at desc, id);
create index withdrawals_owner_idx on finance.withdrawals (owner_user_id, tenant_id, created_at desc, id);
create index withdrawals_membership_idx on finance.withdrawals (membership_id);
create index withdrawals_account_idx on finance.withdrawals (account_id);
create index withdrawals_pocket_idx on finance.withdrawals (pocket_id);
create index withdrawals_payout_account_idx on finance.withdrawals (payout_account_id);
create index withdrawals_wallet_idx on finance.withdrawals (wallet_id);

create function finance.guard_withdrawal()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'requested' then
      perform identity.fail('invariant_violation', jsonb_build_object('table', 'finance.withdrawals'));
    end if;
    new.created_at := now();
    return new;
  end if;
  if not ((old.status = 'requested' and new.status in ('approved', 'rejected', 'cancelled'))
          or (old.status = 'approved' and new.status in ('completed', 'cancelled')))
    or new.id <> old.id or new.reference <> old.reference or new.tenant_id <> old.tenant_id
    or new.office_id <> old.office_id or new.membership_id <> old.membership_id
    or new.wallet_id <> old.wallet_id or new.owner_user_id <> old.owner_user_id
    or new.account_id <> old.account_id or new.pocket_id <> old.pocket_id
    or new.currency <> old.currency or new.amount <> old.amount
    or new.payout_account_id <> old.payout_account_id or new.bank_code <> old.bank_code
    or new.bank_name <> old.bank_name or new.account_last4 <> old.account_last4
    or new.account_ciphertext <> old.account_ciphertext or new.key_version <> old.key_version
    or new.account_name <> old.account_name or new.requested_by <> old.requested_by
    or new.reservation_id <> old.reservation_id or new.idempotency_key <> old.idempotency_key
    or new.created_at <> old.created_at
    or (old.approved_by is not null and (new.approved_by <> old.approved_by or new.approved_at <> old.approved_at)) then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'finance.withdrawals'));
  end if;
  if new.status = 'approved' then
    new.approved_at := now();
  elsif new.status = 'completed' then
    new.completed_at := now();
  else
    new.decided_at := now();
  end if;
  return new;
end;
$$;

create trigger withdrawals_guard
before insert or update on finance.withdrawals
for each row execute function finance.guard_withdrawal();
create trigger withdrawals_no_delete
before delete on finance.withdrawals
for each row execute function audit.reject_change();
create trigger withdrawals_no_truncate before truncate on finance.withdrawals
for each statement execute function audit.reject_change();

-- ── Payout records (W-10) ─────────────────────────────────────────────────

create table finance.payouts (
  id uuid primary key default gen_random_uuid(),
  withdrawal_id uuid not null references finance.withdrawals (id) on delete restrict,
  attempt_no int not null check (attempt_no > 0),
  status text not null default 'verifying'
    check (status in ('verifying', 'correction_required', 'needs_review', 'completed', 'rejected')),
  revision smallint not null default 1 check (revision in (1, 2)),
  submitted_by uuid not null references identity.accounts (user_id) on delete restrict,
  created_at timestamptz not null default now(),
  settled_at timestamptz,
  unique (withdrawal_id, attempt_no),
  check ((status in ('completed', 'rejected')) = (settled_at is not null))
);

-- One open payout record per withdrawal.
create unique index payouts_one_open on finance.payouts (withdrawal_id)
  where status in ('verifying', 'correction_required', 'needs_review');
create index payouts_submitted_idx on finance.payouts (submitted_by);
create index payouts_status_idx on finance.payouts (status, created_at desc);

create function finance.guard_payout()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'verifying' or new.revision <> 1 then
      perform identity.fail('invariant_violation', jsonb_build_object('table', 'finance.payouts'));
    end if;
    new.created_at := now();
    return new;
  end if;
  if not (
      (old.status = 'verifying' and new.status in ('completed', 'correction_required', 'needs_review')
        and new.revision = old.revision)
      or (old.status = 'correction_required' and new.status = 'verifying' and old.revision = 1 and new.revision = 2)
      or (old.status = 'needs_review' and new.status in ('completed', 'rejected') and new.revision = old.revision)
    )
    or (old.status = 'verifying' and new.status = 'correction_required' and old.revision <> 1)
    or (old.status = 'verifying' and new.status = 'needs_review' and old.revision <> 2)
    or new.id <> old.id or new.withdrawal_id <> old.withdrawal_id or new.attempt_no <> old.attempt_no
    or new.submitted_by <> old.submitted_by or new.created_at <> old.created_at then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'finance.payouts'));
  end if;
  if new.status in ('completed', 'rejected') then
    new.settled_at := now();
  end if;
  return new;
end;
$$;

create trigger payouts_guard
before insert or update on finance.payouts
for each row execute function finance.guard_payout();
create trigger payouts_no_delete
before delete on finance.payouts
for each row execute function audit.reject_change();
create trigger payouts_no_truncate before truncate on finance.payouts
for each statement execute function audit.reject_change();

create table finance.payout_revisions (
  id uuid primary key default gen_random_uuid(),
  payout_id uuid not null references finance.payouts (id) on delete restrict,
  revision smallint not null check (revision in (1, 2)),
  amount numeric(38, 18) not null check (amount > 0),
  fee_amount numeric(38, 18) check (fee_amount is null or fee_amount > 0),
  paid_on date not null,
  bank_reference text check (bank_reference is null or length(btrim(bank_reference)) between 1 and 100),
  notes text check (notes is null or length(btrim(notes)) between 1 and 1000),
  evidence_id uuid not null unique references evidence.files (id) on delete restrict,
  submitted_by uuid not null references identity.accounts (user_id) on delete restrict,
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  unique (payout_id, revision),
  unique (submitted_by, idempotency_key)
);

create trigger payout_revisions_immutable
before update or delete on finance.payout_revisions
for each row execute function audit.reject_change();
create trigger payout_revisions_no_truncate before truncate on finance.payout_revisions
for each statement execute function audit.reject_change();

-- ── Receipt checks (E-03), one per revision ───────────────────────────────

create table finance.payout_checks (
  id uuid primary key default gen_random_uuid(),
  payout_id uuid not null references finance.payouts (id) on delete restrict,
  revision_id uuid not null unique references finance.payout_revisions (id) on delete restrict,
  status text not null default 'queued' check (status in ('queued', 'leased', 'done', 'dead', 'obsolete')),
  attempts int not null default 0 check (attempts between 0 and 6),
  cycle int not null default 1 check (cycle > 0),
  next_attempt_at timestamptz,
  lease_token uuid unique,
  lease_expires_at timestamptz,
  last_error text check (last_error is null or last_error ~ '^[a-z_]{2,40}$'),
  outcome text check (outcome in ('match', 'mismatch')),
  facts jsonb,
  reasons text[],
  model text check (model is null or model ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'),
  policy_version text,
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  check ((status = 'queued') = (next_attempt_at is not null)),
  check ((status = 'leased') = (lease_token is not null and lease_expires_at is not null)),
  check ((status = 'done') = (outcome is not null and finished_at is not null)),
  check (outcome is null or (facts is not null and reasons is not null and model is not null and policy_version is not null)),
  check (outcome is null or ((outcome = 'match') = (cardinality(reasons) = 0)))
);

create index payout_checks_ready_idx on finance.payout_checks (next_attempt_at) where status = 'queued';
create index payout_checks_lease_idx on finance.payout_checks (lease_expires_at) where status = 'leased';
create index payout_checks_payout_idx on finance.payout_checks (payout_id);

-- queued → leased → done | queued (retry) | dead; dead → queued (approver
-- requeue, new cycle); queued/leased → obsolete. Done and obsolete are final.
create function finance.guard_payout_check()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'queued' or new.attempts <> 0 or new.outcome is not null then
      perform identity.fail('invariant_violation', jsonb_build_object('table', 'finance.payout_checks'));
    end if;
    new.created_at := now();
    return new;
  end if;
  if not (
      (old.status = 'queued' and new.status in ('leased', 'obsolete'))
      or (old.status = 'leased' and new.status in ('done', 'queued', 'dead', 'obsolete', 'leased'))
      or (old.status = 'dead' and new.status in ('queued', 'obsolete'))
    )
    or new.id <> old.id or new.payout_id <> old.payout_id or new.revision_id <> old.revision_id
    or new.created_at <> old.created_at
    or (old.status = 'dead' and new.status = 'queued' and (new.cycle <> old.cycle + 1 or new.attempts <> 0)) then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'finance.payout_checks'));
  end if;
  if new.status in ('done', 'obsolete', 'dead') then
    new.finished_at := coalesce(new.finished_at, now());
  end if;
  return new;
end;
$$;

create trigger payout_checks_guard
before insert or update on finance.payout_checks
for each row execute function finance.guard_payout_check();
create trigger payout_checks_no_delete
before delete on finance.payout_checks
for each row execute function audit.reject_change();
create trigger payout_checks_no_truncate before truncate on finance.payout_checks
for each statement execute function audit.reject_change();

-- ── Evidence review decisions (W-11) ──────────────────────────────────────

create table finance.payout_reviews (
  payout_id uuid primary key references finance.payouts (id) on delete restrict,
  reviewer_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  reviewer_membership_id uuid not null references org.memberships (id) on delete restrict,
  decision text not null check (decision in ('clear', 'reject')),
  reason text not null check (length(btrim(reason)) between 3 and 500),
  decided_at timestamptz not null default now()
);

create index payout_reviews_reviewer_idx on finance.payout_reviews (reviewer_user_id);
create index payout_reviews_membership_idx on finance.payout_reviews (reviewer_membership_id);

create trigger payout_reviews_immutable
before update or delete on finance.payout_reviews
for each row execute function audit.reject_change();
create trigger payout_reviews_no_truncate before truncate on finance.payout_reviews
for each statement execute function audit.reject_change();

-- ── Pocket moves (W-13) ───────────────────────────────────────────────────

create table finance.pocket_transfers (
  id uuid primary key,
  reference text not null unique references refs.issued (code) on delete restrict,
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  office_id uuid not null,
  membership_id uuid not null references org.memberships (id) on delete restrict,
  wallet_id uuid not null references ledger.wallets (id) on delete restrict,
  owner_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  currency text not null references ledger.currencies (code) on delete restrict,
  source_account_id uuid not null references ledger.accounts (id) on delete restrict,
  destination_account_id uuid not null references ledger.accounts (id) on delete restrict,
  source_pocket_id uuid not null references ledger.pockets (id) on delete restrict,
  destination_pocket_id uuid not null references ledger.pockets (id) on delete restrict,
  amount numeric(38, 18) not null check (amount > 0),
  reservation_id uuid not null unique references ledger.reservations (id) on delete restrict,
  requested_by uuid not null references identity.accounts (user_id) on delete restrict,
  status text not null default 'requested' check (status in ('requested', 'completed', 'rejected', 'cancelled')),
  decided_by uuid references identity.accounts (user_id) on delete restrict,
  decided_at timestamptz,
  decision_reason text check (decision_reason is null or length(btrim(decision_reason)) between 3 and 500),
  transaction_id uuid unique references ledger.transactions (id) on delete restrict,
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  unique (requested_by, idempotency_key),
  foreign key (tenant_id, office_id) references org.offices (tenant_id, id) on delete restrict,
  check (source_account_id <> destination_account_id and source_pocket_id <> destination_pocket_id),
  check ((status = 'requested') = (decided_at is null and decided_by is null)),
  check (status <> 'rejected' or decision_reason is not null),
  check ((status = 'completed') = (transaction_id is not null))
);

create index pocket_transfers_tenant_idx on finance.pocket_transfers (tenant_id, status, created_at desc, id);
create index pocket_transfers_owner_idx on finance.pocket_transfers (owner_user_id, tenant_id, created_at desc, id);
create index pocket_transfers_membership_idx on finance.pocket_transfers (membership_id);
create index pocket_transfers_source_idx on finance.pocket_transfers (source_account_id);
create index pocket_transfers_destination_idx on finance.pocket_transfers (destination_account_id);
create index pocket_transfers_wallet_idx on finance.pocket_transfers (wallet_id);

create function finance.guard_pocket_transfer()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'requested' then
      perform identity.fail('invariant_violation', jsonb_build_object('table', 'finance.pocket_transfers'));
    end if;
    new.created_at := now();
    return new;
  end if;
  if old.status <> 'requested' or new.status = 'requested'
    or new.id <> old.id or new.reference <> old.reference or new.tenant_id <> old.tenant_id
    or new.office_id <> old.office_id or new.membership_id <> old.membership_id
    or new.wallet_id <> old.wallet_id or new.owner_user_id <> old.owner_user_id
    or new.currency <> old.currency or new.source_account_id <> old.source_account_id
    or new.destination_account_id <> old.destination_account_id
    or new.source_pocket_id <> old.source_pocket_id or new.destination_pocket_id <> old.destination_pocket_id
    or new.amount <> old.amount or new.reservation_id <> old.reservation_id
    or new.requested_by <> old.requested_by or new.idempotency_key <> old.idempotency_key
    or new.created_at <> old.created_at then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'finance.pocket_transfers'));
  end if;
  new.decided_at := now();
  return new;
end;
$$;

create trigger pocket_transfers_guard
before insert or update on finance.pocket_transfers
for each row execute function finance.guard_pocket_transfer();
create trigger pocket_transfers_no_delete
before delete on finance.pocket_transfers
for each row execute function audit.reject_change();
create trigger pocket_transfers_no_truncate before truncate on finance.pocket_transfers
for each statement execute function audit.reject_change();

alter table finance.withdrawals enable row level security;
alter table finance.payouts enable row level security;
alter table finance.payout_revisions enable row level security;
alter table finance.payout_checks enable row level security;
alter table finance.payout_reviews enable row level security;
alter table finance.pocket_transfers enable row level security;
