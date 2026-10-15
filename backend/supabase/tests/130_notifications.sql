-- Blueprint 13 — B6 130: the bell and money emails. Every slice 4/5 money
-- event writes its bell item and email in the same transaction; tasks go to
-- the people who can act and clear when the work is done; reads are scoped
-- to the selected network; replays never duplicate; retention is 90 days.
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(111);


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
    pg_temp.id('A4'), 'Monthly upkeep', coalesce(p_key, pg_temp.k()))
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
      -- Untidy but equal values, normalized the same way as the worker's comparison.
      'amount', ' ' || trim_scale(rev.amount)::text, 'currency', 'ngn ', 'recipientAccount', '012 345 6789',
      'recipientName', 'ADA OBI', 'paymentStatus', 'successful', 'confidence', 'high')),
    case when p_outcome = 'match' then '{}'::text[] else array['recipientName_mismatch'] end,
    'gpt-5-mini', 'strict-single-receipt-v1');
end $$;

-- 1 President · 2 Director (D) · 3 TL (T) · 4 member (T) · 5 TL (T2) · 6 member (T2) · 7 reviewer member (T)
-- 8 other founder · 9 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 9) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
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

create function pg_temp.items(n int, p_kind text) returns int language sql stable as
  $$ select count(*)::int from notify.items where user_id = pg_temp.u(n) and kind = p_kind $$;
create function pg_temp.open_tasks(n int, p_kind text) returns int language sql stable as
  $$ select count(*)::int from notify.items where user_id = pg_temp.u(n) and kind = p_kind and resolved_at is null $$;
create function pg_temp.mails(n int, p_template text) returns int language sql stable as
  $$ select count(*)::int from outbox.events where recipient_user_id = pg_temp.u(n) and template = p_template $$;
create function pg_temp.bell(n int, p_view text default 'all') returns jsonb language sql volatile as
  $$ select api.my_notifications(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_view, null, null) $$;
create function pg_temp.proof(n int, p_kind text, p_target uuid, p_key text) returns uuid language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_entry_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_kind, p_target, p_key,
    'proof.pdf', 'application/pdf', 3000, repeat('d', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 3000, repeat('d', 64), 'application/pdf');
  return e;
end $$;
create function pg_temp.adjust(n int, p_direction text, p_amount text) returns jsonb language plpgsql as $$
declare
  key text := pg_temp.k();
begin
  return api.submit_adjustment(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), pg_temp.m(4, pg_temp.id('T')), p_direction, 'NGN',
    p_amount, 'Goodwill credit from the network', null,
    array[pg_temp.proof(n, 'adjustment', pg_temp.m(4, pg_temp.id('T')), key)], key);
end $$;

-- ── Catalogue ──
select is((select count(*)::int from notify.kinds k where k.email_template is not null
  and not exists (select 1 from outbox.templates t where t.key = k.email_template)), 0,
  'every kind with an email names a real template');
select throws_like($$ update notify.kinds set task = true where key = 'money.income_posted' $$, '%invariant_violation%',
  'the catalogue is immutable');

-- ── Income posted (M01) ──
select is(pg_temp.items(4, 'money.income_posted'), 1, 'the member gets an income bell item');
select is(pg_temp.mails(4, 'money.income_posted'), 1, 'and one income email');
select is((select params->>'amount' from outbox.events where template = 'money.income_posted'), '10000.00',
  'the email carries the exact amount');
select is((select params->>'network' from outbox.events where template = 'money.income_posted'), 'Lagos Network',
  'and the network name');
select is(pg_temp.items(1, 'money.income_posted'), 0, 'the recorder gets nothing');

-- ── Withdrawal requested (M02, M03 + approval tasks) ──
create temp table w1 as select pg_temp.wd(4, '1500.00', 'k-wd-0000000000001') as r;
insert into ids select 'w1', (r->>'withdrawalId')::uuid from w1;
select is(pg_temp.items(4, 'money.withdrawal_submitted'), 1, 'the owner hears about their own request');
select is(pg_temp.mails(4, 'money.withdrawal_submitted'), 1, 'by email too');
select is(pg_temp.open_tasks(3, 'task.withdrawal_approve'), 1, 'the Team Leader gets the approval task');
select is(pg_temp.open_tasks(2, 'task.withdrawal_approve'), 1, 'so does the Director over the office');
select is(pg_temp.items(5, 'task.withdrawal_approve'), 0, 'a sibling Team Leader does not');
select is(pg_temp.items(4, 'task.withdrawal_approve'), 0, 'never the owner');
select is(pg_temp.mails(3, 'money.withdrawal_awaiting_approval'), 1, 'approvers get M03');
select is((select params->>'member' from outbox.events where template = 'money.withdrawal_awaiting_approval'
  and recipient_user_id = pg_temp.u(3)), pg_temp.uid(4), 'M03 names the member (UID when no profile name)');
