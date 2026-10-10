-- Blueprint 03 — B6 tests 1, 4–8, 10, 13: create, preview, verify, accept,
-- reissue, revoke, expiry and the in-app list.
begin;
create extension if not exists pgtap with schema extensions;
select plan(69);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.uid(n int) returns text language sql stable as
  $$ select uid from identity.accounts where user_id = pg_temp.u(n) $$;
create function pg_temp.k() returns text language sql volatile as
  $$ select 'k' || md5(random()::text || clock_timestamp()::text) $$;
-- Token digests as the Edge Function sends them: hex SHA-256 of the link token.
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
-- Member invitation by user n from their workspace in office o.
create function pg_temp.invite(n int, ws uuid, office uuid, invitee text, tok text, role text default 'member', reason text default null)
returns jsonb language sql volatile as $$
  select api.create_invitation(pg_temp.u(n), pg_temp.s(n), ws, office, role, invitee, pg_temp.tid(tok), pg_temp.dg(tok), reason, pg_temp.k())
$$;

-- 1 President · 2 World Team · 3 Director · 4 Team Leader (T) · 5 Team Leader (T2)
-- 6,7,8,9 invitees (9 unconfirmed email) · 10 admin
insert into auth.users (id, email, aud, role, email_confirmed_at)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated',
  case when n = 9 then null else now() end
from generate_series(1, 10) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 10) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 5) n; end $$;
do $$ begin perform api.set_pin(pg_temp.u(10), pg_temp.s(10), repeat('a', 64)); end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');

insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos <Network>', 'LGN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), 'Pilot network', pg_temp.k()); end $$;
insert into ids
select 'W', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'world_team', 'North', null, array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', pg_temp.id('W'), array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'), array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T2', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team B', pg_temp.id('D'), array[pg_temp.uid(5)], pg_temp.k())->>'officeId')::uuid;
insert into ids values ('wsT', pg_temp.m(4, pg_temp.id('T'))), ('wsD', pg_temp.m(3, pg_temp.id('D')));

-- ── Create (1) ──
create temp table r1 as select pg_temp.invite(4, pg_temp.id('wsT'), pg_temp.id('T'), ' U6@Example.test ', 'tok-6') as res;
insert into ids select 'inv6', (res->>'invitationId')::uuid from r1;

