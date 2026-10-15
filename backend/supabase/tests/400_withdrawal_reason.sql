-- Blueprint 40 — 400: a withdrawal says what it is for (owner decision
-- 2026-10-15). Required, 3–500 characters after trimming; stored, part of the
-- idempotent request, fixed once placed, shown by every withdrawal read and
-- the transaction detail, carried by the M02/M03 emails (never the bell).
-- Withdrawals placed before it have none.
begin;
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(26);

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
create function pg_temp.wd(n int, p_amount text, p_reason text, p_key text default null) returns jsonb
language sql volatile as $$
  select api.request_withdrawal(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), pg_temp.seg(4), p_amount,
    pg_temp.id('A4'), p_reason, coalesce(p_key, pg_temp.k()))
$$;
-- The error code and details.field a statement fails with.
create function pg_temp.fails(p_sql text) returns text language plpgsql as $$
declare
  msg text;
  detail text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics msg = message_text, detail = pg_exception_detail;
  return msg || ':' || coalesce(detail::jsonb->>'field', '');
end $$;
create function pg_temp.payout_receipt(n int, p_withdrawal uuid, p_key text) returns uuid language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_payout_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_withdrawal, p_key, 'pay.pdf',
    'application/pdf', 2000, repeat('c', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 2000, repeat('c', 64),
    'application/pdf');
  return e;
end $$;

-- 1 President · 2 Director (D) · 3 TL (T) · 4 member (T) · 9 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from unnest(array[1, 2, 3, 4, 9]) n;
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from unnest(array[1, 2, 3, 4, 9]) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from unnest(array[1, 2, 3, 4, 9]) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(9), 'Test admin');
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('tenant'), 'Pilot', pg_temp.k());
end $$;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', null,
  array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'),
  array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(4), pg_temp.k());
  perform api.record_income(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(4, pg_temp.id('T')), 'NGN', '10000.00',
    'Fiverr', to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null,
    array[pg_temp.income_receipt(1, pg_temp.m(4, pg_temp.id('T')), 'k-income-0000000001')], 'k-income-0000000001');
end $$;
insert into payout.banks (provider, code, name, active) values ('paystack', '058', 'Guaranty Trust Bank', true);
insert into ids select 'A4', pg_temp.add_account(4, '058', '0123456789', 'ADA OBI');

-- ── Required, 3–500 characters (4) ──
select is(pg_temp.fails($$ select pg_temp.wd(4, '100.00', null) $$), 'validation_error:reason', 'a reason is required');
select is(pg_temp.fails($$ select pg_temp.wd(4, '100.00', '  ab  ') $$), 'validation_error:reason',
  'under 3 characters after trimming is refused');
select is(pg_temp.fails($$ select pg_temp.wd(4, '100.00', repeat('x', 501)) $$), 'validation_error:reason',
  'over 500 characters is refused');
select is((select count(*)::int from finance.withdrawals), 0, 'a refused request holds nothing');

-- ── Stored and returned (7) ──
create temp table w1 as select pg_temp.wd(4, '1500.00', '  School fees for the term  ', 'k-wd-0000000000001') as r;
insert into ids select 'w1', (r->>'withdrawalId')::uuid from w1;
select is((select r->>'reason' from w1), 'School fees for the term', 'the result carries the trimmed reason');
select is((select reason from finance.withdrawals where id = pg_temp.id('w1')), 'School fees for the term',
  'it is stored trimmed');
select is(api.my_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('w1'))->>'reason',
  'School fees for the term', 'the member sees it on their own request');
select is((api.my_withdrawals(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), null, null, null)->'items'->0->>'reason'),
  'School fees for the term', 'and in My withdrawals');
select is(api.withdrawal_detail(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w1'))->>'reason',
  'School fees for the term', 'the approver sees it in the detail');
select is((api.withdrawal_queue(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), 'action', null, null)->'items'->0->>'reason'),
  'School fees for the term', 'and in the queue');
select is((select reason from audit.tenant_events where action = 'withdrawal.requested'
    and target_id = pg_temp.id('w1')::text), 'School fees for the term', 'the audit event keeps it');

