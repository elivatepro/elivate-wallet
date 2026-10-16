-- Blueprint 42 — 420: push notifications. Which kinds push, this device's
-- switch (allow-listed push services only, one person per device, one
-- subscription per session), a job per Q1 item written with it, the worker's
-- claim (done tasks, inactive accounts and no device are skipped) and report
-- (sent, gone, retried, stale), sign-out and retention cascades, privileges.
begin;
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(43);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.uid(n int) returns text language sql stable as
  $$ select uid from identity.accounts where user_id = pg_temp.u(n) $$;
create function pg_temp.k() returns text language sql volatile as
  $$ select 'k' || md5(random()::text || clock_timestamp()::text) $$;
create temp table ids (name text primary key, id uuid not null);
create function pg_temp.id(p_name text) returns uuid language sql stable as
  $$ select id from ids where name = p_name $$;
create function pg_temp.m(n int, p_office uuid default null) returns uuid language sql stable as $$
  select id from org.memberships
  where user_id = pg_temp.u(n) and status = 'active' and office_id is not distinct from p_office
  order by started_at desc, id limit 1
$$;
create function pg_temp.ws(n int) returns uuid language sql stable as $$
  select id from org.memberships where user_id = pg_temp.u(n) and status = 'active'
  order by (role = 'member'), started_at limit 1
$$;
create function pg_temp.ct() returns text language sql volatile as
  $$ select encode(extensions.gen_random_bytes(38), 'base64') $$;
create function pg_temp.add_account(n int, p_bank text, p_number text, p_name text) returns uuid
language plpgsql volatile as $$
declare
  lookup uuid;
begin
  lookup := (api.prepare_account_lookup(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_bank, pg_temp.ct(), 1,
    encode(extensions.digest(p_bank || ':' || p_number, 'sha256'), 'hex'), right(p_number, 4), null,
    pg_temp.k())->>'lookupId')::uuid;
  perform api.record_account_lookup(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), lookup, 'resolved', p_name);
  return (api.confirm_payout_account(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), lookup, null, pg_temp.k())
    ->'payoutAccount'->>'payoutAccountId')::uuid;
end $$;
create function pg_temp.income_receipt(n int, p_target uuid, p_key text) returns uuid language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_target, p_key, 'r.pdf',
    'application/pdf', 1000, repeat('b', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 1000, repeat('b', 64),
    'application/pdf');
  return e;
end $$;
create function pg_temp.seg(n int) returns uuid language sql stable as $$
  select b.account_id from ledger.balances b join ledger.pockets p on p.id = b.pocket_id
  where b.owner_user_id = pg_temp.u(n) and p.name = 'Point Value' and b.currency = 'NGN'
$$;
-- The error code and details (field or reason) a statement fails with.
create function pg_temp.fails(p_sql text) returns text language plpgsql as $$
declare
  msg text;
  detail text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics msg = message_text, detail = pg_exception_detail;
  return msg || ':' || coalesce(detail::jsonb->>'field', detail::jsonb->>'reason', '');
end $$;
-- Synthetic browser keys: an uncompressed point marker plus filler.
create function pg_temp.p256dh(c text) returns text language sql immutable as $$ select 'B' || repeat(c, 86) $$;
create function pg_temp.auth(c text) returns text language sql immutable as $$ select repeat(c, 22) $$;
create function pg_temp.sub(n int, p_endpoint text, p_hide boolean default false) returns jsonb
language sql volatile as $$
  select api.push_subscribe(pg_temp.u(n), pg_temp.s(n), p_endpoint, pg_temp.p256dh('A'), pg_temp.auth('Q'), p_hide)
$$;
create function pg_temp.job(p_user int, p_kind text) returns notify.push_jobs language sql stable as $$
  select j.* from notify.push_jobs j join notify.items i on i.id = j.item_id
  where i.user_id = pg_temp.u(p_user) and i.kind = p_kind order by i.created_at desc limit 1
$$;

