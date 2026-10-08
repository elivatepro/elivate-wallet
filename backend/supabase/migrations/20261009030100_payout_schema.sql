-- Blueprint 05 — B1/B2: payout accounts, the bank list cache and the NUBAN
-- lookup proof. Full account numbers never reach the database: the payout Edge
-- Function stores AES-256-GCM ciphertext, an HMAC fingerprint and the last 4.

create schema payout;
revoke all on schema payout from public, anon, authenticated;

create type payout.lookup_status as enum ('pending', 'resolved', 'not_found');
create type payout.name_match_result as enum ('matched', 'mismatched', 'identity_pending');
create type payout.account_status as enum ('active', 'replaced', 'deactivated');
create type payout.verification_status as enum ('verified', 'pending_verification');
create type payout.verification_method as enum ('nuban_lookup', 'manual');

-- Policy constants (owner decisions 2026-10-08, Q6 and Q9).
create function payout.proof_ttl() returns interval
language sql immutable set search_path = '' as $$ select interval '15 minutes' $$;
create function payout.cooling_off() returns interval
language sql immutable set search_path = '' as $$ select interval '24 hours' $$;
create function payout.lookups_per_hour() returns int
language sql immutable set search_path = '' as $$ select 10 $$;
create function payout.lookups_per_day() returns int
language sql immutable set search_path = '' as $$ select 30 $$;
create function payout.max_active_accounts() returns int
language sql immutable set search_path = '' as $$ select 5 $$;
create function payout.bank_list_ttl() returns interval
language sql immutable set search_path = '' as $$ select interval '24 hours' $$;

-- ── Bank list cache ───────────────────────────────────────────────────────

-- The provider's Nigerian NUBAN banks. Banks that disappear are marked
-- inactive, never deleted, so saved accounts keep their bank.
create table payout.banks (
  provider text not null check (provider in ('paystack')),
  code text not null check (code ~ '^[0-9A-Z]{3,10}$'),
  name text not null check (length(btrim(name)) between 1 and 100),
  slug text check (slug is null or length(slug) <= 100),
  active boolean not null default true,
  refreshed_at timestamptz not null default now(),
  primary key (provider, code)
);

-- ── Payout accounts ───────────────────────────────────────────────────────

create table payout.accounts (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  country_code text not null default 'NG' check (country_code = 'NG'),
  currency text not null default 'NGN' check (currency = 'NGN'),
  rail text not null default 'bank_transfer' check (rail = 'bank_transfer'),
  provider text not null check (provider in ('paystack')),
  bank_code text not null check (bank_code ~ '^[0-9A-Z]{3,10}$'),
  bank_name text not null check (length(btrim(bank_name)) between 1 and 100),
  account_ciphertext text not null check (account_ciphertext ~ '^[A-Za-z0-9+/]{40,200}={0,2}$'),
  key_version smallint not null check (key_version > 0),
  account_fingerprint text not null check (account_fingerprint ~ '^[0-9a-f]{64}$'),
  account_last4 text not null check (account_last4 ~ '^[0-9]{4}$'),
  account_name text not null check (length(btrim(account_name)) between 1 and 160),
  verification_status payout.verification_status not null,
  verification_method payout.verification_method not null,
  lookup_id uuid,
  verified_at timestamptz,
  name_match payout.name_match_result not null,
  name_rule_version text not null,
  name_checked_at timestamptz not null,
  is_primary boolean not null default false,
  status payout.account_status not null default 'active',
  replaces_id uuid references payout.accounts (id) on delete restrict,
  replaced_by_id uuid references payout.accounts (id) on delete restrict,
  usable_from timestamptz not null,
  deactivated_at timestamptz,
  deactivated_reason text check (deactivated_reason is null or length(btrim(deactivated_reason)) between 3 and 500),
  created_at timestamptz not null default now(),
  check ((verification_status = 'verified') = (verified_at is not null)),
  check (verification_method <> 'nuban_lookup' or lookup_id is not null),
  check ((status = 'deactivated') = (deactivated_at is not null)),
  check ((status = 'deactivated') = (deactivated_reason is not null)),
  check ((status = 'replaced') = (replaced_by_id is not null)),
  check (not is_primary or (status = 'active' and verification_status = 'verified' and name_match <> 'mismatched')),
  check (replaces_id is distinct from id and replaced_by_id is distinct from id),
  check (usable_from >= created_at)
);

-- At most one primary per currency and rail (W-17).
create unique index accounts_one_primary
  on payout.accounts (owner_user_id, currency, rail) where is_primary;
-- One active row per bank + number for each person. Different people may save
-- the same account (Q11).
create unique index accounts_one_active_number
  on payout.accounts (owner_user_id, bank_code, account_fingerprint) where status = 'active';
create unique index accounts_one_replacement on payout.accounts (replaces_id) where replaces_id is not null;
create index accounts_owner_idx on payout.accounts (owner_user_id, created_at desc, id);
-- Admin search by bank account (W-23).
create index accounts_fingerprint_idx on payout.accounts (account_fingerprint);
create index accounts_replaced_by_idx on payout.accounts (replaced_by_id);

-- ── Lookup proofs (W-17) ──────────────────────────────────────────────────

