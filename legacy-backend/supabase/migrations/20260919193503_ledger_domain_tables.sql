create schema ledger;

create type ledger.account_class as enum ('member_value', 'system_counter');

create table ledger.currency_definitions (
  currency_code text primary key
    check (currency_code ~ '^[A-Z]{3}$'),
  minor_unit_scale smallint not null
    check (minor_unit_scale between 0 and 6),
  created_at timestamptz not null default clock_timestamp()
);

create table ledger.ledger_accounts (
  id uuid primary key default extensions.gen_random_uuid(),
  account_class ledger.account_class not null,
  currency_code text not null
    references ledger.currency_definitions (currency_code) on delete restrict,
  wallet_id uuid references public.wallets (id) on delete restrict,
  tenant_id uuid references public.tenants (id) on delete restrict,
  office_id uuid,
  membership_id uuid,
  owner_user_id uuid
    references public.user_accounts (user_id) on delete restrict,
  pocket_key text
    references public.pocket_definitions (pocket_key) on delete restrict,
  system_account_key text
    check (system_account_key is null or system_account_key ~ '^[a-z][a-z0-9_]*$'),
  created_at timestamptz not null default clock_timestamp(),
  foreign key (tenant_id, office_id)
    references public.offices (tenant_id, id)
    on delete restrict,
  foreign key (tenant_id, membership_id)
    references public.memberships (tenant_id, id)
    on delete restrict,
  check (
    (
      account_class = 'member_value'
      and wallet_id is not null
      and tenant_id is not null
      and office_id is not null
      and membership_id is not null
      and owner_user_id is not null
      and pocket_key is not null
      and system_account_key is null
    )
    or (
      account_class = 'system_counter'
      and wallet_id is null
      and tenant_id is null
      and office_id is null
      and membership_id is null
      and owner_user_id is null
      and pocket_key is null
      and system_account_key is not null
    )
  )
);

create unique index ledger_accounts_member_context
  on ledger.ledger_accounts (
    wallet_id,
    tenant_id,
    office_id,
    membership_id,
    currency_code,
    pocket_key
  )
  where account_class = 'member_value';

create unique index ledger_accounts_system_context
  on ledger.ledger_accounts (currency_code, system_account_key)
  where account_class = 'system_counter';

create index ledger_accounts_tenant_office
  on ledger.ledger_accounts (tenant_id, office_id)
  where account_class = 'member_value';

create index ledger_accounts_tenant_membership
  on ledger.ledger_accounts (tenant_id, membership_id)
  where account_class = 'member_value';

create index ledger_accounts_owner_user_id
  on ledger.ledger_accounts (owner_user_id)
  where account_class = 'member_value';

create index ledger_accounts_pocket_key
  on ledger.ledger_accounts (pocket_key)
  where account_class = 'member_value';

create or replace function ledger.generate_transaction_reference()
returns text
language sql
volatile
set search_path = ''
as $$
  select 'FT-' || upper(substr(encode(extensions.gen_random_bytes(10), 'hex'), 1, 16));
$$;

create table ledger.financial_transactions (
  id uuid primary key default extensions.gen_random_uuid(),
  transaction_reference text not null unique
    default ledger.generate_transaction_reference(),
  idempotency_key uuid not null unique,
  request_fingerprint bytea not null
    check (octet_length(request_fingerprint) = 32),
  transaction_type text not null
    check (transaction_type ~ '^[a-z][a-z0-9_]*$'),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  office_id uuid not null,
  membership_id uuid not null,
  wallet_id uuid not null references public.wallets (id) on delete restrict,
  owner_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  actor_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz not null default clock_timestamp(),
  posted_at timestamptz,
  foreign key (tenant_id, office_id)
    references public.offices (tenant_id, id)
    on delete restrict,
  foreign key (tenant_id, membership_id)
    references public.memberships (tenant_id, id)
    on delete restrict,
  check (posted_at is null or posted_at >= created_at)
);

create index financial_transactions_tenant_created_at
  on ledger.financial_transactions (tenant_id, created_at desc);

create index financial_transactions_tenant_office
  on ledger.financial_transactions (tenant_id, office_id);

create index financial_transactions_tenant_membership
  on ledger.financial_transactions (tenant_id, membership_id);

create index financial_transactions_wallet_created_at
  on ledger.financial_transactions (wallet_id, created_at desc);

create index financial_transactions_owner_created_at
  on ledger.financial_transactions (owner_user_id, created_at desc);

create index financial_transactions_actor_created_at
  on ledger.financial_transactions (actor_user_id, created_at desc);

create table ledger.journal_entries (
  id uuid primary key default extensions.gen_random_uuid(),
  financial_transaction_id uuid not null
    references ledger.financial_transactions (id) on delete restrict,
  entry_number smallint not null check (entry_number > 0),
  currency_code text not null
    references ledger.currency_definitions (currency_code) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  unique (financial_transaction_id, entry_number)
);

create index journal_entries_currency_code
  on ledger.journal_entries (currency_code);

create table ledger.journal_postings (
  id bigint generated always as identity primary key,
  journal_entry_id uuid not null
    references ledger.journal_entries (id) on delete restrict,
  ledger_account_id uuid not null
    references ledger.ledger_accounts (id) on delete restrict,
  line_number smallint not null check (line_number > 0),
  amount numeric(38, 18) not null check (amount <> 0),
  created_at timestamptz not null default clock_timestamp(),
  unique (journal_entry_id, line_number),
  unique (journal_entry_id, ledger_account_id)
);

create index journal_postings_ledger_account_id
  on ledger.journal_postings (ledger_account_id);

create table ledger.wallet_balance_projections (
  ledger_account_id uuid primary key
    references ledger.ledger_accounts (id) on delete restrict,
  balance numeric(38, 18) not null default 0,
  version bigint not null default 0 check (version >= 0),
  last_posting_id bigint not null
    references ledger.journal_postings (id) on delete restrict,
  updated_at timestamptz not null default clock_timestamp()
);

create index wallet_balance_projections_last_posting_id
  on ledger.wallet_balance_projections (last_posting_id);

alter table ledger.currency_definitions enable row level security;
alter table ledger.ledger_accounts enable row level security;
alter table ledger.financial_transactions enable row level security;
alter table ledger.journal_entries enable row level security;
alter table ledger.journal_postings enable row level security;
alter table ledger.wallet_balance_projections enable row level security;

alter table ledger.currency_definitions force row level security;
alter table ledger.ledger_accounts force row level security;
alter table ledger.financial_transactions force row level security;
alter table ledger.journal_entries force row level security;
alter table ledger.journal_postings force row level security;
alter table ledger.wallet_balance_projections force row level security;

revoke all on schema ledger from public, anon, authenticated, service_role;
revoke all on all tables in schema ledger from public, anon, authenticated, service_role;
revoke all on all sequences in schema ledger from public, anon, authenticated, service_role;
revoke all on all functions in schema ledger from public, anon, authenticated, service_role;

alter default privileges in schema ledger
  revoke all on tables from public, anon, authenticated, service_role;
alter default privileges in schema ledger
  revoke all on sequences from public, anon, authenticated, service_role;
alter default privileges in schema ledger
  revoke execute on functions from public, anon, authenticated, service_role;
