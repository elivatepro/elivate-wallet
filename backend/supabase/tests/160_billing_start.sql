-- Blueprint 16 — B6 160: plans, founder start, one trial per founder ever,
-- skip-trial pay-first, the founder as Billing Owner, setup reads and the
-- support activation (complimentary period / development exception).
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(32);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.k() returns text language sql volatile as
  $$ select 'k' || md5(random()::text || clock_timestamp()::text) $$;
create temp table ids (name text primary key, id uuid not null);
create function pg_temp.id(p_name text) returns uuid language sql stable as
  $$ select id from ids where name = p_name $$;
create function pg_temp.fails(p_sql text) returns text language plpgsql as $$
declare
  msg text;
  detail text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics msg = message_text, detail = pg_exception_detail;
  return msg || ':' || coalesce(case when detail like '{%' then detail::jsonb->>'reason' end, '');
end $$;
create function pg_temp.start(n int, p_name text, p_plan text, p_trial boolean, p_key text default null)
returns jsonb language sql volatile as $$
  select api.start_network(pg_temp.u(n), pg_temp.s(n), p_name, left(p_name, 3), coalesce(p_key, pg_temp.k()), null,
    p_plan, p_trial)
$$;

-- 1 founder (trial) · 2 founder (skips the trial) · 9 platform admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 9) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 9) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 9) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(9), 'Test admin');

-- ── Plans (4) ──
select is((select count(*)::int from billing.plans where launch), 3, 'three launch bands');
select is((select string_agg(key || '=' || price::text || '/' || coalesce(seat_cap::text, '-'), ', ' order by rank)
  from billing.plans), 'band_400=700000.00/400, band_1000=1000000.00/1000, band_1001_plus=1500000.00/-',
  'D-10 prices in NGN with VAT, and caps');
select throws_ok($$ update billing.plans set price = 1 where key = 'band_400' $$, 'P0001', 'invariant_violation',
  'plans are immutable');
select is((api.billing_setup(pg_temp.u(1), pg_temp.s(1))->>'trialAvailable')::boolean, true,
  'a new founder may start a trial');

-- ── Trial start (9) ──
select is(pg_temp.fails($$ select pg_temp.start(1, 'Cedar Network', 'band_1000', true) $$), 'conflict:trial_plan',
  'the trial is only on the smallest band');
create temp table t1 as select pg_temp.start(1, 'Cedar Network', 'band_400', true, 'k-start-cedar-0001') as r;
insert into ids select 'cedar', (r->>'tenantId')::uuid from t1;
select is((select r->>'status' from t1), 'active', 'a trial network is active at once');
select is((select status::text || '/' || activation_source from org.tenants where id = pg_temp.id('cedar')),
  'active/trial', 'activated by the trial');
select is((select status::text || '/' || kind::text from billing.subscriptions where tenant_id = pg_temp.id('cedar')),
  'trial/trial', 'the subscription is a trial');
select is((select period_end - period_start from billing.subscriptions where tenant_id = pg_temp.id('cedar')),
  interval '7 days', 'seven days');
select is((select count(*)::int from ledger.allocation_policies where tenant_id = pg_temp.id('cedar')), 1,
  'the pocket split is seeded on activation');
select is((select user_id from billing.owners where tenant_id = pg_temp.id('cedar') and ended_at is null), pg_temp.u(1),
  'the founder is the Billing Owner');
select is((pg_temp.start(1, 'Cedar Network', 'band_400', true, 'k-start-cedar-0001')->>'replayed')::boolean, true,
  'the same key replays');
select is((select count(*)::int from org.tenants where created_by = pg_temp.u(1)), 1, 'a replay starts nothing new');

-- ── One trial per founder, ever (5) ──
select is(pg_temp.fails($$ select pg_temp.start(1, 'Second Network', 'band_400', true) $$), 'conflict:trial_used',
  'a founder gets one trial');
select is((api.billing_setup(pg_temp.u(1), pg_temp.s(1))->>'trialAvailable')::boolean, false,
  'setup says the trial is used');
create temp table t2 as select pg_temp.start(1, 'Second Network', 'band_1000', false) as r;
insert into ids select 'second', (r->>'tenantId')::uuid from t2;
select is((select r->>'status' from t2), 'pending_payment', 'further networks pay before they open');
select is((select status::text || '/' || kind::text from billing.subscriptions where tenant_id = pg_temp.id('second')),
  'pending/paid', 'awaiting the first payment');
select is(jsonb_array_length(api.billing_setup(pg_temp.u(1), pg_temp.s(1))->'pending'), 1,
  'setup lists the network awaiting payment');

-- ── Skip the trial (4) ──
create temp table t3 as select pg_temp.start(2, 'Oak Network', 'band_1001_plus', false) as r;
insert into ids select 'oak', (r->>'tenantId')::uuid from t3;
select is((select r->>'status' from t3), 'pending_payment', 'skipping the trial waits for payment');
select is((select key from billing.plans p join billing.subscriptions s on s.plan_id = p.id
  where s.tenant_id = pg_temp.id('oak')), 'band_1001_plus', 'any launch band can be chosen');
select is((api.billing_setup(pg_temp.u(2), pg_temp.s(2))->>'trialAvailable')::boolean, true,
  'skipping does not use the trial');
select is(pg_temp.fails($$ select api.create_office(pg_temp.u(2), pg_temp.s(2),
  (select id from org.memberships where user_id = pg_temp.u(2)), 'world_team', 'WT', null, array[]::text[], pg_temp.k()) $$),
  'network_not_active:', 'nothing works before the first payment');

-- ── Overview for a network awaiting payment (2) ──
select is((api.billing_overview(pg_temp.u(2), pg_temp.s(2),
  (select id from org.memberships where user_id = pg_temp.u(2)))->>'status'), 'pending',
  'the founder can open Billing to pay');
select is((select count(*)::int from jsonb_array_elements(api.billing_overview(pg_temp.u(2), pg_temp.s(2),
  (select id from org.memberships where user_id = pg_temp.u(2)))->'plans') p where p->>'action' = 'choose'), 3,
  'every band can be chosen');

-- ── Support activation (8) ──
select throws_ok($$ select api.activate_tenant(pg_temp.u(1), pg_temp.s(1), pg_temp.id('oak'), 'Paid offline', pg_temp.k()) $$,
  'P0001', 'authorization_denied', 'only platform admins');
select is((api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('oak'), 'Support grant', pg_temp.k(), null,
  (billing.today() + 30))->>'status'), 'active', 'a complimentary period activates');
select is((select kind::text || '/' || status::text from billing.subscriptions where tenant_id = pg_temp.id('oak')),
  'complimentary/active', 'recorded as complimentary');
select is((select billing.last_day(period_end) from billing.subscriptions where tenant_id = pg_temp.id('oak')),
  billing.today() + 30, 'until the given WAT day');
select is((select count(*)::int from billing.payments where tenant_id = pg_temp.id('oak')), 0, 'never a payment');
select is((api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('oak'), 'Development exception', pg_temp.k())
  ->>'status'), 'active', 'the development exception');
select is((select kind::text || '/' || coalesce(period_end::text, 'none') from billing.subscriptions
  where tenant_id = pg_temp.id('oak')), 'development/none', 'no end date');
select is(pg_temp.fails($$ select api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('oak'), 'Again', pg_temp.k()) $$),
  'conflict:not_pending', 'already the development exception');

select * from finish();
rollback;
