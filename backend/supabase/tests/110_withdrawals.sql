-- Blueprint 11 — B7 110: withdrawals (W-09): request and hold, approve,
-- reject, cancel, reveal; payouts (W-10): record, receipt check, one
-- correction, review (W-11), completion posting; replays and authority.
begin;
create extension if not exists pgtap with schema extensions;
select plan(62);

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
    encode(extensions.digest(p_bank || ':' || p_number, 'sha256'), 'hex'), right(p_number, 4), null, pg_temp.k())->>'lookupId')::uuid;
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
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 1000, repeat('b', 64), 'application/pdf');
  return e;
end $$;
-- Point Value segment of member n (40% of income).
create function pg_temp.seg(n int) returns uuid language sql stable as $$
  select b.account_id from ledger.balances b join ledger.pockets p on p.id = b.pocket_id
  where b.owner_user_id = pg_temp.u(n) and p.name = 'Point Value' and b.currency = 'NGN'
$$;
create function pg_temp.avail(n int) returns numeric language sql stable as
  $$ select posted - reserved from ledger.balances where account_id = pg_temp.seg(n) $$;
create function pg_temp.wd(n int, p_amount text, p_key text default null) returns jsonb language sql volatile as $$
  select api.request_withdrawal(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), pg_temp.seg(4), p_amount,
    pg_temp.id('A4'), coalesce(p_key, pg_temp.k()))
$$;
create function pg_temp.payout_receipt(n int, p_withdrawal uuid, p_key text) returns uuid language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_payout_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_withdrawal, p_key, 'pay.pdf',
    'application/pdf', 2000, repeat('c', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 2000, repeat('c', 64), 'application/pdf');
  return e;
end $$;
create function pg_temp.record(n int, p_withdrawal uuid, p_amount text, p_fee text default null, p_key text default null)
returns jsonb language plpgsql as $$
declare
  key text := coalesce(p_key, pg_temp.k());
begin
  return api.record_payout(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_withdrawal, p_amount, p_fee,
    to_char(now() at time zone 'Africa/Lagos', 'YYYY-MM-DD'), '000014261005', null,
    pg_temp.payout_receipt(n, p_withdrawal, key), key);
end $$;
-- The error code and details.reason a statement fails with.
create function pg_temp.fails(p_sql text) returns text language plpgsql as $$
declare
  msg text;
  detail text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics msg = message_text, detail = pg_exception_detail;
  return msg || ':' || coalesce(detail::jsonb->>'reason', '');
end $$;
-- Worker stand-in: claims and finishes the ready check of a payout.
create function pg_temp.finish(p_payout uuid, p_outcome text) returns jsonb language plpgsql as $$
declare
  claimed jsonb;
  item jsonb;
  rev finance.payout_revisions;
begin
  claimed := api.claim_payout_checks('test-worker', 10);
  select value into item from jsonb_array_elements(claimed) where (value->>'payoutId')::uuid = p_payout;
  select r.* into rev from finance.payout_revisions r join finance.payouts p on p.id = r.payout_id and r.revision = p.revision
  where p.id = p_payout;
  return api.finish_payout_check((item->>'checkId')::uuid, (item->>'leaseToken')::uuid, p_outcome,
    jsonb_build_object('paymentDate', rev.paid_on::text, 'receipt', jsonb_build_object(
      'amount', trim_scale(rev.amount)::text, 'currency', 'NGN', 'recipientAccount', '0123456789',
      'recipientName', 'ADA OBI', 'paymentStatus', 'successful', 'confidence', 'high')),
    case when p_outcome = 'match' then '{}'::text[] else array['recipientName_mismatch'] end,
    'gpt-5-mini', 'strict-single-receipt-v1');
end $$;

-- 1 President · 2 Director (D) · 3 TL (T) · 4 member (T) · 5 TL (T2) · 6 member (T2) · 7 reviewer member (T)
-- 8 other founder · 9 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 9) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 9) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 9) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(9), 'Test admin');
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
insert into ids
select 'other', (api.start_network(pg_temp.u(8), pg_temp.s(8), 'Abuja Network', 'ABJ', pg_temp.k())->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('tenant'), 'Pilot', pg_temp.k());
  perform api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('other'), 'Pilot', pg_temp.k());
end $$;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', null, array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'), array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T2', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team B', pg_temp.id('D'), array[pg_temp.uid(5)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(4), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), pg_temp.uid(6), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(7), pg_temp.k());
  perform api.assign_reviewer(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(7, pg_temp.id('T')), 'Finance lead', pg_temp.k());
  perform api.record_income(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(4, pg_temp.id('T')), 'NGN', '10000.00',
    'Fiverr', to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null,
    array[pg_temp.income_receipt(1, pg_temp.m(4, pg_temp.id('T')), 'k-income-0000000001')], 'k-income-0000000001');
