-- Blueprint 27 — B1: find people (name in the network; exact UID or email
-- anywhere), a new office whose leader is invited by email, and a leader
-- replaced by invitation (the outgoing leader stays until it is accepted).
begin;
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(30);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.uid(n int) returns text language sql stable as
  $$ select uid from identity.accounts where user_id = pg_temp.u(n) $$;
create function pg_temp.k() returns text language sql volatile as
  $$ select 'k' || md5(random()::text || clock_timestamp()::text) $$;
create function pg_temp.dg(t text) returns text language sql immutable as
  $$ select encode(sha256(convert_to(t, 'UTF8')), 'hex') $$;
create function pg_temp.tid(t text) returns uuid language sql immutable as
  $$ select md5(t)::uuid $$;
create temp table ids (name text primary key, id uuid not null);
create function pg_temp.id(p_name text) returns uuid language sql stable as
  $$ select id from ids where name = p_name $$;
create function pg_temp.m(n int, p_office uuid default null) returns uuid language sql stable as $$
  select id from org.memberships
  where user_id = pg_temp.u(n) and status = 'active' and office_id is not distinct from p_office
  order by started_at desc, id limit 1
$$;
create function pg_temp.find(n int, ws uuid, q text) returns jsonb language sql volatile as
  $$ select api.find_people(pg_temp.u(n), pg_temp.s(n), ws, q) $$;
create function pg_temp.detail(p_office uuid) returns jsonb language sql volatile as
  $$ select api.office_detail(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), p_office) $$;

-- 1 President · 2 World Team · 3 Director (Femke) · 4 Team Leader of T ·
-- 5 member of T (Femi Adeyemi) · 6 outside the network (Femisola Ojo) · 10 admin.
-- 7 and 8 sign up later, after their invitations.
insert into auth.users (id, email, aud, role, email_confirmed_at)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated', now()
from unnest(array[1, 2, 3, 4, 5, 6, 10]) n;
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from unnest(array[1, 2, 3, 4, 5, 6, 10]) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from unnest(array[1, 2, 3, 4, 5, 10]) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');
update identity.profiles set first_name = 'Femke', last_name = 'Bello' where user_id = pg_temp.u(3);
update identity.profiles set first_name = 'Femi', last_name = 'Adeyemi' where user_id = pg_temp.u(5);
update identity.profiles set first_name = 'Femisola', last_name = 'Ojo' where user_id = pg_temp.u(6);

insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Synthetic Network', 'SYN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), 'Pilot network', pg_temp.k()); end $$;
insert into ids
select 'W', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'world_team', 'North', null, array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', pg_temp.id('W'), array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'), array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.create_invitation(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.id('T'), 'member',
    'u5@example.test', pg_temp.tid('t5'), pg_temp.dg('t5'), null, pg_temp.k());
  perform api.accept_invitation(pg_temp.u(5), pg_temp.s(5), pg_temp.dg('t5'), null, pg_temp.k());
end $$;

-- ── Find people ──
select is(jsonb_array_length(pg_temp.find(1, pg_temp.m(1), 'fem')->'items'), 2,
  'a name matches the network''s people only (the outsider is not listed)');
select is(pg_temp.find(1, pg_temp.m(1), 'fem')->'items'->0->>'name', 'Femi Adeyemi', 'ordered by name');
select is((pg_temp.find(1, pg_temp.m(1), 'adeyemi')->'items'->0) - 'uid',
  '{"name": "Femi Adeyemi", "inNetwork": true, "role": "member", "officeName": "Team A"}',
  'a match carries the name, role and office');
select is(jsonb_array_length(pg_temp.find(4, pg_temp.m(4, pg_temp.id('T')), 'fem')->'items'), 1,
  'a Team Leader only finds people in their own scope');
select is(pg_temp.find(1, pg_temp.m(1), lower(pg_temp.uid(6)))->'items'->0,
  jsonb_build_object('uid', pg_temp.uid(6), 'name', 'Femisola Ojo', 'inNetwork', false, 'role', null, 'officeName', null),
  'an exact UID finds any account');
select is(pg_temp.find(1, pg_temp.m(1), ' U6@Example.test ')->'items'->0->>'uid', pg_temp.uid(6),
  'an exact email finds any account');
select is(pg_temp.find(1, pg_temp.m(1), 'nobody@example.test'), '{"items": [], "noAccount": true}',
  'an email with no account says so');
select is(pg_temp.find(1, pg_temp.m(1), 'EW-99999')->'items', '[]', 'an unknown UID finds nobody');
select throws_ok($$ select pg_temp.find(5, pg_temp.m(5, pg_temp.id('T')), 'fem') $$, 'P0001', 'authorization_denied',
  'plain members cannot search');
select throws_ok($$ select pg_temp.find(1, pg_temp.m(1), 'f') $$, 'P0001', 'validation_error', 'at least 2 characters');

-- Review fix: open leader invitations are hidden, not "none", from others.
select is(pg_temp.detail(pg_temp.id('T'))->'pendingLeaders', '[]', 'the President Team sees no open leader invitations');
select is(api.office_detail(pg_temp.u(5), pg_temp.s(5), pg_temp.m(5, pg_temp.id('T')), pg_temp.id('T'))->'pendingLeaders',
  'null', 'someone who cannot invite there is not told "none"');