-- 1 President · 3 TL (T) · 4 member (T) · 5 member, second device of 4's · 9 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from unnest(array[1, 3, 4, 9]) n;
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from unnest(array[1, 3, 4, 9]) n;
insert into auth.sessions (id, user_id, created_at, updated_at) values (pg_temp.s(5), pg_temp.u(4), now(), now());
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from unnest(array[1, 3, 4, 9]) n; end $$;
insert into identity.session_pin_proofs (session_id, user_id, verified_at, last_activity_at)
select pg_temp.s(5), pg_temp.u(4), now(), now();
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(9), 'Test admin');
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('tenant'), 'Pilot', pg_temp.k());
end $$;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', null,
  array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(4), pg_temp.k());
end $$;
insert into payout.banks (provider, code, name, active) values ('paystack', '058', 'Guaranty Trust Bank', true);
insert into ids select 'A4', pg_temp.add_account(4, '058', '0123456789', 'ADA OBI');

-- ── Which kinds push (3) ──
select is((select count(*)::int from notify.push_kinds),
  (select count(*)::int from notify.kinds where task) + 5, 'every task kind plus five money kinds push (Blueprint 44)');
select ok(not exists (select 1 from notify.push_kinds where key in ('money.withdrawal_cancelled',
  'team.invitation_accepted', 'security.new_sign_in')), 'other kinds never push');
select throws_ok($$ delete from notify.push_kinds where key = 'task.nin_review' $$, 'P0001', 'invariant_violation',
  'the push kinds never change');

-- ── This device's switch (11) ──
select is(pg_temp.sub(4, 'https://fcm.googleapis.com/fcm/send/dev-4a'), '{"on": true, "hideAmounts": false}'::jsonb,
  'a member turns push on for this device');
select is(pg_temp.fails($$ select pg_temp.sub(4, 'https://evil.example.com/push') $$), 'conflict:push_host_not_allowed',
  'a host that is not a push service is refused');
select is(pg_temp.fails($$ select pg_temp.sub(4, 'https://fcm.googleapis.com.evil.example/x') $$),
  'conflict:push_host_not_allowed', 'a look-alike host is refused');
select is(pg_temp.fails($$ select pg_temp.sub(4, 'http://fcm.googleapis.com/fcm/send/x') $$),
  'validation_error:endpoint', 'plain http is refused');
select is(pg_temp.fails($$ select api.push_subscribe(pg_temp.u(4), pg_temp.s(4),
  'https://fcm.googleapis.com/fcm/send/x', 'Bshort', pg_temp.auth('Q'), false) $$), 'validation_error:p256dh',
  'a malformed key is refused');
select is(pg_temp.fails($$ select pg_temp.sub(4, 'https://web.push.apple.com/QK') $$), 'no error',
  'Apple''s push service is allowed (and replaces this session''s earlier one)');
select is((select count(*)::int from notify.push_subscriptions where session_id = pg_temp.s(4)), 1,
  'a session keeps one subscription');
select is((select endpoint from notify.push_subscriptions where session_id = pg_temp.s(4)), 'https://web.push.apple.com/QK',
  'the newest endpoint');
select is(api.push_subscription_state(pg_temp.u(4), pg_temp.s(4), 'https://web.push.apple.com/QK')->>'on', 'true',
  'the switch reads on for this endpoint');
select is(pg_temp.sub(1, 'https://web.push.apple.com/QK', true)->>'hideAmounts', 'true',
  'someone else signing in on the same device takes the endpoint');
select is((select user_id from notify.push_subscriptions where endpoint = 'https://web.push.apple.com/QK'), pg_temp.u(1),
  'one person per device');
do $$ begin
  perform api.push_unsubscribe(pg_temp.u(1), pg_temp.s(1), 'https://web.push.apple.com/QK');
  perform pg_temp.sub(4, 'https://fcm.googleapis.com/fcm/send/dev-4a');
  perform api.push_subscribe(pg_temp.u(4), pg_temp.s(5), 'https://updates.push.services.mozilla.com/wpush/v2/dev-4b',
    pg_temp.p256dh('C'), pg_temp.auth('D'), true);
  perform pg_temp.sub(3, 'https://wns2-par02p.notify.windows.com/w/?token=abc');
end $$;

-- ── A job per Q1 item, in the same transaction (6) ──
do $$ begin
  perform api.record_income(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(4, pg_temp.id('T')), 'NGN', '250000.00',
    'Fiverr', to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null,
    array[pg_temp.income_receipt(1, pg_temp.m(4, pg_temp.id('T')), 'k-income-0000000001')], 'k-income-0000000001');
