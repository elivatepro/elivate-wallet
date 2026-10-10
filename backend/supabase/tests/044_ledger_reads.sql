-- Blueprint 04 — B6 044: own wallet (decision 21), managed wallets, activity,
-- office subtree totals (W-05) and closed offices (decision 23).
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(31);

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
create function pg_temp.m(n int, p_office uuid default null) returns uuid language sql stable as $$
  select id from org.memberships
  where user_id = pg_temp.u(n) and status = 'active' and office_id is not distinct from p_office
  order by started_at desc, id limit 1
$$;
create function pg_temp.ws(n int) returns uuid language sql stable as $$
  select id from org.memberships where user_id = pg_temp.u(n) and status = 'active'
  order by (role = 'member'), started_at limit 1
$$;
create function pg_temp.inc(n int, p_target uuid, p_amount text, p_currency text default 'NGN') returns jsonb
language plpgsql as $$
declare
  key text := pg_temp.k();
  e uuid;
begin
  e := (api.create_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_target, key, 'receipt.pdf',
    'application/pdf', 1000, repeat('b', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 1000, repeat('b', 64), 'application/pdf');
  return api.record_income(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_target, p_currency, p_amount, 'Fiverr',
    to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null, array[e], key);
end $$;
create function pg_temp.uids(p_items jsonb) returns text[] language sql immutable as
  $$ select coalesce(array_agg(i->'person'->>'uid' order by i->'person'->>'uid'), '{}') from jsonb_array_elements(p_items) i $$;
create function pg_temp.managed(n int) returns text[] language sql volatile as
  $$ select pg_temp.uids(api.list_managed_wallets(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n))->'items') $$;
create function pg_temp.totals(n int, p_office uuid, p_currency text) returns text language sql volatile as $$
  select c->>'posted' from jsonb_array_elements(api.office_totals(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_office)->'currencies') c
  where c->>'currency' = p_currency
$$;
create function pg_temp.mine(n int) returns jsonb language sql volatile as
  $$ select api.my_wallet(pg_temp.u(n), pg_temp.s(n)) $$;
create function pg_temp.network(p_wallet jsonb, p_name text) returns jsonb language sql immutable as
  $$ select n from jsonb_array_elements(p_wallet->'networks') n where n->>'name' = p_name $$;
create function pg_temp.posted(p_network jsonb, p_currency text) returns text language sql immutable as
  $$ select c->>'posted' from jsonb_array_elements(p_network->'currencies') c where c->>'currency' = p_currency $$;

-- 1 President · 2 World Team · 3 Director · 4 TL (T) · 5 TL (T2) · 6 member (T, and Abuja)
-- 7 member (T2) · 9 Abuja founder · 10 admin · 11 Abuja TL
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 11) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 11) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 11) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
insert into ids
select 'other', (api.start_network(pg_temp.u(9), pg_temp.s(9), 'Abuja Network', 'ABJ', pg_temp.k())->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), 'Pilot', pg_temp.k());
  perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('other'), 'Pilot', pg_temp.k());