select ok((select res->>'reference' from r1) ~ '^INV-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$', 'INV reference matches the D-01 pattern');
select is((select res->>'status' from r1), 'pending', 'a new invitation is pending');
select ok(not (select res ? 'token' or res ? 'tokenDigest' or res ? 'tokenId' from r1), 'the result never carries the token');
select is((select email from org.invitations where id = pg_temp.id('inv6')), 'u6@example.test', 'email stored trimmed and lower-cased');
select is((select token_digest from org.invitations where id = pg_temp.id('inv6')), decode(pg_temp.dg('tok-6'), 'hex'), 'only the digest is stored');
select ok((select expires_at - created_at from org.invitations where id = pg_temp.id('inv6')) = interval '7 days', 'link lasts 7 days (owner decision 2)');
select is((select count(*)::int from org.invitation_events where invitation_id = pg_temp.id('inv6') and action = 'created'), 1, 'a created event is recorded');
select is((select count(*)::int from audit.tenant_events where target_type = 'invitation' and target_id = pg_temp.id('inv6')::text), 1, 'tenant audit records the invitation');
select is((select count(*)::int from outbox.events where aggregate_id = pg_temp.id('inv6')), 1, 'exactly one email is queued with the invitation');
select is(
  (select params from outbox.events where aggregate_id = pg_temp.id('inv6')),
  jsonb_build_object('network', 'Lagos <Network>', 'office', 'Team A', 'role', 'Member',
    'reference', (select res->>'reference' from r1),
    'expiresAt', (select to_char(expires_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') from org.invitations where id = pg_temp.id('inv6'))),
  'the queued email carries only safe display values'
);
select is((select d.status::text from outbox.deliveries d join outbox.events e on e.id = d.event_id where e.aggregate_id = pg_temp.id('inv6')), 'pending', 'its delivery waits for the worker');

-- Idempotency (5).
create temp table key1 as select pg_temp.k() as k;
create temp table r2 as select api.create_invitation(pg_temp.u(4), pg_temp.s(4), pg_temp.id('wsT'), pg_temp.id('T'), 'member', 'u8@example.test', pg_temp.tid('tok-8'), pg_temp.dg('tok-8'), null, (select k from key1)) as res;
create temp table r3 as select api.create_invitation(pg_temp.u(4), pg_temp.s(4), pg_temp.id('wsT'), pg_temp.id('T'), 'member', 'u8@example.test', pg_temp.tid('tok-8b'), pg_temp.dg('tok-8b'), null, (select k from key1)) as res;
select is((select res->>'invitationId' from r3), (select res->>'invitationId' from r2), 'same key returns the same invitation');
select is((select res->>'replayed' from r3), 'true', 'the repeat is marked as a replay');
select is((select token_digest from org.invitations where id = (select (res->>'invitationId')::uuid from r2)), decode(pg_temp.dg('tok-8'), 'hex'), 'a replay keeps the first link');
select is((select count(*)::int from outbox.events where aggregate_id = (select (res->>'invitationId')::uuid from r2)), 1, 'a replay queues no second email');
select throws_ok(
  $$ select api.create_invitation(pg_temp.u(4), pg_temp.s(4), pg_temp.id('wsT'), pg_temp.id('T'), 'member', 'u9@example.test', pg_temp.tid('x'), pg_temp.dg('x'), null, (select k from key1)) $$,
  'P0001', 'idempotency_conflict', 'same key with a different payload is refused'
);

-- Duplicates (4).
select throws_ok(
  $$ select pg_temp.invite(4, pg_temp.id('wsT'), pg_temp.id('T'), 'u6@example.test', 'tok-dup') $$,
  'P0001', 'invitation_exists', 'one pending invitation per email, office and role'
);
select lives_ok(
  $$ select pg_temp.invite(3, pg_temp.id('wsD'), pg_temp.id('D'), 'u6@example.test', 'tok-6d') $$,
  'the same email can be invited to another office'
);
select throws_ok(
  $$ select pg_temp.invite(4, pg_temp.id('wsT'), pg_temp.id('T'), 'u4@example.test', 'tok-self') $$,
  'P0001', 'self_target_forbidden', 'leaders cannot invite themselves'
);
select throws_ok(
  $$ select pg_temp.invite(4, pg_temp.id('wsT'), pg_temp.id('T'), 'not-an-email', 'tok-bad') $$,
  'P0001', 'validation_error', 'email must look like an email'
);
select is(
  (select count(*)::int from org.invitations), 3,
  'failed creates leave no invitation behind'
);

-- ── Preview and email check (6) ──
select is(api.invitation_preview(pg_temp.dg('tok-6')), '{"email": "u6@example.test"}'::jsonb, 'preview shows only the bound email');
select throws_ok($$ select api.invitation_preview(pg_temp.dg('nope')) $$, 'P0001', 'invitation_unavailable', 'unknown link is unavailable');
select throws_ok($$ select api.invitation_preview('xyz') $$, 'P0001', 'validation_error', 'malformed digest is rejected');
select is(api.request_invitation_verification(pg_temp.dg('tok-6'))->>'email', 'u6@example.test', 'verification returns the bound email to the server');
select throws_ok($$ select api.request_invitation_verification(pg_temp.dg('tok-6')) $$, 'P0001', 'rate_limited', 'verification has a 60 s cooldown');

-- ── Accept (7, 8) ──
create temp table r9 as select pg_temp.invite(4, pg_temp.id('wsT'), pg_temp.id('T'), 'u9@example.test', 'tok-9') as res;
select throws_ok(
  $$ select api.accept_invitation(pg_temp.u(9), pg_temp.s(9), pg_temp.dg('tok-9'), null, pg_temp.k()) $$,
  'P0001', 'email_unverified', 'an unconfirmed email cannot accept'
);
select throws_ok(
  $$ select api.accept_invitation(pg_temp.u(7), pg_temp.s(7), pg_temp.dg('tok-6'), null, pg_temp.k()) $$,
  'P0001', 'invitation_email_mismatch', 'another account cannot use the link'
);
select throws_ok(
  $$ select api.accept_invitation(pg_temp.u(7), pg_temp.s(7), null, pg_temp.id('inv6'), pg_temp.k()) $$,
  'P0001', 'invitation_unavailable', 'by id, another person sees nothing'
);
select throws_ok(
  $$ select api.accept_invitation(pg_temp.u(6), pg_temp.s(6), pg_temp.dg('tok-6'), pg_temp.id('inv6'), pg_temp.k()) $$,
  'P0001', 'validation_error', 'exactly one of token or invitation id'
);

select is((select identity.pin_gate(pg_temp.u(6), pg_temp.s(6))), 'pin_setup_required', 'the invitee has no PIN yet');
create temp table authz_before as select authz_version as v from org.tenants where id = pg_temp.id('tenant');
create temp table acc as select api.accept_invitation(pg_temp.u(6), pg_temp.s(6), pg_temp.dg('tok-6'), null, pg_temp.k()) as res;
select is((select res->>'role' from acc), 'member', 'joining before the PIN is allowed (owner decision 7)');
select is((select (res->>'officeId')::uuid from acc), pg_temp.id('T'), 'membership in exactly the invited office');
select is((select res->>'isPrimary' from acc), 'true', 'the first membership is primary');
select is((select status::text from org.invitations where id = pg_temp.id('inv6')), 'accepted', 'the invitation is accepted');
select is((select accepted_membership_id from org.invitations where id = pg_temp.id('inv6')), (select (res->>'membershipId')::uuid from acc), 'acceptance links the membership');
-- Blueprint 13: T01 to whoever sent the invitation, in the same transaction.
select is((select count(*)::int from outbox.events e join org.invitations i on i.id = pg_temp.id('inv6')
  where e.template = 'team.invitation_accepted' and e.recipient_user_id = i.invited_by), 1,
  'the inviter gets the invitation-accepted email');
select is((select count(*)::int from notify.items n join org.invitations i on i.id = pg_temp.id('inv6')
  where n.kind = 'team.invitation_accepted' and n.user_id = i.invited_by), 1, 'and a bell item');
select ok((select authz_version from org.tenants where id = pg_temp.id('tenant')) > (select v from authz_before), 'acceptance bumps the authorization version');
select is(
  api.accept_invitation(pg_temp.u(6), pg_temp.s(6), pg_temp.dg('tok-6'), null, pg_temp.k())->>'membershipId',
  (select res->>'membershipId' from acc), 'accepting again on another device returns the same membership'
);
select throws_ok($$ select api.invitation_preview(pg_temp.dg('tok-6')) $$, 'P0001', 'invitation_unavailable', 'an accepted link is unavailable');

-- Existing membership: invitation stays pending.
create temp table r6b as select pg_temp.invite(4, pg_temp.id('wsT'), pg_temp.id('T'), 'u6@example.test', 'tok-6b') as res;
select throws_ok(
  $$ select api.accept_invitation(pg_temp.u(6), pg_temp.s(6), pg_temp.dg('tok-6b'), null, pg_temp.k()) $$,
  'P0001', 'membership_exists', 'an existing membership is reported'
);
select is((select status::text from org.invitations where id = (select (res->>'invitationId')::uuid from r6b)), 'pending', 'and the invitation stays pending');

-- PIN gate: pin_required and pin_locked refuse; blocked accounts refuse.
do $$ begin perform api.set_pin(pg_temp.u(8), pg_temp.s(8), repeat('a', 64)); end $$;
delete from identity.session_pin_proofs where user_id = pg_temp.u(8);
select throws_ok(
  $$ select api.accept_invitation(pg_temp.u(8), pg_temp.s(8), pg_temp.dg('tok-8'), null, pg_temp.k()) $$,
  'P0001', 'pin_required', 'a person with a PIN must enter it first'
);
update identity.pin_credentials set failed_attempts = 5, locked_at = now() where user_id = pg_temp.u(8);
select throws_ok(
  $$ select api.accept_invitation(pg_temp.u(8), pg_temp.s(8), pg_temp.dg('tok-8'), null, pg_temp.k()) $$,
  'P0001', 'pin_locked', 'a locked PIN refuses'
);
update identity.accounts set status = 'suspended' where user_id = pg_temp.u(8);
select throws_ok(
  $$ select api.accept_invitation(pg_temp.u(8), pg_temp.s(8), pg_temp.dg('tok-8'), null, pg_temp.k()) $$,
  'P0001', 'account_blocked', 'a suspended account refuses'
);

-- ── In-app list and accept by id (Q8) ──
create temp table r7 as select pg_temp.invite(4, pg_temp.id('wsT'), pg_temp.id('T'), 'u7@example.test', 'tok-7') as res;
select is(jsonb_array_length(api.my_invitations(pg_temp.u(7), pg_temp.s(7))), 1, 'a person sees invitations for their verified email');
select is(api.my_invitations(pg_temp.u(7), pg_temp.s(7))->0->>'tenantName', 'Lagos <Network>', 'with the network name');
select throws_ok($$ select api.my_invitations(pg_temp.u(9), pg_temp.s(9)) $$, 'P0001', 'email_unverified', 'not before the email is verified');

-- ── Reissue (10) ──
select throws_ok(
  $$ select api.reissue_invitation(pg_temp.u(4), pg_temp.s(4), pg_temp.id('wsT'), (select (res->>'invitationId')::uuid from r7), pg_temp.tid('tok-7b'), pg_temp.dg('tok-7b'), pg_temp.k()) $$,
  'P0001', 'rate_limited', 'one reissue per minute'
);
update org.invitations set last_issued_at = now() - interval '2 minutes', expires_at = now() + interval '1 day'
where id = (select (res->>'invitationId')::uuid from r7);
create temp table re7 as select api.reissue_invitation(pg_temp.u(4), pg_temp.s(4), pg_temp.id('wsT'), (select (res->>'invitationId')::uuid from r7), pg_temp.tid('tok-7b'), pg_temp.dg('tok-7b'), pg_temp.k()) as res;
select is((select res->>'issueCount' from re7), '2', 'reissue counts the new link');
select ok((select expires_at from org.invitations where id = (select (res->>'invitationId')::uuid from r7)) = now() + interval '7 days', 'expiry restarts');
select throws_ok($$ select api.invitation_preview(pg_temp.dg('tok-7')) $$, 'P0001', 'invitation_unavailable', 'the old link dies immediately');
select is(api.invitation_preview(pg_temp.dg('tok-7b'))->>'email', 'u7@example.test', 'the new link works');
select is((select count(*)::int from outbox.events where aggregate_id = (select (res->>'invitationId')::uuid from r7)), 2, 'a new email is queued for the new link');
update org.invitations set issue_count = 6, last_issued_at = now() - interval '2 minutes'
where id = (select (res->>'invitationId')::uuid from r7);
select throws_ok(
  $$ select api.reissue_invitation(pg_temp.u(4), pg_temp.s(4), pg_temp.id('wsT'), (select (res->>'invitationId')::uuid from r7), pg_temp.tid('tok-7c'), pg_temp.dg('tok-7c'), pg_temp.k()) $$,
  'P0001', 'conflict', 'at most 5 reissues'
);
select is(
  api.accept_invitation(pg_temp.u(7), pg_temp.s(7), null, (select (res->>'invitationId')::uuid from r7), pg_temp.k())->>'role',
  'member', 'accepting from the in-app list works without the link'
);

-- ── Revoke (Q9) ──
select throws_ok(
  $$ select api.revoke_invitation(pg_temp.u(4), pg_temp.s(4), pg_temp.id('wsT'), (select (res->>'invitationId')::uuid from r9), '', pg_temp.k()) $$,
  'P0001', 'validation_error', 'revoking needs a reason'
);
select is(
  api.revoke_invitation(pg_temp.u(4), pg_temp.s(4), pg_temp.id('wsT'), (select (res->>'invitationId')::uuid from r9), 'Wrong person', pg_temp.k())->>'status',
  'revoked', 'a pending invitation can be revoked'
);
select throws_ok($$ select api.invitation_preview(pg_temp.dg('tok-9')) $$, 'P0001', 'invitation_unavailable', 'a revoked link is unavailable');
select throws_ok(
  $$ select api.reissue_invitation(pg_temp.u(4), pg_temp.s(4), pg_temp.id('wsT'), (select (res->>'invitationId')::uuid from r9), pg_temp.tid('tok-9b'), pg_temp.dg('tok-9b'), pg_temp.k()) $$,
  'P0001', 'conflict', 'a revoked invitation cannot be reissued'
);
select throws_ok(
  $$ select api.revoke_invitation(pg_temp.u(4), pg_temp.s(4), pg_temp.id('wsT'), pg_temp.id('inv6'), 'Too late', pg_temp.k()) $$,
  'P0001', 'conflict', 'an accepted invitation cannot be revoked'
);

-- ── Expiry (13) ──
update org.invitations set expires_at = now() - interval '1 second' where id = (select (res->>'invitationId')::uuid from r2);
select throws_ok($$ select api.invitation_preview(pg_temp.dg('tok-8')) $$, 'P0001', 'invitation_unavailable', 'an overdue link is unavailable at once');
select ok((api.outbox_run_maintenance()->>'expiredInvitations')::int >= 1, 'maintenance records overdue invitations');
select is((select status::text from org.invitations where id = (select (res->>'invitationId')::uuid from r2)), 'expired', 'the invitation is now expired');
select is((select count(*)::int from org.invitation_events where invitation_id = (select (res->>'invitationId')::uuid from r2) and action = 'expired'), 1, 'with an expiry event');
select is((select count(*)::int from org.memberships where user_id = pg_temp.u(8)), 0, 'expiry creates no membership');

-- ── Leader list ──
select is(
  (select count(*)::int from jsonb_array_elements(api.list_invitations(pg_temp.u(3), pg_temp.s(3), pg_temp.id('wsD'))->'items')),
  (select count(*)::int from org.invitations), 'a Director sees invitations across the subtree'
);
select ok(
  not exists (select 1 from jsonb_array_elements(api.list_invitations(pg_temp.u(4), pg_temp.s(4), pg_temp.id('wsT'))->'items') i
              where (i->>'officeId')::uuid <> pg_temp.id('T')),
  'a Team Leader sees only their office'
);

select * from finish();
rollback;
