-- Blueprint 04 — B6 040: ledger invariants, projection, holds, exact decimals.
begin;
create extension if not exists pgtap with schema extensions;
select plan(36);

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
create function pg_temp.pocket(p_name text) returns uuid language sql stable as $$
  select id from ledger.pockets where tenant_id = pg_temp.id('tenant') and name = p_name
$$;
-- Segment of member 6 in a pocket and currency.
create function pg_temp.seg(p_pocket text, p_currency text default 'NGN') returns uuid language sql volatile as $$
  select ledger.segment_account(ledger.wallet_for(pg_temp.u(6)), pg_temp.m(6, pg_temp.id('T')), p_currency, pg_temp.pocket(p_pocket))
$$;
create function pg_temp.inflow(p_currency text default 'NGN') returns uuid language sql volatile as $$
  select ledger.system_account(pg_temp.id('tenant'), p_currency, 'external_inflow')
$$;
-- Posts one journal of (account, amount) pairs for member 6.
create function pg_temp.post(p_lines jsonb, p_currency text default 'NGN', p_consume jsonb default '[]') returns uuid
language sql volatile as $$
  select ledger.post('income', refs.issue('INC'), pg_temp.m(6, pg_temp.id('T')), pg_temp.u(1), pg_temp.k(),
    jsonb_build_array(jsonb_build_object('currency', p_currency, 'postings', p_lines)), p_consume)
$$;
create function pg_temp.line(p_account uuid, p_amount text) returns jsonb language sql immutable as
  $$ select jsonb_build_object('accountId', p_account, 'amount', p_amount) $$;
create function pg_temp.bal(p_account uuid) returns ledger.balances language sql stable as
  $$ select * from ledger.balances where account_id = p_account $$;

-- 1 President · 3 Director · 4 Team Leader · 6 member · 10 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 10) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 10) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 10) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), 'Pilot', pg_temp.k()); end $$;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', null, array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'), array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(6), pg_temp.k());
  perform ledger.backfill_wallets();
end $$;

insert into ids values ('pv', pg_temp.seg('Point Value')), ('sav', pg_temp.seg('Savings')),
  ('debt', pg_temp.seg('Debt')), ('in', pg_temp.inflow()), ('usd', pg_temp.seg('Savings', 'USD'));

-- ── Posting rules (1) ──
select throws_ok(
  $$ select pg_temp.post(jsonb_build_array(pg_temp.line(pg_temp.id('in'), '-10'), pg_temp.line(pg_temp.id('pv'), '9'))) $$,
  'P0001', 'invariant_violation', 'an unbalanced journal is rejected'
);
select throws_ok(
  $$ select pg_temp.post(jsonb_build_array(pg_temp.line(pg_temp.id('pv'), '0'))) $$,
  'P0001', 'invariant_violation', 'a single-posting journal is rejected'
);
select throws_ok(
  $$ select pg_temp.post(jsonb_build_array(pg_temp.line(pg_temp.id('in'), '-10'), pg_temp.line(pg_temp.id('usd'), '10'))) $$,
  'P0001', 'invariant_violation', 'a journal cannot mix currencies'
);
select throws_ok(
  $$ select pg_temp.post(jsonb_build_array(pg_temp.line(pg_temp.id('in'), '0'), pg_temp.line(pg_temp.id('pv'), '0'))) $$,
  'P0001', 'invariant_violation', 'zero amounts are rejected'
);
select throws_ok(
  $$ select pg_temp.post(jsonb_build_array(pg_temp.line(pg_temp.id('in'), '-1.001'), pg_temp.line(pg_temp.id('pv'), '1.001'))) $$,
  'P0001', 'invariant_violation', 'amounts beyond the currency scale are rejected'
);
create function pg_temp.system_only() returns void language plpgsql as $$
begin
  perform ledger.post('income', refs.issue('INC'), pg_temp.m(6, pg_temp.id('T')), pg_temp.u(1), pg_temp.k(),
    jsonb_build_array(jsonb_build_object('currency', 'NGN', 'postings', jsonb_build_array(
      pg_temp.line(pg_temp.id('in'), '-5'),
      pg_temp.line(ledger.system_account(pg_temp.id('tenant'), 'NGN', 'test_clearing'), '5')))));
  set constraints all immediate;
