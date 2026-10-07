create schema commercial;

create type commercial.subscription_status as enum (
  'active',
  'payment_due',
  'grace_period',
  'past_due',
  'suspended',
  'cancelled'
);

create type commercial.seat_capacity_decision as (
  allowed boolean,
  tenant_id uuid,
  candidate_user_id uuid,
  current_billable_users integer,
  projected_billable_users integer,
  capacity_limit integer,
  reason_code text
);

create table commercial.plans (
  id uuid primary key default extensions.gen_random_uuid(),
  plan_key text not null unique
    check (plan_key ~ '^[a-z][a-z0-9_]*$'),
  display_name text not null
    check (length(btrim(display_name)) > 0),
  created_at timestamptz not null default clock_timestamp()
);

create table commercial.plan_versions (
  id uuid primary key default extensions.gen_random_uuid(),
  plan_id uuid not null
    references commercial.plans (id) on delete restrict,
  version_number integer not null check (version_number > 0),
  minimum_covered_users integer not null
    check (minimum_covered_users > 0),
  maximum_covered_users integer
    check (maximum_covered_users is null or maximum_covered_users >= minimum_covered_users),
  list_price_amount numeric(20, 2) not null
    check (list_price_amount > 0),
  currency_code text not null
    check (currency_code ~ '^[A-Z]{3}$'),
  billing_cadence_code text
    check (
      billing_cadence_code is null
      or billing_cadence_code ~ '^[a-z][a-z0-9_]*$'
    ),
  effective_from date not null,
  effective_until date,
  created_at timestamptz not null default clock_timestamp(),
  unique (plan_id, version_number),
  check (effective_until is null or effective_until > effective_from)
);

create index plan_versions_capacity_lookup
  on commercial.plan_versions (
    minimum_covered_users,
    maximum_covered_users,
    effective_from
  );

create table commercial.extra_catalog (
  extra_key text primary key
    check (extra_key ~ '^[a-z][a-z0-9_]*$'),
  display_name text not null
    check (length(btrim(display_name)) > 0),
  created_at timestamptz not null default clock_timestamp()
);

