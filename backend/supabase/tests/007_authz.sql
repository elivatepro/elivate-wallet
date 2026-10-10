-- Blueprint 02 — B6 tests 7–14: resolver, role policy, access rules, reviewers,
-- workspace and replay.
begin;
create extension if not exists pgtap with schema extensions;
select plan(44);

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
create function pg_temp.decide(n int, p_permission text, p_office uuid, p_target int default null) returns jsonb
language sql stable as $$
  select authz.decide(pg_temp.u(n), p_permission, pg_temp.id('tenant'), p_office,
    case when p_target is not null then pg_temp.u(p_target) end)
$$;
create function pg_temp.allowed(n int, p_permission text, p_office uuid, p_target int default null) returns boolean
language sql stable as $$ select (pg_temp.decide(n, p_permission, p_office, p_target)->>'allowed')::boolean $$;

-- 1 President · 2 World Team · 3 Director · 4 Team Leader (T) · 5 Team Leader (T2)
-- 6 member (T) · 7 member (T2) · 9 other network's founder · 10 admin
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
end $$;

-- ── Resolver matrix (8) ──
select ok(pg_temp.allowed(4, 'record_income', pg_temp.id('T')), 'Team Leader: own office');
select ok(not pg_temp.allowed(4, 'record_income', pg_temp.id('T2')), 'Team Leader: not a sibling office');
select ok(not pg_temp.allowed(4, 'record_income', pg_temp.id('D')), 'Team Leader: not the parent office');
select ok(pg_temp.allowed(3, 'record_income', pg_temp.id('T2')), 'Director: everything below');
select ok(pg_temp.allowed(2, 'withdraw_on_behalf', pg_temp.id('T')), 'World Team default includes withdraw on behalf');
select ok(not pg_temp.allowed(3, 'withdraw_on_behalf', pg_temp.id('T')), 'Director default excludes withdraw on behalf');
select ok(pg_temp.allowed(1, 'record_income', pg_temp.id('T')), 'President Team: the whole network');
select ok(
  not (authz.decide(pg_temp.u(2), 'record_income', pg_temp.id('other'), pg_temp.id('O'))->>'allowed')::boolean,
  'nothing across networks'
);
select is(pg_temp.decide(4, 'record_income', pg_temp.id('T'), 4)->>'reason', 'self_target', 'leaders cannot target themselves');
select ok(not pg_temp.allowed(6, 'manage_members', pg_temp.id('T')), 'members have no leadership permissions');

-- ── Evidence reviewers (11) ──
select ok(not pg_temp.allowed(1, 'review_financial_evidence', null, 6), 'the President does not review without an assignment');
select lives_ok(
  $$ select api.assign_reviewer(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(3, pg_temp.id('D')), 'Finance lead', pg_temp.k()) $$,
  'the President assigns a specific reviewer'
);
select ok(pg_temp.allowed(3, 'review_financial_evidence', null, 6), 'the assigned reviewer may review');
select ok(not pg_temp.allowed(3, 'review_financial_evidence', null, 3), 'no self-review');

-- ── Role policy (7) ──
select throws_ok(
  $$ select api.set_role_permission(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'member', 'view_own_wallet', false, 'Test', pg_temp.k()) $$,
  'P0001', 'permission_not_grantable', 'protected rows cannot be changed'
);
select lives_ok(
  $$ select api.set_role_permission(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'record_income', false, 'Directors only', pg_temp.k()) $$,
  'the President switches a configurable permission off'
);
select ok(not pg_temp.allowed(4, 'record_income', pg_temp.id('T')), 'the change applies on the next decision');

-- ── Explicit rules (9, 10) ──
insert into ids
select 'grant', (api.create_access_assignment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(4),
  jsonb_build_array(jsonb_build_object('permission', 'approve_withdrawal', 'effect', 'allow',
    'scopeType', 'office_subtree', 'scopeOfficeId', pg_temp.id('T2'))),
  'Covering Team B', pg_temp.k())->>'assignmentId')::uuid;
select is(pg_temp.decide(4, 'approve_withdrawal', pg_temp.id('T2'))->>'source', 'explicit_grant', 'a grant opens a sibling office');
select lives_ok(
  $$ select api.create_access_assignment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(3),
       jsonb_build_array(jsonb_build_object('permission', 'approve_withdrawal', 'effect', 'deny',
         'scopeType', 'member', 'scopeUid', pg_temp.uid(6))),
       'Related party', pg_temp.k()) $$,
  'a member-scoped deny'
);
select is(pg_temp.decide(3, 'approve_withdrawal', pg_temp.id('T'), 6)->>'reason', 'explicit_deny', 'deny beats the role default');
select ok(not pg_temp.allowed(3, 'approve_withdrawal', null, 6), 'member deny applies when the target is given as a person');
select ok(pg_temp.allowed(3, 'approve_withdrawal', pg_temp.id('T')), 'the deny does not block the rest of the office');

