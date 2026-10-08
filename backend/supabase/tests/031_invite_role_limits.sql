-- Blueprint 03 — B6 tests 2, 3, 5: invite-role matrix B (owner decision 1),
-- reason and step-up for leader roles, explicit grants and denies, restricted
-- accounts, and replays re-checking authority.
begin;
create extension if not exists pgtap with schema extensions;
select plan(25);

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
-- Invitation by user n (workspace in office ws_office) into office o with role r.
create function pg_temp.inv(n int, ws_office text, o text, r text, reason text default 'Leads the team')
returns jsonb language sql volatile as $$
  select api.create_invitation(pg_temp.u(n), pg_temp.s(n), pg_temp.m(n, pg_temp.id(ws_office)), pg_temp.id(o), r,
    'new' || md5(random()::text) || '@example.test', gen_random_uuid(),
    encode(sha256(convert_to(random()::text, 'UTF8')), 'hex'), reason, pg_temp.k())
$$;

-- 1 President · 2 World Team (W) · 3 Director (D) · 4 Team Leader (T) ·
-- 5 Team Leader (Ts, sibling) · 6 member of D with an explicit grant · 10 admin
insert into auth.users (id, email, aud, role, email_confirmed_at)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated', now() from generate_series(1, 10) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 10) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 10) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');

insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), 'Pilot network', pg_temp.k()); end $$;
insert into ids
select 'W', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'world_team', 'North', null, array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', pg_temp.id('W'), array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'), array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'Ts', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team B', pg_temp.id('D'), array[pg_temp.uid(5)], pg_temp.k())->>'officeId')::uuid;
insert into ids values ('P', '00000000-0000-0000-0000-000000000000');
create or replace function pg_temp.m(n int, p_office uuid default null) returns uuid language sql stable as $$
  select id from org.memberships
  where user_id = pg_temp.u(n) and status = 'active'
    and office_id is not distinct from nullif(p_office, '00000000-0000-0000-0000-000000000000'::uuid)
  order by started_at desc, id limit 1
$$;

-- ── Team Leader ──
select lives_ok($$ select pg_temp.inv(4, 'T', 'T', 'member', null) $$, 'TL invites members into their own office');
select throws_ok($$ select pg_temp.inv(4, 'T', 'T', 'team_leader') $$, 'P0001', 'role_not_invitable', 'TL cannot create a peer Team Leader (legacy bug)');
select throws_ok($$ select pg_temp.inv(4, 'T', 'Ts', 'member', null) $$, 'P0001', 'authorization_denied', 'TL cannot invite into a sibling office');
select throws_ok($$ select pg_temp.inv(4, 'T', 'D', 'member', null) $$, 'P0001', 'authorization_denied', 'TL cannot invite above their office');

-- ── Director ──
select lives_ok($$ select pg_temp.inv(3, 'D', 'D', 'member', null) $$, 'Director invites members into their own office');
select lives_ok($$ select pg_temp.inv(3, 'D', 'T', 'member', null) $$, 'Director invites members below');
select lives_ok($$ select pg_temp.inv(3, 'D', 'T', 'team_leader') $$, 'Director invites Team Leaders below');
select throws_ok($$ select pg_temp.inv(3, 'D', 'D', 'director') $$, 'P0001', 'role_not_invitable', 'Director cannot create a peer Director');
select throws_ok($$ select pg_temp.inv(3, 'D', 'D', 'team_leader') $$, 'P0001', 'role_office_mismatch', 'leader role must fit the office kind');

-- ── World Team ──
select lives_ok($$ select pg_temp.inv(2, 'W', 'D', 'director') $$, 'World Team invites Directors below');
select lives_ok($$ select pg_temp.inv(2, 'W', 'T', 'team_leader') $$, 'World Team invites Team Leaders below');
select throws_ok($$ select pg_temp.inv(2, 'W', 'W', 'world_team_member') $$, 'P0001', 'role_not_invitable', 'World Team cannot create a peer');

