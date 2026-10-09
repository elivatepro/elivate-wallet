-- Blueprint 12 — B6 124: the payout fix keeps its receipt (Paper U03); the new
-- tables stay private, the new functions are service-only or invoker helpers.
begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

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

insert into payout.banks (provider, code, name, active) values ('paystack', '058', 'Guaranty Trust Bank', true);
insert into ids select 'A4', pg_temp.add_account(4, '058', '0123456789', 'ADA OBI');

create function pg_temp.mismatch(p_payout uuid) returns jsonb language plpgsql as $$
declare
  item jsonb;
  rev finance.payout_revisions;
begin
  select value into item from jsonb_array_elements(api.claim_payout_checks('test-worker', 10))
  where (value->>'payoutId')::uuid = p_payout;
  select r.* into rev from finance.payout_revisions r join finance.payouts p on p.id = r.payout_id and r.revision = p.revision
  where p.id = p_payout;
  return api.finish_payout_check((item->>'checkId')::uuid, (item->>'leaseToken')::uuid, 'mismatch',
    jsonb_build_object('paymentDate', (rev.paid_on - 1)::text, 'receipt', jsonb_build_object(
      'amount', trim_scale(rev.amount)::text, 'currency', 'NGN', 'recipientAccount', '0123456789',
      'recipientName', 'ADA OBI', 'paymentStatus', 'successful', 'confidence', 'high')),
    array['paymentDate_mismatch'], 'gpt-5-mini', 'strict-single-receipt-v1');
end $$;

insert into ids select 'w', (api.request_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.seg(4),
  '2000.00', pg_temp.id('A4'), pg_temp.k())->>'withdrawalId')::uuid;
do $$
declare
  key text := 'k-pay-000000000001';
begin
  perform api.approve_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w'), pg_temp.k());
  perform api.record_payout(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w'), '2000.00', null,
    to_char(now() at time zone 'Africa/Lagos', 'YYYY-MM-DD'), '000014261005', null,
    pg_temp.payout_receipt(3, pg_temp.id('w'), key), key);
end $$;
insert into ids select 'p', id from finance.payouts where withdrawal_id = pg_temp.id('w');
select pg_temp.mismatch(pg_temp.id('p'));

-- ── The one fix keeps the receipt (U03) (6) ──
select is((select status from finance.payouts where id = pg_temp.id('p')), 'correction_required',
  'a first mismatch asks for the one fix');
create temp table fix as select api.correct_payout(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('p'),
  '2000.00', null, to_char(now() at time zone 'Africa/Lagos', 'YYYY-MM-DD'), '000014261005', null, null,
  'k-fix-000000000001') as r;
select is((select r->'payout'->>'revision' from fix), '2', 'the fix is the second revision');
select is((select count(distinct evidence_id)::int from finance.payout_revisions where payout_id = pg_temp.id('p')), 1,
  'both revisions use the same receipt');
select is((select c.status from finance.payout_checks c join finance.payout_revisions r on r.id = c.revision_id
  where r.payout_id = pg_temp.id('p') and r.revision = 2), 'queued', 'the receipt is checked again');
select is((api.correct_payout(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('p'), '2000.00', null,
  to_char(now() at time zone 'Africa/Lagos', 'YYYY-MM-DD'), '000014261005', null, null,
  'k-fix-000000000001')->>'replayed')::boolean, true, 'the fix replays');
select is(pg_temp.fails($$ select api.correct_payout(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('p'),
  '2000.00', null, to_char(now() at time zone 'Africa/Lagos', 'YYYY-MM-DD'), null, null, null, pg_temp.k()) $$),
  'conflict:payout_state', 'only one fix');

-- ── Privileges (5) ──
select ok(
  not exists (
    select 1 from unnest(array['entries', 'entry_lines', 'reversals']) t
    where has_table_privilege('anon', format('finance.%I', t), 'select')
       or has_table_privilege('authenticated', format('finance.%I', t), 'select')
       or has_table_privilege('authenticated', format('finance.%I', t), 'insert')
  ),
  'the new finance tables are not reachable by anon or authenticated'
);
select ok(
  (select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'finance' and c.relname in ('entries', 'entry_lines', 'reversals')),
  'row level security is on for every new table'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('api', 'finance', 'ledger')
      and p.proname in ('create_entry_evidence_upload', 'entry_targets', 'entry_segments', 'submit_conversion',
        'submit_adjustment', 'returnable_withdrawal', 'submit_returned_funds', 'review_entry', 'entry_evidence',
        'reversal_preview', 'reverse_transaction')
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')
           or not has_function_privilege('service_role', p.oid, 'execute'))
  ),
  'the new api functions are service-only'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('finance', 'ledger') and p.prosecdef
      and p.proname in ('entry_json', 'entry_case_json', 'post_entry', 'returnable_json', 'reversal_json',
        'take_entry_evidence', 'in_effect', 'withdrawal_debit', 'returned_total', 'transaction_by_reference')
  ),
  'the new helpers are not definer'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('api', 'finance', 'ledger')
      and p.proname ~ '(entry|entries|conversion|adjustment|returned|returnable|reversal|reverse_|in_effect|rate)'
      and not coalesce(p.proconfig @> array['search_path=""'], false)
  ),
  'every new function pins an empty search_path'
);

select * from finish();
rollback;
