-- Blueprint 16 — B6 162: checkout, verified payments applied exactly once,
-- forged amounts and wrong modes refused, year maths (end of trial/period,
-- or at payment), proration in exact kobo, upgrades, stale payments,
-- automatic renewals, webhook deduplication and no cross-tenant access.
begin;
create extension if not exists pgtap with schema extensions;
select plan(52);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.k() returns text language sql volatile as
  $$ select 'k' || md5(random()::text || clock_timestamp()::text) $$;
create temp table ids (name text primary key, id uuid not null);
create function pg_temp.id(p_name text) returns uuid language sql stable as
  $$ select id from ids where name = p_name $$;
create function pg_temp.m(n int) returns uuid language sql stable as $$
  select id from org.memberships where user_id = pg_temp.u(n) and status = 'active' and office_id is null
  order by started_at desc, id limit 1
$$;
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
create function pg_temp.checkout(n int, p_plan text, p_kind text, p_key text default null) returns jsonb
language sql volatile as $$
  select api.billing_checkout(pg_temp.u(n), pg_temp.s(n), pg_temp.m(n), p_plan, p_kind, 'test', coalesce(p_key, pg_temp.k()))
$$;
create function pg_temp.pay(p_checkout jsonb, p_kobo bigint default null, p_env text default 'test',
  p_currency text default 'NGN') returns jsonb language sql volatile as $$
  select api.billing_apply_verified(p_checkout->>'providerReference',
    coalesce(p_kobo, (p_checkout->>'amountKobo')::bigint), p_currency, now(), 4099260516, 'CUS_test001', true, p_env)
$$;
create function pg_temp.sub(p_tenant text) returns billing.subscriptions language sql stable as
  $$ select * from billing.subscriptions where tenant_id = pg_temp.id(p_tenant) $$;
create function pg_temp.plan(p_tenant text) returns text language sql stable as
  $$ select p.key from billing.plans p join billing.subscriptions s on s.plan_id = p.id where s.tenant_id = pg_temp.id(p_tenant) $$;

-- 1 founder (trial, Cedar) · 2 founder (pending, Oak) · 3 founder (trial, Pine) · 4 Cedar member
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 4) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 4) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 4) n; end $$;
insert into ids select 'cedar', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Cedar Network', 'CDR', pg_temp.k(), null,
  'band_400', true)->>'tenantId')::uuid;
insert into ids select 'oak', (api.start_network(pg_temp.u(2), pg_temp.s(2), 'Oak Network', 'OAK', pg_temp.k(), null,
  'band_1000', false)->>'tenantId')::uuid;
insert into ids select 'pine', (api.start_network(pg_temp.u(3), pg_temp.s(3), 'Pine Network', 'PIN', pg_temp.k(), null,
  'band_400', true)->>'tenantId')::uuid;
insert into ids select 'WT', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'world_team', 'World', null,
  array[(select uid from identity.accounts where user_id = pg_temp.u(4))], pg_temp.k())->>'officeId')::uuid;

-- ── Proration in exact kobo (5) ──
select is(billing.prorate(700000.00, 1000000.00, 155), 127397.26, 'Paper PL05: ₦300,000 × 155 ÷ 365 = ₦127,397.26');
select is(billing.prorate(700000.00, 1000000.00, 365), 300000.00, 'a whole year is the whole difference');
select is(billing.prorate(700000.00, 1500000.00, 1), 2191.78, 'one day, half-up to the kobo');
select is(billing.prorate(1000000.00, 1500000.00, 0), 0.00, 'the last paid day costs nothing');
select is(billing.days_left(((billing.today() + 156)::timestamp at time zone billing.zone())), 155,
  'days run from today to the last paid day');

-- ── Checkout during the trial (6) ──
create temp table c1 as select pg_temp.checkout(1, 'band_400', 'year', 'k-checkout-cedar-001') as r;
select is((select r->>'purpose' from c1), 'renew', 'paying during the trial buys the year after it');
select is((select r->>'amount' || ' ' || (r->>'currency') from c1), '700000.00 NGN', 'the server sets the price');
select is((select (r->>'amountKobo')::bigint from c1), 70000000::bigint, 'kobo for Paystack');
select matches((select r->>'reference' from c1), '^PAY-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$', 'a PAY reference');
select isnt((select r->>'providerReference' from c1), (select r->>'reference' from c1),
  'the Paystack reference is separate from the public one');
