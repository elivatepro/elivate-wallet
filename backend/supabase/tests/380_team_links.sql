-- Blueprint 38 (owner decisions 2026-10-15): team invite links. One live link
-- per office, made by invite_members holders with the PIN; anyone with it
-- joins the office as a Member at once (seat cap applies); it stops when it
-- expires, fills, is replaced or turned off, or its creator loses authority.
begin;
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(37);

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
-- A link for office T made by person n in their workspace ws.
create function pg_temp.make(n int, ws uuid, code text, days int default 7, uses int default null)
returns jsonb language sql volatile as $$
  select api.create_team_link(pg_temp.u(n), pg_temp.s(n), ws, pg_temp.id('T'), days, uses,
    pg_temp.tid(code), pg_temp.dg(code), pg_temp.k())
$$;

-- 1 President · 3 Director of D · 4 Team Leader of T (under D) · 5 member of T
-- · 6 newcomer (no PIN yet) · 7 newcomer · 10 admin.
insert into auth.users (id, email, aud, role, email_confirmed_at)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated', now()
from unnest(array[1, 3, 4, 5, 6, 7, 10]) n;
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from unnest(array[1, 3, 4, 5, 6, 7, 10]) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from unnest(array[1, 3, 4, 5, 7, 10]) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');

insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Synthetic Network', 'SYN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), 'Pilot network', pg_temp.k()); end $$;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', null, array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'), array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
do $$ begin perform org.create_membership(pg_temp.id('tenant'), pg_temp.id('T'), pg_temp.u(5), 'member', pg_temp.u(1)); end $$;

-- ── Who may make a link ──
select throws_ok(
  $$ select pg_temp.make(5, pg_temp.m(5, pg_temp.id('T')), 'c5') $$,
  'P0001', 'authorization_denied', 'a member cannot make a team link'
);
select throws_ok(
  $$ select api.create_team_link(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.id('D'), 7, null,
       pg_temp.tid('cD'), pg_temp.dg('cD'), pg_temp.k()) $$,
  'P0001', 'authorization_denied', 'a Team Leader cannot make one for the office above'
);
select throws_ok(
  $$ select pg_temp.make(4, pg_temp.m(4, pg_temp.id('T')), 'c3', 3) $$,
  'P0001', 'validation_error', 'only 1, 7 or 30 days (or no end)'
);
select throws_ok(
  $$ select pg_temp.make(4, pg_temp.m(4, pg_temp.id('T')), 'c3', 7, 5) $$,
  'P0001', 'validation_error', 'only 10 or 50 people (or no limit)'
);
update identity.session_pin_proofs set verified_at = now() - interval '6 minutes' where session_id = pg_temp.s(4);
select throws_ok(
  $$ select pg_temp.make(4, pg_temp.m(4, pg_temp.id('T')), 'c4') $$,
  'P0001', 'step_up_required', 'making a link needs a fresh PIN'
);
update identity.session_pin_proofs set verified_at = now() where session_id = pg_temp.s(4);

create temp table first_link as select pg_temp.make(4, pg_temp.m(4, pg_temp.id('T')), 'c4', 7, null) as res;
select ok((select res->>'reference' like 'LNK-%' from first_link), 'the link carries an LNK reference');
select is((select res->>'state' from first_link), 'live', 'it works at once');
select is((select (res->>'replaced')::boolean from first_link), false, 'it replaced nothing');
select ok((select (res->>'expiresAt')::timestamptz between now() + interval '7 days' - interval '1 minute'
                  and now() + interval '7 days' from first_link), 'it works for 7 days');
select is(
  (api.team_link(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.id('T'))->'link'->>'teamLinkId'),
  (select res->>'teamLinkId' from first_link), 'the leader reads the office''s live link'
);
select is(
  (api.team_link(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), pg_temp.id('T'))->'link'->>'teamLinkId'),
  (select res->>'teamLinkId' from first_link), 'the Director above reads it too'
);
select throws_ok(
  $$ select api.team_link(pg_temp.u(5), pg_temp.s(5), pg_temp.m(5, pg_temp.id('T')), pg_temp.id('T')) $$,
  'P0001', 'authorization_denied', 'a member cannot read it'
);
select is((select count(*)::int from audit.tenant_events where action = 'team_link.created'), 1,
  'making it is audited');

-- ── The join page ──
select is(api.team_link_preview(pg_temp.dg('c4')),
  jsonb_build_object('networkName', 'Synthetic Network', 'officeName', 'Team A', 'invitedBy', null),
  'the preview names the network, office and inviter');
select throws_ok($$ select api.team_link_preview(pg_temp.dg('nope')) $$,
  'P0001', 'invitation_unavailable', 'an unknown code is unavailable');

-- ── Joining ──
create temp table joined as
select api.join_team_link(pg_temp.u(6), pg_temp.s(6), pg_temp.dg('c4'), 'kJoinTeamLink00000001') as res;
select is((select role::text from org.memberships where id = (select (res->>'membershipId')::uuid from joined)),
  'member', 'a newcomer without a PIN yet joins as a Member');