end $$;
insert into ids
select 'W', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'world_team', 'North', null, array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', pg_temp.id('W'), array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'), array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T2', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team B', pg_temp.id('D'), array[pg_temp.uid(5)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'O', (api.create_office(pg_temp.u(9), pg_temp.s(9), pg_temp.m(9), 'team_leader', 'Abuja Team', null, array[pg_temp.uid(11)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(6), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), pg_temp.uid(7), pg_temp.k());
  perform api.add_membership(pg_temp.u(9), pg_temp.s(9), pg_temp.m(9), pg_temp.id('O'), pg_temp.uid(6), pg_temp.k());
end $$;
insert into ids values ('m6', pg_temp.m(6, pg_temp.id('T'))), ('m6o', pg_temp.m(6, pg_temp.id('O'))),
  ('m7', pg_temp.m(7, pg_temp.id('T2'))), ('m3', pg_temp.m(3, pg_temp.id('D')));
insert into ids select 'tx_lagos', (pg_temp.inc(4, pg_temp.id('m6'), '1000.00')->>'transactionId')::uuid;
insert into ids select 'tx_usd', (pg_temp.inc(1, pg_temp.id('m6'), '50.00', 'USD')->>'transactionId')::uuid;
insert into ids select 'tx_abuja', (pg_temp.inc(11, pg_temp.id('m6o'), '200.00')->>'transactionId')::uuid;
insert into ids select 'tx_7', (pg_temp.inc(1, pg_temp.id('m7'), '300.00')->>'transactionId')::uuid;
insert into ids select 'tx_3', (pg_temp.inc(1, pg_temp.id('m3'), '25.00')->>'transactionId')::uuid;

-- ── Own wallet (18) ──
select is(jsonb_array_length(pg_temp.mine(6)->'networks'), 2, 'each network is shown separately');
select is(pg_temp.posted(pg_temp.network(pg_temp.mine(6), 'Lagos Network'), 'NGN'), '1000.00', 'per network and currency');
select is(pg_temp.posted(pg_temp.network(pg_temp.mine(6), 'Lagos Network'), 'USD'), '50.00', 'currencies are never mixed');
select is(
  (select jsonb_typeof(p->'available') from jsonb_array_elements(pg_temp.network(pg_temp.mine(6), 'Lagos Network')->'currencies'->0->'pockets') p limit 1),
  'string', 'pocket balances are strings'
);
select is(
  (select jsonb_array_length(c->'pockets')
   from jsonb_array_elements(pg_temp.network(pg_temp.mine(6), 'Lagos Network')->'currencies') c where c->>'currency' = 'NGN'),
  5, 'per pocket'
);
select throws_ok($$ select api.my_wallet(pg_temp.u(9), pg_temp.s(9)) $$, 'P0001', 'no_wallet', 'President-only accounts have no wallet');

-- ── Activity ──
select is(jsonb_array_length(api.my_activity(pg_temp.u(6), pg_temp.s(6))->'items'), 3, 'own activity lists every movement');
select is(jsonb_array_length(api.my_activity(pg_temp.u(6), pg_temp.s(6), p_currency => 'USD')->'items'), 1, 'currency filter');
select is(jsonb_array_length(api.my_activity(pg_temp.u(6), pg_temp.s(6), p_direction => 'out')->'items'), 0, 'direction filter');
create function pg_temp.walk() returns text[] language plpgsql as $$
declare
  cursor_ text;
  page jsonb;
  seen text[] := '{}';
begin
  loop
    page := api.my_activity(pg_temp.u(6), pg_temp.s(6), p_cursor => cursor_, p_limit => 1);
    seen := seen || (select array_agg((i->>'transactionId') || (i->>'currency')) from jsonb_array_elements(page->'items') i);
    cursor_ := page->>'nextCursor';
    exit when cursor_ is null or cardinality(seen) > 10;
  end loop;
  return seen;
end $$;
select is(
  (select count(distinct x)::int from unnest(pg_temp.walk()) x) || '/' || cardinality(pg_temp.walk()),
  '3/3', 'paging with equal timestamps neither skips nor repeats'
);
select is(
  (api.my_transaction(pg_temp.u(6), pg_temp.s(6), pg_temp.id('tx_lagos'))->'income'->>'source'), 'Fiverr',
  'transaction detail carries the income facts'
);
select is(
  jsonb_array_length(api.my_transaction(pg_temp.u(6), pg_temp.s(6), pg_temp.id('tx_lagos'))->'income'->'receipts'), 1,
  'and its receipts'
);
select throws_ok($$ select api.my_transaction(pg_temp.u(6), pg_temp.s(6), pg_temp.id('tx_7')) $$, 'P0001', 'not_found',
  'someone else''s transaction is not found');

-- ── Managed wallets (19) ──
select is(pg_temp.managed(4), array[pg_temp.uid(6)], 'a Team Leader sees their office');
select is(pg_temp.managed(3), (select array_agg(x order by x) from unnest(array[pg_temp.uid(6), pg_temp.uid(7)]) x),
  'a Director sees the subtree, never themselves');
select is(
  pg_temp.posted(api.managed_wallet(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), ledger.wallet_for(pg_temp.u(6)))->'networks'->0, 'NGN'),
  '1000.00', 'one member''s wallet, this network only'
);
select is(jsonb_array_length(api.managed_wallet(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), ledger.wallet_for(pg_temp.u(6)))->'networks'), 1,
  'no other network leaks in');