update authz.access_rules set starts_at = now() - interval '2 hours', expires_at = now() - interval '1 hour'
where assignment_id = pg_temp.id('grant');
select ok(not pg_temp.allowed(4, 'approve_withdrawal', pg_temp.id('T2')), 'an expired grant stops working');

select throws_ok(
  $$ select api.create_access_assignment(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), pg_temp.uid(4),
       jsonb_build_array(jsonb_build_object('permission', 'record_income', 'effect', 'allow', 'scopeType', 'office_subtree', 'scopeOfficeId', pg_temp.id('W'))),
       'Too wide', pg_temp.k()) $$,
  'P0001', 'scope_exceeds_authority', 'a Director cannot grant above their office'
);
select throws_ok(
  $$ select api.create_access_assignment(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), pg_temp.uid(4),
       jsonb_build_array(jsonb_build_object('permission', 'record_income', 'effect', 'allow', 'scopeType', 'tenant')),
       'Too wide', pg_temp.k()) $$,
  'P0001', 'scope_exceeds_authority', 'a Director cannot grant network-wide'
);
insert into ids
select 'director_grant', (api.create_access_assignment(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), pg_temp.uid(4),
  jsonb_build_array(jsonb_build_object('permission', 'view_scoped_financial_reports', 'effect', 'allow', 'scopeType', 'office_subtree', 'scopeOfficeId', pg_temp.id('T'))),
  'Reports for Team A', pg_temp.k())->>'assignmentId')::uuid;
select ok(pg_temp.id('director_grant') is not null, 'a Director grants within their own subtree');
select throws_ok(
  $$ select api.create_access_assignment(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), pg_temp.uid(4),
       jsonb_build_array(jsonb_build_object('permission', 'manage_role_permissions', 'effect', 'allow', 'scopeType', 'office_subtree', 'scopeOfficeId', pg_temp.id('T'))),
       'Protected', pg_temp.k()) $$,
  'P0001', 'permission_not_grantable', 'protected permissions cannot be granted'
);
select throws_ok(
  $$ select api.create_access_assignment(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), pg_temp.uid(3),
       jsonb_build_array(jsonb_build_object('permission', 'record_income', 'effect', 'allow', 'scopeType', 'office_subtree', 'scopeOfficeId', pg_temp.id('T'))),
       'Self', pg_temp.k()) $$,
  'P0001', 'self_target_forbidden', 'no self-grants'
);

-- The Director loses access-management authority; the President can still revoke
-- what the Director created (checked against the revoker).
do $$ begin
  perform api.create_access_assignment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(3),
    jsonb_build_array(jsonb_build_object('permission', 'manage_access_rules', 'effect', 'deny', 'scopeType', 'tenant')),
    'Under review', pg_temp.k());
end $$;
select is(
  api.revoke_access_assignment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('director_grant'), 'Cleanup', pg_temp.k())->>'changed',
  'true', 'revocation works after the creator lost scope'
);
select ok(not pg_temp.allowed(4, 'view_scoped_financial_reports', pg_temp.id('T2')), 'revoked rules stop working');

-- ── W-05: generic member management is not lifecycle power (12) ──
select throws_ok(
  $$ select api.move_membership(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.m(6, pg_temp.id('T')), pg_temp.id('T2'), 'Move', pg_temp.k()) $$,
  'P0001', 'authorization_denied', 'a Team Leader cannot move memberships'
);

-- ── Replay re-checks authority; key reuse (14) ──
create temp table keys as select pg_temp.k() as replay_key, pg_temp.k() as conflict_key;
select lives_ok(
  $$ select api.add_membership(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.id('T'), pg_temp.uid(10), (select replay_key from keys)) $$,
  'a Team Leader adds a member'
);
select lives_ok(
  $$ select api.set_role_permission(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'manage_members', false, 'Central onboarding', pg_temp.k()) $$,
  'the President removes member management from Team Leaders'
);
select throws_ok(
  $$ select api.add_membership(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.id('T'), pg_temp.uid(10), (select replay_key from keys)) $$,
  'P0001', 'authorization_denied', 'a replay after losing authority is denied'
);
select lives_ok(
  $$ select api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), pg_temp.uid(10), (select conflict_key from keys)) $$,
  'first use of a key'
);
select throws_ok(
  $$ select api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('D'), pg_temp.uid(10), (select conflict_key from keys)) $$,
  'P0001', 'idempotency_conflict', 'same key, different request'
);

