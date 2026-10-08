begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (id, email, aud, role)
values ('00000000-0000-0000-0000-0000000000c1', 'c1@example.test', 'authenticated', 'authenticated');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('00000000-0000-0000-0000-00000000c0a1', '00000000-0000-0000-0000-0000000000c1', now(), now()),
  ('00000000-0000-0000-0000-00000000c0a2', '00000000-0000-0000-0000-0000000000c1', now(), now()),
  ('00000000-0000-0000-0000-00000000c0a3', '00000000-0000-0000-0000-0000000000c1', now(), now());

select ok(api.set_pin('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000c0a1', repeat('a', 64)) is not null, 'PIN set');
select ok(
  (api.verify_pin('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000c0a2', repeat('a', 64))->>'ok')::boolean,
  'second device verified'
);

-- Session list and revocation.
select is(
  jsonb_array_length(api.list_sessions('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000c0a1')),
  3, 'all three sessions are listed'
);
select is(
  (api.revoke_sessions('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000c0a1',
    '00000000-0000-0000-0000-00000000c0a3', false)->>'revoked')::int,
  1, 'one session signed out'
);
select throws_ok(
  $$ select api.revoke_sessions('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000c0a1',
       '00000000-0000-0000-0000-00000000c0a3', false) $$,
  'P0001', 'not_found', 'already-revoked session is not found'
);
select throws_ok(
  $$ select api.security_state('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000c0a3') $$,
  'P0001', 'authentication_required', 'revoked session is no longer authenticated'
);

-- Reset needs a pending request.
insert into auth.sessions (id, user_id, created_at, updated_at)
values ('00000000-0000-0000-0000-00000000c0b1', '00000000-0000-0000-0000-0000000000c1', now(), now());
select throws_ok(
  $$ select api.complete_pin_reset('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000c0b1', repeat('d', 64)) $$,
  'P0001', 'conflict', 'no reset without a request'
);

select ok(
  api.request_pin_reset('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000c0a1') ? 'expiresAt',
  'reset requested'
);
select throws_ok(
  $$ select api.request_pin_reset('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000c0a1') $$,
  'P0001', 'rate_limited', 'a second request within 60 seconds is refused'
);

-- A password-only session cannot complete it.
insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
values (gen_random_uuid(), '00000000-0000-0000-0000-00000000c0a1', now(), now(), 'password');
select throws_ok(
  $$ select api.complete_pin_reset('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000c0a1', repeat('d', 64)) $$,
  'P0001', 'authorization_denied', 'password session cannot reset the PIN'
);

-- The emailed-link session can.
insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
values (gen_random_uuid(), '00000000-0000-0000-0000-00000000c0b1', now(), now(), 'otp');
select is(
  api.complete_pin_reset('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000c0b1', repeat('d', 64))->>'gate',
  'ready', 'email-link session sets the new PIN'
);
select is(
  (select array_agg(session_id::text) from identity.session_pin_proofs where user_id = '00000000-0000-0000-0000-0000000000c1'),
  array['00000000-0000-0000-0000-00000000c0b1'], 'every other PIN window was closed'
);
select is(
  api.verify_pin('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000c0a1', repeat('a', 64))->>'code',
  'pin_incorrect', 'old PIN no longer works'
);
select throws_ok(
  $$ select api.complete_pin_reset('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000c0b1', repeat('e', 64)) $$,
  'P0001', 'conflict', 'a reset cannot be used twice'
);

select * from finish();
rollback;
