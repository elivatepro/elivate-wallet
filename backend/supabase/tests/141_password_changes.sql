-- Blueprint 14 — signed-in password change (PIN only), reset record, A06 and
-- A08 with their bell items, the overview (B1, B2, B4).
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(33);

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-000000141001', 'pw1@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000141002', 'pw2@example.test', 'authenticated', 'authenticated');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('00000000-0000-0000-0000-0000001410a1', '00000000-0000-0000-0000-000000141001', now(), now()),
  ('00000000-0000-0000-0000-0000001410a2', '00000000-0000-0000-0000-000000141001', now(), now()),
  -- A Recovery-link session (email OTP), and an old one.
  ('00000000-0000-0000-0000-0000001410a3', '00000000-0000-0000-0000-000000141001', now(), now()),
  ('00000000-0000-0000-0000-0000001410a4', '00000000-0000-0000-0000-000000141001',
    now() - interval '2 hours', now() - interval '2 hours'),
  ('00000000-0000-0000-0000-0000001410b1', '00000000-0000-0000-0000-000000141002', now(), now());
insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method) values
  (gen_random_uuid(), '00000000-0000-0000-0000-0000001410a1', now(), now(), 'password'),
  (gen_random_uuid(), '00000000-0000-0000-0000-0000001410a3', now(), now(), 'otp'),
  (gen_random_uuid(), '00000000-0000-0000-0000-0000001410a4', now(), now(), 'otp');

create function pg_temp.authorize(p_session text, p_pin text) returns jsonb
language sql as $$
  select api.authorize_password_change('00000000-0000-0000-0000-000000141001', p_session::uuid, p_pin)
$$;
create function pg_temp.record(p_session text, p_change uuid, p_recovery boolean) returns jsonb
language sql as $$
  select api.record_password_change('00000000-0000-0000-0000-000000141001', p_session::uuid, p_change, p_recovery)
$$;

-- Needs a PIN and a PIN-ready session.
select throws_ok($$ select pg_temp.authorize('00000000-0000-0000-0000-0000001410a1', repeat('a', 64)) $$,
  'P0001', 'pin_setup_required', 'no PIN yet');
select is(api.set_pin('00000000-0000-0000-0000-000000141001', '00000000-0000-0000-0000-0000001410a1',
  repeat('a', 64))->>'gate', 'ready', 'PIN set on session 1');
select throws_ok($$ select pg_temp.authorize('00000000-0000-0000-0000-0000001410a2', repeat('a', 64)) $$,
  'P0001', 'pin_required', 'a session that owes its PIN cannot authorize');
select throws_ok($$ select pg_temp.authorize('00000000-0000-0000-0000-0000001410a1', '1234') $$,
  'P0001', 'validation_error', 'raw PIN refused');

-- Wrong PIN: the shared counter.
select is(pg_temp.authorize('00000000-0000-0000-0000-0000001410a1', repeat('b', 64)),
  '{"ok": false, "code": "pin_incorrect", "attemptsRemaining": 4}'::jsonb, 'wrong PIN counted');
select is((select failed_attempts::int from identity.pin_credentials
           where user_id = '00000000-0000-0000-0000-000000141001'), 1, 'the attempt is committed');
select is((select count(*)::int from identity.password_changes
           where user_id = '00000000-0000-0000-0000-000000141001'), 0, 'nothing authorized');

-- Right PIN.
create temp table grant1 as
  select (pg_temp.authorize('00000000-0000-0000-0000-0000001410a1', repeat('a', 64))->>'changeId')::uuid as id;
select isnt((select id from grant1), null, 'the right PIN authorizes a change');
select is((select failed_attempts::int from identity.pin_credentials
           where user_id = '00000000-0000-0000-0000-000000141001'), 0, 'attempts reset');
select ok(exists (select 1 from audit.security_events where action = 'password.change_authorized'
                  and actor_user_id = '00000000-0000-0000-0000-000000141001'), 'authorization audited');
select is((select count(*)::int from outbox.events where template = 'security.password_changed'), 0,
  'no email until the password is actually saved');

-- Recording: exactly one source.
select throws_ok($$ select pg_temp.record('00000000-0000-0000-0000-0000001410a1', null, null) $$,
  'P0001', 'validation_error', 'needs a change or a recovery');