-- ── New office, leader invited by email ──
insert into ids select 'TC', (api.create_office_inviting_leader(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader',
  'Team C', pg_temp.id('D'), ' New7@Example.test ', pg_temp.tid('t7'), pg_temp.dg('t7'), pg_temp.k())->>'officeId')::uuid;
select is(jsonb_array_length(pg_temp.detail(pg_temp.id('TC'))->'leaders'), 0, 'the office waits for its leader');
select is(pg_temp.detail(pg_temp.id('TC'))->'pendingLeaders'->0->>'email', 'new7@example.test',
  'its pending leader invitation is shown');
select is((select row(role, reason)::text from org.invitations where office_id = pg_temp.id('TC')),
  '(team_leader,"Leader of new office Team C")', 'a Team Leader invitation with the reason filled in');
select is((select count(*)::int from outbox.events e join org.invitations i on i.id = e.aggregate_id
  where i.office_id = pg_temp.id('TC')), 1, 'its email is queued');
select throws_ok($$ select api.create_office_inviting_leader(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')),
  'team_leader', 'Team X', pg_temp.id('D'), 'x@example.test', pg_temp.tid('tx'), pg_temp.dg('tx'), pg_temp.k()) $$,
  'P0001', null, 'President Team only');
select lives_ok($$ select org.assert_leader_remains(pg_temp.id('TC')) $$,
  'a waiting office passes the leader rule');

insert into auth.users (id, email, aud, role, email_confirmed_at)
values (pg_temp.u(7), 'new7@example.test', 'authenticated', 'authenticated', now());
insert into auth.sessions (id, user_id, created_at, updated_at) values (pg_temp.s(7), pg_temp.u(7), now(), now());
select is(api.accept_invitation(pg_temp.u(7), pg_temp.s(7), pg_temp.dg('t7'), null, pg_temp.k())->>'role', 'team_leader',
  'the invitee signs up and becomes the leader');
select is(pg_temp.detail(pg_temp.id('TC'))->'leaders'->0->'person'->>'uid', pg_temp.uid(7), 'the office has its leader');
select is(pg_temp.detail(pg_temp.id('TC'))->'pendingLeaders', '[]', 'nothing pending any more');
select throws_ok($$ select api.end_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(7, pg_temp.id('TC')),
  'Leaving', pg_temp.k()) $$, 'P0001', 'last_leader', 'once it has had a leader, it keeps one');

-- ── Replace a leader by invitation ──
select throws_ok($$ select api.create_invitation(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), 'team_leader',
  'new8@example.test', pg_temp.tid('t8x'), pg_temp.dg('t8x'), 'Handover', pg_temp.k(), null, pg_temp.m(5, pg_temp.id('T'))) $$,
  'P0001', 'validation_error', 'only a current leader of the office can be replaced');
insert into ids select 'inv8', (api.create_invitation(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), 'team_leader',
  'new8@example.test', pg_temp.tid('t8'), pg_temp.dg('t8'), 'Handover', pg_temp.k(), null,
  pg_temp.m(4, pg_temp.id('T')))->>'invitationId')::uuid;
select is(pg_temp.detail(pg_temp.id('T'))->'pendingLeaders'->0->'replaces'->>'uid', pg_temp.uid(4),
  'the office shows who the invitation replaces');
select isnt(pg_temp.m(4, pg_temp.id('T')), null, 'the current leader stays until it is accepted');

-- The invitee joins Team A as a member first (review fix: replacing ends it).
insert into auth.users (id, email, aud, role, email_confirmed_at)
values (pg_temp.u(8), 'new8@example.test', 'authenticated', 'authenticated', now());
insert into auth.sessions (id, user_id, created_at, updated_at) values (pg_temp.s(8), pg_temp.u(8), now(), now());
do $$ begin
  perform api.create_invitation(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.id('T'), 'member',
    'new8@example.test', pg_temp.tid('t8m'), pg_temp.dg('t8m'), null, pg_temp.k());
  perform api.accept_invitation(pg_temp.u(8), pg_temp.s(8), pg_temp.dg('t8m'), null, pg_temp.k());
  perform api.accept_invitation(pg_temp.u(8), pg_temp.s(8), pg_temp.dg('t8'), null, pg_temp.k());
end $$;
select is((select string_agg(role::text || ':' || status::text, ',' order by started_at) from org.memberships
  where user_id = pg_temp.u(8) and office_id = pg_temp.id('T')), 'member:ended,team_leader:active',
  'the incoming leader''s member role in the office ends; one role remains');
select is(pg_temp.m(4, pg_temp.id('T')), null, 'accepting ends the outgoing leader''s membership');
select is((select m.replaced_by_id from org.memberships m where m.user_id = pg_temp.u(4) and m.office_id = pg_temp.id('T')),
  pg_temp.m(8, pg_temp.id('T')), 'as a replacement by the new leader');
select is(jsonb_array_length(pg_temp.detail(pg_temp.id('T'))->'leaders'), 1, 'the office keeps one leader, the new one');
select is((select count(*)::int from audit.tenant_events where action = 'office.leader_replaced' and target_id = pg_temp.id('T')::text),
  1, 'the replacement is audited');

select * from finish();
rollback;
