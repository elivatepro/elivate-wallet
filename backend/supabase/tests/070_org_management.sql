-- Blueprint 07 — B6: close office, role change (end + new), office and member
-- detail reads, member search, list_offices leaders, privileges.
begin;
create extension if not exists pgtap with schema extensions;
select plan(56);

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

-- 1 President · 2 World Team (W) · 3 Director (D) · 4 Team Leader (T) · 5 Team Leader (T2)
-- 6, 7, 8, 9 people · 10 admin · 11 other network's President
insert into auth.users (id, email, aud, role, email_confirmed_at)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated', now() from generate_series(1, 11) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 11) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 11) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');

insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
insert into ids
select 'tenant2', (api.start_network(pg_temp.u(11), pg_temp.s(11), 'Other Network', 'OTH', pg_temp.k())->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), 'Pilot', pg_temp.k());
  perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant2'), 'Pilot', pg_temp.k());
end $$;
insert into ids
select 'W', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'world_team', 'North', null, array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', pg_temp.id('W'), array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'), array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T2', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team B', pg_temp.id('D'), array[pg_temp.uid(5)], pg_temp.k())->>'officeId')::uuid;
update identity.profiles set first_name = 'Adaeze', last_name = 'Nwosu' where user_id = pg_temp.u(6);
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(6), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), pg_temp.uid(7), pg_temp.k());
end $$;

-- ── list_offices: leaders and child counts ──
select is(
  (select e->'leaders'->0->>'uid' from jsonb_array_elements(api.list_offices(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1))->'items') e
   where (e->>'id')::uuid = pg_temp.id('T')),
  pg_temp.uid(4), 'list_offices shows the office''s leaders'
);
select is(
  (select (e->>'childCount')::int from jsonb_array_elements(api.list_offices(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1))->'items') e
   where (e->>'id')::uuid = pg_temp.id('D')),
  2, 'list_offices counts open child offices'
);

-- ── office_detail ──
select is(
  jsonb_array_length(api.office_detail(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'))->'path'),
  3, 'the path runs from the top office to this one'
);
select is(
  api.office_detail(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'))->'path'->0->>'name',
  'North', 'the path starts at the top'
);
select is(
  (api.office_detail(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), pg_temp.id('D'))->>'memberCount')::int,
  5, 'a Director sees the rolled-up count of their own office'
);
select throws_ok(
  $$ select api.office_detail(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.id('T2')) $$,
  'P0001', 'not_found', 'a sibling office is not visible'
);
select throws_ok(
  $$ select api.office_detail(pg_temp.u(11), pg_temp.s(11), pg_temp.m(11), pg_temp.id('T')) $$,
  'P0001', 'not_found', 'another network''s office is not visible'
);
select is(
  (api.office_detail(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.id('T'))->>'canLeadAssign')::boolean,
  false, 'a Team Leader cannot lead-assign in their own office'
);

-- ── list_members search and masked email ──
select is(
  jsonb_array_length(api.list_members(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), p_query => 'adaeze')->'items'),
  1, 'members can be searched by name'
);
select is(
  jsonb_array_length(api.list_members(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), p_query => lower(pg_temp.uid(7)))->'items'),
  1, 'members can be searched by UID, case-insensitively'
);
select is(
  api.list_members(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), p_query => 'adaeze')->'items'->0->>'emailMasked',
  'u•••••@example.test', 'emails are masked'
);
select throws_ok(
  $$ select api.list_members(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), p_query => ' ') $$,
  'P0001', 'validation_error', 'an empty search is refused'
);

-- ── member_detail ──
select is(
  api.member_detail(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(6, pg_temp.id('T')))->'office'->>'name',
  'Team A', 'the President reads a member''s detail'
);
select is(
  (api.member_detail(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(6, pg_temp.id('T')))->'actions'->>'move')::boolean,
  true, 'the President may move the member'
);
select is(
  (api.member_detail(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.m(6, pg_temp.id('T')))->'actions'->>'move')::boolean,
  false, 'a Team Leader may not move (no move_membership by default)'
);
select is(
  (api.member_detail(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.m(6, pg_temp.id('T')))->'actions'->>'changeRole')::boolean,
  false, 'a Team Leader may not change roles in their own office'
);
select throws_ok(
  $$ select api.member_detail(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.m(7, pg_temp.id('T2'))) $$,
  'P0001', 'not_found', 'a member of a sibling office is not visible'
);
select throws_ok(
  $$ select api.member_detail(pg_temp.u(11), pg_temp.s(11), pg_temp.m(11), pg_temp.m(6, pg_temp.id('T'))) $$,
  'P0001', 'not_found', 'another network''s member is not visible'
);
select is(
  jsonb_array_length(api.member_detail(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(6, pg_temp.id('T')))->'history'),
  1, 'the membership history is listed'
);

