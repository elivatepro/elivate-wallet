-- Blueprint 03 — B6 test 12: outbox enqueue, claim, complete/fail, backoff,
-- dead letters, lease expiry, relevance, requeue and the cron schedule.
begin;
create extension if not exists pgtap with schema extensions;
select plan(44);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.k() returns text language sql volatile as
  $$ select 'k' || md5(random()::text || clock_timestamp()::text) $$;
create temp table ids (name text primary key, id uuid not null);
create function pg_temp.id(p_name text) returns uuid language sql stable as
  $$ select id from ids where name = p_name $$;
create function pg_temp.d(p_name text) returns outbox.deliveries language sql stable as
  $$ select * from outbox.deliveries where event_id = pg_temp.id(p_name) $$;
-- Makes every waiting delivery due now.
create function pg_temp.due() returns void language sql as
  $$ update outbox.deliveries set next_attempt_at = now() - interval '1 second' where status in ('pending', 'retry_scheduled') $$;
create function pg_temp.claim() returns jsonb language sql volatile as
  $$ select api.outbox_claim('test-worker', 25, 60) $$;

-- Test-only templates (inserted inside this rolled-back transaction).
insert into outbox.templates (key, version, duplicate_safe, params) values
  ('test.safe', 1, true, array['name']),
  ('test.unsafe', 1, false, array['name']);

insert into auth.users (id, email, aud, role, email_confirmed_at)
select pg_temp.u(n), 'U' || n || '@Example.test', 'authenticated', 'authenticated', now() from generate_series(1, 2) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 2) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 2) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(1), 'Test admin');

-- ── Enqueue ──
select throws_ok(
  $$ select outbox.enqueue_email('nope.template', 'x', 'test', gen_random_uuid(), null, null, 'a@example.test', '{}') $$,
  'P0001', 'invariant_violation', 'unknown templates are rejected'
);
select throws_ok(
  $$ select outbox.enqueue_email('test.safe', 'x', 'test', gen_random_uuid(), null, null, 'a@example.test', '{"pin": "1234"}') $$,
  'P0001', 'invariant_violation', 'params not named by the template are rejected'
);
select throws_ok(
  $$ select outbox.enqueue_email('test.safe', 'x', 'test', gen_random_uuid(), null, null, 'a@example.test', '{"name": {"a": 1}}') $$,
  'P0001', 'invariant_violation', 'params must be plain display values'
);
select throws_ok(
  $$ select outbox.enqueue_email('test.safe', 'x', 'test', gen_random_uuid(), null, pg_temp.u(1), 'a@example.test', '{}') $$,
  '23514', null, 'exactly one recipient kind'
);
insert into ids select 'safe', outbox.enqueue_email('test.safe', 'safe:1', 'test', gen_random_uuid(), null, null, 'A@Example.test', '{"name": "Ada"}');
select is(outbox.enqueue_email('test.safe', 'safe:1', 'test', gen_random_uuid(), null, null, 'a@example.test', '{"name": "Ada"}'),
  pg_temp.id('safe'), 'the same dedupe key returns the existing event');
select is((select count(*)::int from outbox.events), 1, 'and creates nothing new');
select is((pg_temp.d('safe')).status::text, 'pending', 'a delivery row is created with the event');
select throws_ok($$ update outbox.events set params = '{}' $$, 'P0001', 'invariant_violation', 'events are immutable');
select throws_ok($$ delete from outbox.events $$, 'P0001', 'invariant_violation', 'events cannot be deleted');
select throws_ok($$ update outbox.templates set duplicate_safe = false $$, 'P0001', 'invariant_violation', 'templates are immutable');

