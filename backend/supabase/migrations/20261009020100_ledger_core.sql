-- Blueprint 04 — B2/B3d: wallets, per-network pockets, double-entry ledger,
-- balance projection and reservations. Ported from the legacy ledger
-- (numeric(38,18), member-value vs system accounts, immutable journals and
-- postings, deferred balance checks, trigger-maintained projections), without
-- its GUC-based write gates.

create schema ledger;
create schema finance;
create schema evidence;
revoke all on schema ledger, finance, evidence from public, anon, authenticated;

-- ── Currencies (Q7) ───────────────────────────────────────────────────────

create table ledger.currencies (
  code text primary key check (code ~ '^[A-Z]{3}$'),
  scale smallint not null check (scale between 0 and 6),
  active boolean not null default true
);

insert into ledger.currencies (code, scale) values ('NGN', 2), ('USD', 2);

create function ledger.keep_currency()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.code <> old.code or new.scale <> old.scale then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.currencies'));
  end if;
  return new;
end;
$$;

create trigger currencies_identity
before update on ledger.currencies
for each row execute function ledger.keep_currency();
create trigger currencies_no_delete
before delete on ledger.currencies
for each row execute function audit.reject_change();

-- Scale of an active currency, or currency_not_supported.
create function ledger.currency_scale(p_currency text)
returns smallint
language plpgsql
stable
set search_path = ''
as $$
declare
  found_scale smallint;
begin
  select scale into found_scale from ledger.currencies where code = p_currency and active;
  if found_scale is null then
    perform identity.fail('currency_not_supported');
  end if;
  return found_scale;
end;
$$;

-- Exact decimal text for the wire, at the currency's scale (lossless: amounts
-- never carry more decimals than the scale).
create function ledger.money(p_amount numeric, p_currency text)
returns text
language sql
stable
set search_path = ''
as $$
  select round(p_amount, (select scale from ledger.currencies where code = p_currency))::text;
$$;

-- Parses a positive decimal string within the currency scale.
create function ledger.parse_amount(p_amount text, p_currency text, p_field text)
returns numeric
language plpgsql
stable
set search_path = ''
as $$
declare
  scale smallint;
  parsed numeric;
begin
  scale := ledger.currency_scale(p_currency);
  if p_amount is null or p_amount !~ '^[0-9]{1,20}(\.[0-9]{1,18})?$' then
    perform identity.fail('validation_error', jsonb_build_object('field', p_field));
  end if;
  parsed := p_amount::numeric;
  if parsed <= 0 or parsed <> round(parsed, scale) then
    perform identity.fail('validation_error', jsonb_build_object('field', p_field));
  end if;
  return parsed;
end;
$$;

-- ── Pockets (per network; Q1/Q2) ──────────────────────────────────────────

create type ledger.pocket_kind as enum ('ordinary', 'debt');

create table ledger.pockets (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  kind ledger.pocket_kind not null,
  name text not null check (length(btrim(name)) between 1 and 40 and name = btrim(name)),
  sort_order int not null check (sort_order > 0),
  status text not null default 'active' check (status in ('active', 'retired')),
  created_by uuid references identity.accounts (user_id) on delete restrict,
  created_at timestamptz not null default now(),
  retired_at timestamptz,
  unique (tenant_id, id),
  check ((status = 'retired') = (retired_at is not null)),
  check (kind = 'ordinary' or status = 'active'),
  -- One command may swap names, so uniqueness is checked at commit.
  constraint pockets_active_name_unique
    exclude using btree (tenant_id with =, (lower(name)) with =) where (status = 'active')
    deferrable initially deferred
);

create unique index pockets_one_debt on ledger.pockets (tenant_id) where kind = 'debt';
create index pockets_tenant_idx on ledger.pockets (tenant_id, sort_order);

create function ledger.keep_pocket()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id <> old.id or new.tenant_id <> old.tenant_id or new.kind <> old.kind
    or new.created_at <> old.created_at or old.status = 'retired'
    or (old.kind = 'debt' and (new.name <> old.name or new.sort_order <> old.sort_order)) then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.pockets'));
  end if;
  return new;
