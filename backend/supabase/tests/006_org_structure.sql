-- Blueprint 02 — B6 tests 1–7, 13, 16: networks, offices, memberships.
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
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
-- Newest active membership of user n in an office (null office = President Team).
create function pg_temp.m(n int, p_office uuid default null) returns uuid language sql stable as $$
  select id from org.memberships
  where user_id = pg_temp.u(n) and status = 'active' and office_id is not distinct from p_office
  order by started_at desc, id limit 1
$$;

-- 1 founder · 2 World Team · 3 Director · 4,5 Team Leaders · 6,7,8,9 people · 10 admin · 11 other founder
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 11) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 11) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 11) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');

-- ── Networks (2a) ──
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;

select is((select status::text from org.tenants where id = pg_temp.id('tenant')), 'pending_payment', 'a new network awaits payment');
select is((select role::text from org.memberships where user_id = pg_temp.u(1)), 'president_team_member', 'the founder is its first President Team Member');
select is((select count(*)::int from authz.role_permissions where tenant_id = pg_temp.id('tenant')), 175, 'role policy seeded with the A-03 matrix (35 × 5, incl. manage_allocation, the slice 10 keys and review_identity)');
select throws_ok(
  $$ select api.start_network(pg_temp.u(1), pg_temp.s(1), 'Second', 'SEC', pg_temp.k()) $$,
  'P0001', 'conflict', 'one network awaiting payment per founder'
);
select throws_ok(
  $$ select api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'world_team', 'North', null, array[pg_temp.uid(2)], pg_temp.k()) $$,
  'P0001', 'network_not_active', 'no offices until the network is active'
);
select throws_ok(
  $$ select api.activate_tenant(pg_temp.u(1), pg_temp.s(1), pg_temp.id('tenant'), 'Paid offline', pg_temp.k()) $$,
  'P0001', 'authorization_denied', 'only Elivate admins activate networks'
);
select throws_ok(
  $$ select api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), '', pg_temp.k()) $$,
  'P0001', 'validation_error', 'activation needs a reason'
);
select is(
  api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), 'Pilot network', pg_temp.k())->>'status',
  'active', 'admin activates the network'
);

-- ── Offices (1, Q2) ──
insert into ids
select 'W', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'world_team', 'North World Team', null, array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja Directors', pg_temp.id('W'), array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Ikeja Team A', pg_temp.id('D'), array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T2', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Lekki Team', null, array[pg_temp.uid(5)], pg_temp.k())->>'officeId')::uuid;

select is((select count(*)::int from org.offices where tenant_id = pg_temp.id('tenant')), 4, 'offices created, a Team Leader office can sit at the top');
select is((select count(*)::int from org.office_closure where ancestor_id = pg_temp.id('W')), 3, 'World Team covers itself, the Director office and its Team');
select is((select depth from org.office_closure where ancestor_id = pg_temp.id('W') and descendant_id = pg_temp.id('T')), 2, 'closure depth is correct');
select throws_ok(
  $$ select api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Bad', pg_temp.id('T'), array[pg_temp.uid(6)], pg_temp.k()) $$,
  'P0001', 'hierarchy_invalid', 'a parent must be a higher kind'
);
select throws_ok(
  $$ select api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Bad', pg_temp.id('T'), array[pg_temp.uid(6)], pg_temp.k()) $$,
  'P0001', 'hierarchy_invalid', 'a parent cannot be the same kind'
);
select throws_ok(
  $$ select api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Bad', null, array[]::text[], pg_temp.k()) $$,
  'P0001', 'validation_error', 'an office needs at least one leader'
);
select throws_ok(
  $$ select api.create_office(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), 'team_leader', 'Mine', pg_temp.id('D'), array[pg_temp.uid(6)], pg_temp.k()) $$,
  'P0001', 'authorization_denied', 'only the President Team creates offices'
);

-- Insert a World Team above an existing top-level Team Leader office (Q2).
select is(
  api.place_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), pg_temp.id('D'), 'Joins Ikeja', pg_temp.k())->>'changed',
  'true', 'an office can be placed under a higher office later'
);
select ok(exists (select 1 from org.office_closure where ancestor_id = pg_temp.id('W') and descendant_id = pg_temp.id('T2')),
  'the World Team now covers the re-placed office');