create table commercial.tenant_subscriptions (
  id uuid primary key default extensions.gen_random_uuid(),
  tenant_id uuid not null
    references public.tenants (id) on delete restrict,
  plan_version_id uuid not null
    references commercial.plan_versions (id) on delete restrict,
  status commercial.subscription_status not null,
  is_current boolean not null default true,
  starts_at timestamptz not null,
  service_ends_at timestamptz,
  status_reason text not null
    check (length(btrim(status_reason)) > 0),
  status_changed_at timestamptz not null default clock_timestamp(),
  status_changed_by_user_id uuid
    references public.user_accounts (user_id) on delete restrict,
  superseded_at timestamptz,
  created_by_user_id uuid
    references public.user_accounts (user_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  unique (tenant_id, id),
  check (
    (is_current and superseded_at is null)
    or (not is_current and superseded_at is not null)
  ),
  check (service_ends_at is null or service_ends_at >= starts_at),
  check (superseded_at is null or superseded_at >= starts_at)
);

create unique index tenant_subscriptions_one_current
  on commercial.tenant_subscriptions (tenant_id)
  where is_current;

create index tenant_subscriptions_tenant_status
  on commercial.tenant_subscriptions (tenant_id, status)
  where is_current;

create table commercial.subscription_status_events (
  id bigint generated always as identity primary key,
  tenant_id uuid not null,
  subscription_id uuid not null,
  previous_status commercial.subscription_status,
  new_status commercial.subscription_status not null,
  reason text not null check (length(btrim(reason)) > 0),
  actor_user_id uuid
    references public.user_accounts (user_id) on delete restrict,
  occurred_at timestamptz not null default clock_timestamp(),
  foreign key (tenant_id, subscription_id)
    references commercial.tenant_subscriptions (tenant_id, id)
    on delete restrict,
  check (previous_status is null or previous_status <> new_status)
);

create index subscription_status_events_subscription_occurred
  on commercial.subscription_status_events (
    subscription_id,
    occurred_at desc
  );

create table commercial.billing_owner_assignments (
  id uuid primary key default extensions.gen_random_uuid(),
  tenant_id uuid not null
    references public.tenants (id) on delete restrict,
  membership_id uuid not null,
  owner_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  assigned_by_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  assignment_reason text not null
    check (length(btrim(assignment_reason)) > 0),
  started_at timestamptz not null default clock_timestamp(),
  ended_at timestamptz,
  ended_by_user_id uuid
    references public.user_accounts (user_id) on delete restrict,
  end_reason text,
  foreign key (tenant_id, membership_id)
    references public.memberships (tenant_id, id)
    on delete restrict,
  check (
    (ended_at is null and ended_by_user_id is null and end_reason is null)
    or (
      ended_at is not null
      and ended_by_user_id is not null
      and length(btrim(end_reason)) > 0
    )
  ),
  check (ended_at is null or ended_at >= started_at)
);

create unique index billing_owner_assignments_one_current
  on commercial.billing_owner_assignments (tenant_id)
  where ended_at is null;

create index billing_owner_assignments_membership_history
  on commercial.billing_owner_assignments (
    membership_id,
    started_at desc
  );

insert into commercial.plans (id, plan_key, display_name)
values
  ('c0000000-0000-4000-8000-000000000001', 'launch_up_to_400', 'Up to 400 covered users'),
  ('c0000000-0000-4000-8000-000000000002', 'launch_up_to_1000', 'Up to 1,000 covered users'),
  ('c0000000-0000-4000-8000-000000000003', 'launch_1001_plus', '1,001 or more covered users');

insert into commercial.plan_versions (
  id,
  plan_id,
  version_number,
  minimum_covered_users,
  maximum_covered_users,
  list_price_amount,
  currency_code,
  billing_cadence_code,
  effective_from
)
values
  (
    'c1000000-0000-4000-8000-000000000001',
    'c0000000-0000-4000-8000-000000000001',
    1, 1, 400, 700000.00, 'NGN', null, '2026-09-20'
  ),
  (
    'c1000000-0000-4000-8000-000000000002',
    'c0000000-0000-4000-8000-000000000002',
    1, 401, 1000, 1000000.00, 'NGN', null, '2026-09-20'
  ),
  (
    'c1000000-0000-4000-8000-000000000003',
    'c0000000-0000-4000-8000-000000000003',
    1, 1001, null, 1500000.00, 'NGN', null, '2026-09-20'
  );

insert into commercial.extra_catalog (extra_key, display_name)
values
  ('custom_branding', 'Custom Branding'),
  ('data_migration', 'Data Migration'),
  ('enhanced_support', 'Enhanced Support'),
  ('special_integrations', 'Special Integrations');

alter table authz.permission_catalog
  add column blocked_during_commercial_restriction boolean not null default false;

update authz.permission_catalog
   set blocked_during_commercial_restriction = true
 where permission_key in (
   'record_income',
   'approve_pocket_transfer',
   'transfer_between_own_pockets',
   'transfer_between_pockets_on_behalf',
   'reverse_transaction',
   'manual_credit_debit_adjustment',
   'perform_currency_conversion',
   'approve_withdrawal',
   'initiate_own_withdrawal',
   'record_returned_funds',
   'withdraw_on_behalf'
 );

comment on schema commercial is
  'Private commercial truth for versioned plans, tenant subscriptions, capacity, and Billing Owner history.';
comment on column commercial.plan_versions.billing_cadence_code is
  'Intentionally nullable until the launch billing cadence is approved.';
comment on table commercial.extra_catalog is
  'Approved optional extras only; pricing and activation lifecycle are deferred.';
comment on column commercial.tenant_subscriptions.status_changed_by_user_id is
  'Trusted actor or null for a system-originated status change.';
comment on column authz.permission_catalog.blocked_during_commercial_restriction is
  'True only for new money-moving actions blocked by an effective commercial suspension or cancellation.';