-- ── President Team ──
select lives_ok($$ select pg_temp.inv(1, 'P', 'W', 'world_team_member') $$, 'President Team invites World Team Members');
select lives_ok($$ select pg_temp.inv(1, 'P', 'Ts', 'member', null) $$, 'President Team invites members anywhere');
select throws_ok($$ select pg_temp.inv(1, 'P', 'W', 'president_team_member') $$, 'P0001', 'role_not_invitable', 'President Team Member is never invited');

-- ── Reason and step-up (3) ──
select throws_ok($$ select pg_temp.inv(3, 'D', 'T', 'team_leader', null) $$, 'P0001', 'validation_error', 'leader invitations need a reason');
update identity.session_pin_proofs set verified_at = now() - interval '10 minutes' where user_id = pg_temp.u(3);
select throws_ok($$ select pg_temp.inv(3, 'D', 'T', 'team_leader') $$, 'P0001', 'step_up_required', 'leader invitations need a fresh PIN');
select lives_ok($$ select pg_temp.inv(3, 'D', 'T', 'member', null) $$, 'member invitations need neither');
update identity.session_pin_proofs set verified_at = now() where user_id = pg_temp.u(3);

-- ── Explicit grant only: members, never leaders ──
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('D'), pg_temp.uid(6), pg_temp.k());
  perform api.create_access_assignment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(6),
    jsonb_build_array(jsonb_build_object('permission', 'invite_members', 'effect', 'allow', 'scopeType', 'office_subtree',
      'scopeOfficeId', pg_temp.id('D'))), 'Helps with onboarding', pg_temp.k());
end $$;
select lives_ok($$ select pg_temp.inv(6, 'D', 'T', 'member', null) $$, 'an explicit grant allows member invitations in scope');
select throws_ok($$ select pg_temp.inv(6, 'D', 'T', 'team_leader') $$, 'P0001', 'role_not_invitable', 'an explicit grant never allows leader invitations');

-- ── Deny beats role; replays re-check authority (5) ──
create temp table key3 as select pg_temp.k() as k;
create temp table first3 as select api.create_invitation(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), pg_temp.id('T'),
  'member', 'replay@example.test', gen_random_uuid(), encode(sha256('r'::bytea), 'hex'), null, (select k from key3)) as res;
do $$ begin
  perform api.create_access_assignment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(3),
    jsonb_build_array(jsonb_build_object('permission', 'invite_members', 'effect', 'deny', 'scopeType', 'tenant')),
    'Paused invitations', pg_temp.k());
end $$;
select throws_ok($$ select pg_temp.inv(3, 'D', 'T', 'member', null) $$, 'P0001', 'authorization_denied', 'an explicit deny beats the role');
select throws_ok(
  $$ select api.create_invitation(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), pg_temp.id('T'),
       'member', 'replay@example.test', gen_random_uuid(), encode(sha256('r'::bytea), 'hex'), null, (select k from key3)) $$,
  'P0001', 'authorization_denied', 'a replay after losing invite_members is refused'
);
select throws_ok(
  $$ select api.revoke_invitation(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), (select (res->>'invitationId')::uuid from first3), 'Cleanup', pg_temp.k()) $$,
  'P0001', 'authorization_denied', 'revoking needs invite_members too'
);
select lives_ok(
  $$ select api.revoke_invitation(pg_temp.u(2), pg_temp.s(2), pg_temp.m(2, pg_temp.id('W')), (select (res->>'invitationId')::uuid from first3), 'Cleanup', pg_temp.k()) $$,
  'any current leader above can revoke an invitation they did not send (Q10)'
);

-- ── Restricted accounts ──
update identity.accounts set status = 'restricted' where user_id = pg_temp.u(2);
select throws_ok($$ select pg_temp.inv(2, 'W', 'T', 'member', null) $$, 'P0001', 'authorization_denied', 'restricted accounts cannot invite');

select * from finish();
rollback;