-- ── Workspace (A-02) ──
select throws_ok(
  $$ select api.list_members(pg_temp.u(4), pg_temp.s(4), pg_temp.m(2, pg_temp.id('W'))) $$,
  'P0001', 'workspace_invalid', 'a workspace must be your own membership'
);
select ok(
  (api.my_capabilities(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')))->'permissions') ? 'view_own_wallet'
  and not ((api.my_capabilities(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')))->'permissions') ? 'move_membership'),
  'capabilities list what the workspace allows'
);

-- ── Review fixes (PR #3) ──
select ok(not pg_temp.allowed(3, 'review_financial_evidence', null, 2), 'a scoped reviewer cannot review outside their subtree');

do $$ begin
  perform api.create_access_assignment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(2),
    jsonb_build_array(
      jsonb_build_object('permission', 'manage_members', 'effect', 'deny', 'scopeType', 'member', 'scopeUid', pg_temp.uid(7)),
      jsonb_build_object('permission', 'view_managed_wallets', 'effect', 'deny', 'scopeType', 'member', 'scopeUid', pg_temp.uid(7))),
    'Privacy request', pg_temp.k());
end $$;
select ok(
  not exists (
    select 1 from jsonb_array_elements(api.list_members(pg_temp.u(2), pg_temp.s(2), pg_temp.m(2, pg_temp.id('W')))->'items') i
    where i->'person'->>'uid' = pg_temp.uid(7)
  )
  and exists (
    select 1 from jsonb_array_elements(api.list_members(pg_temp.u(2), pg_temp.s(2), pg_temp.m(2, pg_temp.id('W')))->'items') i
    where i->'person'->>'uid' = pg_temp.uid(6)
  ),
  'member lists hide people the viewer is denied'
);

do $$ begin
  perform api.create_access_assignment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(2),
    jsonb_build_array(jsonb_build_object('permission', 'manage_access_rules', 'effect', 'deny',
      'scopeType', 'office_subtree', 'scopeOfficeId', pg_temp.id('T2'))),
    'Team B handled centrally', pg_temp.k());
end $$;
select throws_ok(
  $$ select api.create_access_assignment(pg_temp.u(2), pg_temp.s(2), pg_temp.m(2, pg_temp.id('W')), pg_temp.uid(3),
       jsonb_build_array(jsonb_build_object('permission', 'record_income', 'effect', 'allow', 'scopeType', 'office_subtree', 'scopeOfficeId', pg_temp.id('D'))),
       'Wide grant', pg_temp.k()) $$,
  'P0001', 'scope_exceeds_authority', 'a broad rule cannot cover a narrower deny inside it'
);

-- A leader who is also a plain member elsewhere cannot use the member
-- workspace to manage access with leader authority (A-02).
do $$ begin
  perform api.set_role_permission(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'manage_access_rules', true, 'Pilot', pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(5), pg_temp.k());
end $$;
select throws_ok(
  $$ select api.create_access_assignment(pg_temp.u(5), pg_temp.s(5), pg_temp.m(5, pg_temp.id('T')), pg_temp.uid(7),
       jsonb_build_array(jsonb_build_object('permission', 'record_income', 'effect', 'allow', 'scopeType', 'office_subtree', 'scopeOfficeId', pg_temp.id('T2'))),
       'From the wrong workspace', pg_temp.k()) $$,
  'P0001', 'scope_exceeds_authority', 'access management stays inside the selected workspace'
);
select lives_ok(
  $$ select api.create_access_assignment(pg_temp.u(5), pg_temp.s(5), pg_temp.m(5, pg_temp.id('T2')), pg_temp.uid(7),
       jsonb_build_array(jsonb_build_object('permission', 'record_income', 'effect', 'allow', 'scopeType', 'office_subtree', 'scopeOfficeId', pg_temp.id('T2'))),
       'From the leader workspace', pg_temp.k()) $$,
  'the same rule works from the leader workspace'
);

update identity.accounts set status = 'restricted' where user_id = pg_temp.u(1);
select throws_ok(
  $$ select api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Restricted', null, array[pg_temp.uid(6)], pg_temp.k()) $$,
  'P0001', 'authorization_denied', 'restricted accounts cannot make organizational changes'
);

select * from finish();
rollback;