end $$;
select throws_ok($$ select pg_temp.system_only() $$, 'P0001', 'invariant_violation',
  'a transaction must move member value (checked at commit)');
create function pg_temp.unbalanced_direct() returns void language plpgsql as $$
declare tx uuid; j uuid;
begin
  tx := pg_temp.post(jsonb_build_array(pg_temp.line(pg_temp.id('in'), '-1'), pg_temp.line(pg_temp.id('pv'), '1')));
  insert into ledger.journals (transaction_id, entry_no, currency) values (tx, 2, 'USD') returning id into j;
  insert into ledger.postings (journal_id, account_id, line_no, amount) values (j, pg_temp.id('usd'), 1, 3);
  set constraints all immediate;
end $$;
select throws_ok($$ select pg_temp.unbalanced_direct() $$, 'P0001', 'invariant_violation',
  'a journal written around ledger.post must still balance at commit');

-- ── Valid posts, projection (3) ──
insert into ids
select 'tx1', pg_temp.post(jsonb_build_array(pg_temp.line(pg_temp.id('in'), '-1000.50'),
  pg_temp.line(pg_temp.id('pv'), '600.25'), pg_temp.line(pg_temp.id('sav'), '400.25')));
select lives_ok($$ set constraints all immediate $$, 'a balanced transaction passes the commit checks');
set constraints all deferred;
select is((pg_temp.bal(pg_temp.id('pv'))).posted, 600.25::numeric, 'posting updates the projection');
select ok(not exists (select 1 from ledger.balances where account_id = pg_temp.id('in')), 'system accounts have no projection row');

-- ── Immutability (2) ──
select throws_ok($$ update ledger.transactions set metadata = '{"x":1}' $$, 'P0001', 'invariant_violation', 'transactions are immutable');
select throws_ok($$ delete from ledger.postings $$, 'P0001', 'invariant_violation', 'postings cannot be deleted');
select throws_ok($$ update ledger.journals set entry_no = 9 $$, 'P0001', 'invariant_violation', 'journals are immutable');
select throws_ok($$ delete from ledger.wallets $$, 'P0001', 'invariant_violation', 'wallets cannot be deleted');
select throws_ok($$ update ledger.accounts set currency = 'USD' $$, 'P0001', 'invariant_violation', 'accounts are immutable');
select throws_ok($$ update ledger.balances set posted = 1000000 $$, 'P0001', 'invariant_violation',
  'balances change only through postings and holds');
select throws_ok($$ truncate ledger.postings $$, 'P0001', 'invariant_violation', 'postings cannot be truncated');

-- Postings can't be appended to a transaction committed earlier.
alter table ledger.transactions disable trigger transactions_immutable;
update ledger.transactions set db_xact_id = '3'::xid8 where id = pg_temp.id('tx1');
alter table ledger.transactions enable trigger transactions_immutable;
select throws_ok(
  $$ insert into ledger.journals (transaction_id, entry_no, currency) values (pg_temp.id('tx1'), 2, 'USD') $$,
  'P0001', 'invariant_violation', 'an earlier transaction cannot get new journals'
);
select throws_ok(
  $$ insert into ledger.postings (journal_id, account_id, line_no, amount)
     select id, pg_temp.id('pv'), 9, 1 from ledger.journals where transaction_id = pg_temp.id('tx1') $$,
  'P0001', 'invariant_violation', 'an earlier transaction cannot get new postings'
);

-- ── Non-negative (4) ──
select throws_ok(
  $$ select pg_temp.post(jsonb_build_array(pg_temp.line(pg_temp.id('sav'), '-400.26'), pg_temp.line(pg_temp.id('pv'), '400.26'))) $$,
  'P0001', 'insufficient_funds', 'an ordinary pocket cannot go below zero'
);
select lives_ok(
  $$ select pg_temp.post(jsonb_build_array(pg_temp.line(pg_temp.id('debt'), '-50'), pg_temp.line(pg_temp.id('sav'), '50'))) $$,
  'Debt may go negative'
);
select is((pg_temp.bal(pg_temp.id('debt'))).posted, -50::numeric, 'Debt balance is negative');