-- Bound to actor, workspace, bank and account; valid 15 minutes. The first
-- provider result is final.
create table payout.account_lookups (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  workspace_membership_id uuid not null references org.memberships (id) on delete restrict,
  lookup_key text not null check (lookup_key ~ '^[A-Za-z0-9_-]{16,100}$'),
  provider text not null check (provider in ('paystack')),
  bank_code text not null check (bank_code ~ '^[0-9A-Z]{3,10}$'),
  account_ciphertext text not null check (account_ciphertext ~ '^[A-Za-z0-9+/]{40,200}={0,2}$'),
  key_version smallint not null check (key_version > 0),
  account_fingerprint text not null check (account_fingerprint ~ '^[0-9a-f]{64}$'),
  account_last4 text not null check (account_last4 ~ '^[0-9]{4}$'),
  replaces_payout_account_id uuid references payout.accounts (id) on delete restrict,
  status payout.lookup_status not null default 'pending',
  resolved_name text check (resolved_name is null or length(btrim(resolved_name)) between 1 and 160),
  name_match payout.name_match_result,
  name_rule_version text,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  confirmed_payout_account_id uuid references payout.accounts (id) on delete restrict,
  confirmed_at timestamptz,
  unique (owner_user_id, lookup_key),
  check (expires_at = created_at + interval '15 minutes'),
  check ((status = 'pending') = (resolved_at is null)),
  check ((status = 'resolved') = (resolved_name is not null)),
  check ((status = 'resolved') = (name_match is not null)),
  check ((name_match is null) = (name_rule_version is null)),
  check ((confirmed_at is null) = (confirmed_payout_account_id is null)),
  check (confirmed_at is null or status = 'resolved')
);

create index account_lookups_owner_idx on payout.account_lookups (owner_user_id, created_at desc);
create index account_lookups_workspace_idx on payout.account_lookups (workspace_membership_id);
create index account_lookups_replaces_idx on payout.account_lookups (replaces_payout_account_id);
create index account_lookups_confirmed_idx on payout.account_lookups (confirmed_payout_account_id);

alter table payout.accounts
  add constraint accounts_lookup_fk foreign key (lookup_id) references payout.account_lookups (id) on delete restrict;
create unique index accounts_one_per_lookup on payout.accounts (lookup_id) where lookup_id is not null;

-- ── Guards ────────────────────────────────────────────────────────────────

-- Ported from legacy guard_bank_resolution_intent: the request is immutable,
-- the first provider result is final and a confirmation is set once.
create function payout.guard_lookup()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id <> old.id or new.owner_user_id <> old.owner_user_id
    or new.workspace_membership_id <> old.workspace_membership_id or new.lookup_key <> old.lookup_key
    or new.provider <> old.provider or new.bank_code <> old.bank_code
    or new.account_ciphertext <> old.account_ciphertext or new.key_version <> old.key_version
    or new.account_fingerprint <> old.account_fingerprint or new.account_last4 <> old.account_last4
    or new.replaces_payout_account_id is distinct from old.replaces_payout_account_id
    or new.created_at <> old.created_at or new.expires_at <> old.expires_at
    or (old.status <> 'pending' and (
      new.status <> old.status or new.resolved_name is distinct from old.resolved_name
      or new.name_match is distinct from old.name_match
      or new.name_rule_version is distinct from old.name_rule_version
      or new.resolved_at is distinct from old.resolved_at))
    or (old.confirmed_at is not null and (
      new.confirmed_at is distinct from old.confirmed_at
      or new.confirmed_payout_account_id is distinct from old.confirmed_payout_account_id))
  then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'payout.account_lookups'));
  end if;
  return new;
end;
$$;

create trigger account_lookups_guard
before update on payout.account_lookups
for each row execute function payout.guard_lookup();
create trigger account_lookups_no_delete
before delete on payout.account_lookups
for each row execute function audit.reject_change();
create trigger account_lookups_no_truncate
before truncate on payout.account_lookups
for each statement execute function audit.reject_change();

-- Identity, ownership and number never change; replaced and deactivated rows
-- are final. Only the lifecycle and name-check columns move.
create function payout.guard_account()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id <> old.id or new.owner_user_id <> old.owner_user_id
    or new.country_code <> old.country_code or new.currency <> old.currency or new.rail <> old.rail
    or new.provider <> old.provider or new.bank_code <> old.bank_code or new.bank_name <> old.bank_name
    or new.account_ciphertext <> old.account_ciphertext or new.key_version <> old.key_version
    or new.account_fingerprint <> old.account_fingerprint or new.account_last4 <> old.account_last4
    or new.account_name <> old.account_name or new.verification_method <> old.verification_method
    or new.lookup_id is distinct from old.lookup_id
    or new.replaces_id is distinct from old.replaces_id
    or new.created_at <> old.created_at or new.usable_from <> old.usable_from
    or (old.status <> 'active' and (
      new.status <> old.status or new.is_primary
      or new.replaced_by_id is distinct from old.replaced_by_id
      or new.deactivated_at is distinct from old.deactivated_at
      or new.deactivated_reason is distinct from old.deactivated_reason))
  then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'payout.accounts'));
  end if;
  return new;
end;
$$;

create trigger accounts_guard
before update on payout.accounts
for each row execute function payout.guard_account();
create trigger accounts_no_delete
before delete on payout.accounts
for each row execute function audit.reject_change();
create trigger accounts_no_truncate
before truncate on payout.accounts
for each statement execute function audit.reject_change();

alter table payout.banks enable row level security;
alter table payout.accounts enable row level security;
alter table payout.account_lookups enable row level security;

-- Serializes one person's payout-account changes. Lock order: owner lock →
-- lookup row → payout account rows (by id). The bank list has its own lock.
create function payout.lock_owner(p_user_id uuid)
returns void
language sql
set search_path = ''
as $$
  select pg_advisory_xact_lock(hashtextextended('payout.owner:' || p_user_id::text, 0));
$$;