select is((select count(*)::int from outbox.events e where e.params::text ~ '0123456789'
  or e.params::text ~ '"(last4|bank)"'), 0, 'no account number or bank details in any email');
select is((select params->>'last4' from notify.items where user_id = pg_temp.u(3) and kind = 'task.withdrawal_approve'),
  '6789', 'the bell task shows the masked last 4, as the app does');
select is((pg_temp.wd(4, '1500.00', 'k-wd-0000000000001')->>'replayed')::boolean, true, 'a replay');
select is(pg_temp.items(4, 'money.withdrawal_submitted') + pg_temp.mails(3, 'money.withdrawal_awaiting_approval'), 2,
  'a replay never notifies twice');

-- ── Reads ──
select is(jsonb_array_length(pg_temp.bell(3)->'actions'), 1, 'the task shows under Needs your action');
select is((pg_temp.bell(3)->'actions'->0->>'kind'), 'task.withdrawal_approve', 'as an approval task');
select is((pg_temp.bell(3)->>'unread')::int, 1, 'and counts as unread');
select is((api.my_notification_count(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3))->>'unread')::int, 1, 'the badge count');
select is((pg_temp.bell(5)->>'unread')::int, 0, 'the sibling Team Leader sees nothing');
select is(jsonb_array_length(api.my_notifications(pg_temp.u(8), pg_temp.s(8), pg_temp.ws(8), 'all', null, null)->'items'), 0,
  'another network sees nothing');
select throws_ok($$ select api.my_notifications(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), 'new', null, null) $$,
  'P0001', 'validation_error', 'unknown view');
select throws_ok($$ select api.my_notifications(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(4), 'all', null, null) $$,
  'P0001', 'workspace_invalid', 'only one''s own workspace');
select is((api.mark_notifications_read(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3),
  array[(pg_temp.bell(3)->'actions'->0->>'id')::uuid], null)->>'unread')::int, 0, 'marking read clears the count');
select is(jsonb_array_length(pg_temp.bell(3, 'unread')->'actions'), 1, 'a read task still needs action');
select is((api.mark_notifications_read(pg_temp.u(5), pg_temp.s(5), pg_temp.ws(5),
  array[(select id from notify.items where user_id = pg_temp.u(2) limit 1)], null)->>'marked')::int, 0,
  'nobody marks another person''s items');
select throws_ok($$ select api.mark_notifications_read(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), '{}'::uuid[], null) $$,
  'P0001', 'validation_error', 'ids or all');
select is((api.mark_notifications_read(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), null, true)->>'unread')::int, 0,
  'mark all as read');
select is(jsonb_array_length(pg_temp.bell(4, 'unread')->'items'), 0, 'the unread view is empty after');
select is(jsonb_array_length(pg_temp.bell(4, 'all')->'items'), 3, 'all still lists them (income, request, payout account)');
select throws_like($$ update notify.items set params = '{}' where user_id = pg_temp.u(4) $$, '%invariant_violation%',
  'items never change except read/resolved');

-- ── Approve → payout to record ──
select lives_ok($$ select api.approve_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w1'), pg_temp.k()) $$,
  'the Team Leader approves');
select is(pg_temp.open_tasks(3, 'task.withdrawal_approve') + pg_temp.open_tasks(2, 'task.withdrawal_approve'), 0,
  'every approval task clears, also the Director''s');
select is(jsonb_array_length(api.my_notifications(pg_temp.u(2), pg_temp.s(2), pg_temp.ws(2), 'all', null, null)->'items'), 1,
  'a done task becomes an ordinary item');
select is(pg_temp.items(4, 'money.withdrawal_approved'), 1, 'the owner hears it was approved (M04)');
select is(pg_temp.open_tasks(3, 'task.payout_record'), 1, 'the approver must record the payout');
select is(pg_temp.items(2, 'task.payout_record'), 0, 'only the approver');