end;
$$;

create trigger pockets_rules
before update on ledger.pockets
for each row execute function ledger.keep_pocket();
create trigger pockets_no_delete
before delete on ledger.pockets
for each row execute function audit.reject_change();

-- Debt sits after every ordinary pocket.
create function ledger.debt_sort_order() returns int
language sql immutable set search_path = '' as $$ select 1000000 $$;

-- ── Wallets ───────────────────────────────────────────────────────────────

create table ledger.wallets (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null unique references identity.accounts (user_id) on delete restrict,
  created_at timestamptz not null default now()
);

create trigger wallets_immutable
before update or delete on ledger.wallets
for each row execute function audit.reject_change();

-- ── Accounts (segments and tenant system accounts) ────────────────────────

create table ledger.accounts (
  id uuid primary key default gen_random_uuid(),
  class text not null check (class in ('member_value', 'system')),
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  currency text not null references ledger.currencies (code) on delete restrict,
  wallet_id uuid references ledger.wallets (id) on delete restrict,
  membership_id uuid references org.memberships (id) on delete restrict,
  office_id uuid,
  owner_user_id uuid references identity.accounts (user_id) on delete restrict,
  pocket_id uuid,
  system_key text check (system_key ~ '^[a-z][a-z0-9_]*$'),
  created_at timestamptz not null default now(),
  foreign key (tenant_id, office_id) references org.offices (tenant_id, id) on delete restrict,
  foreign key (tenant_id, pocket_id) references ledger.pockets (tenant_id, id) on delete restrict,
  check ((class = 'member_value') = (
    wallet_id is not null and membership_id is not null and office_id is not null
    and owner_user_id is not null and pocket_id is not null and system_key is null)),
  check ((class = 'system') = (
    system_key is not null and wallet_id is null and membership_id is null and office_id is null
    and owner_user_id is null and pocket_id is null))
);

create unique index accounts_segment_idx on ledger.accounts (wallet_id, membership_id, currency, pocket_id)
  where class = 'member_value';
create unique index accounts_system_idx on ledger.accounts (tenant_id, currency, system_key)
  where class = 'system';
create index accounts_membership_idx on ledger.accounts (membership_id);
create index accounts_pocket_idx on ledger.accounts (pocket_id);
create index accounts_office_idx on ledger.accounts (tenant_id, office_id);

-- A segment's provenance must be consistent: the membership is the wallet
-- owner's, in the tenant, not President Team, at that office.
create function ledger.check_account()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  membership org.memberships;
begin
  if new.class = 'member_value' then
    select * into membership from org.memberships where id = new.membership_id;
    if membership.tenant_id is distinct from new.tenant_id
      or membership.user_id is distinct from new.owner_user_id
      or membership.office_id is distinct from new.office_id
      or membership.role = 'president_team_member'
      or not exists (
        select 1 from ledger.wallets w where w.id = new.wallet_id and w.owner_user_id = new.owner_user_id
      ) then
      perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.accounts'));
    end if;
  end if;
  return new;
end;
$$;

create trigger accounts_provenance
before insert on ledger.accounts
for each row execute function ledger.check_account();
create trigger accounts_immutable
before update or delete on ledger.accounts
for each row execute function audit.reject_change();

-- ── Transactions, journals, postings ──────────────────────────────────────

create table ledger.transactions (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique references refs.issued (code) on delete restrict,
  type text not null check (type in ('income')),
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  office_id uuid not null,
  membership_id uuid not null references org.memberships (id) on delete restrict,
  wallet_id uuid not null references ledger.wallets (id) on delete restrict,
  owner_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  actor_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  idempotency_key text not null check (idempotency_key ~ '^[A-Za-z0-9_-]{16,100}$'),
  posted_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  db_xact_id xid8 not null default pg_current_xact_id(),
  foreign key (tenant_id, office_id) references org.offices (tenant_id, id) on delete restrict
);