-- ── Holds (5) ──  Savings: 450.25 posted.
select throws_ok(
  $$ select ledger.reserve(pg_temp.id('sav'), 450.26, 'withdrawal', 'test', gen_random_uuid(), pg_temp.u(6)) $$,
  'P0001', 'insufficient_funds', 'a hold beyond available is refused'
);
select throws_ok(
  $$ select ledger.reserve(pg_temp.id('debt'), 1, 'withdrawal', 'test', gen_random_uuid(), pg_temp.u(6)) $$,
  'P0001', 'invariant_violation', 'Debt is never a source'
);
insert into ids select 'h1', ledger.reserve(pg_temp.id('sav'), 200.25, 'withdrawal', 'test', gen_random_uuid(), pg_temp.u(6));
insert into ids select 'h2', ledger.reserve(pg_temp.id('sav'), 250, 'pocket_transfer', 'test', gen_random_uuid(), pg_temp.u(6));
select is(ledger.available(pg_temp.id('sav')), 0::numeric, 'two holds exactly exhaust the pocket');
select throws_ok(
  $$ select ledger.reserve(pg_temp.id('sav'), 0.01, 'withdrawal', 'test', gen_random_uuid(), pg_temp.u(6)) $$,
  'P0001', 'insufficient_funds', 'a third hold fails'
);
select throws_ok(
  $$ select pg_temp.post(jsonb_build_array(pg_temp.line(pg_temp.id('sav'), '-1'), pg_temp.line(pg_temp.id('pv'), '1'))) $$,
  'P0001', 'insufficient_funds', 'held money cannot be posted away'
);
do $$ begin perform ledger.release(pg_temp.id('h2'), 'Cancelled by member', pg_temp.u(6)); end $$;
select is(ledger.available(pg_temp.id('sav')), 250::numeric, 'release frees the hold');
select lives_ok(
  $$ select pg_temp.post(jsonb_build_array(pg_temp.line(pg_temp.id('sav'), '-200.25'), pg_temp.line(pg_temp.id('pv'), '200.25')),
       'NGN', jsonb_build_array(jsonb_build_object('reservationId', pg_temp.id('h1'), 'amount', '200.25'))) $$,
  'posting can consume a hold'
);
select is((select status from ledger.reservations where id = pg_temp.id('h1')), 'consumed', 'the hold is settled');
select throws_ok(
  $$ select pg_temp.post(jsonb_build_array(pg_temp.line(pg_temp.id('sav'), '-1'), pg_temp.line(pg_temp.id('pv'), '1')),
       'NGN', jsonb_build_array(jsonb_build_object('reservationId', pg_temp.id('h1'), 'amount', '1'))) $$,
  'P0001', 'conflict', 'a hold cannot be consumed twice'
);
insert into ids select 'h3', ledger.reserve(pg_temp.id('sav'), 10, 'withdrawal', 'test', gen_random_uuid(), pg_temp.u(6));
select throws_ok(
  $$ select pg_temp.post(jsonb_build_array(pg_temp.line(pg_temp.id('sav'), '-11'), pg_temp.line(pg_temp.id('pv'), '11')),
       'NGN', jsonb_build_array(jsonb_build_object('reservationId', pg_temp.id('h3'), 'amount', '11'))) $$,
  'P0001', 'conflict', 'a hold cannot be consumed beyond its amount'
);
select throws_ok($$ update ledger.reservations set release_reason = 'x' where id = pg_temp.id('h2') $$,
  'P0001', 'invariant_violation', 'settled holds are immutable');

-- ── Exact decimals (6) ──
create function pg_temp.big() returns void language plpgsql as $$
declare a uuid; b uuid;
begin
  a := pg_temp.seg('Upkeep', 'USD');
  perform pg_temp.post(jsonb_build_array(pg_temp.line(pg_temp.inflow('USD'), '-99999999999999999999.99'),
    pg_temp.line(a, '99999999999999999999.99')), 'USD');
end $$;
do $$ begin perform pg_temp.big(); end $$;
select is(
  (select ledger.money(posted, currency) from ledger.balances where pocket_id = pg_temp.pocket('Upkeep') and currency = 'USD'),
  '99999999999999999999.99', '20 integer digits survive exactly'
);
select is(jsonb_typeof(jsonb_build_object('a', ledger.money(1.5, 'NGN'))->'a'), 'string', 'amounts leave the database as strings');

-- ── Projection matches the ledger (3) ──
select is((select count(*)::int from ledger.verify_balances()), 0, 'the projection equals the postings and active holds');

select * from finish();
rollback;