-- ── Payout: fix, review, rejected ──
create temp table p1 as select pg_temp.record(3, pg_temp.id('w1'), '1490.00', '10.00') as r;
insert into ids select 'p1', (r->'payout'->>'payoutId')::uuid from p1;
select is(pg_temp.open_tasks(3, 'task.payout_record'), 0, 'recording the payout clears the task');
select is((pg_temp.finish(pg_temp.id('p1'), 'mismatch')->>'status'), 'correction_required', 'a mismatch');
select is(pg_temp.open_tasks(3, 'task.payout_fix'), 1, 'the recorder must fix the record');
select is(pg_temp.mails(3, 'money.payout_correction_required'), 1, 'M08');
select lives_ok($$ select api.correct_payout(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('p1'), '1490.00', '10.00',
  to_char(now() at time zone 'Africa/Lagos', 'YYYY-MM-DD'), null, null,
  pg_temp.payout_receipt(3, pg_temp.id('w1'), 'k-correct-00000001'), 'k-correct-00000001') $$, 'the one correction');
select is(pg_temp.open_tasks(3, 'task.payout_fix'), 0, 'the fix task clears');
select is((pg_temp.finish(pg_temp.id('p1'), 'mismatch')->>'status'), 'needs_review', 'second mismatch: review');
select is(pg_temp.open_tasks(7, 'task.payout_review'), 1, 'the assigned reviewer gets the review task');
select is(pg_temp.mails(7, 'money.evidence_review_assigned'), 1, 'M09');
select is(pg_temp.items(3, 'task.payout_review'), 0, 'never the recorder');
select is(pg_temp.items(1, 'task.payout_review'), 0, 'review comes only from an assignment');
select lives_ok($$ select api.review_payout(pg_temp.u(7), pg_temp.s(7), pg_temp.m(7, pg_temp.id('T')), pg_temp.id('p1'),
  'reject', 'The receipt is for another payment', pg_temp.k()) $$, 'the reviewer rejects the receipt');
select is(pg_temp.open_tasks(7, 'task.payout_review'), 0, 'the review task clears');
select is(pg_temp.items(3, 'money.payout_receipt_rejected'), 1, 'the recorder hears it (M17)');
select is(pg_temp.open_tasks(3, 'task.payout_record'), 1, 'and must record the payout again');
select is((select count(*)::int from outbox.events where params::text ~ 'another payment'), 0,
  'the reviewer''s reason is never emailed');
select lives_ok($$ select api.cancel_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w1'),
  'No payout was made', pg_temp.k()) $$, 'the approver cancels instead');
select is(pg_temp.open_tasks(3, 'task.payout_record'), 0, 'nothing left to record');
select is(pg_temp.items(4, 'money.withdrawal_cancelled'), 1, 'the owner hears it was cancelled (M07)');

-- ── Rejected and completed ──
create temp table w2 as select pg_temp.wd(4, '200.00') as r;
select lives_ok($$ select api.reject_withdrawal(pg_temp.u(2), pg_temp.s(2), pg_temp.ws(2),
  (select (r->>'withdrawalId')::uuid from w2), 'Wrong pocket', pg_temp.k()) $$, 'the Director rejects');
select is(pg_temp.items(4, 'money.withdrawal_not_approved'), 1, 'M06');
create temp table w4 as select pg_temp.wd(4, '400.00') as r;
insert into ids select 'w4', (r->>'withdrawalId')::uuid from w4;
select lives_ok($$ select api.approve_withdrawal(pg_temp.u(2), pg_temp.s(2), pg_temp.ws(2), pg_temp.id('w4'), pg_temp.k()) $$,
  'approved');
create temp table p4 as select pg_temp.record(2, pg_temp.id('w4'), '400.00') as r;
select is((pg_temp.finish((select (r->'payout'->>'payoutId')::uuid from p4), 'match')->>'status'), 'completed', 'paid');
select is(pg_temp.items(4, 'money.withdrawal_completed'), 1, 'M05');
select is((select params->>'amount' from outbox.events where template = 'money.withdrawal_completed'), '400.00',
  'with the exact amount');

-- ── Pocket moves ──
create temp table t1 as select api.request_pocket_transfer(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.seg(4),
  (select id from ledger.pockets where tenant_id = pg_temp.id('tenant') and name = 'Savings'), '100.00', pg_temp.k()) as r;
select is(pg_temp.open_tasks(3, 'task.transfer_approve'), 1, 'a move to approve');
select is(pg_temp.items(4, 'task.transfer_approve'), 0, 'not for the owner');
select lives_ok($$ select api.approve_pocket_transfer(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3),
  (select (r->>'transferId')::uuid from t1), pg_temp.k()) $$, 'approved');
select is(pg_temp.open_tasks(3, 'task.transfer_approve'), 0, 'the task clears');
select is(pg_temp.mails(4, 'money.pocket_move_done'), 1, 'M10');
select is((select params->>'to' from outbox.events where template = 'money.pocket_move_done'), 'Savings', 'names the pockets');

