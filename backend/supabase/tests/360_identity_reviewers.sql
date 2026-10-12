-- Blueprint 36 (owner decision 2026-10-12): identity review is the
-- `review_identity` permission. The President Team switches it per role (their
-- own cell locked on, the World Team's switchable) and gives it to one person
-- through Cross-access; a lower role reviews its office and the offices below.
begin;
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(26);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.uid(n int) returns text language sql stable as
  $$ select uid from identity.accounts where user_id = pg_temp.u(n) $$;
create function pg_temp.k() returns text language sql volatile as
  $$ select 'k' || md5(random()::text || clock_timestamp()::text) $$;
create function pg_temp.fp(n int) returns text language sql immutable as
  $$ select repeat(to_hex(n % 16), 64) $$;
create temp table ids (name text primary key, id uuid not null);
create function pg_temp.id(p_name text) returns uuid language sql stable as
  $$ select id from ids where name = p_name $$;
create function pg_temp.m(n int, p_office uuid default null) returns uuid language sql stable as $$
  select id from org.memberships
  where user_id = pg_temp.u(n) and status = 'active' and office_id is not distinct from p_office
  order by started_at desc, id limit 1
$$;
-- How many pending reviews this person sees from a workspace.
create function pg_temp.sees(n int, ws uuid) returns int language sql volatile as
  $$ select jsonb_array_length(api.nin_reviews(pg_temp.u(n), pg_temp.s(n), ws)) $$;
create function pg_temp.switch(p_role text, p_on boolean) returns jsonb language sql volatile as
  $$ select api.set_role_permission(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), p_role, 'review_identity', p_on,
       'Identity reviews', pg_temp.k()) $$;
create function pg_temp.request(n int, p_office uuid) returns uuid language plpgsql as $$
begin
  perform api.prepare_nin_check(pg_temp.u(n), pg_temp.s(n), pg_temp.fp(n), '6789');
  perform api.record_nin_check(pg_temp.u(n), pg_temp.s(n), pg_temp.fp(n), '6789', 'not_found', 'A', null, 'B', null);
  return (api.request_nin_review(pg_temp.u(n), pg_temp.s(n), pg_temp.m(n, p_office), pg_temp.fp(n), '1234',
    'Bola', null, 'Ade', pg_temp.k())->>'reviewId')::uuid;
end $$;

-- 1 President · 2 World Team (W) · 3 Director (D under W) · 4 TL (T under D)
-- 5 member (T) · 6 member (W2) · 7 World Team (W2) · 8 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 8) n;
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 8) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 8) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(8), 'Test admin');
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Synthetic Network', 'SYN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin perform api.activate_tenant(pg_temp.u(8), pg_temp.s(8), pg_temp.id('tenant'), 'Pilot', pg_temp.k()); end $$;
insert into ids select 'W', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'world_team', 'North', null,
  array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', pg_temp.id('W'),
  array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
insert into ids select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'),
  array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
insert into ids select 'W2', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'world_team', 'South', null,
  array[pg_temp.uid(7)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(5), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('W2'), pg_temp.uid(6), pg_temp.k());
end $$;
insert into ids select 'r5', pg_temp.request(5, pg_temp.id('T'));
insert into ids select 'r6', pg_temp.request(6, pg_temp.id('W2'));

-- ── Catalogue and defaults (3) ──
select is((select protected::text || '/' || grantable::text || '/' || scope from authz.permission_catalog
  where key = 'review_identity'), 'false/true/office', 'review_identity is office-scoped and grantable');
select is((select string_agg(role::text, ',' order by role) from authz.role_permissions
  where tenant_id = pg_temp.id('tenant') and permission_key = 'review_identity' and allowed),
  'world_team_member,president_team_member', 'on for the World Team and President Team by default');
select is(pg_temp.sees(2, pg_temp.m(2, pg_temp.id('W'))), 1, 'the World Team still reviews below its office');

-- ── The President Team's cell is locked (3) ──
select throws_ok($$ select pg_temp.switch('president_team_member', false) $$, 'P0001', 'permission_not_grantable',
  'the President Team cannot switch it off for themselves');
select is((select (e->>'editable')::boolean from jsonb_array_elements(
  api.list_role_permissions(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1))) e
  where e->>'permission' = 'review_identity' and e->>'role' = 'president_team_member'), false,
  'the President Team cell shows locked');
select is((select (e->>'editable')::boolean from jsonb_array_elements(
  api.list_role_permissions(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1))) e
  where e->>'permission' = 'review_identity' and e->>'role' = 'world_team_member'), true,
  'the World Team cell is switchable');