create index transactions_wallet_idx on ledger.transactions (wallet_id, posted_at desc, id desc);
create index transactions_tenant_idx on ledger.transactions (tenant_id, posted_at desc);
create index transactions_membership_idx on ledger.transactions (membership_id);

create table ledger.journals (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null references ledger.transactions (id) on delete restrict,
  entry_no smallint not null check (entry_no > 0),
  currency text not null references ledger.currencies (code) on delete restrict,
  unique (transaction_id, entry_no),
  unique (transaction_id, currency)
);

create table ledger.postings (
  id bigint generated always as identity primary key,
  journal_id uuid not null references ledger.journals (id) on delete restrict,
  account_id uuid not null references ledger.accounts (id) on delete restrict,
  line_no smallint not null check (line_no > 0),
  amount numeric(38, 18) not null check (amount <> 0),
  unique (journal_id, line_no)
);

create index postings_account_idx on ledger.postings (account_id);

-- Inserted complete: the database sets the posting time and the creating
-- database transaction, whatever the caller sent.
create function ledger.stamp_transaction()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.posted_at := now();
  new.db_xact_id := pg_current_xact_id();
  select office_id, user_id into new.office_id, new.owner_user_id
  from org.memberships where id = new.membership_id and tenant_id = new.tenant_id;
  if new.office_id is null or not exists (
    select 1 from ledger.wallets where id = new.wallet_id and owner_user_id = new.owner_user_id
  ) then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.transactions'));
  end if;
  return new;
end;
$$;

create trigger transactions_stamp
before insert on ledger.transactions
for each row execute function ledger.stamp_transaction();

-- Journals and postings may only be added in the database transaction that
-- created their ledger transaction.
create function ledger.require_open_transaction(p_transaction_id uuid)
returns ledger.transactions
language plpgsql
set search_path = ''
as $$
declare
  tx ledger.transactions;
begin
  select * into tx from ledger.transactions where id = p_transaction_id;
  if tx.id is null or tx.db_xact_id <> pg_current_xact_id() then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.transactions', 'reason', 'closed'));
  end if;
  return tx;
end;
$$;

create function ledger.check_journal()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform ledger.require_open_transaction(new.transaction_id);
  return new;
end;
$$;

create trigger journals_open
before insert on ledger.journals
for each row execute function ledger.check_journal();

create function ledger.check_posting()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  journal ledger.journals;
  tx ledger.transactions;
  account ledger.accounts;
  scale smallint;
begin
  select * into journal from ledger.journals where id = new.journal_id;
  tx := ledger.require_open_transaction(journal.transaction_id);
  select * into account from ledger.accounts where id = new.account_id;
  select c.scale into scale from ledger.currencies c where c.code = journal.currency;
  if account.currency <> journal.currency
    or account.tenant_id <> tx.tenant_id
    or (account.class = 'member_value' and account.wallet_id <> tx.wallet_id)
    or new.amount <> round(new.amount, scale) then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.postings'));
  end if;
  return new;
end;
$$;

create trigger postings_check
before insert on ledger.postings
for each row execute function ledger.check_posting();

create trigger transactions_immutable
before update or delete on ledger.transactions
for each row execute function audit.reject_change();
create trigger journals_immutable
before update or delete on ledger.journals
for each row execute function audit.reject_change();
create trigger postings_immutable
before update or delete on ledger.postings
for each row execute function audit.reject_change();

-- Deferred: every journal balances with at least two postings; every
-- transaction has a journal and moves member value.
create function ledger.check_journal_balanced()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  lines int;
  total numeric;
begin
  select count(*), coalesce(sum(amount), 0) into lines, total from ledger.postings where journal_id = new.id;
  if lines < 2 or total <> 0 then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.journals', 'reason', 'unbalanced'));
  end if;
  return null;
end;
$$;

create constraint trigger journals_balanced
after insert on ledger.journals
deferrable initially deferred
for each row execute function ledger.check_journal_balanced();

create function ledger.check_transaction_complete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1 from ledger.journals j
    join ledger.postings p on p.journal_id = j.id
    join ledger.accounts a on a.id = p.account_id
    where j.transaction_id = new.id and a.class = 'member_value'
  ) then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.transactions', 'reason', 'incomplete'));
  end if;
  return null;
