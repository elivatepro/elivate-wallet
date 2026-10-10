-- Blueprint 22 — B5 220: setup by role and the profile gate. Levels and steps
-- per role, the gate in the security state and the bootstrap, refusals with
-- step and level, the calls that stay open (the list is exact), joining, a
-- paused network, and the light setup's name rules.
begin;
create extension if not exists pgtap with schema extensions;
select plan(52);

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
create function pg_temp.ws(n int) returns uuid language sql stable as $$
  select id from org.memberships where user_id = pg_temp.u(n) and status = 'active'
  order by (role = 'president_team_member') desc, started_at, id limit 1
$$;
create function pg_temp.setup(n int) returns jsonb language sql stable as
  $$ select identity.setup_state(pg_temp.u(n)) $$;
create function pg_temp.level_next(n int) returns text language sql stable as
  $$ select (pg_temp.setup(n)->>'level') || ':' || coalesce(pg_temp.setup(n)->>'next', '-') $$;
-- The error code and its details, or 'no error'.
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare
  msg text;
  det text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  return msg || coalesce(' ' || nullif(det, '{}'), '');
end $$;
create function pg_temp.photo(n int) returns void language plpgsql as $$
begin
  perform api.set_profile_photo(pg_temp.u(n), pg_temp.s(n),
    'photos/' || pg_temp.u(n)::text || '/' || gen_random_uuid()::text || '.png');
end $$;

-- 1 founder, President · 2 Team Leader · 3 member · 4 Director · 5 World Team
-- 6 second President · 7 approved founder, no network yet · 8 admin, nothing else
-- 10 founder of a second network · 11 member there (the network gets paused)
-- 12 invited, joins during the test
insert into auth.users (id, email, aud, role, email_confirmed_at)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated', now()
from unnest(array[1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12]) n;
insert into founders.approved (user_id, source)
select pg_temp.u(n), 'existing' from unnest(array[1, 7, 10]) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from unnest(array[1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12]) n;
do $$ begin
  perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from unnest(array[1, 2, 3, 4, 5, 6, 7, 8, 10, 11]) n;
end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(8), 'Test admin');

-- Fixtures are built with the gate off; the tests turn it back on.
set local identity.setup_gate = off;
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
insert into ids
select 'other', (api.start_network(pg_temp.u(10), pg_temp.s(10), 'Abuja Network', 'ABJ', pg_temp.k())->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(8), pg_temp.s(8), pg_temp.id('tenant'), 'Pilot', pg_temp.k());
  perform api.activate_tenant(pg_temp.u(8), pg_temp.s(8), pg_temp.id('other'), 'Pilot', pg_temp.k());
end $$;
insert into ids
select 'W', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), 'world_team', 'World', null,
  array[pg_temp.uid(5)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), 'director', 'Directors', pg_temp.id('W'),
  array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), 'team_leader', 'Team A', pg_temp.id('D'),
  array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T2', (api.create_office(pg_temp.u(10), pg_temp.s(10), pg_temp.ws(10), 'team_leader', 'Team B', null,
  array[pg_temp.uid(10)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('T'), pg_temp.uid(3), pg_temp.k());
  perform api.add_president(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.uid(6), 'Co-president', pg_temp.k());
  perform api.add_membership(pg_temp.u(10), pg_temp.s(10), pg_temp.ws(10), pg_temp.id('T2'), pg_temp.uid(11),
    pg_temp.k());
end $$;
insert into ids select 'inv', (api.create_invitation(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('T'),
  'member', 'u12@example.test', pg_temp.tid('tok-12'), pg_temp.dg('tok-12'), null, pg_temp.k())->>'invitationId')::uuid;
set local identity.setup_gate = on;

-- ── Levels and steps per role (11) ──
select is(pg_temp.level_next(1), 'light:profile', 'President Team: light setup');
select is(pg_temp.level_next(6), 'light:profile', 'a second President: light setup');
select is(pg_temp.level_next(7), 'light:profile', 'an approved founder before naming a network: light setup');
select is(pg_temp.level_next(2), 'wallet:identity', 'Team Leader: wallet setup, NIN first');
select is(pg_temp.level_next(3), 'wallet:identity', 'member: wallet setup');
select is(pg_temp.level_next(4), 'wallet:identity', 'Director: wallet setup');
select is(pg_temp.level_next(5), 'wallet:identity', 'World Team: wallet setup');
select is(pg_temp.level_next(8), 'none:-', 'an admin with no membership owes nothing');
select is(pg_temp.setup(3)->>'walletMembershipId',
  (select id::text from org.memberships where user_id = pg_temp.u(3) and office_id = pg_temp.id('T')),
  'the bank step uses the wallet membership');
select is(pg_temp.setup(1)->'walletMembershipId', 'null'::jsonb, 'none below the wallet level');
-- Founder 10 leads Team B: a wallet membership in an active network.
select is(pg_temp.level_next(10), 'wallet:identity', 'a founder who also leads an office owes the wallet setup');

