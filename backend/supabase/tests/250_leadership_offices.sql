-- Blueprint 25 — B3 250: "Offices this month" on the network home
-- (api.leadership_offices, W-07 Leadership). Authorization, scope exclusion,
-- tenant isolation, one figure per currency and the network's month.
begin;
-- These fixtures predate setup by role (pgTAP 220 tests the gate).
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
create function pg_temp.of(n int) returns jsonb language sql volatile as
  $$ select api.leadership_offices(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n)) $$;
-- One office row of a reply, by office name.
create function pg_temp.row(p jsonb, p_name text) returns jsonb language sql immutable as
  $$ select o from jsonb_array_elements(p->'offices') o where o->>'name' = p_name $$;
-- One office's income in one currency.
create function pg_temp.amt(p jsonb, p_name text, p_currency text) returns text language sql immutable as $$
  select i->>'amount' from jsonb_array_elements(pg_temp.row(p, p_name)->'income') i where i->>'currency' = p_currency
$$;
create function pg_temp.names(p jsonb) returns text language sql immutable as
  $$ select string_agg(o->>'name', ',' order by ord) from jsonb_array_elements(p->'offices') with ordinality as x (o, ord) $$;
-- Moves one income transaction (found by its amount) to a moment.
create function pg_temp.move(p_amount numeric, p_at timestamptz) returns void language plpgsql as $$
begin
  set local session_replication_role = replica;
  update ledger.transactions t set posted_at = p_at
  where t.type = 'income' and exists (
    select 1 from ledger.journals j join ledger.postings p on p.journal_id = j.id
    where j.transaction_id = t.id and abs(p.amount) = p_amount);
  set local session_replication_role = origin;
end $$;

