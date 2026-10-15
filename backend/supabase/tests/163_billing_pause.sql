-- Blueprint 16 — B6 163: reminders, expiry with no grace (trial and paid
-- year), the paused network (every catalogued money and organizational
-- write refused; reads, statements, reports and Billing kept; payouts for
-- withdrawals approved before the pause still recorded and completed) and
-- reactivation by payment with the year starting at payment.
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(45);

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
create function pg_temp.fails(p_sql text) returns text language plpgsql as $$
declare
  msg text;
  detail text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics msg = message_text, detail = pg_exception_detail;
  return msg || ':' || coalesce(case when detail like '{%' then detail::jsonb->>'reason' end, '');
end $$;
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
create function pg_temp.income(n int, p_key text) returns jsonb language sql volatile as $$
  select api.record_income(pg_temp.u(n), pg_temp.s(n), pg_temp.m(n), pg_temp.m(4, pg_temp.id('T')), 'NGN', '10000.00',
    'Fiverr', to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null,
    array[pg_temp.income_receipt(n, pg_temp.m(4, pg_temp.id('T')), p_key)], p_key)
$$;
create function pg_temp.proof(n int, p_kind text, p_target uuid, p_key text) returns uuid language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_entry_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_kind, p_target, p_key,
    'proof.pdf', 'application/pdf', 3000, repeat('d', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 3000, repeat('d', 64), 'application/pdf');
  return e;
end $$;
create function pg_temp.seg(n int, p_pocket text default 'Point Value') returns uuid language sql stable as $$
  select b.account_id from ledger.balances b join ledger.pockets p on p.id = b.pocket_id
  where b.owner_user_id = pg_temp.u(n) and p.name = p_pocket and b.currency = 'NGN'
$$;
create function pg_temp.wd(n int, p_amount text) returns jsonb language sql volatile as $$
  select api.request_withdrawal(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), pg_temp.seg(4), p_amount,
    pg_temp.id('A4'), 'Monthly upkeep', pg_temp.k())
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
create function pg_temp.finish(p_payout uuid) returns jsonb language plpgsql as $$
declare
  item jsonb;
  rev finance.payout_revisions;
begin
  select value into item from jsonb_array_elements(api.claim_payout_checks('test-worker', 10))
  where (value->>'payoutId')::uuid = p_payout;
  select r.* into rev from finance.payout_revisions r join finance.payouts p on p.id = r.payout_id and r.revision = p.revision
  where p.id = p_payout;
  return api.finish_payout_check((item->>'checkId')::uuid, (item->>'leaseToken')::uuid, 'match',
    jsonb_build_object('paymentDate', rev.paid_on::text, 'receipt', jsonb_build_object(
      'amount', trim_scale(rev.amount)::text, 'currency', 'NGN', 'recipientAccount', '0123456789',
      'recipientName', 'ADA OBI', 'paymentStatus', 'successful', 'confidence', 'high')),
    '{}'::text[], 'gpt-5-mini', 'strict-single-receipt-v1');
end $$;
create function pg_temp.sub() returns billing.subscriptions language sql stable as
  $$ select * from billing.subscriptions where tenant_id = pg_temp.id('tenant') $$;
create function pg_temp.ends_in(p_days int) returns void language sql as $$
  update billing.subscriptions
  set period_end = ((billing.today() + p_days)::timestamp at time zone billing.zone()) + interval '12 hours'
  where tenant_id = pg_temp.id('tenant')
$$;
create function pg_temp.items(p_kind text) returns int language sql stable as
  $$ select count(*)::int from notify.items where kind = p_kind and user_id = pg_temp.u(1) $$;

-- 1 President (founder, trial) · 2 Director (D) · 3 TL (T) · 4 member (T) · 7 reviewer (T) · 8 invitee
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 8) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
update auth.users set email_confirmed_at = now() where id = pg_temp.u(8);
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 8) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 8) n; end $$;
insert into ids select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Cedar Network', 'CDR', pg_temp.k(), null,
  'band_400', true)->>'tenantId')::uuid;
insert into ids select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', null,
  array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A',
  pg_temp.id('D'), array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(4), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(7), pg_temp.k());
  perform api.assign_reviewer(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(7, pg_temp.id('T')), 'Finance lead', pg_temp.k());
  perform pg_temp.income(1, 'k-income-0000000001');
end $$;
insert into payout.banks (provider, code, name, active) values ('paystack', '058', 'Guaranty Trust Bank', true);
insert into ids select 'A4', pg_temp.add_account(4, '058', '0123456789', 'ADA OBI');
insert into ids select 'w1', (pg_temp.wd(4, '1500.00')->>'withdrawalId')::uuid;
insert into ids select 'w2', (pg_temp.wd(4, '500.00')->>'withdrawalId')::uuid;
do $$ begin perform api.approve_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w1'), pg_temp.k()); end $$;
insert into ids select 'inv', (api.create_invitation(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), 'member',
  'u8@example.test', md5('tok-8')::uuid, encode(sha256(convert_to('tok-8', 'UTF8')), 'hex'), null, pg_temp.k())
  ->>'invitationId')::uuid;