end;
$$;

create constraint trigger transactions_complete
after insert on ledger.transactions
deferrable initially deferred
for each row execute function ledger.check_transaction_complete();

-- ── Balance projection ────────────────────────────────────────────────────

create table ledger.balances (
  account_id uuid primary key references ledger.accounts (id) on delete restrict,
  tenant_id uuid not null,
  office_id uuid not null,
  wallet_id uuid not null,
  owner_user_id uuid not null,
  membership_id uuid not null,
  currency text not null,
  pocket_id uuid not null,
  allows_negative boolean not null,
  posted numeric(38, 18) not null default 0,
  reserved numeric(38, 18) not null default 0 check (reserved >= 0),
  version bigint not null default 0,
  updated_at timestamptz not null default now(),
  constraint balances_available_non_negative check (allows_negative or posted - reserved >= 0)
);

create index balances_office_idx on ledger.balances (office_id, currency, pocket_id) include (posted, reserved, owner_user_id);
create index balances_wallet_idx on ledger.balances (wallet_id, tenant_id);
create index balances_tenant_owner_idx on ledger.balances (tenant_id, owner_user_id);
create index balances_pocket_idx on ledger.balances (pocket_id);

-- Rows start at zero; afterwards only the posting/reservation triggers may
-- change them (they run one trigger level down).
create function ledger.guard_balance()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.posted <> 0 or new.reserved <> 0 or new.version <> 0 then
      perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.balances'));
    end if;
    return new;
  end if;
  if pg_trigger_depth() < 2
    or new.account_id <> old.account_id or new.tenant_id <> old.tenant_id or new.office_id <> old.office_id
    or new.wallet_id <> old.wallet_id or new.owner_user_id <> old.owner_user_id
    or new.membership_id <> old.membership_id or new.currency <> old.currency
    or new.pocket_id <> old.pocket_id or new.allows_negative <> old.allows_negative then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.balances'));
  end if;
  return new;
end;
$$;

create trigger balances_guard
before insert or update on ledger.balances
for each row execute function ledger.guard_balance();
create trigger balances_no_delete
before delete on ledger.balances
for each row execute function audit.reject_change();

create function ledger.project_posting()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  update ledger.balances
  set posted = posted + new.amount, version = version + 1, updated_at = now()
  where account_id = new.account_id;
  return null;
end;
$$;

create trigger postings_project
after insert on ledger.postings
for each row execute function ledger.project_posting();

-- ── Reservations (holds) ──────────────────────────────────────────────────

create table ledger.reservations (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references ledger.accounts (id) on delete restrict,
  amount numeric(38, 18) not null check (amount > 0),
  purpose text not null check (purpose in ('withdrawal', 'pocket_transfer')),
  source_type text not null check (source_type ~ '^[a-z][a-z_]*$'),
  source_id uuid not null,
  status text not null default 'active' check (status in ('active', 'consumed', 'released')),
  consumed_amount numeric(38, 18) check (consumed_amount is null or (consumed_amount > 0 and consumed_amount <= amount)),
  consumed_by_transaction_id uuid references ledger.transactions (id) on delete restrict,
  release_reason text check (release_reason is null or length(btrim(release_reason)) between 3 and 500),
  actor_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  created_at timestamptz not null default now(),
  settled_at timestamptz,
  check ((status = 'active') = (settled_at is null)),
  check ((status = 'consumed') = (consumed_amount is not null and consumed_by_transaction_id is not null)),
  check ((status = 'released') = (release_reason is not null))
);

create unique index reservations_one_active_per_source
  on ledger.reservations (source_type, source_id, account_id) where status = 'active';
create index reservations_account_idx on ledger.reservations (account_id) where status = 'active';
create index reservations_transaction_idx on ledger.reservations (consumed_by_transaction_id);