-- ── The gate (6) ──
select is(api.security_state(pg_temp.u(3), pg_temp.s(3))->>'gate', 'profile_required', 'state: profile_required');
select is(api.security_state(pg_temp.u(3), pg_temp.s(3))->'setup', pg_temp.setup(3), 'state carries the setup');
select is(api.security_state(pg_temp.u(8), pg_temp.s(8))->>'gate', 'ready', 'nothing owed: ready');
select is(identity.session_gate(pg_temp.u(1), pg_temp.s(1)), 'profile_required', 'session_gate agrees');
select is(api.app_bootstrap(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3)) - 'state',
  jsonb_build_object('profile', null, 'workspace', null, 'capabilities', null, 'brand', null),
  'the bootstrap returns only the state at profile_required');
select is(api.app_bootstrap(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3))->'state'->>'gate', 'profile_required',
  'with the gate');

-- ── Refused with the step and level (5) ──
select is(pg_temp.err(format('select api.my_capabilities(%L, %L, %L)', pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3))),
  'profile_required {"step": "identity", "level": "wallet"}', 'a read refuses with the step');
select is(pg_temp.err(format('select api.home_view(%L, %L, %L)', pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1))),
  'profile_required {"step": "profile", "level": "light"}', 'President Team too');
select is(pg_temp.err(format('select api.start_network(%L, %L, %L, %L, %L)', pg_temp.u(7), pg_temp.s(7),
  'Kano Network', 'KAN', pg_temp.k())), 'profile_required {"step": "profile", "level": "light"}',
  'a founder names a network only after the light setup');
select is(pg_temp.err(format('select api.my_notification_count(%L, %L, %L)', pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3))),
  'profile_required {"step": "identity", "level": "wallet"}', 'the bell badge too');
select is(pg_temp.err(format('select api.admin_overview(%L, %L)', pg_temp.u(8), pg_temp.s(8))), 'no error',
  'admin reads are not member setup');

-- ── Calls that stay open (7) ──
select is(pg_temp.err(format('select api.my_profile(%L, %L)', pg_temp.u(3), pg_temp.s(3))), 'no error', 'my profile');
select is(pg_temp.err(format('select api.my_workspaces(%L, %L)', pg_temp.u(3), pg_temp.s(3))), 'no error',
  'my workspaces');
select is(pg_temp.err(format('select api.my_invitations(%L, %L)', pg_temp.u(3), pg_temp.s(3))), 'no error',
  'my invitations');
select is(pg_temp.err(format('select api.list_sessions(%L, %L)', pg_temp.u(3), pg_temp.s(3))), 'no error',
  'my devices');
select is(pg_temp.err(format('select api.list_banks(%L, %L)', pg_temp.u(3), pg_temp.s(3))), 'no error', 'the bank list');
select is(pg_temp.err(format('select api.list_payout_accounts(%L, %L, %L)', pg_temp.u(3), pg_temp.s(3),
  pg_temp.setup(3)->>'walletMembershipId')), 'no error', 'my payout accounts');
-- An exempt entry point stays exempt for what it calls, a gated one does not.
select is(pg_temp.err(format($q$
  do $d$ begin perform api.my_profile(%L, %L); perform api.my_capabilities(%L, %L, %L); end $d$ $q$,
  pg_temp.u(3), pg_temp.s(3), pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3))),
  'profile_required {"step": "identity", "level": "wallet"}', 'the entry point decides, not an earlier call');

-- ── The exempt list is exact (2) ──
select is(identity.setup_exempt_functions(), array[
    'my_profile', 'update_profile', 'set_profile_photo', 'prepare_nin_check', 'record_nin_check',
    'request_nin_review', 'list_banks', 'refresh_banks', 'prepare_account_lookup',
    'record_account_lookup', 'confirm_payout_account', 'list_payout_accounts', 'my_workspaces',
    'my_invitations',
    'list_sessions', 'revoke_sessions', 'change_pin', 'security_overview',
    'authorize_password_change', 'record_password_change', 'record_sign_in',
    'activate_tenant', 'set_account_status', 'grant_platform_admin', 'revoke_platform_admin',
    'outbox_dead_letters', 'outbox_requeue', 'platform_advance_restore'],
  'the exempt entry points');
select is((select count(*)::int from unnest(identity.setup_exempt_functions()) f
           where not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                             where n.nspname = 'api' and p.proname = f)), 0, 'each one exists');

-- ── Joining stays open (2) ──
select is(pg_temp.err(format('select api.accept_invitation(%L, %L, %L, null, %L)', pg_temp.u(12), pg_temp.s(12),
  pg_temp.dg('tok-12'), pg_temp.k())), 'no error', 'an invitation is accepted before the PIN');
do $$ begin perform api.set_pin(pg_temp.u(12), pg_temp.s(12), repeat('a', 64)); end $$;
select is(pg_temp.level_next(12), 'wallet:identity', 'and the new member owes the wallet setup');