select throws_ok(
  $$ select api.place_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('W'), pg_temp.id('T'), 'Loop', pg_temp.k()) $$,
  'P0001', 'hierarchy_invalid', 'cannot place an office under a lower office'
);
select is((select count(*)::int from org.office_moves where office_id = pg_temp.id('T2')), 1, 're-placement is recorded');

-- ── Memberships (2, 3, 4, 5, Q3, Q4) ──
select is(
  api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('D'), pg_temp.uid(6), pg_temp.k())->>'isPrimary',
  'true', 'members can sit in a Director office; the first membership is primary'
);
select throws_ok(
  $$ insert into org.memberships (tenant_id, office_id, user_id, role, created_by)
     values (pg_temp.id('tenant'), pg_temp.id('T'), pg_temp.u(7), 'director', pg_temp.u(1)) $$,
  'P0001', 'role_office_mismatch', 'leader roles only in the matching office kind'
);
select throws_ok(
  $$ select api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('D'), pg_temp.uid(6), pg_temp.k()) $$,
  'P0001', 'membership_exists', 'no duplicate open membership'
);
select lives_ok(
  $$ select api.add_office_leader(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(7), 'Co-leader', pg_temp.k()) $$,
  'an office can have several leaders'
);
select throws_ok(
  $$ select api.end_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(5, pg_temp.id('T2')), 'Leaving', pg_temp.k()) $$,
  'P0001', 'last_leader', 'the last leader cannot be ended'
);
select lives_ok(
  $$ select api.replace_office_leader(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), pg_temp.m(5, pg_temp.id('T2')), pg_temp.uid(8), 'Handover', pg_temp.k()) $$,
  'a leader can be replaced'
);
select is((select status::text from org.memberships where user_id = pg_temp.u(5) and office_id = pg_temp.id('T2')), 'ended', 'the outgoing leadership ended');
select is((select role::text from org.memberships where user_id = pg_temp.u(8) and status = 'active'), 'team_leader', 'the incoming leader holds the leader role');

-- Primary handover and move.
select lives_ok(
  $$ select api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(6), pg_temp.k()) $$,
  'a second membership in the same network'
);
select lives_ok(
  $$ select api.end_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(6, pg_temp.id('D')), 'Left Ikeja', pg_temp.k()) $$,
  'ending the primary membership'
);
select ok((select is_primary from org.memberships where id = pg_temp.m(6, pg_temp.id('T'))), 'the remaining membership becomes primary');
select lives_ok(
  $$ select api.move_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(6, pg_temp.id('T')), pg_temp.id('T2'), 'Relocated', pg_temp.k()) $$,
  'moving a membership'
);
select ok(
  (select is_primary and status = 'active' from org.memberships where id = pg_temp.m(6, pg_temp.id('T2')))
  and (select count(*) = 2 from org.memberships where user_id = pg_temp.u(6) and status = 'ended'),
  'move ends the old membership and carries primary to the new one'
);

-- ── Reasons, step-up, President Team (6, 13, Q5) ──
select throws_ok(
  $$ select api.end_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(6, pg_temp.id('T2')), ' ', pg_temp.k()) $$,
  'P0001', 'validation_error', 'ending needs a reason'
);
update identity.session_pin_proofs set verified_at = now() - interval '6 minutes' where session_id = pg_temp.s(1);
select throws_ok(
  $$ select api.end_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(6, pg_temp.id('T2')), 'Left', pg_temp.k()) $$,
  'P0001', 'step_up_required', 'ending needs a fresh PIN'
);
update identity.session_pin_proofs set verified_at = now() where session_id = pg_temp.s(1);
select throws_ok(
  $$ select api.remove_president(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(1), 'Leaving', pg_temp.k()) $$,
  'P0001', 'self_target_forbidden', 'a President cannot remove themselves, so one always remains'
);

-- ── Seat count (16) ──
select is(org.billable_accounts(pg_temp.id('tenant')), 7, 'seats count distinct people with active or suspended memberships');

select * from finish();
rollback;