create function ledger.guard_reservation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'active' then
      perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.reservations'));
    end if;
    new.created_at := now();
    return new;
  end if;
  if old.status <> 'active' or new.status = 'active'
    or new.id <> old.id or new.account_id <> old.account_id or new.amount <> old.amount
    or new.purpose <> old.purpose or new.source_type <> old.source_type or new.source_id <> old.source_id
    or new.actor_user_id <> old.actor_user_id or new.created_at <> old.created_at then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.reservations'));
  end if;
  new.settled_at := now();
  return new;
end;
$$;

create trigger reservations_guard
before insert or update on ledger.reservations
for each row execute function ledger.guard_reservation();
create trigger reservations_no_delete
before delete on ledger.reservations
for each row execute function audit.reject_change();

create function ledger.project_reservation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  update ledger.balances
  set reserved = reserved + case when tg_op = 'INSERT' then new.amount else -old.amount end,
      version = version + 1, updated_at = now()
  where account_id = new.account_id;
  return null;
end;
$$;

create trigger reservations_project
after insert or update of status on ledger.reservations
for each row execute function ledger.project_reservation();

create trigger currencies_no_truncate before truncate on ledger.currencies for each statement execute function audit.reject_change();
create trigger pockets_no_truncate before truncate on ledger.pockets for each statement execute function audit.reject_change();
create trigger wallets_no_truncate before truncate on ledger.wallets for each statement execute function audit.reject_change();
create trigger accounts_no_truncate before truncate on ledger.accounts for each statement execute function audit.reject_change();
create trigger transactions_no_truncate before truncate on ledger.transactions for each statement execute function audit.reject_change();
create trigger journals_no_truncate before truncate on ledger.journals for each statement execute function audit.reject_change();
create trigger postings_no_truncate before truncate on ledger.postings for each statement execute function audit.reject_change();
create trigger balances_no_truncate before truncate on ledger.balances for each statement execute function audit.reject_change();
create trigger reservations_no_truncate before truncate on ledger.reservations for each statement execute function audit.reject_change();

alter table ledger.currencies enable row level security;
alter table ledger.pockets enable row level security;
alter table ledger.wallets enable row level security;
alter table ledger.accounts enable row level security;
alter table ledger.transactions enable row level security;
alter table ledger.journals enable row level security;
alter table ledger.postings enable row level security;
alter table ledger.balances enable row level security;
alter table ledger.reservations enable row level security;

-- ── Internal ledger API (B3d) ─────────────────────────────────────────────

