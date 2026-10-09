-- Blueprint 16 — B1: billing (W-19, D-10, U-03). Plans, one subscription per
-- network with its period history, the founder trial ledger, Paystack
-- payments and webhook deduplication, the Billing Owner history and the
-- B01–B05 catalogue rows. Billing money never touches the ledger.

create schema billing;
revoke all on schema billing from public, anon, authenticated;

-- ── Rules as functions (owner decisions 2026-10-08/09) ────────────────────

-- Dates (trial ends, proration days, reminders) are WAT.
create function billing.zone() returns text
language sql immutable set search_path = '' as $$ select 'Africa/Lagos'::text $$;

create function billing.trial_length() returns interval
language sql immutable set search_path = '' as $$ select interval '7 days' $$;

-- B04 once per period when seats reach this share of the cap.
create function billing.seat_warning_share() returns numeric
language sql immutable set search_path = '' as $$ select 0.9 $$;

-- Open checkouts are abandoned after a day.
create function billing.checkout_lifetime() returns interval
language sql immutable set search_path = '' as $$ select interval '24 hours' $$;

-- The Paystack subscription charges a day before the year ends, so a
-- successful renewal never pauses the network.
create function billing.renewal_lead() returns interval
language sql immutable set search_path = '' as $$ select interval '1 day' $$;

create function billing.today() returns date
language sql stable set search_path = '' as $$ select (now() at time zone billing.zone())::date $$;

-- ── Plans (immutable, versioned) ──────────────────────────────────────────

create table billing.plans (
  id uuid primary key default gen_random_uuid(),
  key text not null check (key in ('band_400', 'band_1000', 'band_1001_plus')),
  version int not null check (version > 0),
  name text not null check (length(btrim(name)) between 1 and 60),
  seat_cap int check (seat_cap is null or seat_cap > 0),
  price numeric(14, 2) not null check (price > 0),
  currency text not null default 'NGN' check (currency = 'NGN'),
  rank int not null check (rank > 0),
  launch boolean not null default true,
  created_at timestamptz not null default now(),
  unique (key, version)
);

create trigger plans_immutable
before update or delete on billing.plans
for each row execute function audit.reject_change();

-- The three launch bands (D-10), VAT included. Bands 4–6 stay U-13.
insert into billing.plans (key, version, name, seat_cap, price, rank) values
  ('band_400', 1, 'Up to 400 users', 400, 700000.00, 1),
  ('band_1000', 1, 'Up to 1,000 users', 1000, 1000000.00, 2),
  ('band_1001_plus', 1, '1,001+ users', null, 1500000.00, 3);

-- The current offered version of a band.
create function billing.plan(p_key text)
returns billing.plans
language plpgsql
set search_path = ''
as $$
declare
  found billing.plans;
begin
  select * into found from billing.plans
  where key = p_key and launch
  order by version desc limit 1;
  if found.id is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'planKey'));
  end if;
  return found;
end;
$$;

-- Paystack plan codes, found or created by the billing function per mode.
create table billing.provider_plans (
  plan_id uuid not null references billing.plans (id) on delete restrict,
  environment text not null check (environment in ('test', 'live')),
  plan_code text not null unique check (plan_code ~ '^PLN_[A-Za-z0-9]{1,60}$'),
  created_at timestamptz not null default now(),
  primary key (plan_id, environment)
);

-- ── Subscriptions ─────────────────────────────────────────────────────────

create type billing.status as enum ('pending', 'trial', 'active', 'paused');
create type billing.kind as enum ('trial', 'paid', 'complimentary', 'development');

