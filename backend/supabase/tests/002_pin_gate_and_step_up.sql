begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(19);

insert into auth.users (id, email, aud, role)
values ('00000000-0000-0000-0000-0000000000b1', 'b1@example.test', 'authenticated', 'authenticated');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('00000000-0000-0000-0000-00000000b0a1', '00000000-0000-0000-0000-0000000000b1', now(), now()),
  ('00000000-0000-0000-0000-00000000b0a2', '00000000-0000-0000-0000-0000000000b1', now(), now());

-- Stand-ins for HMAC hex values computed by the Edge Function.
create temp table pins as select repeat('a', 64) as good, repeat('b', 64) as bad;
grant select on pins to service_role;

select throws_ok(
  $$ select api.security_state('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000ffff') $$,
  'P0001', 'authentication_required', 'unknown session is not authenticated'
);
select is(
  api.security_state('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000b0a1')->>'gate',
  'pin_setup_required', 'no PIN yet'
);
select throws_ok(
  $$ select api.list_sessions('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000b0a1') $$,
  'P0001', 'pin_setup_required', 'protected reads wait for PIN setup'
);
select throws_ok(
  $$ select api.set_pin('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000b0a1', '1234') $$,
  'P0001', 'validation_error', 'raw PINs are rejected; only HMAC hex is accepted'
);
select is(
  api.set_pin('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000b0a1', (select good from pins))->>'gate',
  'ready', 'setting the PIN opens this session'
);
select ok(
  (select pin_hash <> (select good from pins) and pin_hash like '$2%' from identity.pin_credentials
   where user_id = '00000000-0000-0000-0000-0000000000b1'),
  'PIN is stored as bcrypt'
);
select throws_ok(
  $$ select api.set_pin('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000b0a1', repeat('c', 64)) $$,
  'P0001', 'conflict', 'PIN cannot be set twice'
);
select is(
  api.security_state('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000b0a2')->>'gate',
  'pin_required', 'another session of the same user still needs the PIN'
);

-- Idle timeout.
update identity.session_pin_proofs set last_activity_at = now() - interval '16 minutes'
where session_id = '00000000-0000-0000-0000-00000000b0a1';
select is(
  api.security_state('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000b0a1')->>'gate',
  'pin_required', 'PIN is asked again after 15 minutes of inactivity'
);

-- Wrong PIN four times, then right.
select is(
  (select api.verify_pin('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000b0a1', (select bad from pins))->>'attemptsRemaining'),
  '4', 'first wrong PIN leaves 4 attempts'
);
do $$ begin
  for i in 1..3 loop
    perform api.verify_pin('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000b0a1', repeat('b', 64));
  end loop;
end $$;
select is(
  (select failed_attempts::int from identity.pin_credentials where user_id = '00000000-0000-0000-0000-0000000000b1'),
  4, 'wrong attempts are counted'
);
select is(
  api.verify_pin('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000b0a1', (select good from pins))->>'ok',
  'true', 'correct PIN succeeds'
);
select is(
  (select failed_attempts::int from identity.pin_credentials where user_id = '00000000-0000-0000-0000-0000000000b1'),
  0, 'success resets the attempt count'
);

-- Step-up window: anchored to the PIN proof, not extended by activity.
select lives_ok(
  $$ select identity.require_session('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000b0a1', true) $$,
  'step-up passes right after the PIN'
);
update identity.session_pin_proofs set verified_at = now() - interval '4 minutes 59 seconds'
where session_id = '00000000-0000-0000-0000-00000000b0a1';
select lives_ok(
  $$ select identity.require_session('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000b0a1', true) $$,
  'step-up still valid at 4:59'
);
update identity.session_pin_proofs set verified_at = now() - interval '5 minutes 1 second'
where session_id = '00000000-0000-0000-0000-00000000b0a1';
select throws_ok(
  $$ select identity.require_session('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000b0a1', true) $$,
  'P0001', 'step_up_required', 'step-up expires after 5 minutes even with recent activity'
);

-- Lock after 5 wrong attempts.
do $$ begin
  for i in 1..4 loop
    perform api.verify_pin('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000b0a1', repeat('b', 64));
  end loop;
end $$;
select is(
  api.verify_pin('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000b0a1', (select bad from pins))->>'code',
  'pin_locked', 'fifth wrong PIN locks'
);
select throws_ok(
  $$ select api.verify_pin('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000b0a1', (select good from pins)) $$,
  'P0001', 'pin_locked', 'even the correct PIN is refused while locked'
);
select is(
  api.security_state('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000b0a1')->>'gate',
  'pin_locked', 'gate shows the lock'
);

select * from finish();
rollback;