end $$;
select is((pg_temp.job(4, 'money.income_posted')).status::text, 'pending', 'income posted queues a push for the owner');
select is(current_setting('notify.push_kick', true), '1', 'and kicks the worker once for the transaction');
insert into ids select 'w1', (api.request_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.seg(4),
  '1500.00', pg_temp.id('A4'), 'School fees', pg_temp.k())->>'withdrawalId')::uuid;
select is((pg_temp.job(4, 'money.withdrawal_submitted')).status::text, 'pending',
  'Blueprint 44: the owner''s own request pushes too');
select is((pg_temp.job(3, 'task.withdrawal_approve')).status::text, 'pending', 'a task for a subscribed approver pushes');
select ok(notify.emit(pg_temp.u(1), null, 'money.income_posted', 'test', gen_random_uuid(), '{}'::jsonb, 'no-device')
  is not null and (pg_temp.job(1, 'money.income_posted')).item_id is null, 'someone with no device gets the bell item only');
select is((select count(*)::int from notify.push_jobs j join notify.items i on i.id = j.item_id
  where i.user_id = pg_temp.u(4) and i.kind = 'money.income_posted'), 1, 'a replayed event never duplicates the job');

-- ── Claim (7) ──
create temp table c1 as select api.push_claim('test-worker', 25, 60) as r;
create temp table c1_items as select value as v from c1, jsonb_array_elements(c1.r);
select is((select count(*)::int from c1_items), 3, 'every due job is claimed');
select is((select v->'params' from c1_items where v->>'kind' = 'money.income_posted'),
  jsonb_build_object('amount', '250000.00', 'currency', 'NGN', 'path',
    (select params->>'path' from notify.items where id = (pg_temp.job(4, 'money.income_posted')).item_id)),
  'only the amount, currency and link travel');
select is((select jsonb_array_length(v->'devices') from c1_items where v->>'kind' = 'money.income_posted'), 2,
  'with every live device of the owner''s');
select is((select string_agg(d->>'hideAmounts', ',' order by d->>'hideAmounts') from c1_items,
  jsonb_array_elements(v->'devices') d where v->>'kind' = 'money.income_posted'), 'false,true',
  'each with its Hide amounts');
select is((pg_temp.job(4, 'money.income_posted')).status::text, 'processing', 'a claimed job is leased');
select is(jsonb_array_length(api.push_claim('test-worker', 25, 60)), 0, 'a leased job is not claimed twice');

do $$ begin
  perform api.approve_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w1'), pg_temp.k());
end $$;
update notify.push_jobs set status = 'pending', next_attempt_at = now(), lease_token = null, lease_expires_at = null,
  worker_id = null where item_id = (pg_temp.job(3, 'task.withdrawal_approve')).item_id;
create temp table c2 as select api.push_claim('test-worker', 25, 60) as r;
select is(((pg_temp.job(3, 'task.withdrawal_approve')).skipped_reason), 'resolved',
  'a task done before its push leaves is skipped');

-- A task the approver can no longer do (left the office) is not pushed.
create temp table w2 as select api.request_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.seg(4),
  '100.00', pg_temp.id('A4'), 'Bus fare home', pg_temp.k()) as r;
set local session_replication_role = replica;
create temp table m3 as select id, is_primary from org.memberships where user_id = pg_temp.u(3);
update org.memberships set status = 'ended', ended_at = now(), is_primary = false where user_id = pg_temp.u(3);
set local session_replication_role = origin;
create temp table c2b as select api.push_claim('test-worker', 25, 60) as r;
select is((select j.skipped_reason from notify.push_jobs j join notify.items i on i.id = j.item_id
    where i.user_id = pg_temp.u(3) and i.subject_id = (select (r->>'withdrawalId')::uuid from w2)), 'not_allowed',
  'a task the person can no longer do is skipped');
set local session_replication_role = replica;
update org.memberships m set status = 'active', ended_at = null, is_primary = m3.is_primary
from m3 where m.id = m3.id;
set local session_replication_role = origin;

-- ── Report (8) ──
create function pg_temp.report(p_kind text, p_claim jsonb, p_results jsonb) returns jsonb language sql volatile as $$
  select api.push_report((x->>'itemId')::uuid, (x->>'leaseToken')::uuid, p_results)
  from jsonb_array_elements(p_claim) x where x->>'kind' = p_kind