-- ── Role change (end + new) ──
do $$ begin
  perform api.assign_reviewer(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(6, pg_temp.id('T')), 'Careful reviewer', pg_temp.k());
end $$;
insert into ids select 'old6', pg_temp.m(6, pg_temp.id('T'));
select throws_ok(
  $$ select api.change_membership_role(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('old6'), 'director', 'Promote', pg_temp.k()) $$,
  'P0001', 'validation_error', 'a role that does not fit the office is refused'
);
select throws_ok(
  $$ select api.change_membership_role(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('old6'), 'member', 'Same', pg_temp.k()) $$,
  'P0001', 'validation_error', 'the same role is refused'
);
select throws_ok(
  $$ select api.change_membership_role(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('old6'), 'team_leader', ' ', pg_temp.k()) $$,
  'P0001', 'validation_error', 'a reason is required'
);
select throws_ok(
  $$ select api.change_membership_role(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.id('old6'), 'team_leader', 'Co-lead', pg_temp.k()) $$,
  'P0001', 'authorization_denied', 'a Team Leader cannot make a co-leader in their own office'
);
update identity.session_pin_proofs set verified_at = now() - interval '6 minutes' where session_id = pg_temp.s(3);
select throws_ok(
  $$ select api.change_membership_role(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), pg_temp.id('old6'), 'team_leader', 'Promote', pg_temp.k()) $$,
  'P0001', 'step_up_required', 'a role change needs a fresh PIN'
);
update identity.session_pin_proofs set verified_at = now() where session_id = pg_temp.s(3);
create temp table rc as
select api.change_membership_role(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), pg_temp.id('old6'), 'team_leader', 'Promote', 'kRoleChange0000001') as res;
select is((select status::text from org.memberships where id = pg_temp.id('old6')), 'ended', 'the old membership ended');
select is((select action from org.membership_events where membership_id = pg_temp.id('old6') order by id desc limit 1),
  'replaced', 'it is recorded as replaced');
select is((select role::text from org.memberships where id = ((select res from rc)->>'membershipId')::uuid),
  'team_leader', 'the new membership holds the new role');
select is((select is_primary from org.memberships where id = ((select res from rc)->>'membershipId')::uuid),
  true, 'primary carries over');
select is((select replaced_by_id from org.memberships where id = pg_temp.id('old6')),
  ((select res from rc)->>'membershipId')::uuid, 'the old membership points to the new one');
select is((select count(*)::int from authz.reviewer_assignments where membership_id = pg_temp.id('old6') and ended_at is null),
  0, 'a reviewer assignment held through the old membership ends');
select is(
  api.change_membership_role(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), pg_temp.id('old6'), 'team_leader', 'Promote', 'kRoleChange0000001') - 'replayed',
  (select res from rc) - 'replayed', 'same key, same payload replays'
);
select throws_ok(
  $$ select api.change_membership_role(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), pg_temp.id('old6'), 'team_leader', 'Different', 'kRoleChange0000001') $$,
  'P0001', 'idempotency_conflict', 'same key, different payload conflicts'
);
select is((select count(*)::int from audit.tenant_events where action = 'membership.role_changed'), 1, 'the change is audited once');
-- Leader back to member: the other leader (4) remains.
select lives_ok(
  $$ select api.change_membership_role(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(6, pg_temp.id('T')), 'member', 'Step down', pg_temp.k()) $$,
  'a leader becomes a member while another leader remains'
);
select throws_ok(
  $$ select api.change_membership_role(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(5, pg_temp.id('T2')), 'member', 'Step down', pg_temp.k()) $$,
  'P0001', 'last_leader', 'the last leader cannot become a member'
);
select throws_ok(
  $$ select api.change_membership_role(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(1), 'member', 'Change', pg_temp.k()) $$,
  'P0001', 'conflict', 'a President Team membership has no office role to change'
);

-- ── Close office ──
do $$ begin
  perform api.create_invitation(pg_temp.u(5), pg_temp.s(5), pg_temp.m(5, pg_temp.id('T2')), pg_temp.id('T2'), 'member',
    'new@example.test', pg_temp.tid('tok-close'), pg_temp.dg('tok-close'), null, pg_temp.k());