select throws_ok($$ select pg_temp.record('00000000-0000-0000-0000-0000001410a1', (select id from grant1), true) $$,
  'P0001', 'validation_error', 'not both');
select throws_ok($$ select pg_temp.record('00000000-0000-0000-0000-0000001410a2', (select id from grant1), null) $$,
  'P0001', 'conflict', 'another session cannot use the authorization');
select throws_ok($$ select pg_temp.record('00000000-0000-0000-0000-0000001410a1', gen_random_uuid(), null) $$,
  'P0001', 'conflict', 'an unknown change is not authorized');
select ok(pg_temp.record('00000000-0000-0000-0000-0000001410a1', (select id from grant1), null) ? 'changedAt',
  'the change is recorded');
select throws_ok($$ select pg_temp.record('00000000-0000-0000-0000-0000001410a1', (select id from grant1), null) $$,
  'P0001', 'conflict', 'and only once');

-- A06 + bell.
select is((select count(*)::int from outbox.events where template = 'security.password_changed'
           and recipient_user_id = '00000000-0000-0000-0000-000000141001'), 1, 'A06 queued');
select is((select params->>'path' from outbox.events where template = 'security.password_changed'),
  '/app/account', 'A06 opens Profile & security');
select ok((select params->>'at' from outbox.events where template = 'security.password_changed')
  ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$', 'A06 carries the UTC time');
select is((select count(*)::int from notify.items where kind = 'security.password_changed'
           and user_id = '00000000-0000-0000-0000-000000141001' and tenant_id is null), 1, 'personal bell item');

-- An authorization expires.
create temp table grant2 as
  select (pg_temp.authorize('00000000-0000-0000-0000-0000001410a1', repeat('a', 64))->>'changeId')::uuid as id;
alter table identity.password_changes disable trigger password_changes_guard;
update identity.password_changes set authorized_at = now() - interval '11 minutes' where id = (select id from grant2);
alter table identity.password_changes enable trigger password_changes_guard;
select throws_ok($$ select pg_temp.record('00000000-0000-0000-0000-0000001410a1', (select id from grant2), null) $$,
  'P0001', 'conflict', 'an authorization older than 10 minutes is refused');

-- Recovery: a fresh email-link session, once.
select throws_ok($$ select pg_temp.record('00000000-0000-0000-0000-0000001410a1', null, true) $$,
  'P0001', 'conflict', 'a password session is not a recovery session');
select throws_ok($$ select pg_temp.record('00000000-0000-0000-0000-0000001410a4', null, true) $$,
  'P0001', 'conflict', 'an old email-link session is refused');
select ok(pg_temp.record('00000000-0000-0000-0000-0000001410a3', null, true) ? 'changedAt',
  'the reset is recorded from the Recovery session (before the PIN)');
select throws_ok($$ select pg_temp.record('00000000-0000-0000-0000-0000001410a3', null, true) $$,
  'P0001', 'conflict', 'a reset is recorded once');
select is((select count(*)::int from outbox.events where template = 'security.password_changed'), 2,
  'A06 for the reset too');

-- Overview.
select ok((api.security_overview('00000000-0000-0000-0000-000000141001', '00000000-0000-0000-0000-0000001410a1')
  ->>'passwordChangedAt') is not null, 'the overview shows when the password changed');

-- A08 on a PIN change.
select is(api.change_pin('00000000-0000-0000-0000-000000141001', '00000000-0000-0000-0000-0000001410a1',
  repeat('a', 64), repeat('c', 64))->>'ok', 'true', 'PIN changed');
select is((select count(*)::int from outbox.events where template = 'security.pin_changed'
           and recipient_user_id = '00000000-0000-0000-0000-000000141001'), 1, 'A08 queued');
select is((select count(*)::int from notify.items where kind = 'security.pin_changed'
           and user_id = '00000000-0000-0000-0000-000000141001'), 1, 'A08 bell item');
select is((select count(*)::int from outbox.events
           where template in ('security.pin_changed', 'security.password_changed')
             and params::text ~ 'aaaa|cccc'), 0, 'no PIN material in any email');

select ok(not has_function_privilege('authenticated',
  'api.authorize_password_change(uuid, uuid, text, text)', 'execute'), 'service role only');

select * from finish();
rollback;