-- ── Switched on for Team Leaders (8) ──
select throws_ok($$ select pg_temp.sees(4, pg_temp.m(4, pg_temp.id('T'))) $$, 'P0001', 'authorization_denied',
  'a Team Leader cannot review by default');
select lives_ok($$ select pg_temp.switch('team_leader', true) $$, 'the President Team switches it on for Team Leaders');
select is((select count(*)::int from notify.items where user_id = pg_temp.u(4) and kind = 'task.nin_review'
  and subject_id = pg_temp.id('r5')), 1, 'the waiting review reaches the Team Leader''s bell');
select is(pg_temp.sees(4, pg_temp.m(4, pg_temp.id('T'))), 1, 'the Team Leader sees their office''s review only');
select ok((api.my_capabilities(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')))->'permissions') ? 'review_identity',
  'the Team Leader''s capabilities include it (the nav shows Identity reviews)');
select throws_ok($$ select api.decide_nin_review(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')),
  pg_temp.id('r6'), 'approve', 'Checked the card', pg_temp.k()) $$, 'P0001', 'authorization_denied',
  'not a review outside their office');
select is(api.decide_nin_review(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.id('r5'),
  'approve', 'Checked the card', pg_temp.k())->>'status', 'approved', 'the Team Leader approves in their office');
select throws_ok($$ select pg_temp.sees(3, pg_temp.m(3, pg_temp.id('D'))) $$, 'P0001', 'authorization_denied',
  'Directors are still off');

-- ── Switched off for the World Team (2) ──
select lives_ok($$ select pg_temp.switch('world_team_member', false) $$, 'the World Team cell can be switched off');
select throws_ok($$ select pg_temp.sees(7, pg_temp.m(7, pg_temp.id('W2'))) $$, 'P0001', 'authorization_denied',
  'the World Team no longer reviews');

-- ── Cross-access (6) ──
select throws_ok($$ select api.create_access_assignment(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')),
  pg_temp.uid(4), jsonb_build_array(jsonb_build_object('permission', 'review_identity', 'effect', 'allow',
    'scopeType', 'office_subtree', 'scopeOfficeId', pg_temp.id('T'))), 'Cover reviews', pg_temp.k()) $$,
  'P0001', 'permission_not_grantable', 'a Director cannot hand out identity review');
select lives_ok($$ select api.create_access_assignment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(3),
  jsonb_build_array(jsonb_build_object('permission', 'review_identity', 'effect', 'allow', 'scopeType', 'tenant')),
  'Covers identity reviews network-wide', pg_temp.k()) $$, 'the President Team gives it to one Director');
select is(pg_temp.sees(3, pg_temp.m(3, pg_temp.id('D'))), 1, 'that Director sees the review in another World Team');
select is((select count(*)::int from notify.items where user_id = pg_temp.u(3) and kind = 'task.nin_review'
  and subject_id = pg_temp.id('r6')), 1, 'and gets its bell task');
select is(api.decide_nin_review(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), pg_temp.id('r6'),
  'reject', 'Name unreadable', pg_temp.k())->>'status', 'rejected', 'and decides it');
select is(pg_temp.sees(1, pg_temp.m(1)), 0, 'nothing left for the President Team');

-- ── Never one's own (2) ──
do $$ begin perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(3), pg_temp.k()); end $$;
insert into ids select 'r3', pg_temp.request(3, pg_temp.id('T'));
select is(pg_temp.sees(3, pg_temp.m(3, pg_temp.id('D'))), 0, 'a reviewer never sees their own review');
select is(pg_temp.sees(4, pg_temp.m(4, pg_temp.id('T'))), 1, 'their Team Leader does');

-- ── Only the President Team revokes identity review rules (2) ──
insert into ids select 'deny4', (api.create_access_assignment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(4),
  jsonb_build_array(jsonb_build_object('permission', 'review_identity', 'effect', 'deny',
    'scopeType', 'office_subtree', 'scopeOfficeId', pg_temp.id('T'))), 'Related to the team', pg_temp.k())->>'assignmentId')::uuid;
select throws_ok($$ select api.revoke_access_assignment(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')),
  pg_temp.id('deny4'), 'Lift it', pg_temp.k()) $$, 'P0001', 'permission_not_grantable',
  'a Director cannot lift the President''s identity review deny');
select lives_ok($$ select api.revoke_access_assignment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1),
  pg_temp.id('deny4'), 'Lift it', pg_temp.k()) $$, 'the President Team can');

select * from finish();
rollback;