select is((pg_temp.checkout(1, 'band_400', 'year', 'k-checkout-cedar-001')->>'paymentId'), (select r->>'paymentId' from c1),
  'the same key returns the same checkout');

select is((api.billing_checkout_opened(pg_temp.u(1), (select (r->>'paymentId')::uuid from c1),
  'https://checkout.paystack.com/abc123xyz')->>'paymentId'), (select r->>'paymentId' from c1),
  'the Paystack page is recorded for the open checkout');
select is(pg_temp.fails($$ select api.billing_checkout_opened(pg_temp.u(1), (select (r->>'paymentId')::uuid from c1),
  'javascript:alert(1)') $$), 'validation_error:', 'only an http(s) page');

-- ── Forged and misdirected payments (6) ──
select is((pg_temp.pay((select r from c1), 69999999)->>'outcome'), 'amount_mismatch', 'a forged amount is refused');
select is((pg_temp.sub('cedar')).status::text, 'trial', 'nothing activates on a forged amount');
select is((select status || '/' || needs_review::text from billing.payments where id = (select (r->>'paymentId')::uuid from c1)),
  'failed/true', 'the payment is failed and flagged');
create temp table c2 as select pg_temp.checkout(1, 'band_400', 'year') as r;
select is((pg_temp.pay((select r from c2), null, 'live')->>'outcome'), 'wrong_environment', 'a live charge cannot pay a test checkout');
select is((pg_temp.pay((select r from c2), null, 'test', 'USD')->>'outcome'), 'amount_mismatch', 'the currency must be NGN');
create temp table c3 as select pg_temp.checkout(1, 'band_400', 'year') as r;
select is((api.billing_apply_verified('ewp_doesnotexist0000', 70000000, 'NGN', now(), 1, null, false, 'test')->>'outcome'),
  'unknown_reference', 'an unknown reference changes nothing');

-- ── A verified trial payment (8) ──
create temp table trial_end as select period_end as at from billing.subscriptions where tenant_id = pg_temp.id('cedar');
select is((pg_temp.pay((select r from c3))->>'outcome'), 'applied', 'a verified payment applies');
select is((pg_temp.sub('cedar')).status::text || '/' || (pg_temp.sub('cedar')).kind::text, 'active/paid', 'the network is paid');
select is((pg_temp.sub('cedar')).period_start, (select at from trial_end), 'the paid year starts when the trial ends');
select is((pg_temp.sub('cedar')).period_end, (select at + interval '1 year' from trial_end), 'one year');
select is((pg_temp.pay((select r from c3))->>'outcome'), 'duplicate', 'a replayed webhook applies nothing');
select is((select count(*)::int from billing.periods where tenant_id = pg_temp.id('cedar') and kind = 'paid'), 1,
  'one paid year, however many replays');
select is((select count(*)::int from notify.items where kind = 'billing.payment_received' and user_id = pg_temp.u(1)), 1,
  'B01 to the Billing Owner');
select is((select params->>'reference' from outbox.events where template = 'billing.payment_received' limit 1),
  (select r->>'reference' from c3), 'the receipt shows the PAY reference');

-- ── Pay-first network (3) ──
create temp table c4 as select pg_temp.checkout(2, 'band_1000', 'year') as r;
select is((select r->>'purpose' from c4), 'start', 'the first payment starts the network');
select is((pg_temp.pay((select r from c4))->>'outcome'), 'applied', 'applied');
select is((select status::text || '/' || activation_source from org.tenants where id = pg_temp.id('oak')),
  'active/payment', 'opened by the payment, the year from today');

-- ── Upgrades (10) ──
update billing.subscriptions
set period_start = now() - interval '200 days', period_end = ((billing.today() + 156)::timestamp at time zone billing.zone())
where tenant_id = pg_temp.id('cedar');
select is((select p->>'amount' from jsonb_array_elements(api.billing_overview(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1))->'plans') p
  where p->>'key' = 'band_1000'), '127397.26', 'the plan list quotes the prorated upgrade');
select is(pg_temp.fails($$ select pg_temp.checkout(1, 'band_1000', 'year') $$), 'conflict:use_upgrade',
  'a bigger band mid-year is an upgrade');
select is(pg_temp.fails($$ select pg_temp.checkout(1, 'band_400', 'upgrade') $$), 'conflict:not_upgradable',
  'no upgrade to the same band');