create table billing.subscriptions (
  tenant_id uuid primary key references org.tenants (id) on delete restrict,
  status billing.status not null,
  kind billing.kind not null,
  plan_id uuid not null references billing.plans (id) on delete restrict,
  period_start timestamptz,
  period_end timestamptz,
  paused_at timestamptz,
  auto_renew boolean not null default false,
  next_plan_id uuid references billing.plans (id) on delete restrict,
  -- Paystack state; the email token is only ever used server-side to disable.
  provider_customer_code text check (provider_customer_code ~ '^CUS_[A-Za-z0-9]{1,60}$'),
  provider_subscription_code text check (provider_subscription_code ~ '^SUB_[A-Za-z0-9]{1,60}$'),
  provider_email_token text check (provider_email_token ~ '^[A-Za-z0-9_-]{1,100}$'),
  provider_plan_code text check (provider_plan_code ~ '^PLN_[A-Za-z0-9]{1,60}$'),
  reusable_card boolean not null default false,
  sync_state text not null default 'none' check (sync_state in ('none', 'pending', 'failed')),
  sync_attempts int not null default 0 check (sync_attempts >= 0),
  sync_after timestamptz,
  sync_lease_until timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((status = 'paused') = (paused_at is not null)),
  check (kind <> 'development' or (period_end is null and status = 'active')),
  check (status <> 'pending' or period_end is null),
  check (status = 'pending' or kind = 'development' or period_end is not null),
  check (period_end is null or (period_start is not null and period_end > period_start)),
  check (status <> 'trial' or kind = 'trial'),
  check (next_plan_id is null or next_plan_id <> plan_id)
);

create index subscriptions_due_idx on billing.subscriptions (period_end) where status in ('trial', 'active');
create index subscriptions_sync_idx on billing.subscriptions (sync_after) where sync_state = 'pending';
create index subscriptions_customer_idx on billing.subscriptions (provider_customer_code);

-- Every trial, paid year, upgrade, grant, pause and reactivation.
create table billing.periods (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  kind text not null check (kind in ('trial', 'paid', 'upgrade', 'complimentary', 'development', 'paused',
                                     'next_plan', 'auto_renew')),
  plan_id uuid references billing.plans (id) on delete restrict,
  starts_at timestamptz,
  ends_at timestamptz,
  payment_id uuid,
  actor_user_id uuid references identity.accounts (user_id) on delete restrict,
  reason text check (reason is null or length(btrim(reason)) between 3 and 500),
  created_at timestamptz not null default now()
);

create index periods_tenant_idx on billing.periods (tenant_id, id);

create trigger periods_append_only
before update or delete on billing.periods
for each row execute function audit.reject_change();

-- One trial per founder account, ever (owner decision 2026-10-08).
create table billing.trials (
  user_id uuid primary key references identity.accounts (user_id) on delete restrict,
  tenant_id uuid not null unique references org.tenants (id) on delete restrict,
  started_at timestamptz not null default now()
);

create trigger trials_append_only
before update or delete on billing.trials
for each row execute function audit.reject_change();

-- ── Payments ──────────────────────────────────────────────────────────────

create table billing.payments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  reference text not null unique references refs.issued (code) on delete restrict
    check (reference like 'PAY-%'),
  purpose text not null check (purpose in ('start', 'renew', 'upgrade', 'reactivate', 'auto_renewal')),
  plan_id uuid not null references billing.plans (id) on delete restrict,
  from_plan_id uuid references billing.plans (id) on delete restrict,
  amount numeric(14, 2) not null check (amount > 0),
  currency text not null check (currency = 'NGN'),
  days_left int check (days_left is null or days_left >= 0),
  status text not null default 'open' check (status in ('open', 'paid', 'failed', 'abandoned', 'superseded')),
  applied boolean not null default false,
  needs_review boolean not null default false,
  review_reason text check (review_reason is null or review_reason ~ '^[a-z_]{3,40}$'),
  provider_reference text not null unique check (provider_reference ~ '^[A-Za-z0-9._=-]{6,100}$'),
  provider_transaction_id bigint,
  environment text not null check (environment in ('test', 'live')),
  authorization_url text check (authorization_url is null
    or (length(authorization_url) <= 500 and authorization_url ~ '^https?://[^\s]+$')),
  initiated_by uuid references identity.accounts (user_id) on delete restrict,
  idempotency_key text,
  covers_from timestamptz,
  covers_to timestamptz,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (initiated_by, idempotency_key),
  check ((status = 'paid') = (paid_at is not null)),
  check (not applied or status = 'paid'),
  check ((purpose = 'auto_renewal') = (initiated_by is null)),
  check ((purpose = 'upgrade') = (days_left is not null))
);

-- One open checkout per network: a new checkout supersedes the old one.
create unique index payments_one_open on billing.payments (tenant_id)
  where status = 'open' and purpose <> 'auto_renewal';
