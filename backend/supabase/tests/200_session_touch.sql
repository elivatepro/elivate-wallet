-- Blueprint 20 — B2 200: require_session writes last_activity_at at most once
-- every 30 seconds; the idle lock (15 minutes) and step-up (5 minutes, from
-- verified_at) behave as before. Each read below is a protected read
-- (api.list_sessions); now() is fixed inside the test transaction, so the
-- activity time is placed relative to it.
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(14);

create function pg_temp.u() returns uuid language sql immutable as
  $$ select '20000000-0000-0000-0000-0000000000a1'::uuid $$;
create function pg_temp.s() returns uuid language sql immutable as
  $$ select '20000000-0000-0000-0000-00000000a0a1'::uuid $$;
create function pg_temp.seen() returns timestamptz language sql stable as
  $$ select last_activity_at from identity.session_pin_proofs where session_id = pg_temp.s() $$;
create function pg_temp.idle(p_age interval) returns void language sql as $$
  update identity.session_pin_proofs set last_activity_at = now() - p_age where session_id = pg_temp.s()
$$;
create function pg_temp.read() returns jsonb language sql volatile as
  $$ select api.list_sessions(pg_temp.u(), pg_temp.s()) $$;

insert into auth.users (id, email, aud, role)
values (pg_temp.u(), 'touch@example.test', 'authenticated', 'authenticated');
insert into auth.sessions (id, user_id, created_at, updated_at) values (pg_temp.s(), pg_temp.u(), now(), now());
do $$ begin perform api.set_pin(pg_temp.u(), pg_temp.s(), repeat('a', 64)); end $$;

-- ── At most every 30 seconds (5) ──
do $$ begin perform pg_temp.idle('1 second'); end $$;
select lives_ok($$ select pg_temp.read() $$, 'a read 1 s after the last one works');
select is(pg_temp.seen(), now() - interval '1 second', 'and leaves the activity time unchanged');
select lives_ok($$ select pg_temp.read() $$, 'so does the next one');
select is(pg_temp.seen(), now() - interval '1 second', 'still unchanged');
do $$ begin perform pg_temp.idle('31 seconds'); end $$;
do $$ begin perform pg_temp.read(); end $$;
select is(pg_temp.seen(), now(), 'a read once it is 31 s old records the activity');

-- ── Exactly 30 seconds is not yet stale (1) ──
do $$ begin perform pg_temp.idle('30 seconds'); end $$;
do $$ begin perform pg_temp.read(); end $$;
select is(pg_temp.seen(), now() - interval '30 seconds', 'at exactly 30 s nothing is written');

-- ── Idle lock as before (3) ──
do $$ begin perform pg_temp.idle('14 minutes 50 seconds'); end $$;
do $$ begin perform pg_temp.read(); end $$;
select is(pg_temp.seen(), now(), 'activity within 15 minutes keeps the session open and is recorded');
do $$ begin perform pg_temp.idle('15 minutes 1 second'); end $$;
select throws_ok($$ select pg_temp.read() $$, 'P0001', 'pin_required', 'after 15 idle minutes the PIN is asked again');
select is(pg_temp.seen(), now() - interval '15 minutes 1 second', 'a refused read records nothing');

-- ── Step-up as before (4) ──
do $$ begin perform pg_temp.idle('0 seconds'); end $$;
update identity.session_pin_proofs set verified_at = now() - interval '4 minutes' where session_id = pg_temp.s();
select lives_ok($$ select identity.require_session(pg_temp.u(), pg_temp.s(), p_step_up => true) $$,
  'step-up passes within 5 minutes of the PIN');
update identity.session_pin_proofs set verified_at = now() - interval '6 minutes' where session_id = pg_temp.s();
select throws_ok($$ select identity.require_session(pg_temp.u(), pg_temp.s(), p_step_up => true) $$,
  'P0001', 'step_up_required', 'and is required again after 5 minutes');
select lives_ok($$ select pg_temp.read() $$, 'ordinary reads still work then');
select is((select verified_at from identity.session_pin_proofs where session_id = pg_temp.s()),
  now() - interval '6 minutes', 'the touch never moves verified_at');

-- ── Same failures (1) ──
select throws_ok($$ select api.list_sessions(pg_temp.u(), '20000000-0000-0000-0000-00000000ffff') $$,
  'P0001', 'authentication_required', 'an unknown session is still not authenticated');

select * from finish();
rollback;