select is((select office_id from org.memberships where id = (select (res->>'membershipId')::uuid from joined)),
  pg_temp.id('T'), 'in the link''s office');
select is((select uses from org.team_links where token_digest = decode(pg_temp.dg('c4'), 'hex')), 1, 'one use counted');
select is((select count(*)::int from org.team_link_joins), 1, 'the join is recorded');
select is(api.join_team_link(pg_temp.u(6), pg_temp.s(6), pg_temp.dg('c4'), 'kJoinTeamLink00000001') - 'replayed',
  (select res - 'replayed' from joined), 'a replay returns the same result');
select throws_ok(
  $$ select api.join_team_link(pg_temp.u(6), pg_temp.s(6), pg_temp.dg('c4'), pg_temp.k()) $$,
  'P0001', 'membership_exists', 'joining twice is refused'
);
select throws_ok(
  $$ select api.join_team_link(pg_temp.u(3), pg_temp.s(3), pg_temp.dg('c4'), pg_temp.k()) $$,
  'P0001', 'membership_exists', 'someone already in the network is refused'
);
update auth.users set email_confirmed_at = null where id = pg_temp.u(7);
select throws_ok(
  $$ select api.join_team_link(pg_temp.u(7), pg_temp.s(7), pg_temp.dg('c4'), pg_temp.k()) $$,
  'P0001', 'email_unverified', 'an unconfirmed email cannot join'
);
update auth.users set email_confirmed_at = now() where id = pg_temp.u(7);

-- ── Replace, full, expired, turned off ──
create temp table second_link as select pg_temp.make(3, pg_temp.m(3, pg_temp.id('D')), 'c3', null, 10) as res;
select is((select (res->>'replaced')::boolean from second_link), true, 'a new link replaces the old one');
select is((select status::text from org.team_links where token_digest = decode(pg_temp.dg('c4'), 'hex')),
  'replaced', 'the old one is ended');
select throws_ok($$ select api.team_link_preview(pg_temp.dg('c4')) $$,
  'P0001', 'invitation_unavailable', 'the old link stops at once');
select is((select res->>'expiresAt' from second_link), null, 'no end date when asked');

update org.team_links set uses = 10 where token_digest = decode(pg_temp.dg('c3'), 'hex');
select throws_ok(
  $$ select api.join_team_link(pg_temp.u(7), pg_temp.s(7), pg_temp.dg('c3'), pg_temp.k()) $$,
  'P0001', 'invitation_unavailable', 'a full link takes nobody else'
);
select is(
  api.team_link(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D')), pg_temp.id('T'))->'link'->>'state',
  'full', 'the leader sees why it stopped'
);

create temp table third_link as select pg_temp.make(4, pg_temp.m(4, pg_temp.id('T')), 'c9', 1, null) as res;
alter table org.team_links disable trigger team_links_check;
update org.team_links set expires_at = now() - interval '1 minute' where token_digest = decode(pg_temp.dg('c9'), 'hex');
alter table org.team_links enable trigger team_links_check;
select throws_ok($$ select api.team_link_preview(pg_temp.dg('c9')) $$,
  'P0001', 'invitation_unavailable', 'an expired link is unavailable');

create temp table fourth_link as select pg_temp.make(4, pg_temp.m(4, pg_temp.id('T')), 'c8') as res;
select is(
  api.turn_off_team_link(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')),
    (select (res->>'teamLinkId')::uuid from fourth_link), 'kTurnOffTeamLink00001')->>'changed',
  'true', 'the leader turns it off'
);
select throws_ok($$ select api.team_link_preview(pg_temp.dg('c8')) $$,
  'P0001', 'invitation_unavailable', 'a turned-off link is unavailable');
select is(
  api.turn_off_team_link(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')),
    (select (res->>'teamLinkId')::uuid from fourth_link), pg_temp.k())->>'changed',
  'false', 'turning it off again changes nothing'
);
select is(
  api.team_link(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.id('T'))->'link',
  'null'::jsonb, 'no live link is left'
);

-- ── The creator loses authority ──
create temp table fifth_link as select pg_temp.make(4, pg_temp.m(4, pg_temp.id('T')), 'c7') as res;
update authz.role_permissions set allowed = false
where tenant_id = pg_temp.id('tenant') and role = 'team_leader' and permission_key = 'invite_members';
select throws_ok($$ select api.team_link_preview(pg_temp.dg('c7')) $$,
  'P0001', 'invitation_unavailable', 'a link stops when its creator can no longer invite');

-- ── Privileges ──
select ok(not has_function_privilege('authenticated', 'api.join_team_link(uuid, uuid, text, text, text)', 'execute'),
  'clients cannot call the join command directly');
select ok(not has_table_privilege('authenticated', 'org.team_links', 'select'),
  'clients cannot read team links');

select * from finish();
rollback;
