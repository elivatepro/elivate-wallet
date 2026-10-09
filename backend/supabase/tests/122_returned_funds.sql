-- Blueprint 12 — B6 122: returned funds (W-16): same pocket, never more than
-- what left (sent + fee) minus returns, pending returns count, review, posting.
begin;
create extension if not exists pgtap with schema extensions;
select plan(18);

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
create function pg_temp.income_receipt(n int, p_target uuid, p_key text) returns uuid language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_target, p_key, 'r.pdf',
    'application/pdf', 1000, repeat('b', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 1000, repeat('b', 64), 'application/pdf');
  return e;
end $$;
-- Evidence for an entry of `p_kind`, uploaded by n for the target membership.
create function pg_temp.proof(n int, p_kind text, p_target uuid, p_key text) returns uuid language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_entry_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_kind, p_target, p_key,
    'proof.pdf', 'application/pdf', 3000, repeat('d', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 3000, repeat('d', 64), 'application/pdf');
  return e;
end $$;
-- The segment of member n in a currency and pocket.
create function pg_temp.seg(n int, p_currency text default 'NGN', p_pocket text default 'Point Value') returns uuid
language sql stable as $$
  select b.account_id from ledger.balances b join ledger.pockets p on p.id = b.pocket_id
  where b.owner_user_id = pg_temp.u(n) and p.name = p_pocket and b.currency = p_currency
$$;
create function pg_temp.avail(n int, p_currency text default 'NGN', p_pocket text default 'Point Value')
returns numeric language sql stable as
  $$ select posted - reserved from ledger.balances where account_id = pg_temp.seg(n, p_currency, p_pocket) $$;
create function pg_temp.posted(n int, p_currency text default 'NGN', p_pocket text default 'Point Value')
returns numeric language sql stable as
  $$ select posted from ledger.balances where account_id = pg_temp.seg(n, p_currency, p_pocket) $$;
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
create function pg_temp.review(n int, p_entry uuid, p_decision text, p_key text default null) returns jsonb
language sql volatile as $$
  select api.review_entry(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_entry, p_decision, 'Checked the statement',
    coalesce(p_key, pg_temp.k()))
$$;

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
  -- Member 4: ₦10,000 and $1,000 of income (Point Value gets 40%).
  perform api.record_income(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(4, pg_temp.id('T')), 'NGN', '10000.00',
    'Fiverr', to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null,
    array[pg_temp.income_receipt(1, pg_temp.m(4, pg_temp.id('T')), 'k-income-0000000001')], 'k-income-0000000001');
  perform api.record_income(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(4, pg_temp.id('T')), 'USD', '1000.00',
    'Upwork', to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null,
    array[pg_temp.income_receipt(1, pg_temp.m(4, pg_temp.id('T')), 'k-income-0000000002')], 'k-income-0000000002');
end $$;
insert into ids select 'm4', pg_temp.m(4, pg_temp.id('T'));

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
create function pg_temp.payout_receipt(n int, p_withdrawal uuid, p_key text) returns uuid language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_payout_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_withdrawal, p_key, 'pay.pdf',
    'application/pdf', 2000, repeat('c', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 2000, repeat('c', 64), 'application/pdf');
  return e;
end $$;
-- Worker stand-in: claims and finishes the ready check of a payout with a match.
create function pg_temp.match(p_payout uuid) returns jsonb language plpgsql as $$
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
create function pg_temp.give_back(n int, p_amount text, p_key text default null) returns jsonb language plpgsql as $$
declare
  key text := coalesce(p_key, pg_temp.k());
begin
  return api.submit_returned_funds(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), pg_temp.id('w'), p_amount,
    to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF":00"'), 'Guaranty Trust Bank', 'RV-0001', null,
    array[pg_temp.proof(n, 'returned_funds', pg_temp.id('m4'), key)], key);
end $$;

insert into payout.banks (provider, code, name, active) values ('paystack', '058', 'Guaranty Trust Bank', true);
insert into ids select 'A4', pg_temp.add_account(4, '058', '0123456789', 'ADA OBI');
-- Member 4 withdraws ₦2,000 from Point Value; ₦1,950 is sent with a ₦50 fee.
insert into ids select 'w', (api.request_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.seg(4),
  '2000.00', pg_temp.id('A4'), pg_temp.k())->>'withdrawalId')::uuid;
do $$
declare
  key text := pg_temp.k();
begin
  perform api.approve_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w'), pg_temp.k());
  perform api.record_payout(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w'), '1950.00', '50.00',
    to_char(now() at time zone 'Africa/Lagos', 'YYYY-MM-DD'), '000014261005', null,
    pg_temp.payout_receipt(3, pg_temp.id('w'), key), key);
  perform pg_temp.match((select id from finance.payouts where withdrawal_id = pg_temp.id('w')));
end $$;

-- ── Before (3) ──
select is((select status from finance.withdrawals where id = pg_temp.id('w')), 'completed', 'the payout completed');
select is(pg_temp.posted(4), 2000.00::numeric, '₦2,000 left Point Value (sent + fee)');
select is(api.returnable_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w'))->>'remaining',
  '2000.00', 'everything that left is returnable');

-- ── Submit (8) ──
create temp table r1 as select pg_temp.give_back(3, '1500.00', 'k-rtn-000000000001') as r;
insert into ids select 'r1', (r->>'entryId')::uuid from r1;
select is((select r->>'status' from r1), 'needs_review', 'returned funds wait for review');
select matches((select r->>'reference' from r1), '^RTN-', 'RTN reference');
select is((select r->'pocket'->>'name' from r1), 'Point Value', 'it goes back to the pocket it left');
select is((select r->'returnable'->>'remaining' from r1), '500.00', 'a pending return counts against the rest');
select is(pg_temp.fails($$ select pg_temp.give_back(3, '500.01') $$), 'conflict:exceeds_returnable',
  'never more than what is left');
select throws_ok($$ select pg_temp.give_back(5, '10.00') $$, 'P0001', 'authorization_denied',
  'a sibling Team Leader cannot record it');
select throws_ok($$ select pg_temp.give_back(4, '10.00') $$, 'P0001', 'self_target_forbidden',
  'nobody records a return to their own wallet');
select is(pg_temp.posted(4), 2000.00::numeric, 'nothing posts before review');

-- ── Review and posting (5) ──
select is((pg_temp.review(7, pg_temp.id('r1'), 'clear')->>'status'), 'posted', 'the reviewer clears it');
select is(pg_temp.posted(4), 3500.00::numeric, 'the money is back in Point Value');
select is((select status from finance.withdrawals where id = pg_temp.id('w')), 'completed',
  'the withdrawal stays completed');
create temp table r2 as select pg_temp.give_back(3, '500.00') as r;
select is((pg_temp.review(7, (select (r->>'entryId')::uuid from r2), 'clear')->>'status'), 'posted',
  'a second partial return posts');
select is(pg_temp.fails($$ select pg_temp.give_back(3, '0.01') $$), 'conflict:exceeds_returnable',
  'nothing more once it is all back');

-- ── Ledger (2) ──
select is((select count(*)::int from ledger.verify_balances()), 0, 'projections match the ledger');
select is((select count(*)::int from jsonb_array_elements(api.my_activity(pg_temp.u(4), pg_temp.s(4),
  p_type => 'returned_funds')->'items')), 2, 'activity shows both returns');

select * from finish();
rollback;