create temp table u1 as select pg_temp.checkout(1, 'band_1000', 'upgrade') as r;
select is((select r->>'amount' from u1), '127397.26', 'the upgrade charges the prorated difference');
create temp table u2 as select pg_temp.checkout(1, 'band_1000', 'upgrade') as r;
select is((select status from billing.payments where id = (select (r->>'paymentId')::uuid from u1)), 'superseded',
  'a new checkout supersedes the open one');
select is((pg_temp.pay((select r from u2))->>'outcome'), 'applied', 'the upgrade applies');
select is(pg_temp.plan('cedar'), 'band_1000', 'the bigger band applies at once');
select is((pg_temp.sub('cedar')).period_end, ((billing.today() + 156)::timestamp at time zone billing.zone()),
  'the paid year does not change');
select is((pg_temp.pay((select r from u1))->>'outcome'), 'needs_review', 'a stale upgrade paid late is flagged');
select is((select status || '/' || applied::text || '/' || needs_review::text from billing.payments
  where id = (select (r->>'paymentId')::uuid from u1)), 'paid/false/true', 'recorded as paid, not applied, for support');

-- ── Renewing while auto-renew is on (1) ──
update billing.subscriptions set provider_subscription_code = 'SUB_test0001', reusable_card = true, auto_renew = true,
  sync_state = 'none' where tenant_id = pg_temp.id('cedar');
select is(pg_temp.fails($$ select pg_temp.checkout(1, 'band_1000', 'year') $$), 'conflict:auto_renew_on',
  'no manual renewal while the card renews it');

-- ── Automatic renewal (6) ──
select api.billing_set_plan_code(id, 'test', 'PLN_' || replace(key, '_', '')) from billing.plans;
update billing.subscriptions set provider_plan_code = 'PLN_band1000', provider_customer_code = 'CUS_test001'
where tenant_id = pg_temp.id('cedar');
create temp table before_renewal as select period_end as at from billing.subscriptions where tenant_id = pg_temp.id('cedar');
select is((api.billing_record_renewal('T_renew_000000001', 'SUB_test0001', 'CUS_test001', 'PLN_band1000', 99900000, 'NGN',
  now(), 5, true, 'test')->>'outcome'), 'amount_mismatch', 'a renewal must charge the plan price');
select is((api.billing_record_renewal('T_renew_000000002', 'SUB_test0001', 'CUS_test001', 'PLN_band1000', 100000000, 'NGN',
  now(), 6, true, 'test')->>'outcome'), 'applied', 'the yearly charge renews');
select is((pg_temp.sub('cedar')).period_end, (select at + interval '1 year' from before_renewal),
  'one more year from the end of the current one');
select is((api.billing_record_renewal('T_renew_000000002', 'SUB_test0001', 'CUS_test001', 'PLN_band1000', 100000000, 'NGN',
  now(), 6, true, 'test')->>'outcome'), 'duplicate', 'the same charge twice renews once');
select is((api.billing_record_renewal('T_renew_000000003', 'SUB_unknown01', 'CUS_nobody', 'PLN_band1000', 100000000, 'NGN',
  now(), 7, true, 'test')->>'outcome'), 'unmatched', 'a charge for no known subscription changes nothing');
select is((select purpose from billing.payments where provider_reference = 'T_renew_000000002'), 'auto_renewal',
  'recorded as an automatic renewal with its own PAY reference');

-- ── Webhook deduplication (2) ──
select is((api.billing_record_event('charge.success:42', 'charge.success', repeat('a', 64))->>'duplicate')::boolean, false,
  'a new event is processed');
select api.billing_event_done((api.billing_record_event('charge.success:42', 'charge.success', repeat('a', 64))->>'eventId')::bigint,
  'applied');
select is((api.billing_record_event('charge.success:42', 'charge.success', repeat('a', 64))->>'duplicate')::boolean, true,
  'a processed event is a duplicate');

-- ── Access and isolation (3) ──
select is(pg_temp.fails($$ select api.billing_payment(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3),
  (select (r->>'paymentId')::uuid from c3)) $$), 'not_found:', 'no payment of another network');
select is(pg_temp.fails($$ select api.billing_overview(pg_temp.u(4), pg_temp.s(4),
  (select id from org.memberships where user_id = pg_temp.u(4) and status = 'active' limit 1)) $$),
  'authorization_denied:', 'members without authority or ownership see no billing');
select is(jsonb_typeof(api.billing_payment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1),
  (select (r->>'paymentId')::uuid from c3))->'verify'), 'null', 'a paid payment needs no further check');

select * from finish();
rollback;