-- Ensures one segment (wallet + membership + currency + pocket) and its
-- balance row. Membership activity is the caller's rule (fix g).
create function ledger.segment_account(
  p_wallet_id uuid,
  p_membership_id uuid,
  p_currency text,
  p_pocket_id uuid
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  membership org.memberships;
  v_owner uuid;
  pocket ledger.pockets;
  v_account_id uuid;
begin
  select * into membership from org.memberships where id = p_membership_id;
  select w.owner_user_id into v_owner from ledger.wallets w where w.id = p_wallet_id;
  select * into pocket from ledger.pockets where id = p_pocket_id;
  if membership.id is null or v_owner is null or pocket.id is null
    or pocket.tenant_id <> membership.tenant_id
    or not exists (select 1 from ledger.currencies where code = p_currency) then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.accounts'));
  end if;

  insert into ledger.accounts (class, tenant_id, currency, wallet_id, membership_id, office_id, owner_user_id, pocket_id)
  values ('member_value', membership.tenant_id, p_currency, p_wallet_id, membership.id, membership.office_id,
    v_owner, pocket.id)
  on conflict (wallet_id, membership_id, currency, pocket_id) where class = 'member_value' do nothing
  returning id into v_account_id;

  if v_account_id is null then
    select id into v_account_id from ledger.accounts
    where class = 'member_value' and wallet_id = p_wallet_id and membership_id = p_membership_id
      and currency = p_currency and pocket_id = p_pocket_id;
  else
    insert into ledger.balances (account_id, tenant_id, office_id, wallet_id, owner_user_id, membership_id,
      currency, pocket_id, allows_negative)
    values (v_account_id, membership.tenant_id, membership.office_id, p_wallet_id, v_owner, membership.id,
      p_currency, pocket.id, pocket.kind = 'debt');
  end if;
  return v_account_id;
end;
$$;

create function ledger.system_account(p_tenant_id uuid, p_currency text, p_key text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_account_id uuid;
begin
  insert into ledger.accounts (class, tenant_id, currency, system_key)
  values ('system', p_tenant_id, p_currency, p_key)
  on conflict (tenant_id, currency, system_key) where class = 'system' do nothing
  returning id into v_account_id;
  if v_account_id is null then
    select id into v_account_id from ledger.accounts
    where class = 'system' and tenant_id = p_tenant_id and currency = p_currency and system_key = p_key;
  end if;
  return v_account_id;
end;
$$;

create function ledger.available(p_account_id uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  select posted - reserved from ledger.balances where account_id = p_account_id;
$$;

-- Holds part of an ordinary pocket (Debt is never a source, Q2).
create function ledger.reserve(
  p_account_id uuid,
  p_amount numeric,
  p_purpose text,
  p_source_type text,
  p_source_id uuid,
  p_actor_user_id uuid
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  balance ledger.balances;
  pocket ledger.pockets;
  reservation_id uuid;
begin
  select * into balance from ledger.balances where account_id = p_account_id for update;
  select * into pocket from ledger.pockets where id = balance.pocket_id;
  if balance.account_id is null or pocket.kind <> 'ordinary' or pocket.status <> 'active' then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.reservations'));
  end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, ledger.currency_scale(balance.currency)) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'amount'));
  end if;
  if balance.posted - balance.reserved < p_amount then
    perform identity.fail('insufficient_funds',
      jsonb_build_object('available', ledger.money(balance.posted - balance.reserved, balance.currency)));
  end if;

  insert into ledger.reservations (account_id, amount, purpose, source_type, source_id, actor_user_id)
  values (p_account_id, p_amount, p_purpose, p_source_type, p_source_id, p_actor_user_id)
  returning id into reservation_id;
  return reservation_id;
end;
$$;

create function ledger.release(p_reservation_id uuid, p_reason text, p_actor_user_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  reservation ledger.reservations;
begin
  select * into reservation from ledger.reservations where id = p_reservation_id;
  if reservation.id is null then
    perform identity.fail('not_found');
  end if;
  perform 1 from ledger.balances where account_id = reservation.account_id for update;
  select * into reservation from ledger.reservations where id = p_reservation_id for update;
  if reservation.status <> 'active' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'reservation_settled'));
  end if;
  update ledger.reservations
  set status = 'released', release_reason = identity.require_reason(p_reason)
  where id = p_reservation_id;
end;
$$;