-- ── Trial reminders (4) ──
select pg_temp.ends_in(2);
select billing.run_lifecycle();
select is(pg_temp.items('billing.renewal_reminder'), 1, 'B02 three days before the trial ends');
select billing.run_lifecycle();
select is(pg_temp.items('billing.renewal_reminder'), 1, 'once per day mark');
select is((select params->>'chip' from notify.items where kind = 'billing.renewal_reminder' and user_id = pg_temp.u(1)),
  'Trial ends soon', 'the trial chip');
select pg_temp.ends_in(4);
select billing.run_lifecycle();
select is(pg_temp.items('billing.renewal_reminder'), 1, 'no reminder five days out');

-- ── Expiry, no grace (6) ──
update billing.subscriptions set period_start = now() - interval '7 days', period_end = now() + interval '1 minute' where tenant_id = pg_temp.id('tenant');
select billing.run_lifecycle();
select is((pg_temp.sub()).status::text, 'trial', 'still open a minute before the end');
update billing.subscriptions set period_start = now() - interval '7 days', period_end = now() - interval '1 second' where tenant_id = pg_temp.id('tenant');
select is((billing.run_lifecycle()->>'paused')::int, 1, 'a second past the end it pauses');
select is((pg_temp.sub()).status::text, 'paused', 'paused');
select is((select status::text from org.tenants where id = pg_temp.id('tenant')), 'suspended', 'the network is suspended');
select is(pg_temp.items('billing.paused'), 1, 'B05 to the Billing Owner');
select is((billing.run_lifecycle()->>'paused')::int, 0, 'pausing happens once');

-- ── Every catalogued write is refused (14) ──
select is(pg_temp.fails($$ select pg_temp.income(1, 'k-income-0000000002') $$), 'network_not_active:', 'no new income');
select is(pg_temp.fails($$ select pg_temp.wd(4, '100.00') $$), 'network_not_active:', 'no new withdrawal');
select is(pg_temp.fails($$ select api.approve_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w2'), pg_temp.k()) $$),
  'network_not_active:', 'no approvals');
select is(pg_temp.fails($$ select api.cancel_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('w2'), null, pg_temp.k()) $$),
  'network_not_active:', 'no cancelling either');
select is(pg_temp.fails($$ select api.request_pocket_transfer(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.seg(4),
  (select pocket_id from ledger.balances where account_id = pg_temp.seg(4, 'Savings')), '10.00', pg_temp.k()) $$),
  'network_not_active:', 'no pocket moves');
select is(pg_temp.fails($$ select api.submit_conversion(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.seg(4), '10.00',
  'NGN', '0.01', '1525', 'Grey', to_char(now() - interval '1 hour', 'YYYY-MM-DD"T"HH24:MI:SSOF":00"'), 'GRY-1', null,
  array[pg_temp.proof(1, 'conversion', pg_temp.m(4, pg_temp.id('T')), 'k-conv-0000000001')], 'k-conv-0000000001') $$),
  'network_not_active:', 'no conversions');
select is(pg_temp.fails($$ select api.submit_adjustment(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.m(4, pg_temp.id('T')),
  'credit', 'NGN', '10.00', 'Goodwill credit from the network', null,
  array[pg_temp.proof(1, 'adjustment', pg_temp.m(4, pg_temp.id('T')), 'k-adj-00000000001')], 'k-adj-00000000001') $$),
  'network_not_active:', 'no adjustments');
select is(pg_temp.fails($$ select api.submit_returned_funds(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w1'), '10.00',
  to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF":00"'), 'Guaranty Trust Bank', 'RV-0001', null,
  array[pg_temp.proof(3, 'returned_funds', pg_temp.m(4, pg_temp.id('T')), 'k-ret-00000000001')], 'k-ret-00000000001') $$),
  'network_not_active:', 'no returned funds');
select is(pg_temp.fails($$ select api.reverse_transaction(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1),
  (select id from ledger.transactions where tenant_id = pg_temp.id('tenant') and type = 'income' limit 1),
  'recorded_twice', 'Same order recorded twice', 'x', pg_temp.k()) $$), 'network_not_active:', 'no reversals');
select is(pg_temp.fails($$ select api.create_invitation(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), 'member',
  'u9@example.test', md5('tok-9')::uuid, encode(sha256(convert_to('tok-9', 'UTF8')), 'hex'), null, pg_temp.k()) $$),
  'network_not_active:', 'no invitations');
select isnt(pg_temp.fails($$ select api.accept_invitation(pg_temp.u(8), pg_temp.s(8), null, pg_temp.id('inv'), pg_temp.k()) $$),
  'no error', 'a pending invitation cannot be accepted');