$$;
create function pg_temp.device(p_endpoint text) returns text language sql stable as
  $$ select id::text from notify.push_subscriptions where endpoint = p_endpoint $$;
select is(pg_temp.report('money.income_posted', (select r from c1), jsonb_build_array(
    jsonb_build_object('subscriptionId', pg_temp.device('https://fcm.googleapis.com/fcm/send/dev-4a'),
      'outcome', 'sent', 'providerStatus', 201, 'latencyMs', 80),
    jsonb_build_object('subscriptionId', pg_temp.device('https://updates.push.services.mozilla.com/wpush/v2/dev-4b'),
      'outcome', 'gone', 'providerStatus', 410, 'latencyMs', 60)))->>'status',
  'sent', 'sent to one device counts as sent');
select ok(pg_temp.device('https://updates.push.services.mozilla.com/wpush/v2/dev-4b') is null,
  'a device the push service says is gone is deleted');
select ok((select last_success_at is not null from notify.push_subscriptions
  where endpoint = 'https://fcm.googleapis.com/fcm/send/dev-4a'), 'the working device is marked');
select is((select count(*)::int from notify.push_attempts where job_id = (pg_temp.job(4, 'money.income_posted')).item_id),
  2, 'one attempt per device, never the endpoint');
select is((pg_temp.report('money.income_posted', (select r from c1), '[]'::jsonb))->>'reason', 'already_recorded',
  'a repeated report is not applied');

select ok((select r from c2) @> '[{"kind": "money.withdrawal_approved"}]'::jsonb,
  'the approval push is claimed in the same run');
select is(pg_temp.report('money.withdrawal_approved', (select r from c2), jsonb_build_array(
    jsonb_build_object('subscriptionId', pg_temp.device('https://fcm.googleapis.com/fcm/send/dev-4a'),
      'outcome', 'retryable_failure', 'providerStatus', 503, 'errorCode', 'push.unavailable'))) ->>'status',
  'retry_scheduled', 'a retryable failure is retried');
select is((select next_attempt_at - updated_at from notify.push_jobs
  where item_id = (pg_temp.job(4, 'money.withdrawal_approved')).item_id), interval '30 seconds', 'after 30 seconds first');

-- ── Skips (2) ──
update notify.push_jobs set next_attempt_at = now() where item_id = (pg_temp.job(4, 'money.withdrawal_approved')).item_id;
set local session_replication_role = replica;
update identity.accounts set status = 'suspended' where user_id = pg_temp.u(4);
set local session_replication_role = origin;
create temp table c4 as select api.push_claim('test-worker', 25, 60) as r;
select is((pg_temp.job(4, 'money.withdrawal_approved')).skipped_reason, 'account_inactive',
  'a suspended account gets no push');
set local session_replication_role = replica;
update identity.accounts set status = 'active' where user_id = pg_temp.u(4);
set local session_replication_role = origin;
delete from auth.sessions where id = pg_temp.s(3);
select is((select count(*)::int from notify.push_subscriptions where user_id = pg_temp.u(3)), 0,
  'signing out ends push on that device');

-- ── Off, retention, privileges (5) ──
select is(api.push_unsubscribe(pg_temp.u(4), pg_temp.s(4), 'https://fcm.googleapis.com/fcm/send/dev-4a')->>'on', 'false',
  'turning it off');
select is(api.push_unsubscribe(pg_temp.u(4), pg_temp.s(4), 'https://fcm.googleapis.com/fcm/send/dev-4a')->>'on', 'false',
  'twice is fine');
delete from notify.items where id = (pg_temp.job(4, 'money.income_posted')).item_id;
select is((select count(*)::int from notify.push_attempts a
  where not exists (select 1 from notify.push_jobs j where j.item_id = a.job_id)), 0,
  'the bell''s housekeeping takes jobs and attempts with the item');
set local role authenticated;
select throws_ok($$ select api.push_claim('x', 1, 60) $$, '42501', null, 'people cannot claim pushes');
select throws_ok($$ select * from notify.push_subscriptions $$, '42501', null, 'subscriptions are private');
reset role;

select * from finish();
rollback;