-- ── Adjustments (the member is notified) ──
create temp table a1 as select pg_temp.adjust(1, 'credit', '250.00') as r;
select is(pg_temp.open_tasks(7, 'task.entry_review'), 1, 'the reviewer gets the adjustment to review');
select is(pg_temp.items(4, 'money.adjustment_posted'), 0, 'nothing for the member until it posts');
select lives_ok($$ select api.review_entry(pg_temp.u(7), pg_temp.s(7), pg_temp.m(7, pg_temp.id('T')),
  (select (r->>'entryId')::uuid from a1), 'clear', 'Checked the statement', pg_temp.k()) $$, 'cleared');
select is(pg_temp.open_tasks(7, 'task.entry_review'), 0, 'the review task clears');
select is(pg_temp.mails(4, 'money.adjustment_posted'), 1, 'M12 to the member');
select is((select params->>'direction' from outbox.events where template = 'money.adjustment_posted'), 'credit', 'a credit');
create temp table a2 as select pg_temp.adjust(1, 'debit', '50.00') as r;
select lives_ok($$ select api.review_entry(pg_temp.u(7), pg_temp.s(7), pg_temp.m(7, pg_temp.id('T')),
  (select (r->>'entryId')::uuid from a2), 'reject', 'No statement attached', pg_temp.k()) $$, 'rejected');
select is(pg_temp.mails(1, 'money.entry_not_posted'), 1, 'the submitter hears it was not posted (M18)');
select is((select params->>'subject' from outbox.events where template = 'money.entry_not_posted'), 'adjustment', 'which kind');

-- ── Conversion posted (M16) ──
do $$ begin
  perform api.record_income(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(4, pg_temp.id('T')), 'USD', '1000.00',
    'Upwork', to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null,
    array[pg_temp.income_receipt(1, pg_temp.m(4, pg_temp.id('T')), 'k-income-0000000002')], 'k-income-0000000002');
end $$;
create temp table c1 as select api.submit_conversion(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1),
  (select b.account_id from ledger.balances b join ledger.pockets p on p.id = b.pocket_id
   where b.owner_user_id = pg_temp.u(4) and p.name = 'Point Value' and b.currency = 'USD'),
  '100.00', 'NGN', '152500.00', '1525', 'Grey', to_char(now() - interval '1 hour', 'YYYY-MM-DD"T"HH24:MI:SSOF":00"'),
  'GRY-1', null, array[pg_temp.proof(1, 'conversion', pg_temp.m(4, pg_temp.id('T')), 'k-conv-00000000001')],
  'k-conv-00000000001') as r;
select is(pg_temp.open_tasks(7, 'task.entry_review'), 1, 'the conversion goes to the reviewer');
select lives_ok($$ select api.review_entry(pg_temp.u(7), pg_temp.s(7), pg_temp.m(7, pg_temp.id('T')),
  (select (r->>'entryId')::uuid from c1), 'clear', 'Matches the Grey receipt', pg_temp.k()) $$, 'cleared');
select is((select params->>'destinationAmount' || ' ' || (params->>'destinationCurrency') from outbox.events
  where template = 'money.conversion_posted' and recipient_user_id = pg_temp.u(4)), '152500.00 NGN',
  'M16 tells the member what they received');

-- ── Reversal (M13) ──
select lives_ok($$ select api.reverse_transaction(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1),
  (select transaction_id from finance.pocket_transfers where transaction_id is not null), 'wrong_amount',
  'Moved by mistake',
  (select t.reference from ledger.transactions t join finance.pocket_transfers x on x.transaction_id = t.id),
  pg_temp.k()) $$, 'the President reverses the pocket move');
select is(pg_temp.mails(4, 'money.transaction_reversed'), 1, 'M13 to the member');
select is((select params->>'amount' from outbox.events where template = 'money.transaction_reversed'), '100.00',
  'the amount that moved, not the net zero');
select matches((select params->>'reverses' from outbox.events where template = 'money.transaction_reversed'), '^PTR-',
  'names the original reference');

-- ── NIN review task ──
insert into identity.nin_reviews (user_id, tenant_id, membership_id, nin_fingerprint, nin_last4, given_name, surname)
values (pg_temp.u(6), pg_temp.id('tenant'), pg_temp.m(6, pg_temp.id('T2')), repeat('e', 64), '1234', 'Ngozi', 'Eze');
select is(pg_temp.open_tasks(1, 'task.nin_review'), 1, 'the President gets the identity to review');
select is(pg_temp.items(3, 'task.nin_review'), 0, 'a Team Leader does not (Blueprint 06 Q4)');
select is((select count(*)::int from notify.items where kind = 'task.nin_review' and params::text ~ '1234'), 0,
  'never NIN digits');