create index payments_tenant_idx on billing.payments (tenant_id, created_at desc, id);

-- Webhook deduplication. Raw bodies (emails, card details) are never kept.
create table billing.provider_events (
  id bigint generated always as identity primary key,
  dedupe_key text not null unique check (length(dedupe_key) between 3 and 200),
  event text not null check (length(event) between 1 and 60),
  body_sha256 text not null check (body_sha256 ~ '^[0-9a-f]{64}$'),
  outcome text check (outcome is null or outcome ~ '^[a-z_]{2,40}$'),
  tenant_id uuid references org.tenants (id) on delete restrict,
  payment_id uuid references billing.payments (id) on delete restrict,
  received_at timestamptz not null default now(),
  processed_at timestamptz
);

-- ── Billing Owner ─────────────────────────────────────────────────────────

create table billing.owners (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  user_id uuid not null references identity.accounts (user_id) on delete restrict,
  membership_id uuid references org.memberships (id) on delete restrict,
  assigned_by uuid references identity.accounts (user_id) on delete restrict,
  assigned_at timestamptz not null default now(),
  ended_at timestamptz,
  ended_by uuid references identity.accounts (user_id) on delete restrict
);

create unique index owners_one_current on billing.owners (tenant_id) where ended_at is null;

create function billing.keep_owner_history()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' or new.tenant_id <> old.tenant_id or new.user_id <> old.user_id
     or new.assigned_at <> old.assigned_at or old.ended_at is not null then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'billing.owners'));
  end if;
  return new;
end;
$$;

create trigger owners_history
before update or delete on billing.owners
for each row execute function billing.keep_owner_history();

-- ── Catalogue: B01–B05 (Paper "Emails — Transactional v2") ────────────────

insert into outbox.templates (key, version, duplicate_safe, params) values
  ('billing.payment_received', 1, true, array['network', 'amount', 'currency', 'reference', 'path']),
  ('billing.renewal_reminder', 1, true, array['network', 'amount', 'currency', 'due', 'chip', 'path']),
  ('billing.owner_assigned', 1, true, array['network', 'path']),
  ('billing.seats_almost_full', 1, true, array['network', 'used', 'cap', 'path']),
  ('billing.paused', 1, true, array['network', 'path']);

insert into notify.kinds (key, task, email_template) values
  ('billing.payment_received', false, 'billing.payment_received'),
  ('billing.renewal_reminder', false, 'billing.renewal_reminder'),
  ('billing.owner_assigned', false, 'billing.owner_assigned'),
  ('billing.seats_almost_full', false, 'billing.seats_almost_full'),
  ('billing.paused', false, 'billing.paused');

-- Tenant audit targets: the union of every slice's values so far.
alter table audit.tenant_events drop constraint tenant_events_target_type_check;
alter table audit.tenant_events add constraint tenant_events_target_type_check
  check (target_type in (
    'tenant', 'office', 'membership', 'role_permission', 'access_assignment', 'reviewer_assignment',
    'invitation',
    'allocation_policy', 'income', 'evidence',
    'withdrawal', 'payout', 'pocket_transfer',
    'entry', 'reversal',
    'export',
    'subscription', 'billing_payment', 'billing_owner'
  ));

-- System billing events (expiry, Paystack webhooks, the existing-network
-- migration) have no person behind them; the audit log shows "Elivate".
alter table audit.tenant_events alter column actor_user_id drop not null;

-- Trials and payments activate a network too (Blueprint 16).
alter table org.tenants drop constraint tenants_activation_source_check;
alter table org.tenants add constraint tenants_activation_source_check
  check (activation_source in ('admin', 'payment', 'trial'));

-- ── Privacy ───────────────────────────────────────────────────────────────

alter table billing.plans enable row level security;
alter table billing.provider_plans enable row level security;
alter table billing.subscriptions enable row level security;
alter table billing.periods enable row level security;
alter table billing.trials enable row level security;
alter table billing.payments enable row level security;
alter table billing.provider_events enable row level security;
alter table billing.owners enable row level security;

revoke all on all tables in schema billing from public, anon, authenticated;
revoke all on all sequences in schema billing from public, anon, authenticated;
revoke all on all functions in schema billing from public, anon, authenticated;