select is(pg_temp.fails($$ select api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team B',
  pg_temp.id('D'), array[pg_temp.uid(2)], pg_temp.k()) $$), 'network_not_active:', 'no organizational changes');
select is(pg_temp.fails($$ select api.create_access_assignment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(2),
  jsonb_build_array(jsonb_build_object('permission', 'approve_withdrawal', 'effect', 'allow',
    'scopeType', 'office_subtree', 'scopeOfficeId', pg_temp.id('T'))), 'Cover', pg_temp.k()) $$),
  'network_not_active:', 'no access changes');
select is(pg_temp.fails($$ select pg_temp.add_account(4, '058', '1122334455', 'ADA OBI') $$), 'network_not_active:',
  'no payout account changes');

-- ── Reads stay (8) ──
select is(jsonb_typeof(api.my_wallet(pg_temp.u(4), pg_temp.s(4))->'networks'), 'array', 'members still see their money');
select is(api.my_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('w2'))->>'status', 'requested',
  'their withdrawals');
select is(jsonb_typeof(api.list_payout_accounts(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4))), 'object', 'their payout accounts');
select is(api.withdrawal_detail(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w2'))->>'status', 'requested',
  'leaders still open a waiting request (a read that shares the approve check)');
select is(pg_temp.fails($$ select api.create_statement(pg_temp.u(4), pg_temp.s(4), pg_temp.id('tenant'), 'NGN', 'month',
  to_char(date_trunc('month', now()) - interval '1 month', 'YYYY-MM-DD'),
  to_char(date_trunc('month', now()) - interval '1 day', 'YYYY-MM-DD'), 'pdf', pg_temp.k()) $$), 'no error',
  'statements still work');
select is(pg_temp.fails($$ select api.list_members(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3)) $$), 'no error',
  'leaders keep their member lists');
select is(pg_temp.fails($$ select api.report_overview(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), 'NGN', 'month',
  to_char(date_trunc('month', now()) - interval '1 month', 'YYYY-MM-DD'),
  to_char(date_trunc('month', now()) - interval '1 day', 'YYYY-MM-DD')) $$), 'no error', 'and their reports');
select is(api.billing_overview(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1))->>'status', 'paused',
  'Billing shows the pay-to-resume view');

-- ── Approved before the pause: paid out (5) ──
select is((api.reveal_withdrawal_destination(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w1'))->>'accountLast4'),
  '6789', 'the approver can still see where to pay');
create temp table p1 as select api.record_payout(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w1'), '1500.00', null,
  to_char(now() at time zone 'Africa/Lagos', 'YYYY-MM-DD'), '000014261005', null,
  pg_temp.payout_receipt(3, pg_temp.id('w1'), 'k-payout-00000001'), 'k-payout-00000001') as r;
select is((select r->'payout'->>'status' from p1), 'verifying', 'the payout is recorded');
select is((pg_temp.finish((select (r->'payout'->>'payoutId')::uuid from p1))->>'status'), 'completed',
  'and completes after the receipt check');
select is((select status from finance.withdrawals where id = pg_temp.id('w1')), 'completed', 'the withdrawal is paid out');
select is(pg_temp.fails($$ select api.reveal_withdrawal_destination(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w2')) $$),
  'network_not_active:', 'a request approved after nothing stays waiting');

-- ── Reactivate by payment (5) ──
create temp table c1 as select api.billing_checkout(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'band_400', 'year', 'test',
  pg_temp.k()) as r;
select is((select r->>'purpose' from c1), 'reactivate', 'paying a paused network reactivates it');
select is((api.billing_apply_verified((select r->>'providerReference' from c1), 70000000, 'NGN', now(), 1, 'CUS_x0001', false,
  'test')->>'outcome'), 'applied', 'applied');
select is((pg_temp.sub()).period_start, now(), 'the year starts at payment');
select is((select status::text from org.tenants where id = pg_temp.id('tenant')), 'active', 'the network is active again');
select is(pg_temp.fails($$ select api.approve_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w2'), pg_temp.k()) $$),
  'no error', 'waiting requests can move again');

-- ── Paid year: reminders and expiry (3) ──
select pg_temp.ends_in(6);
select billing.run_lifecycle();
select is((select count(*)::int from notify.items where kind = 'billing.renewal_reminder' and user_id = pg_temp.u(1)
  and params->>'chip' = 'Renews soon'), 1, 'B02 seven days before a renewal');
update billing.subscriptions set period_start = now() - interval '1 year', period_end = now() - interval '1 second' where tenant_id = pg_temp.id('tenant');
select is((billing.run_lifecycle()->>'paused')::int, 1, 'a paid year ends with no grace too');
select is((select status::text from org.tenants where id = pg_temp.id('tenant')), 'suspended', 'suspended again');

select * from finish();
rollback;