select throws_ok($$ select api.managed_wallet(pg_temp.u(5), pg_temp.s(5), pg_temp.ws(5), ledger.wallet_for(pg_temp.u(6))) $$,
  'P0001', 'not_found', 'a sibling Team Leader cannot open it');
select is(jsonb_array_length(api.managed_wallet_activity(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), ledger.wallet_for(pg_temp.u(6)))->'items'), 2,
  'managed activity covers only visible segments');
select throws_ok(
  $$ select api.managed_transaction(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), ledger.wallet_for(pg_temp.u(6)), pg_temp.id('tx_abuja')) $$,
  'P0001', 'not_found', 'another network''s transaction is not found'
);

-- ── Office totals (20) ──
select is(pg_temp.totals(1, pg_temp.id('D'), 'NGN'), '1325.00', 'subtree total per currency');
select is(pg_temp.totals(1, pg_temp.id('D'), 'USD'), '50.00', 'currencies stay separate');
do $$ begin
  perform api.create_access_assignment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(3),
    jsonb_build_array(
      jsonb_build_object('permission', 'view_managed_wallets', 'effect', 'deny', 'scopeType', 'member', 'scopeUid', pg_temp.uid(6)),
      jsonb_build_object('permission', 'view_scoped_financial_reports', 'effect', 'deny', 'scopeType', 'member', 'scopeUid', pg_temp.uid(6))),
    'Related party', pg_temp.k());
end $$;
select is(pg_temp.managed(3), array[pg_temp.uid(7)], 'a member deny hides that member');
select is(pg_temp.totals(3, pg_temp.id('D'), 'NGN'), '300.00', 'denied scope does not count');
select is(
  (api.office_totals(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('D'))->'excluded'->>'members')::int, 2,
  'and is reported as excluded (the denied member and the viewer''s own money)'
);
do $$ begin
  perform api.place_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), pg_temp.id('W'), 'Restructure', pg_temp.k());
end $$;
select is(pg_temp.totals(1, pg_temp.id('D'), 'NGN'), '1025.00', 're-placing an office moves its totals away');
select is(pg_temp.totals(1, pg_temp.id('W'), 'NGN'), '1325.00', 'and its new ancestors include them');

-- ── Closed office (decision 23) ──
update org.offices set status = 'closed' where id = pg_temp.id('T');
select ok(pg_temp.uid(6) = any (pg_temp.managed(2)), 'a higher-up leader still sees money from a closed office');
select ok(pg_temp.uid(6) = any (pg_temp.managed(1)), 'so does the President Team');
select ok(not (pg_temp.uid(6) = any (pg_temp.managed(5))), 'a leader outside the subtree does not');

-- ── Left network, suspended network (decision 21) ──
do $$ begin
  perform api.end_membership(pg_temp.u(9), pg_temp.s(9), pg_temp.m(9), pg_temp.id('m6o'), 'Left', pg_temp.k());
end $$;
update org.tenants set status = 'suspended' where id = pg_temp.id('other');
select is(pg_temp.posted(pg_temp.network(pg_temp.mine(6), 'Abuja Network'), 'NGN'), '200.00',
  'own money stays visible after leaving a suspended network');

select * from finish();
rollback;
