-- Blueprint 16 — review fixes: sync versions, seats against next year's
-- smaller band (paused reads that share command checks: 163).
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(7);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.uid(n int) returns text language sql stable as
  $$ select uid from identity.accounts where user_id = pg_temp.u(n) $$;
create function pg_temp.k() returns text language sql volatile as
  $$ select 'k' || md5(random()::text || clock_timestamp()::text) $$;
create temp table ids (name text primary key, id uuid not null);
create function pg_temp.id(p_name text) returns uuid language sql stable as
  $$ select id from ids where name = p_name $$;
create function pg_temp.ws(n int) returns uuid language sql stable as $$
  select id from org.memberships where user_id = pg_temp.u(n) and status = 'active'
  order by (role = 'member'), started_at limit 1
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
create function pg_temp.sub() returns billing.subscriptions language sql stable as
  $$ select * from billing.subscriptions where tenant_id = pg_temp.id('t') $$;

insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 6) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 6) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 6) n; end $$;
insert into ids select 't', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Cedar Network', 'CDR', pg_temp.k(), null,
  'band_400', true)->>'tenantId')::uuid;
insert into ids select 'WT', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), 'world_team', 'World', null,
  array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
-- A paid year on the 1,000 band with a saved card.
update billing.subscriptions set status = 'active', kind = 'paid', plan_id = (billing.plan('band_1000')).id,
  period_start = now() - interval '10 days', period_end = now() + interval '200 days', reusable_card = true,
  provider_customer_code = 'CUS_t0001', sync_state = 'none' where tenant_id = pg_temp.id('t');

-- ── Sync versions (3) ──
select billing.mark_sync(pg_temp.id('t'));
create temp table job as select api.billing_sync_claim(10)->0 as j;
select api.billing_set_auto_renew(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), false, pg_temp.k());
select api.billing_sync_done(pg_temp.id('t'), (select (j->>'version')::bigint from job), 'ok', 'SUB_old0001', 'tok', 'PLN_x1');
select is((pg_temp.sub()).sync_state, 'pending', 'a change made during the sync stays queued');
select is((pg_temp.sub()).provider_subscription_code, 'SUB_old0001', 'what Paystack holds is still recorded');
create temp table job2 as select api.billing_sync_claim(10)->0 as j;
select api.billing_sync_done(pg_temp.id('t'), (select (j->>'version')::bigint from job2), 'ok', null, null, null);
select is((pg_temp.sub()).sync_state, 'none', 'the current job clears the queue');

-- ── Next year's smaller band (3) ──
update billing.subscriptions set next_plan_id = (billing.plan('band_400')).id where tenant_id = pg_temp.id('t');
-- Fill to the smaller cap with synthetic people.
with people as (
  insert into auth.users (id, email, aud, role)
  select gen_random_uuid(), 'n' || n || '@fill.test', 'authenticated', 'authenticated'
  from generate_series(1, 400 - billing.seats_used(pg_temp.id('t'))) n returning id)
insert into org.memberships (tenant_id, office_id, user_id, role, is_primary, created_by)
select pg_temp.id('t'), pg_temp.id('WT'), id, 'member', true, pg_temp.u(1) from people;
select lives_ok($$ select api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('WT'), pg_temp.uid(3), pg_temp.k()) $$,
  'the current 1,000 band still has room');
select is((pg_temp.sub()).next_plan_id, null, 'an unpaid smaller choice that no longer fits is dropped');
update billing.subscriptions set next_plan_id = (billing.plan('band_400')).id, plan_change_at = period_end
where tenant_id = pg_temp.id('t');
select is(pg_temp.fails($$ select api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('WT'), pg_temp.uid(4), pg_temp.k()) $$),
  'conflict:seat_limit_reached', 'a paid smaller year caps seats now');

-- ── Adoption filter (1) ──
update billing.subscriptions set provider_subscription_code = 'SUB_mine00001' where tenant_id = pg_temp.id('t');
select is(api.billing_unclaimed_subscriptions(gen_random_uuid(), array['SUB_mine00001', 'SUB_free00001']),
  '["SUB_free00001"]'::jsonb, 'another network never adopts a subscription this one recorded');

select * from finish();
rollback;