update identity.nin_reviews set status = 'approved', decided_at = now(), decided_by = pg_temp.u(1),
  decision_reason = 'Matches the card' where user_id = pg_temp.u(6);
select is(pg_temp.open_tasks(1, 'task.nin_review'), 0, 'deciding clears it');
select is(pg_temp.items(6, 'identity.nin_review_decided'), 1, 'the older NIN email gets its bell item');

-- ── Role changed (A11), membership ended (A12), account status (A10) ──
select lives_ok($$ select api.change_membership_role(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(6, pg_temp.id('T2')),
  'team_leader', 'Leads the second team now', pg_temp.k()) $$, 'a role change');
select is(pg_temp.mails(6, 'account.role_changed'), 1, 'A11');
select is((select params->>'role' from outbox.events where template = 'account.role_changed'), 'team_leader', 'the new role');
select is(pg_temp.items(6, 'account.membership_ended'), 0, 'a role change is not an ended membership');
select lives_ok($$ select api.end_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(6, pg_temp.id('T2')),
  'Left the team', pg_temp.k()) $$, 'membership ended');
select is(pg_temp.mails(6, 'account.membership_ended'), 1, 'A12');
insert into audit.security_events (actor_user_id, action, target_user_id, safe_after)
values (pg_temp.u(9), 'account.status_changed', pg_temp.u(6), '{"status": "restricted"}');
select is((select tenant_id from notify.items where user_id = pg_temp.u(6) and kind = 'account.status_changed'), null,
  'A10 is personal (no network)');
select is((select params->>'status' from outbox.events where template = 'account.status_changed'), 'restricted', 'A10');

-- ── Personal items show in every workspace ──
select is((select count(*)::int from jsonb_array_elements(pg_temp.bell(4)->'items') x
  where x->>'kind' = 'payout_account.alert'), 1, 'the payout-account alert is in the bell');

-- ── Retention ──
insert into notify.items (user_id, tenant_id, kind, task, subject_type, subject_id, params, dedupe_key, created_at)
values (pg_temp.u(4), pg_temp.id('tenant'), 'money.income_posted', false, 'income', gen_random_uuid(), '{}', 'old-item',
  now() - interval '91 days');
insert into notify.items (user_id, tenant_id, kind, task, subject_type, subject_id, params, dedupe_key, created_at)
values (pg_temp.u(3), pg_temp.id('tenant'), 'task.withdrawal_approve', true, 'withdrawal',
  (select (r->>'withdrawalId')::uuid from w4), '{}', 'old-done-task', now() - interval '91 days');
create temp table w6 as select pg_temp.wd(4, '10.00') as r;
insert into notify.items (user_id, tenant_id, kind, task, subject_type, subject_id, params, dedupe_key, created_at)
values (pg_temp.u(3), pg_temp.id('tenant'), 'task.withdrawal_approve', true, 'withdrawal',
  (select (r->>'withdrawalId')::uuid from w6), '{}', 'old-open-task', now() - interval '91 days');
select is((api.outbox_run_maintenance()->>'prunedNotifications')::int, 2, 'items older than 90 days go');
select is((select count(*)::int from notify.items where dedupe_key = 'old-open-task'), 1, 'an open task stays until done');

-- ── Privileges ──
select ok(not has_schema_privilege('authenticated', 'notify', 'usage'), 'notify is private');
select ok(not has_function_privilege('authenticated', 'api.my_notifications(uuid, uuid, uuid, text, text, int)', 'execute'),
  'signed-in clients cannot call the read directly');
select ok(not has_function_privilege('anon', 'api.mark_notifications_read(uuid, uuid, uuid, uuid[], boolean)', 'execute'),
  'nor anonymous ones');
select ok(has_function_privilege('service_role', 'api.my_notification_count(uuid, uuid, uuid)', 'execute'),
  'the Edge Function can');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'notify' and p.prosecdef), 0, 'nothing in notify is security definer');

-- ── The badge poll is not activity ──
update identity.session_pin_proofs set last_activity_at = now() - interval '5 minutes' where user_id = pg_temp.u(3);
select lives_ok($$ select api.my_notification_count(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3)) $$, 'poll');
select ok((select last_activity_at < now() - interval '4 minutes' from identity.session_pin_proofs
  where user_id = pg_temp.u(3)), 'the poll leaves the idle timer alone');

select * from finish();
rollback;