-- ── Claim and complete ──
create temp table c1 as select pg_temp.claim() as res;
select is(jsonb_array_length((select res from c1)), 1, 'claim returns due deliveries');
select is((select res->0->>'to' from c1), 'a@example.test', 'with the recipient address');
select is((select res->0->>'attempt' from c1), '1', 'and the attempt number');
select is((pg_temp.d('safe')).status::text, 'processing', 'the delivery is leased');
select is(jsonb_array_length(pg_temp.claim()), 0, 'a leased delivery is not claimed twice');
select is(api.outbox_complete(pg_temp.id('safe'), gen_random_uuid(), 'm-1', 200, 5)->>'reason', 'stale_lease', 'a wrong lease cannot complete');
select is(api.outbox_complete(pg_temp.id('safe'), (select (res->0->>'leaseToken')::uuid from c1), '<m-1@cf>', 200, 5)->>'status', 'sent', 'the right lease completes');
select is(api.outbox_complete(pg_temp.id('safe'), (select (res->0->>'leaseToken')::uuid from c1), '<m-1@cf>', 200, 5)->>'reason', 'already_recorded', 'completion is idempotent per lease');
select is((select count(*)::int from outbox.attempts where event_id = pg_temp.id('safe')), 1, 'one attempt recorded');
select is((pg_temp.d('safe')).provider_message_id, '<m-1@cf>', 'provider message id stored');

-- ── Backoff and dead letter (exact schedule) ──
select is(array[outbox.retry_delay(1), outbox.retry_delay(2), outbox.retry_delay(8), outbox.retry_delay(9)],
  array[interval '15 seconds', interval '30 seconds', interval '1920 seconds', interval '3600 seconds'], 'backoff doubles from 15 s, capped at 1 hour');
insert into ids select 'retry', outbox.enqueue_email('test.safe', 'retry:1', 'test', gen_random_uuid(), null, pg_temp.u(2), null, '{"name": "Bo"}');
create temp table c2 as select pg_temp.claim() as res;
select is((select res->0->>'to' from c2), 'u2@example.test', 'user recipients resolve to their current Auth email');
select is(api.outbox_fail(pg_temp.id('retry'), (select (res->0->>'leaseToken')::uuid from c2), 'retryable_failure', 'provider.rate_limited', 429, 10)->>'status',
  'retry_scheduled', 'a retryable failure is rescheduled');
select is((pg_temp.d('retry')).next_attempt_at, now() + interval '15 seconds', 'after 15 seconds');
select is(jsonb_array_length(pg_temp.claim()), 0, 'not before it is due');
do $$
declare
  lease uuid;
begin
  for i in 2..8 loop
    perform pg_temp.due();
    lease := (pg_temp.claim()->0->>'leaseToken')::uuid;
    perform api.outbox_fail(pg_temp.id('retry'), lease, 'retryable_failure', 'provider.unavailable', 503, 10);
  end loop;
end $$;
select is((pg_temp.d('retry')).status::text, 'dead_lettered', 'dead-lettered after 8 attempts');
select is((select count(*)::int from outbox.attempts where event_id = pg_temp.id('retry')), 8, 'every attempt is kept');

insert into ids select 'perm', outbox.enqueue_email('test.safe', 'perm:1', 'test', gen_random_uuid(), null, null, 'p@example.test', '{}');
select is(api.outbox_fail(pg_temp.id('perm'), (pg_temp.claim()->0->>'leaseToken')::uuid, 'permanent_failure', 'provider.rejected', 400, 10)->>'status',
  'dead_lettered', 'a permanent failure dead-letters at once');

-- outcome_unknown: retried only for duplicate-safe templates.
insert into ids select 'unknown_safe', outbox.enqueue_email('test.safe', 'us:1', 'test', gen_random_uuid(), null, null, 'q@example.test', '{}');
select is(api.outbox_fail(pg_temp.id('unknown_safe'), (pg_temp.claim()->0->>'leaseToken')::uuid, 'outcome_unknown', 'provider.timeout', null, 10)->>'status',
  'retry_scheduled', 'unknown outcome is retried for a duplicate-safe template');