-- ── Replays (2) ──
select is((pg_temp.wd(4, '1500.00', 'School fees for the term', 'k-wd-0000000000001')->>'replayed')::boolean, true,
  'same key and same reason replays');
select throws_ok($$ select pg_temp.wd(4, '1500.00', 'Rent for March', 'k-wd-0000000000001') $$, 'P0001',
  'idempotency_conflict', 'same key, different reason is a conflict');

-- ── On behalf (2) ──
select is(pg_temp.fails($$ select pg_temp.wd(1, '100.00', '') $$), 'validation_error:reason',
  'a leader withdrawing on behalf gives a reason too');
select is((pg_temp.wd(1, '100.00', 'Hospital bill, member asked')->>'reason'), 'Hospital bill, member asked',
  'and it is stored with the request');

-- ── Emails, never the bell (3) ──
select is((select params->>'reason' from outbox.events where template = 'money.withdrawal_submitted'
    and aggregate_id = pg_temp.id('w1')), 'School fees for the term', 'M02 repeats the reason to the member');
select is((select params->>'reason' from outbox.events where template = 'money.withdrawal_awaiting_approval'
    and aggregate_id = pg_temp.id('w1') and recipient_user_id = pg_temp.u(3)), 'School fees for the term',
  'M03 shows it to the approver');
select is((select count(*)::int from notify.items where subject_id = pg_temp.id('w1') and params ? 'reason'), 0,
  'bell items never carry it');

-- ── Fixed once placed (2) ──
select throws_ok($$ update finance.withdrawals set reason = 'Something else' where id = pg_temp.id('w1') $$,
  'P0001', 'invariant_violation', 'the reason cannot be edited');
set local session_replication_role = replica;
select throws_ok($$ update finance.withdrawals set reason = 'ab' where id = pg_temp.id('w1') $$, '23514', null,
  'the column refuses a short reason even past the guard');
set local session_replication_role = origin;

-- ── Older withdrawals have none (2) ──
create temp table w0 as select pg_temp.wd(4, '50.00', 'Placeholder reason') as r;
insert into ids select 'w0', (r->>'withdrawalId')::uuid from w0;
set local session_replication_role = replica;
update finance.withdrawals set reason = null where id = pg_temp.id('w0');
set local session_replication_role = origin;
select ok((api.my_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('w0')) ? 'reason')
  and (api.my_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('w0'))->'reason') = 'null'::jsonb,
  'a withdrawal from before has a null reason');
select is(api.withdrawal_detail(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w0'))->>'status', 'requested',
  'and still reads for the approver');

-- ── Activity transaction detail (4) ──
select lives_ok($$ select api.approve_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w1'),
  pg_temp.k()) $$, 'the Team Leader approves');
create temp table p1 as select api.record_payout(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w1'),
  '1500.00', null, to_char(now() at time zone 'Africa/Lagos', 'YYYY-MM-DD'), '000014261005', null,
  pg_temp.payout_receipt(3, pg_temp.id('w1'), 'k-payout-000000001'), 'k-payout-000000001') as r;
create temp table claim as select api.claim_payout_checks('test-worker', 10) as r;
select is((api.finish_payout_check((select (r->0->>'checkId')::uuid from claim),
    (select (r->0->>'leaseToken')::uuid from claim), 'match',
    jsonb_build_object('paymentDate', to_char(now() at time zone 'Africa/Lagos', 'YYYY-MM-DD'),
      'receipt', jsonb_build_object('amount', '1500.00', 'currency', 'NGN', 'recipientAccount', '0123456789',
        'recipientName', 'ADA OBI', 'paymentStatus', 'successful', 'confidence', 'high')),
    '{}'::text[], 'gpt-5-mini', 'strict-single-receipt-v1')->>'status'), 'completed', 'a matching receipt completes it');
select is(api.my_transaction(pg_temp.u(4), pg_temp.s(4),
    (select transaction_id from finance.withdrawals where id = pg_temp.id('w1')))->'withdrawal'->>'reason',
  'School fees for the term', 'Activity''s transaction detail shows the reason');
select is((select reason from finance.withdrawals where id = pg_temp.id('w1')), 'School fees for the term',
  'completion leaves it as placed');

select * from finish();
rollback;