end $$;
select throws_ok(
  $$ select api.close_office(pg_temp.u(2), pg_temp.s(2), pg_temp.m(2, pg_temp.id('W')), pg_temp.id('T2'), 'Merged', pg_temp.k()) $$,
  'P0001', 'authorization_denied', 'only the President Team closes offices'
);
select throws_ok(
  $$ select api.close_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('D'), 'Merged', pg_temp.k()) $$,
  'P0001', 'conflict', 'an office with open child offices cannot close'
);
select throws_ok(
  $$ select api.close_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), 'Merged', pg_temp.k()) $$,
  'P0001', 'conflict', 'an office with members cannot close'
);
select throws_ok(
  $$ select api.close_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), ' ', pg_temp.k()) $$,
  'P0001', 'validation_error', 'closing needs a reason'
);
do $$ begin
  perform api.move_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(7, pg_temp.id('T2')), pg_temp.id('T'), 'Merge into Team A', pg_temp.k());
end $$;
update identity.session_pin_proofs set verified_at = now() - interval '6 minutes' where session_id = pg_temp.s(1);
select throws_ok(
  $$ select api.close_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), 'Merged', pg_temp.k()) $$,
  'P0001', 'step_up_required', 'closing needs a fresh PIN'
);
update identity.session_pin_proofs set verified_at = now() where session_id = pg_temp.s(1);
insert into ids select 'lead5', pg_temp.m(5, pg_temp.id('T2'));
create temp table co as
select api.close_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), 'Merged into Team A', 'kCloseOffice00001') as res;
select is((select status::text from org.offices where id = pg_temp.id('T2')), 'closed', 'the office is closed');
select is((select status::text from org.memberships where id = pg_temp.id('lead5')), 'ended', 'its leader''s membership ended');
select is((select ended_reason from org.memberships where id = pg_temp.id('lead5')), 'Merged into Team A', 'with the reason');
select is((select status::text from org.invitations where office_id = pg_temp.id('T2')), 'revoked', 'pending invitations are revoked');
select is(((select res from co)->>'revokedInvitations')::int, 1, 'the result counts revoked invitations');
select is(
  api.close_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), 'Merged into Team A', 'kCloseOffice00001') - 'replayed',
  (select res from co) - 'replayed', 'a replay returns the same result'
);
select is(
  api.close_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), 'Again', pg_temp.k())->>'changed',
  'false', 'closing a closed office changes nothing'
);
select throws_ok(
  $$ select api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), pg_temp.uid(8), pg_temp.k()) $$,
  'P0001', 'not_found', 'nobody can be added to a closed office'
);
select throws_ok(
  $$ insert into org.memberships (tenant_id, office_id, user_id, role, created_by)
     values (pg_temp.id('tenant'), pg_temp.id('T2'), pg_temp.u(8), 'member', pg_temp.u(1)) $$,
  'P0001', 'conflict', 'the table itself refuses memberships in a closed office'
);
select throws_ok(
  $$ select api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Under closed', pg_temp.id('T2'), array[pg_temp.uid(8)], pg_temp.k()) $$,
  'P0001', 'hierarchy_invalid', 'a closed office cannot be a parent'
);
select is(
  (select count(*)::int from org.memberships where user_id = pg_temp.u(5) and is_primary),
  0, 'a person whose only membership ended has no primary'
);
select is((select count(*)::int from audit.tenant_events where action = 'office.closed'), 1, 'closing is audited once');
select is(
  api.office_detail(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'))->>'status',
  'closed', 'the President still reads the closed office'
);

-- ── Privileges ──
select ok(
  not has_function_privilege('authenticated', 'api.close_office(uuid,uuid,uuid,uuid,text,text,text)', 'execute')
  and not has_function_privilege('anon', 'api.change_membership_role(uuid,uuid,uuid,uuid,text,text,text,text)', 'execute')
  and not has_function_privilege('authenticated', 'api.member_detail(uuid,uuid,uuid,uuid)', 'execute')
  and not has_function_privilege('authenticated', 'api.office_detail(uuid,uuid,uuid,uuid)', 'execute')
  and not has_function_privilege('authenticated', 'api.list_members(uuid,uuid,uuid,uuid,text,text,text,int,text)', 'execute'),
  'public clients cannot call the new commands and reads'
);
select ok(
  has_function_privilege('service_role', 'api.close_office(uuid,uuid,uuid,uuid,text,text,text)', 'execute')
  and has_function_privilege('service_role', 'api.list_members(uuid,uuid,uuid,uuid,text,text,text,int,text)', 'execute'),
  'the service role calls them'
);

select * from finish();
rollback;
