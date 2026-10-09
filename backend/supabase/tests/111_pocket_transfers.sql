-- Blueprint 11 — B7 111: pocket moves (W-13): request and hold, approve
-- and post, reject, cancel, Debt limits, lists and activity.
begin;
create extension if not exists pgtap with schema extensions;
select plan(29);

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


create function pg_temp.pocket(p_name text) returns uuid language sql stable as
  $$ select id from ledger.pockets where tenant_id = pg_temp.id('tenant') and name = p_name $$;
create function pg_temp.acct(n int, p_name text) returns uuid language sql stable as $$
  select b.account_id from ledger.balances b where b.owner_user_id = pg_temp.u(n) and b.pocket_id = pg_temp.pocket(p_name)
    and b.currency = 'NGN'
$$;
create function pg_temp.bal(n int, p_name text) returns numeric language sql stable as
  $$ select posted from ledger.balances where account_id = pg_temp.acct(n, p_name) $$;
create function pg_temp.mv(n int, p_from text, p_to text, p_amount text, p_key text default null) returns jsonb
language sql volatile as $$
  select api.request_pocket_transfer(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), pg_temp.acct(4, p_from),
    pg_temp.pocket(p_to), p_amount, coalesce(p_key, pg_temp.k()))
$$;

-- ── Request (7) ──
create temp table t1 as select pg_temp.mv(4, 'Point Value', 'Savings', '500.00', 'k-move-00000000001') as r;
insert into ids select 't1', (r->>'transferId')::uuid from t1;
select is((select r->>'status' from t1), 'requested', 'a pocket move is requested');
select matches((select r->>'reference' from t1), '^PTR-', 'PTR reference');
select is((select posted - reserved from ledger.balances where account_id = pg_temp.acct(4, 'Point Value')), 3500.00::numeric,
  'the source is held at once');
select is((pg_temp.mv(4, 'Point Value', 'Savings', '500.00', 'k-move-00000000001')->>'replayed')::boolean, true, 'same key replays');
select is((select count(*)::int from finance.pocket_transfers), 1, 'one move only');
select throws_ok($$ select pg_temp.mv(4, 'Point Value', 'Point Value', '1.00') $$, 'P0001', 'validation_error', 'pockets must differ');
select throws_ok($$ select pg_temp.mv(4, 'Point Value', 'Savings', '3500.01') $$, 'P0001', 'insufficient_funds', 'no more than available');

-- ── Approve (7) ──
select throws_ok($$ select api.approve_pocket_transfer(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('t1'), pg_temp.k()) $$,
  'P0001', 'self_target_forbidden', 'nobody approves their own move');
select throws_ok($$ select api.approve_pocket_transfer(pg_temp.u(5), pg_temp.s(5), pg_temp.ws(5), pg_temp.id('t1'), pg_temp.k()) $$,
  'P0001', 'authorization_denied', 'a sibling Team Leader cannot approve');
select is((api.approve_pocket_transfer(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('t1'), pg_temp.k())->>'status'),
  'completed', 'approval posts at once');
select is(pg_temp.bal(4, 'Point Value'), 3500.00::numeric, 'the source is debited');
select is(pg_temp.bal(4, 'Savings'), 1500.00::numeric, 'the destination is credited');
select is((select reserved from ledger.balances where account_id = pg_temp.acct(4, 'Point Value')), 0::numeric, 'the hold is consumed');
select is((select count(*)::int from ledger.verify_balances()), 0, 'no projection drift');

-- ── Reject, cancel (5) ──
create temp table t2 as select pg_temp.mv(4, 'Upkeep', 'Savings', '100.00') as r;
insert into ids select 't2', (r->>'transferId')::uuid from t2;
select is((api.reject_pocket_transfer(pg_temp.u(2), pg_temp.s(2), pg_temp.ws(2), pg_temp.id('t2'), 'Keep it in Upkeep', pg_temp.k())->>'status'),
  'rejected', 'the Director rejects with a reason');
select is((select reserved from ledger.balances where account_id = pg_temp.acct(4, 'Upkeep')), 0::numeric, 'rejection releases the hold');
create temp table t3 as select pg_temp.mv(4, 'Upkeep', 'Savings', '100.00') as r;
insert into ids select 't3', (r->>'transferId')::uuid from t3;
select throws_ok($$ select api.cancel_pocket_transfer(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('t3'), pg_temp.k()) $$,
  'P0001', 'not_found', 'a leader rejects, not cancels');
select is((api.cancel_pocket_transfer(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('t3'), pg_temp.k())->>'status'),
  'cancelled', 'the member cancels');
select is(pg_temp.fails($$ select api.approve_pocket_transfer(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('t3'), pg_temp.k()) $$),
  'conflict:transfer_state', 'a cancelled move cannot be approved');

-- ── Debt (4) ──
select throws_ok($$ select api.request_pocket_transfer(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4),
  (select account_id from ledger.balances b join ledger.pockets p on p.id = b.pocket_id
   where b.owner_user_id = pg_temp.u(4) and p.kind = 'debt' and b.currency = 'NGN'),
  pg_temp.pocket('Savings'), '1.00', pg_temp.k()) $$, 'P0001', 'not_found', 'Debt has no segment yet');
select is(pg_temp.fails($$ select pg_temp.mv(4, 'Savings', 'Debt', '1.00') $$), 'conflict:debt_limit',
  'Debt receives only up to zero');
-- A debt of 250 (stand-in for a later adjustment slice).
insert into ids select 'debt', ledger.segment_account(
  (select id from ledger.wallets where owner_user_id = pg_temp.u(4)), pg_temp.m(4, pg_temp.id('T')), 'NGN', pg_temp.pocket('Debt'));
set local session_replication_role = replica;
update ledger.balances set posted = -250 where account_id = pg_temp.id('debt');
set local session_replication_role = origin;
select is(pg_temp.fails($$ select pg_temp.mv(4, 'Savings', 'Debt', '250.01') $$), 'conflict:debt_limit', 'not past zero');
select is((pg_temp.mv(4, 'Savings', 'Debt', '250.00')->>'status'), 'requested', 'up to the deficit is fine');

-- ── Lists and activity (6) ──
select is((api.transfer_queue(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), 'waiting', null, null)->'counts'->>'open'), '1',
  'the Team Leader sees the waiting move');
select throws_ok($$ select api.transfer_queue(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), 'waiting', null, null) $$,
  'P0001', 'authorization_denied', 'members have no transfer queue');
select is((api.my_pocket_transfers(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), null, null, null)->'counts'->>'all'), '4',
  'the member sees their moves');
select is((select jsonb_array_length(api.transfer_choices(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4))->'groups')), 1,
  'choices: one membership and currency');
select is((select i->>'movedAmount' from jsonb_array_elements(api.my_activity(pg_temp.u(4), pg_temp.s(4),
  p_type => 'pocket_transfer')->'items') i), '500.00', 'activity shows the moved amount');
select is((select i->>'title' from jsonb_array_elements(api.my_activity(pg_temp.u(4), pg_temp.s(4),
  p_type => 'pocket_transfer')->'items') i), 'Point Value → Savings', 'and both pockets');

select * from finish();
rollback;
