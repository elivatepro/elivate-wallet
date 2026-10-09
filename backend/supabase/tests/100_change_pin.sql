-- Blueprint 10 — change PIN (B7 items 1–6).
begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

insert into auth.users (id, email, aud, role)
values ('00000000-0000-0000-0000-000000010001', 'cp1@example.test', 'authenticated', 'authenticated');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('00000000-0000-0000-0000-0000000100a1', '00000000-0000-0000-0000-000000010001', now(), now()),
  ('00000000-0000-0000-0000-0000000100a2', '00000000-0000-0000-0000-000000010001', now(), now());

-- Stand-ins for HMAC hex values computed by the Edge Function.
create temp table pins as
  select repeat('a', 64) as old_pin, repeat('c', 64) as new_pin, repeat('b', 64) as wrong;
grant select on pins to service_role;

create function pg_temp.change(p_session text, p_current text, p_new text) returns jsonb
language sql as $$
  select api.change_pin('00000000-0000-0000-0000-000000010001', p_session::uuid, p_current, p_new)
$$;

-- Needs a PIN first, then a PIN-ready session.
select throws_ok(
  $$ select pg_temp.change('00000000-0000-0000-0000-0000000100a1', repeat('a', 64), repeat('c', 64)) $$,
  'P0001', 'pin_setup_required', 'no PIN yet: nothing to change'
);
select is(
  api.set_pin('00000000-0000-0000-0000-000000010001', '00000000-0000-0000-0000-0000000100a1',
    (select old_pin from pins))->>'gate',
  'ready', 'PIN set on session 1'
);
select is(
  api.verify_pin('00000000-0000-0000-0000-000000010001', '00000000-0000-0000-0000-0000000100a2',
    (select old_pin from pins))->>'ok',
  'true', 'session 2 unlocked too'
);
select throws_ok(
  $$ select pg_temp.change('00000000-0000-0000-0000-0000000100a1', '1234', repeat('c', 64)) $$,
  'P0001', 'validation_error', 'raw current PIN rejected'
);
select throws_ok(
  $$ select pg_temp.change('00000000-0000-0000-0000-0000000100a1', repeat('a', 64), 'nope') $$,
  'P0001', 'validation_error', 'raw new PIN rejected'
);
select throws_ok(
  $$ select pg_temp.change('00000000-0000-0000-0000-0000000100a1', repeat('a', 64), repeat('a', 64)) $$,
  'P0001', 'validation_error', 'the new PIN must differ from the current one'
);

-- Wrong current PIN counts against the same 5 attempts as verify_pin.
select is(
  pg_temp.change('00000000-0000-0000-0000-0000000100a1', (select wrong from pins), (select new_pin from pins)),
  '{"ok": false, "code": "pin_incorrect", "attemptsRemaining": 4}'::jsonb,
  'wrong current PIN is pin_incorrect with attempts left'
);
select is(
  (select failed_attempts::int from identity.pin_credentials where user_id = '00000000-0000-0000-0000-000000010001'),
  1, 'the wrong attempt is counted and committed'
);
select ok(
  exists (select 1 from audit.security_events
          where actor_user_id = '00000000-0000-0000-0000-000000010001' and action = 'pin.rejected'),
  'wrong attempt is audited'
);

-- Correct change.
select is(
  pg_temp.change('00000000-0000-0000-0000-0000000100a1', (select old_pin from pins), (select new_pin from pins))->'state'->>'gate',
  'ready', 'change succeeds and this session stays ready'
);
select is(
  (select failed_attempts::int from identity.pin_credentials where user_id = '00000000-0000-0000-0000-000000010001'),
  0, 'attempts reset after the change'
);
select is(
  api.security_state('00000000-0000-0000-0000-000000010001', '00000000-0000-0000-0000-0000000100a2')->>'gate',
  'pin_required', 'the other session must enter the PIN again'
);
select ok(
  (select verified_at > now() - interval '1 second' from identity.session_pin_proofs
   where session_id = '00000000-0000-0000-0000-0000000100a1'),
  'this session gets a fresh step-up window'
);
select is(
  api.verify_pin('00000000-0000-0000-0000-000000010001', '00000000-0000-0000-0000-0000000100a2',
    (select old_pin from pins))->>'code',
  'pin_incorrect', 'the old PIN no longer works'
);
select is(
  api.verify_pin('00000000-0000-0000-0000-000000010001', '00000000-0000-0000-0000-0000000100a2',
    (select new_pin from pins))->>'ok',
  'true', 'the new PIN works'
);
select ok(
  exists (select 1 from audit.security_events
          where actor_user_id = '00000000-0000-0000-0000-000000010001' and action = 'pin.changed'
            and safe_after is null and reason is null),
  'change is audited without any PIN material'
);

-- Five wrong current PINs lock, exactly like verify_pin.
do $$ begin
  for i in 1..4 loop
    perform pg_temp.change('00000000-0000-0000-0000-0000000100a1', repeat('b', 64), repeat('d', 64));
  end loop;
end $$;
select is(
  pg_temp.change('00000000-0000-0000-0000-0000000100a1', (select wrong from pins), (select old_pin from pins))->>'code',
  'pin_locked', 'fifth wrong current PIN locks'
);
select is(
  (select count(*)::int from identity.session_pin_proofs where user_id = '00000000-0000-0000-0000-000000010001'),
  0, 'locking closes every PIN window'
);
select throws_ok(
  $$ select pg_temp.change('00000000-0000-0000-0000-0000000100a1', repeat('c', 64), repeat('d', 64)) $$,
  'P0001', 'pin_locked', 'a locked PIN cannot be changed, even with the right current PIN'
);

-- Privileges: service_role only, definer only in api.
select ok(
  not has_function_privilege('authenticated', 'api.change_pin(uuid, uuid, text, text, text)', 'execute')
  and not has_function_privilege('anon', 'api.change_pin(uuid, uuid, text, text, text)', 'execute')
  and not has_function_privilege('authenticated', 'identity.record_wrong_pin(uuid, uuid, smallint, text)', 'execute')
  and has_function_privilege('service_role', 'api.change_pin(uuid, uuid, text, text, text)', 'execute'),
  'only service_role may call change_pin'
);

select * from finish();
rollback;