end $$;
insert into payout.banks (provider, code, name, active) values ('paystack', '058', 'Guaranty Trust Bank', true);
insert into ids select 'A4', pg_temp.add_account(4, '058', '0123456789', 'ADA OBI');

-- ── Request (9) ──
select is(pg_temp.avail(4), 4000.00::numeric, 'Point Value holds 40% of the income');
create temp table w1 as select pg_temp.wd(4, '1500.00', 'k-wd-0000000000001') as r;
insert into ids select 'w1', (r->>'withdrawalId')::uuid from w1;
select is((select r->>'status' from w1), 'requested', 'the request is accepted');
select matches((select r->>'reference' from w1), '^WDR-', 'WDR reference');
select is(pg_temp.avail(4), 2500.00::numeric, 'the amount is held at once');
select is((select posted from ledger.balances where account_id = pg_temp.seg(4)), 4000.00::numeric,
  'posted balance does not change on request');
select is((pg_temp.wd(4, '1500.00', 'k-wd-0000000000001')->>'replayed')::boolean, true, 'same key replays');
select is(pg_temp.avail(4), 2500.00::numeric, 'a replay never holds twice');
select throws_ok($$ select pg_temp.wd(4, '1600.00', 'k-wd-0000000000001') $$, 'P0001', 'idempotency_conflict',
  'same key, different amount');
select throws_ok($$ select pg_temp.wd(4, '2500.01') $$, 'P0001', 'insufficient_funds', 'no more than available');

-- ── Request authority (3) ──
select throws_ok($$ select pg_temp.wd(3, '10.00') $$, 'P0001', 'authorization_denied',
  'a Team Leader cannot withdraw on behalf by default');
select throws_ok($$ select api.request_withdrawal(pg_temp.u(8), pg_temp.s(8), pg_temp.ws(8), pg_temp.seg(4), '10.00',
  pg_temp.id('A4'), pg_temp.k()) $$, 'P0001', 'not_found', 'nothing across networks');
select is((pg_temp.wd(1, '100.00')->>'onBehalf')::boolean, true, 'the President may withdraw on behalf');

-- ── Approve / reject / cancel (12) ──
select throws_ok($$ select api.approve_withdrawal(pg_temp.u(5), pg_temp.s(5), pg_temp.ws(5), pg_temp.id('w1'), pg_temp.k()) $$,
  'P0001', 'authorization_denied', 'a sibling Team Leader cannot approve');
select throws_ok($$ select api.approve_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('w1'), pg_temp.k()) $$,
  'P0001', 'self_target_forbidden', 'nobody approves their own withdrawal');
select is((api.approve_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w1'), pg_temp.k())->>'status'),
  'approved', 'the Team Leader approves');
select is(pg_temp.avail(4), 2400.00::numeric, 'approval keeps the hold');
select throws_like($$ select api.approve_withdrawal(pg_temp.u(2), pg_temp.s(2), pg_temp.ws(2), pg_temp.id('w1'), pg_temp.k()) $$,
  '%conflict%', 'approving twice is a conflict');
select throws_ok($$ select api.cancel_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('w1'), null, pg_temp.k()) $$,
  'P0001', 'self_target_forbidden', 'the member cannot cancel an approved withdrawal');

create temp table w2 as select pg_temp.wd(4, '200.00') as r;
insert into ids select 'w2', (r->>'withdrawalId')::uuid from w2;
select throws_ok($$ select api.reject_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w2'), 'no', pg_temp.k()) $$,
  'P0001', 'validation_error', 'rejecting needs a reason');
select is((api.reject_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w2'), 'Wrong pocket', pg_temp.k())->>'status'),
  'rejected', 'the Team Leader rejects with a reason');
select is(pg_temp.avail(4), 2400.00::numeric, 'rejection releases the hold');

create temp table w3 as select pg_temp.wd(4, '300.00') as r;
insert into ids select 'w3', (r->>'withdrawalId')::uuid from w3;
select throws_ok($$ select api.cancel_withdrawal(pg_temp.u(6), pg_temp.s(6), pg_temp.ws(6), pg_temp.id('w3'), null, pg_temp.k()) $$,
  'P0001', 'not_found', 'only the member or the requester may cancel');
select is((api.cancel_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('w3'), null, pg_temp.k())->>'status'),
  'cancelled', 'the member cancels a request without a reason');