insert into ids select 'unknown_unsafe', outbox.enqueue_email('test.unsafe', 'uu:1', 'test', gen_random_uuid(), null, null, 'r@example.test', '{}');
select is(api.outbox_fail(pg_temp.id('unknown_unsafe'), (pg_temp.claim()->0->>'leaseToken')::uuid, 'outcome_unknown', 'provider.timeout', null, 10)->>'status',
  'dead_lettered', 'unknown outcome dead-letters otherwise');

-- ── Lease expiry ──
update outbox.deliveries set status = 'dead_lettered', dead_lettered_at = now(), next_attempt_at = null
where event_id = pg_temp.id('unknown_safe');
insert into ids select 'lease', outbox.enqueue_email('test.safe', 'lease:1', 'test', gen_random_uuid(), null, null, 's@example.test', '{}');
create temp table c3 as select pg_temp.claim() as res;
update outbox.deliveries set lease_expires_at = now() - interval '1 second' where event_id = pg_temp.id('lease');
create temp table c4 as select pg_temp.claim() as res;
select is((select res->0->>'attempt' from c4), '2', 'an expired lease is recovered and claimed again');
select is((select outcome::text from outbox.attempts where lease_token = (select (res->0->>'leaseToken')::uuid from c3)), 'lease_expired', 'the lost attempt is recorded');
select is(api.outbox_fail(pg_temp.id('lease'), (select (res->0->>'leaseToken')::uuid from c3), 'retryable_failure', 'late', null, 1)->>'reason',
  'already_recorded', 'the old lease can no longer report');

-- ── Relevance: invitation emails for dead links are skipped ──
-- (covered with real invitations in 030; here: an unrelated template passes)
select ok(outbox.is_relevant((select e from outbox.events e where id = pg_temp.id('lease'))), 'other templates are always relevant');

-- ── Admin dead letters and requeue ──
select ok(
  not exists (select 1 from jsonb_array_elements(api.outbox_dead_letters(pg_temp.u(1), pg_temp.s(1))) x where x ? 'to' or x ? 'recipient'),
  'dead-letter list carries no addresses'
);
select throws_ok($$ select api.outbox_dead_letters(pg_temp.u(2), pg_temp.s(2)) $$, 'P0001', 'authorization_denied', 'only platform admins see dead letters');
select throws_ok(
  $$ select api.outbox_requeue(pg_temp.u(2), pg_temp.s(2), pg_temp.id('perm'), 'Fixed sender', pg_temp.k()) $$,
  'P0001', 'authorization_denied', 'only platform admins requeue'
);
select throws_ok(
  $$ select api.outbox_requeue(pg_temp.u(1), pg_temp.s(1), pg_temp.id('perm'), '', pg_temp.k()) $$,
  'P0001', 'validation_error', 'requeue needs a reason'
);
update identity.session_pin_proofs set verified_at = now() - interval '10 minutes' where user_id = pg_temp.u(1);
select throws_ok(
  $$ select api.outbox_requeue(pg_temp.u(1), pg_temp.s(1), pg_temp.id('perm'), 'Fixed sender', pg_temp.k()) $$,
  'P0001', 'step_up_required', 'requeue needs a fresh PIN'
);
update identity.session_pin_proofs set verified_at = now() where user_id = pg_temp.u(1);
select is(api.outbox_requeue(pg_temp.u(1), pg_temp.s(1), pg_temp.id('perm'), 'Fixed sender', pg_temp.k())->>'cycle', '2',
  'requeue opens a new delivery cycle');
select is((pg_temp.d('perm')).status::text, 'pending', 'and the email waits again');
select throws_ok(
  $$ select api.outbox_requeue(pg_temp.u(1), pg_temp.s(1), pg_temp.id('perm'), 'Again', pg_temp.k()) $$,
  'P0001', 'conflict', 'only dead-lettered emails can be requeued'
);

-- ── Schedule ──
select is(outbox.trigger_worker(), null::bigint, 'without Vault entries the scheduled call does nothing');
select is((select schedule from cron.job where jobname = 'outbox-worker'), '* * * * *', 'the worker is scheduled every minute');

select * from finish();
rollback;
