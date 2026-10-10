-- Tidy-up (owner decisions 1, 53, 54 of 2026-10-08): leader roles only
-- strictly below the actor's own office, rolled-up office member counts, one
-- self-target code, and a PIN-reset request that can be withdrawn when its
-- email was not sent.
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
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
create function pg_temp.office(p_name text) returns jsonb language sql volatile as $$
  select e from jsonb_array_elements(
    api.list_offices(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1))->'items') e
  where (e->>'id')::uuid = pg_temp.id(p_name)
$$;

-- 1 President · 2 World Team (W) · 3 Director (D) · 4 Team Leader (T) · 5 Team Leader (T2)
-- 6, 7, 8, 9 people · 10 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 10) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 10) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 10) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');

insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), 'Pilot', pg_temp.k());
end $$;
insert into ids
select 'W', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'world_team', 'North', null, array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', pg_temp.id('W'), array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'), array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T2', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team B', pg_temp.id('D'), array[pg_temp.uid(5)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(9), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), pg_temp.uid(9), pg_temp.k());
end $$;

-- ── Office counts roll up over the subtree (decision 53) ──
select is((pg_temp.office('T')->>'memberCount')::int, 2, 'a team counts its own people');
select is((pg_temp.office('D')->>'memberCount')::int, 4, 'a Director office counts distinct people in its whole subtree');
select is((pg_temp.office('W')->>'memberCount')::int, 5, 'a World Team office counts its whole subtree');
select is((pg_temp.office('D')->>'leaderCount')::int, 1, 'leaderCount stays the office''s own leaders');
select is(
  (select (e->>'memberCount')::int from jsonb_array_elements(
     api.list_offices(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')))->'items') e
   where (e->>'id')::uuid = pg_temp.id('D')),
  4, 'a Director sees the same rolled-up count'
);

-- ── Leader roles strictly below the actor's own office (decision 1) ──
select throws_ok(
  $$ select api.add_office_leader(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.id('T'), pg_temp.uid(6), 'Co-leader', pg_temp.k()) $$,
  'P0001', 'authorization_denied', 'a Team Leader cannot add a co-Team Leader to their own office'
);
select throws_ok(
  $$ select api.add_office_leader(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), pg_temp.id('D'), pg_temp.uid(6), 'Co-director', pg_temp.k()) $$,
  'P0001', 'authorization_denied', 'a Director cannot add a co-Director to their own office'
);
select lives_ok(
  $$ select api.add_office_leader(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), pg_temp.id('T'), pg_temp.uid(6), 'Second leader', pg_temp.k()) $$,
  'a Director adds a Team Leader below'
);
select is((select role::text from org.memberships where user_id = pg_temp.u(6) and office_id = pg_temp.id('T') and status = 'active'),
  'team_leader', 'the new leader holds the office''s leader role');
select throws_ok(
  $$ select api.replace_office_leader(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.id('T'),
       pg_temp.m(6, pg_temp.id('T')), pg_temp.uid(7), 'Swap', pg_temp.k()) $$,
  'P0001', 'authorization_denied', 'a Team Leader cannot replace a co-Team Leader in their own office'
);
select lives_ok(
  $$ select api.replace_office_leader(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), pg_temp.id('T'),
       pg_temp.m(6, pg_temp.id('T')), pg_temp.uid(7), 'Handover', pg_temp.k()) $$,
  'a Director replaces a Team Leader below'
);
select lives_ok(
  $$ select api.add_office_leader(pg_temp.u(2), pg_temp.s(2), pg_temp.m(2, pg_temp.id('W')), pg_temp.id('D'), pg_temp.uid(8), 'Co-director', pg_temp.k()) $$,
  'a World Team leader adds a Director below'
);
select lives_ok(
  $$ select api.add_office_leader(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('W'), pg_temp.uid(6), 'Co-lead', pg_temp.k()) $$,
  'the President Team adds a leader to any office'
);

-- ── One self-target code (decision 54) ──
select throws_ok(
  $$ select api.set_account_status(pg_temp.u(10), pg_temp.s(10), pg_temp.uid(10), 'suspended', 'Self test', pg_temp.k()) $$,
  'P0001', 'self_target_forbidden', 'account status uses the same self-target code as org'
);

-- ── PIN-reset email failure releases the cooldown (decision 54) ──
select lives_ok(
  $$ select api.request_pin_reset(pg_temp.u(6), pg_temp.s(6)) $$,
  'a reset request is recorded'
);
select throws_ok(
  $$ select api.request_pin_reset(pg_temp.u(6), pg_temp.s(6)) $$,
  'P0001', 'rate_limited', 'a second request within 60 seconds is rate limited'
);
select is(api.cancel_pin_reset(pg_temp.u(6), pg_temp.s(6))->>'cancelled', 'true',
  'a request whose email failed is withdrawn');
select lives_ok(
  $$ select api.request_pin_reset(pg_temp.u(6), pg_temp.s(6)) $$,
  'after a failed email the person can retry at once'
);
select is(
  (select count(*)::int from audit.security_events where action = 'pin.reset_email_failed' and actor_user_id = pg_temp.u(6)),
  1, 'the failed email is audited'
);
select is(api.cancel_pin_reset(pg_temp.u(7), pg_temp.s(7))->>'cancelled', 'false',
  'nothing to withdraw is not an error');

select * from finish();
rollback;