-- 1 President · 2 World Team · 3 Director · 4 TL (T) · 5 TL (T2) · 6 member (T) · 7 member (T2)
-- 8 founder of another network · 9 TL there · 10 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated'
from unnest(array[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) n;
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from unnest(array[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from unnest(array[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');
insert into ids select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
insert into ids select 'tenant2', (api.start_network(pg_temp.u(8), pg_temp.s(8), 'Other Network', 'OTH', pg_temp.k())->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), 'Pilot', pg_temp.k());
  perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant2'), 'Pilot', pg_temp.k());
end $$;
insert into ids select 'W', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'world_team', 'North', null,
  array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', pg_temp.id('W'),
  array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
insert into ids select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'),
  array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
insert into ids select 'T2', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team B', pg_temp.id('D'),
  array[pg_temp.uid(5)], pg_temp.k())->>'officeId')::uuid;
insert into ids select 'X', (api.create_office(pg_temp.u(8), pg_temp.s(8), pg_temp.m(8), 'team_leader', 'Elsewhere', null,
  array[pg_temp.uid(9)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(6), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), pg_temp.uid(7), pg_temp.k());
end $$;
insert into ids values ('m6', pg_temp.m(6, pg_temp.id('T'))), ('m7', pg_temp.m(7, pg_temp.id('T2'))),
  ('m9', pg_temp.m(9, pg_temp.id('X')));
do $$ begin
  perform pg_temp.inc(4, pg_temp.id('m6'), '1000.00');
  perform pg_temp.inc(1, pg_temp.id('m6'), '50.00', 'USD');
  perform pg_temp.inc(1, pg_temp.id('m7'), '300.00');
  -- The Director's own wallet gets income too; it never shows in their own view.
  perform pg_temp.inc(1, pg_temp.m(3, pg_temp.id('D')), '77.00');
  -- Another network's income never shows here.
  perform pg_temp.inc(8, pg_temp.id('m9'), '9999.00');
end $$;

-- ── Team Leader: their office only ──
select is(pg_temp.of(4)->'scope'->>'name', 'Team A', 'a Team Leader''s scope is their office');
select is(pg_temp.names(pg_temp.of(4)), 'Team A', 'one row: their own office');
select is(pg_temp.amt(pg_temp.of(4), 'Team A', 'NGN'), '1000.00', 'income recorded this month');
select is(pg_temp.amt(pg_temp.of(4), 'Team A', 'USD'), '50.00', 'per currency, never mixed');
select is(jsonb_typeof(pg_temp.row(pg_temp.of(4), 'Team A')->'income'->0->'amount'), 'string', 'amounts are strings');
select is((pg_temp.row(pg_temp.of(4), 'Team A')->>'members')::int, 1, 'members exclude the viewer');
select ok(not (pg_temp.row(pg_temp.of(4), 'Team A') ? 'total'), 'no total across currencies');
select is(pg_temp.of(4)->'period'->>'timeZone', 'Africa/Lagos', 'the network''s time zone');

-- ── Director: the subtree, each office on its own ──
select is(pg_temp.names(pg_temp.of(3)), 'Ikeja,Team A,Team B', 'Director: their office, then the teams');
select is(pg_temp.amt(pg_temp.of(3), 'Ikeja', 'NGN'), '0.00', 'own money is not part of the view');
select is(pg_temp.amt(pg_temp.of(3), 'Team B', 'NGN'), '300.00', 'each office counts its own income');
select is((pg_temp.row(pg_temp.of(3), 'Team A')->>'members')::int, 2, 'leader and member of Team A');
select is((pg_temp.of(3)->'excluded'->>'members')::int, 0, 'own money is not reported as excluded');

-- ── President: the whole network, never another network ──
select is(pg_temp.of(1)->'scope'->>'kind', 'network', 'the President Team sees the network');
select is(pg_temp.names(pg_temp.of(1)), 'North,Ikeja,Team A,Team B', 'every office, World Team first');
select is(pg_temp.amt(pg_temp.of(1), 'Ikeja', 'NGN'), '77.00', 'the Director''s wallet counts for the President');
select is(pg_temp.row(pg_temp.of(1), 'Elsewhere'), null, 'another network''s offices never show');
select is((select sum((i->>'amount')::numeric) from jsonb_array_elements(pg_temp.of(1)->'offices') o,
  jsonb_array_elements(o->'income') i where i->>'currency' = 'NGN'), 1377.00::numeric,
  'rows add up to the network''s income (no other network)');
select throws_ok($$ select api.leadership_offices(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(8)) $$,
  'P0001', null, 'another person''s workspace is refused');
select is(pg_temp.names(pg_temp.of(8)), 'Elsewhere', 'the other network sees only its own office');

-- ── The network's month (Africa/Lagos, UTC+1) ──
do $$
declare
  start_utc timestamptz := date_trunc('month', now() at time zone 'Africa/Lagos') at time zone 'Africa/Lagos';
begin
  perform pg_temp.inc(1, pg_temp.id('m7'), '11.00');
  perform pg_temp.inc(1, pg_temp.id('m7'), '22.00');
  perform pg_temp.inc(1, pg_temp.id('m7'), '33.00');
  -- One second before the month began in Lagos: last month.
  perform pg_temp.move(11.00, start_utc - interval '1 second');
  -- The very first instant of the month in Lagos.
  perform pg_temp.move(22.00, start_utc);
  -- 30 minutes in: still the previous month in UTC, this month in Lagos.
  perform pg_temp.move(33.00, start_utc + interval '30 minutes');
end $$;
select is(pg_temp.amt(pg_temp.of(1), 'Team B', 'NGN'), '355.00', 'month boundaries follow the network''s time zone');
select is(to_char(date_trunc('month', now() at time zone 'Africa/Lagos'), 'YYYY-MM'), pg_temp.of(1)->'period'->>'month',
  'the period is the network''s month');

-- ── Denied scope is excluded and reported ──
do $$ begin
  perform api.create_access_assignment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(3),
    jsonb_build_array(
      jsonb_build_object('permission', 'view_managed_wallets', 'effect', 'deny', 'scopeType', 'member', 'scopeUid', pg_temp.uid(6)),
      jsonb_build_object('permission', 'view_scoped_financial_reports', 'effect', 'deny', 'scopeType', 'member', 'scopeUid', pg_temp.uid(6))),
    'Related party', pg_temp.k());
end $$;
select is(pg_temp.amt(pg_temp.of(3), 'Team A', 'NGN'), '0.00', 'denied members do not count');
select is(pg_temp.amt(pg_temp.of(3), 'Team A', 'USD'), '0.00', 'in any currency');
select is((pg_temp.row(pg_temp.of(3), 'Team A')->>'excludedMembers')::int, 1, 'the office says someone is left out');
select is((pg_temp.row(pg_temp.of(3), 'Team A')->>'members')::int, 1, 'and does not count them');
select is((pg_temp.of(3)->'excluded'->>'members')::int, 1, 'reported in total too');
select is(pg_temp.amt(pg_temp.of(1), 'Team A', 'NGN'), '1000.00', 'the deny is the Director''s only');

-- ── No leadership read: refused ──
select throws_ok($$ select pg_temp.of(6) $$, 'P0001', 'authorization_denied', 'a member has no office figures');
select is(pg_temp.names(pg_temp.of(9)), 'Elsewhere', 'a leader in the other network sees only their office');

-- ── Privileges ──
select ok(not has_function_privilege('authenticated', 'api.leadership_offices(uuid, uuid, uuid)', 'execute'),
  'callable only through the trusted Edge');

select * from finish();
rollback;
