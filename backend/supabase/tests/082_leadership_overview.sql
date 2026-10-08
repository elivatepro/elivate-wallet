-- Blueprint 08 — B6 082: the leadership dashboard read (W-07 Leadership).
begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

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
create function pg_temp.ov(n int) returns jsonb language sql volatile as
  $$ select api.leadership_overview(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), 'Africa/Lagos') $$;
create function pg_temp.cur(p jsonb, p_currency text) returns jsonb language sql immutable as
  $$ select c from jsonb_array_elements(p->'currencies') c where c->>'currency' = p_currency $$;

-- 1 President · 2 World Team · 3 Director · 4 TL (T) · 5 TL (T2) · 6 member (T) · 7 member (T2) · 10 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from unnest(array[1, 2, 3, 4, 5, 6, 7, 10]) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from unnest(array[1, 2, 3, 4, 5, 6, 7, 10]) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from unnest(array[1, 2, 3, 4, 5, 6, 7, 10]) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');
insert into ids select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), 'Pilot', pg_temp.k()); end $$;
insert into ids select 'W', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'world_team', 'North', null,
  array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', pg_temp.id('W'),
  array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
insert into ids select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'),
  array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
insert into ids select 'T2', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team B', pg_temp.id('D'),
  array[pg_temp.uid(5)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(6), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), pg_temp.uid(7), pg_temp.k());
end $$;
insert into ids values ('m6', pg_temp.m(6, pg_temp.id('T'))), ('m7', pg_temp.m(7, pg_temp.id('T2')));
do $$ begin
  perform pg_temp.inc(4, pg_temp.id('m6'), '1000.00');
  perform pg_temp.inc(1, pg_temp.id('m6'), '50.00', 'USD');
  perform pg_temp.inc(1, pg_temp.id('m7'), '300.00');
  -- The Director's own wallet gets income too; it never shows in their dashboard.
  perform pg_temp.inc(1, pg_temp.m(3, pg_temp.id('D')), '77.00');
end $$;

-- ── Team Leader ──
select is(pg_temp.ov(4)->'scope'->>'name', 'Team A', 'a Team Leader''s scope is their office');
select is(pg_temp.cur(pg_temp.ov(4), 'NGN')->>'incomeThisMonth', '1000.00', 'income recorded this month');
select is(pg_temp.cur(pg_temp.ov(4), 'USD')->>'incomeThisMonth', '50.00', 'per currency, never mixed');
select is(pg_temp.cur(pg_temp.ov(4), 'NGN')->>'incomePreviousMonth', '0.00', 'previous month for the comparison');
select is(pg_temp.cur(pg_temp.ov(4), 'NGN')->>'reserved', '0.00', 'reserved for open requests');
select is(jsonb_typeof(pg_temp.cur(pg_temp.ov(4), 'NGN')->'reserved'), 'string', 'amounts are strings');
select is(jsonb_array_length(pg_temp.cur(pg_temp.ov(4), 'NGN')->'weeks'), 5, 'five weekly buckets');
select is(pg_temp.cur(pg_temp.ov(4), 'NGN')->'weeks'->4->>'income', '1000.00', 'the current week is last');
select is((pg_temp.ov(4)->'members'->>'active')::int, 1, 'active members exclude the leader');
select is((pg_temp.ov(4)->'members'->>'pendingInvitations')::int, 0, 'pending invitations counted');
do $$ begin
  perform api.create_invitation(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('T'), 'member', 'u8@example.test',
    md5('tok-8')::uuid, encode(sha256(convert_to('tok-8', 'UTF8')), 'hex'), null, pg_temp.k());
end $$;
select is((pg_temp.ov(4)->'members'->>'pendingInvitations')::int, 1, 'a new invitation shows up');

-- ── Director: the subtree, never themselves ──
select is(pg_temp.cur(pg_temp.ov(3), 'NGN')->>'incomeThisMonth', '1300.00', 'a Director sees the subtree');
select is((pg_temp.ov(3)->'members'->>'active')::int, 4, 'two leaders and two members below them');
select is((pg_temp.ov(3)->'excluded'->>'members')::int, 0, 'own money is not reported as excluded');

-- ── President: the whole network ──
select is(pg_temp.ov(1)->'scope'->>'kind', 'network', 'the President Team sees the network');
select is(pg_temp.cur(pg_temp.ov(1), 'NGN')->>'incomeThisMonth', '1377.00', 'every office');

-- ── Denied scope is excluded and reported ──
do $$ begin
  perform api.create_access_assignment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(3),
    jsonb_build_array(
      jsonb_build_object('permission', 'view_managed_wallets', 'effect', 'deny', 'scopeType', 'member', 'scopeUid', pg_temp.uid(6)),
      jsonb_build_object('permission', 'view_scoped_financial_reports', 'effect', 'deny', 'scopeType', 'member', 'scopeUid', pg_temp.uid(6))),
    'Related party', pg_temp.k());
end $$;
select is(pg_temp.cur(pg_temp.ov(3), 'NGN')->>'incomeThisMonth', '300.00', 'denied members do not count');
select is((pg_temp.ov(3)->'excluded'->>'members')::int, 1, 'and are reported as excluded');

-- ── Members have no dashboard ──
select throws_ok($$ select pg_temp.ov(6) $$, 'P0001', 'authorization_denied', 'a member has no leadership dashboard');
select throws_ok($$ select api.leadership_overview(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), 'Nowhere/Else') $$,
  'P0001', 'validation_error', 'unknown time zones are refused');

select * from finish();
rollback;