select is(pg_temp.avail(4), 2400.00::numeric, 'cancellation releases the hold');

-- ── Reveal (4) ──
select throws_ok($$ select api.reveal_withdrawal_destination(pg_temp.u(2), pg_temp.s(2), pg_temp.ws(2), pg_temp.id('w1')) $$,
  'P0001', 'authorization_denied', 'only the approving leader may reveal');
select is((api.reveal_withdrawal_destination(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w1'))->>'accountLast4'),
  '6789', 'the approver gets the sealed number');
select is((select count(*)::int from audit.tenant_events where action = 'withdrawal.destination_revealed'), 1, 'the reveal is audited');
update identity.session_pin_proofs set verified_at = now() - interval '10 minutes' where user_id = pg_temp.u(3);
select throws_ok($$ select api.reveal_withdrawal_destination(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w1')) $$,
  'P0001', 'step_up_required', 'reveal needs a fresh PIN');
update identity.session_pin_proofs set verified_at = now() where user_id = pg_temp.u(3);

-- ── Record and check: mismatch → correction → mismatch → review (14) ──
select throws_like($$ select pg_temp.record(3, pg_temp.id('w1'), '1500.00', '0.01') $$, '%validation_error%',
  'sent + fee cannot exceed the request');
select throws_ok($$ select pg_temp.record(2, pg_temp.id('w1'), '1500.00') $$, 'P0001', 'authorization_denied',
  'only the approving leader records the payout');
create temp table p1 as select pg_temp.record(3, pg_temp.id('w1'), '1490.00', '10.00') as r;
insert into ids select 'p1', (r->'payout'->>'payoutId')::uuid from p1;
select is((select r->'payout'->>'status' from p1), 'verifying', 'the payout is being checked');
select is((select status from finance.withdrawals where id = pg_temp.id('w1')), 'approved', 'receipt upload alone never completes');
select is(pg_temp.fails($$ select pg_temp.record(3, pg_temp.id('w1'), '1490.00') $$), 'conflict:payout_open',
  'one open payout at a time');
select is(pg_temp.fails($$ select api.cancel_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w1'), 'Never paid', pg_temp.k()) $$),
  'conflict:payout_open', 'no cancelling while a payout is open');
select is((pg_temp.finish(pg_temp.id('p1'), 'mismatch')->>'status'), 'correction_required', 'first mismatch asks for the one correction');
select is(pg_temp.avail(4), 2400.00::numeric, 'a mismatch posts nothing');
create temp table c1 as select api.correct_payout(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('p1'), '1490.00', '10.00',
  to_char(now() at time zone 'Africa/Lagos', 'YYYY-MM-DD'), null, null,
  pg_temp.payout_receipt(3, pg_temp.id('w1'), 'k-correct-00000001'), 'k-correct-00000001') as r;
select is((select r->'payout'->>'revision' from c1), '2', 'the correction is revision 2');
select is((pg_temp.finish(pg_temp.id('p1'), 'mismatch')->>'status'), 'needs_review', 'second mismatch goes to review');
select is(pg_temp.fails($$ select api.correct_payout(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('p1'), '1490.00', null,
  to_char(now() at time zone 'Africa/Lagos', 'YYYY-MM-DD'), null, null,
  pg_temp.payout_receipt(3, pg_temp.id('w1'), 'k-correct-00000002'), 'k-correct-00000002') $$),
  'conflict:payout_state', 'there is only one correction');

-- ── Review (8) ──
select throws_ok($$ select api.review_payout(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('p1'), 'clear', 'Looks right', pg_temp.k()) $$,
  'P0001', 'authorization_denied', 'the recording leader is not a reviewer');
select is((api.review_queue(pg_temp.u(7), pg_temp.s(7), pg_temp.m(7, pg_temp.id('T')), 'assigned', null, null)->'counts'->>'assigned'),
  '1', 'the assigned reviewer sees the case');
select throws_ok($$ select api.review_queue(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), 'assigned', null, null) $$,
  'P0001', 'authorization_denied', 'others have no review queue');
select is((api.review_case(pg_temp.u(7), pg_temp.s(7), pg_temp.m(7, pg_temp.id('T')), pg_temp.id('p1'))->'payout'->>'status'),
  'needs_review', 'the reviewer opens the case');
select is((api.review_payout(pg_temp.u(7), pg_temp.s(7), pg_temp.m(7, pg_temp.id('T')), pg_temp.id('p1'), 'clear',
  'Name spelling only; bank confirms', 'k-review-000000001')->>'status'), 'completed', 'clearing completes the payout');
select is((select status from finance.withdrawals where id = pg_temp.id('w1')), 'completed', 'the withdrawal is completed');
select is((select posted from ledger.balances where account_id = pg_temp.seg(4)), 2500.00::numeric,
  'the pocket is debited sent + fee');
select is(pg_temp.avail(4), 2400.00::numeric, 'the hold is consumed; the remaining open request still holds 100');

-- ── Posting (5) ──
select is((select sum(p.amount) from ledger.postings p join ledger.accounts a on a.id = p.account_id
  where a.system_key = 'external_outflow'), 1490.00::numeric, 'external outflow gets what was sent');
select is((select sum(p.amount) from ledger.postings p join ledger.accounts a on a.id = p.account_id
  where a.system_key = 'payout_fee'), 10.00::numeric, 'the fee is its own line');
select is((select type from ledger.transactions t join finance.withdrawals w on w.transaction_id = t.id
  where w.id = pg_temp.id('w1')), 'withdrawal', 'one withdrawal transaction');
select is((select count(*)::int from ledger.verify_balances()), 0, 'no projection drift');
select lives_ok($$ set constraints all immediate $$, 'the ledger commit checks pass');
set constraints all deferred;

-- ── Happy path and technical failure (8) ──
create temp table w4 as select pg_temp.wd(4, '400.00') as r;
insert into ids select 'w4', (r->>'withdrawalId')::uuid from w4;
select lives_ok($$ select api.approve_withdrawal(pg_temp.u(2), pg_temp.s(2), pg_temp.ws(2), pg_temp.id('w4'), pg_temp.k()) $$,
  'the Director over the subtree approves');
create temp table p4 as select pg_temp.record(2, pg_temp.id('w4'), '400.00') as r;
insert into ids select 'p4', (r->'payout'->>'payoutId')::uuid from p4;
create temp table claim1 as select api.claim_payout_checks('test-worker', 10) as r;
select is((select jsonb_array_length(r) from claim1), 1, 'one check is ready');
select is((api.fail_payout_check((select (r->0->>'checkId')::uuid from claim1), (select (r->0->>'leaseToken')::uuid from claim1),
  'provider_error')->>'status'), 'queued', 'a technical failure is retried later');
select is((select status from finance.payouts where id = pg_temp.id('p4')), 'verifying', 'it does not use the correction');
select is(pg_temp.fails($$ select api.fail_payout_check((select (r->0->>'checkId')::uuid from claim1),
  (select (r->0->>'leaseToken')::uuid from claim1), 'provider_error') $$), 'conflict:lease_lost', 'a spent lease cannot report twice');
set local session_replication_role = replica;
update finance.payout_checks set next_attempt_at = now() where payout_id = pg_temp.id('p4');
set local session_replication_role = origin;
select is(pg_temp.fails($$ select api.finish_payout_check(c.id, c.lease_token, 'match',
    jsonb_build_object('paymentDate', '2000-01-01', 'receipt', jsonb_build_object('amount', '400', 'currency', 'NGN',
      'recipientAccount', '0123456789', 'paymentStatus', 'successful', 'confidence', 'high')),
    '{}'::text[], 'gpt-5-mini', 'strict-single-receipt-v1')
  from (select (x->>'checkId')::uuid as id, (x->>'leaseToken')::uuid as lease_token
        from jsonb_array_elements(api.claim_payout_checks('test-worker', 10)) x) c $$),
  'validation_error:match_not_supported', 'a match the recorded facts do not support is refused');
set local session_replication_role = replica;
update finance.payout_checks set status = 'queued', next_attempt_at = now(), lease_token = null, lease_expires_at = null
where payout_id = pg_temp.id('p4') and status = 'leased';
set local session_replication_role = origin;
select is((pg_temp.finish(pg_temp.id('p4'), 'match')->>'status'), 'completed', 'a full match completes at once');
select is((select status from finance.withdrawals where id = pg_temp.id('w4')), 'completed', 'and the withdrawal');

-- ── Approved cancel (2) ──
create temp table w5 as select pg_temp.wd(4, '50.00') as r;
insert into ids select 'w5', (r->>'withdrawalId')::uuid from w5;
select lives_ok($$ select api.approve_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w5'), pg_temp.k()) $$,
  'approved for cancel');
select is((api.cancel_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w5'), 'No payout was made', pg_temp.k())->>'status'),
  'cancelled', 'an approved withdrawal with no payout can be cancelled with a reason');

select * from finish();
rollback;