-- Posts one balanced transaction (one journal per currency). Validates the
-- shape up front; the database re-checks balance and completeness at commit.
create function ledger.post(
  p_type text,
  p_reference text,
  p_membership_id uuid,
  p_actor_user_id uuid,
  p_idempotency_key text,
  p_journals jsonb,
  p_consume jsonb default '[]'::jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  membership org.memberships;
  v_wallet_id uuid;
  tx_id uuid;
  journal jsonb;
  posting jsonb;
  item jsonb;
  journal_id uuid;
  entry int := 0;
  line int;
  total numeric;
  account ledger.accounts;
  v_amount numeric;
  reservation ledger.reservations;
  consume_amount numeric;
  account_ids uuid[] := '{}'::uuid[];
  v_constraint text;
begin
  select * into membership from org.memberships where id = p_membership_id;
  select id into v_wallet_id from ledger.wallets where owner_user_id = membership.user_id;
  if membership.id is null or v_wallet_id is null
    or jsonb_typeof(p_journals) is distinct from 'array' or jsonb_array_length(p_journals) < 1
    or jsonb_typeof(p_consume) is distinct from 'array' then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.transactions'));
  end if;

  -- Shape and balance, before anything is written.
  for journal in select value from jsonb_array_elements(p_journals) loop
    if jsonb_typeof(journal->'postings') is distinct from 'array' or jsonb_array_length(journal->'postings') < 2 then
      perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.journals', 'reason', 'unbalanced'));
    end if;
    total := 0;
    for posting in select value from jsonb_array_elements(journal->'postings') loop
      if posting->>'amount' is null or posting->>'amount' !~ '^-?[0-9]{1,20}(\.[0-9]{1,18})?$'
        or (posting->>'amount')::numeric = 0 then
        perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.postings'));
      end if;
      total := total + (posting->>'amount')::numeric;
      account_ids := account_ids || (posting->>'accountId')::uuid;
    end loop;
    if total <> 0 then
      perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.journals', 'reason', 'unbalanced'));
    end if;
  end loop;

  -- Lock order step 9: member balances sorted by account id.
  perform 1 from ledger.balances
  where account_id = any (account_ids)
  order by account_id
  for update;

  insert into ledger.transactions (reference, type, tenant_id, office_id, membership_id, wallet_id,
    owner_user_id, actor_user_id, idempotency_key, metadata)
  values (p_reference, p_type, membership.tenant_id, membership.office_id, membership.id, v_wallet_id,
    membership.user_id, p_actor_user_id, p_idempotency_key, coalesce(p_metadata, '{}'::jsonb))
  returning id into tx_id;

  -- Settle holds first, so a consumed hold isn't counted against the debit.
  for item in
    select value from jsonb_array_elements(p_consume) order by value->>'reservationId'
  loop
    select * into reservation from ledger.reservations where id = (item->>'reservationId')::uuid for update;
    consume_amount := (item->>'amount')::numeric;
    if reservation.id is null or reservation.status <> 'active'
      or not exists (select 1 from ledger.accounts a where a.id = reservation.account_id and a.wallet_id = v_wallet_id)
      or consume_amount is null or consume_amount <= 0 or consume_amount > reservation.amount then
      perform identity.fail('conflict', jsonb_build_object('reason', 'reservation_unavailable'));
    end if;
    update ledger.reservations
    set status = 'consumed', consumed_amount = consume_amount, consumed_by_transaction_id = tx_id
    where id = reservation.id;
  end loop;

  for journal in select value from jsonb_array_elements(p_journals) loop
    entry := entry + 1;
    insert into ledger.journals (transaction_id, entry_no, currency)
    values (tx_id, entry, journal->>'currency')
    returning id into journal_id;
    line := 0;
    for posting in select value from jsonb_array_elements(journal->'postings') loop
      line := line + 1;
      v_amount := (posting->>'amount')::numeric;
      begin
        insert into ledger.postings (journal_id, account_id, line_no, amount)
        values (journal_id, (posting->>'accountId')::uuid, line, v_amount);
      exception when check_violation then
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint is distinct from 'balances_available_non_negative' then
          raise;
        end if;
        select * into account from ledger.accounts where id = (posting->>'accountId')::uuid;
        perform identity.fail('insufficient_funds', jsonb_build_object('available',
          ledger.money(ledger.available(account.id), account.currency)));
      end;
    end loop;
  end loop;
  return tx_id;
end;
$$;

-- Projection drift (F-01.7): rows whose stored balance differs from the ledger.
create function ledger.verify_balances()
returns table (account_id uuid, posted numeric, ledger_posted numeric, reserved numeric, ledger_reserved numeric)
language sql
stable
set search_path = ''
as $$
  select b.account_id, b.posted, coalesce(p.total, 0), b.reserved, coalesce(r.total, 0)
  from ledger.balances b
  left join (select p.account_id, sum(p.amount) as total from ledger.postings p group by p.account_id) p
    on p.account_id = b.account_id
  left join (select r.account_id, sum(r.amount) as total from ledger.reservations r where r.status = 'active' group by r.account_id) r
    on r.account_id = b.account_id
  where b.posted <> coalesce(p.total, 0) or b.reserved <> coalesce(r.total, 0)
  union all
  -- Member postings without a projection row.
  select a.id, null, sum(p.amount), null, null
  from ledger.accounts a join ledger.postings p on p.account_id = a.id
  where a.class = 'member_value' and not exists (select 1 from ledger.balances b where b.account_id = a.id)
  group by a.id;
$$;