-- ── A wallet member's steps, in order (7) ──
insert into identity.nin_records (user_id, nin_fingerprint, nin_last4, given_name, surname, phone, method, verified_at)
values (pg_temp.u(3), repeat('c', 64), '4321', 'Ada', 'Obi', null, 'provider', now());
select is(pg_temp.level_next(3), 'wallet:profile', 'after the NIN: the profile');
do $$ begin
  perform api.update_profile(pg_temp.u(3), pg_temp.s(3), '{"phone": "+2348030000003", "rank": "Distributor"}',
    pg_temp.k());
end $$;
select is(pg_temp.level_next(3), 'wallet:profile', 'a photo is required');
select pg_temp.photo(3);
select is(pg_temp.level_next(3), 'wallet:bank', 'then the bank account');
insert into payout.banks (provider, code, name, active) values ('paystack', '058', 'Guaranty Trust Bank', true);
do $$
declare
  lookup uuid;
  m uuid := (pg_temp.setup(3)->>'walletMembershipId')::uuid;
begin
  lookup := (api.prepare_account_lookup(pg_temp.u(3), pg_temp.s(3), m, '058',
    encode(extensions.gen_random_bytes(38), 'base64'), 1, repeat('d', 64), '6789', null, pg_temp.k())->>'lookupId')::uuid;
  perform api.record_account_lookup(pg_temp.u(3), pg_temp.s(3), m, lookup, 'resolved', 'ADA OBI');
  perform api.confirm_payout_account(pg_temp.u(3), pg_temp.s(3), m, lookup, null, pg_temp.k());
end $$;
select is(pg_temp.level_next(3), 'wallet:-', 'done');
select is(api.security_state(pg_temp.u(3), pg_temp.s(3))->>'gate', 'ready', 'ready');
select is(pg_temp.err(format('select api.my_capabilities(%L, %L, %L)', pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3))),
  'no error', 'and every call works');
select ok(api.app_bootstrap(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3))->'workspace' is not null,
  'the bootstrap opens the workspace');

-- ── The light setup: names, photo, rank (7) ──
select is(pg_temp.err(format($q$select api.update_profile(%L, %L, '{"firstName": " "}', %L)$q$,
  pg_temp.u(1), pg_temp.s(1), pg_temp.k())), 'validation_error {"field": "firstName"}', 'a blank first name');
select is(pg_temp.err(format($q$select api.update_profile(%L, %L, '{"lastName": 4}', %L)$q$,
  pg_temp.u(1), pg_temp.s(1), pg_temp.k())), 'validation_error {"field": "lastName"}', 'a last name must be text');
do $$ begin
  perform api.update_profile(pg_temp.u(1), pg_temp.s(1),
    '{"firstName": "Bola  Ade", "lastName": "Ige", "rank": "Diamond Director"}', pg_temp.k());
end $$;
select is((select first_name || '|' || last_name from identity.profiles where user_id = pg_temp.u(1)),
  'Bola Ade|Ige', 'names are saved, spaces tidied');
select is(pg_temp.level_next(1), 'light:profile', 'the photo is still owed');
select pg_temp.photo(1);
select is(pg_temp.level_next(1), 'light:-', 'light setup done: no NIN, phone or bank');
select is(pg_temp.err(format($q$select api.update_profile(%L, %L, '{"firstName": "Someone"}', %L)$q$,
  pg_temp.u(3), pg_temp.s(3), pg_temp.k())), 'conflict {"reason": "name_locked"}', 'a NIN name is locked');
select is(pg_temp.err(format('select api.home_view(%L, %L, %L)', pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1))),
  'no error', 'the President works once set up');

-- ── A paused network asks only for the light setup (3) ──
select is(pg_temp.level_next(11), 'wallet:identity', 'a member of an active network');
update org.tenants set status = 'suspended' where id = pg_temp.id('other');
select is(pg_temp.level_next(11), 'light:profile', 'paused: the bank step could not run, so light');
select is(pg_temp.level_next(10), 'light:profile', 'its founder too');

-- ── A restricted account cannot add a bank account, so is not asked (2) ──
insert into identity.nin_records (user_id, nin_fingerprint, nin_last4, given_name, surname, phone, method, verified_at)
values (pg_temp.u(2), repeat('e', 64), '2222', 'Tunde', 'Bello', '+2348030000002', 'provider', now());
update identity.profiles set rank = 'Manager', phone = '+2348030000002', phone_source = 'nin', photo_key = 'photos/' || user_id || '/' || gen_random_uuid() || '.png',
  photo_updated_at = now() where user_id = pg_temp.u(2);
select is(pg_temp.level_next(2), 'wallet:bank', 'an active account owes the bank step');
update identity.accounts set status = 'restricted' where user_id = pg_temp.u(2);
select is(pg_temp.level_next(2), 'wallet:-', 'a restricted one does not');

select * from finish();
rollback;
