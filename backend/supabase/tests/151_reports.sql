-- Blueprint 15 — B6 151: leadership reports (W-18). Scope and permission,
-- excluded people, the actor's own wallet left out, one member, money held
-- reconciled by movement type, withdrawals by lifecycle, memberships vs
-- people, separate currencies, the live Reports page, no other network.
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(30);

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
create function pg_temp.receipt(n int, p_ws uuid, p_target uuid, p_key text) returns uuid language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_evidence_upload(pg_temp.u(n), pg_temp.s(n), p_ws, p_target, p_key, 'r.pdf',
    'application/pdf', 1000, repeat('b', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), p_ws, e, 1000, repeat('b', 64), 'application/pdf');
  return e;
end $$;
create function pg_temp.income(n int, p_ws uuid, p_target uuid, p_currency text, p_amount text, p_source text)
returns uuid language plpgsql as $$
declare
  key text := pg_temp.k();
begin
  perform api.record_income(pg_temp.u(n), pg_temp.s(n), p_ws, p_target, p_currency, p_amount, p_source,
    to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null,
    array[pg_temp.receipt(n, p_ws, p_target, key)], key);
  return (select transaction_id from finance.income_records where source = p_source);
end $$;
create function pg_temp.seg(n int) returns uuid language sql stable as $$
  select b.account_id from ledger.balances b join ledger.pockets p on p.id = b.pocket_id
  where b.owner_user_id = pg_temp.u(n) and p.name = 'Point Value' and b.currency = 'NGN'
$$;
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
create function pg_temp.run(p_worker text default 'w-test') returns jsonb language plpgsql as $$
declare
  job jsonb := api.export_claim(p_worker)->'job';
  prepared jsonb;
begin
  if job is null then
    return null;
  end if;
  prepared := api.export_prepare((job->>'exportId')::uuid, p_worker);
  return prepared || jsonb_build_object('exportId', job->>'exportId');
end $$;
create function pg_temp.report(n int, p_kind text, p_member int default null, p_currency text default 'NGN')
returns uuid language sql volatile as $$
  select (api.create_report(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_kind,
    case when p_member is not null then (select id from ledger.wallets where owner_user_id = pg_temp.u(p_member)) end,
    p_currency, 'custom',
    to_char((now() at time zone 'Africa/Lagos')::date - 1, 'YYYY-MM-DD'),
    to_char((now() at time zone 'Africa/Lagos')::date, 'YYYY-MM-DD'), pg_temp.k())->>'exportId')::uuid
$$;
create function pg_temp.held(p_summary jsonb, p_kind text) returns text language sql immutable as
  $$ select h->>'amount' from jsonb_array_elements(p_summary->'held') h where h->>'kind' = p_kind $$;
create function pg_temp.stage(p_summary jsonb, p_stage text) returns int language sql immutable as
  $$ select (w->>'count')::int from jsonb_array_elements(p_summary->'withdrawals') w where w->>'stage' = p_stage $$;

-- 1 President · 2 Director (D) · 3 TL (T, under D) · 4 member (T) · 5 TL (T2, under D) · 6 member (T2)
-- 7 member (T and T2: two memberships, one person) · 8 other founder · 9 admin · 10 other network member
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 11) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 11) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 11) n; end $$;
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
insert into ids
select 'X', (api.create_office(pg_temp.u(8), pg_temp.s(8), pg_temp.m(8), 'team_leader', 'Abuja Team', null, array[pg_temp.uid(11)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(4), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), pg_temp.uid(6), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(7), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), pg_temp.uid(7), pg_temp.k());
  perform api.add_membership(pg_temp.u(8), pg_temp.s(8), pg_temp.m(8), pg_temp.id('X'), pg_temp.uid(10), pg_temp.k());
end $$;

-- Income: 4 ₦10,000 · 6 ₦30,000 · 7 ₦5,000 in each office · TL 3's own ₦8,000 · 4 $200 · Abuja 10 ₦90,000.
-- A reversal of 6's income; 4 requests three withdrawals: approved, rejected, cancelled.
do $$ begin
  perform pg_temp.income(1, pg_temp.m(1), pg_temp.m(4, pg_temp.id('T')), 'NGN', '10000.00', 'Four NGN');
  perform pg_temp.income(1, pg_temp.m(1), pg_temp.m(6, pg_temp.id('T2')), 'NGN', '30000.00', 'Six NGN');
  perform pg_temp.income(1, pg_temp.m(1), pg_temp.m(7, pg_temp.id('T')), 'NGN', '5000.00', 'Seven A');
  perform pg_temp.income(1, pg_temp.m(1), pg_temp.m(7, pg_temp.id('T2')), 'NGN', '5000.00', 'Seven B');
  perform pg_temp.income(1, pg_temp.m(1), pg_temp.m(3, pg_temp.id('T')), 'NGN', '8000.00', 'Leader own');
  perform pg_temp.income(1, pg_temp.m(1), pg_temp.m(4, pg_temp.id('T')), 'USD', '200.00', 'Four USD');
  perform pg_temp.income(8, pg_temp.m(8), pg_temp.m(10, pg_temp.id('X')), 'NGN', '90000.00', 'Abuja NGN');
  perform api.reverse_transaction(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1),
    (select transaction_id from finance.income_records where source = 'Six NGN'), 'wrong_amount', 'Recorded the wrong amount',
    (select t.reference from ledger.transactions t join finance.income_records i on i.transaction_id = t.id where i.source = 'Six NGN'),
    pg_temp.k());
end $$;
insert into payout.banks (provider, code, name, active) values ('paystack', '058', 'Guaranty Trust Bank', true);
insert into ids select 'A4', pg_temp.add_account(4, '058', '0123456789', 'ADA OBI');
insert into ids select 'w1', (api.request_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.seg(4), '1000.00',
  pg_temp.id('A4'), pg_temp.k())->>'withdrawalId')::uuid;
insert into ids select 'w2', (api.request_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.seg(4), '700.00',
  pg_temp.id('A4'), pg_temp.k())->>'withdrawalId')::uuid;
insert into ids select 'w3', (api.request_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.seg(4), '300.00',
  pg_temp.id('A4'), pg_temp.k())->>'withdrawalId')::uuid;
do $$ begin
  perform api.approve_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w1'), pg_temp.k());
  perform api.reject_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w2'), 'Wrong pocket', pg_temp.k());
  perform api.cancel_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('w3'), null, pg_temp.k());
end $$;
-- Everything above happened an hour ago, so a period ending now includes it.
do $$ begin
  set local session_replication_role = replica;
  update ledger.transactions set posted_at = posted_at - interval '1 hour';
  update ledger.reservations set created_at = created_at - interval '1 hour',
    settled_at = settled_at - interval '1 hour';
  update finance.withdrawals set created_at = created_at - interval '1 hour', approved_at = approved_at - interval '1 hour',
    decided_at = decided_at - interval '1 hour';
  update org.memberships set started_at = started_at - interval '1 hour';
  set local session_replication_role = origin;
end $$;

-- ── Who may ask (4) ──
select throws_ok($$ select pg_temp.report(4, 'office_pdf') $$, 'P0001', 'authorization_denied',
  'a member has no scoped reports');
select is(pg_temp.fails($$ select pg_temp.report(3, 'office_pdf', 6) $$), 'not_found:',
  'one member must be inside the leader''s scope');
select is(pg_temp.fails($$ select pg_temp.report(3, 'office_pdf', 3) $$), 'not_found:',
  'a leader cannot pick their own wallet');
select is(pg_temp.fails($$ select pg_temp.report(3, 'monthly_pdf') $$), 'validation_error:', 'unknown report kind');

-- ── Team A office report by its Team Leader (9) ──
insert into ids select 'ta', pg_temp.report(3, 'office_pdf');
select is((pg_temp.run()->>'status'), 'rendering', 'prepared');
create temp table ta as select summary as s from exports.files where id = pg_temp.id('ta');
select is((select s->>'closing' from ta), '15000.00', 'Team A holds member 4''s and member 7''s Team A money, not the leader''s');
select is((select pg_temp.held(s, 'income') from ta), '15000.00', 'income posted in scope');
select is((select s->>'opening' from ta)::numeric + (select sum((h->>'amount')::numeric) from ta, jsonb_array_elements(s->'held') h),
  (select (s->>'closing')::numeric from ta), 'opening + every movement = closing');
select is((select s->>'reserved' from ta), '1000.00', 'reserved: the approved withdrawal still waiting to be paid');
select is((select pg_temp.stage(s, 'requested') from ta), 3, 'three withdrawals requested');
select ok((select pg_temp.stage(s, 'approved') = 1 and pg_temp.stage(s, 'rejected') = 1 and pg_temp.stage(s, 'cancelled') = 1
  and pg_temp.stage(s, 'completed') = 0 from ta), 'approved, not approved, cancelled and completed are counted apart');
select is((select (s->'counts'->>'activeMemberships')::int from ta), 2, 'two memberships in Team A (leader excluded)');
select is((select s->>'excludedPeople' from ta), '0', 'nobody in Team A is hidden from its leader');

-- ── Member rows (3) ──
select is((select row_count from exports.files where id = pg_temp.id('ta')), 2, 'one row per person');
select is((select data->'member'->>'uid' from exports.rows where file_id = pg_temp.id('ta') and seq = 1), pg_temp.uid(4),
  'largest income first');
select is((select data->>'reserved' from exports.rows where file_id = pg_temp.id('ta') and seq = 1), '1000.00',
  'with their reserved amount');

-- ── Director's scope covers both teams; memberships vs people (5) ──
insert into ids select 'dir', pg_temp.report(2, 'member_balances_csv');
select pg_temp.run();
create temp table dr as select summary as s from exports.files where id = pg_temp.id('dir');
select is((select (s->'counts'->>'activeMemberships')::int from dr), 6, 'six memberships under Ikeja (both leaders and members)');
select is((select (s->'counts'->>'people')::int from dr), 5, 'five distinct people: member 7 counts once');
select is((select pg_temp.held(s, 'reversal') from dr), '-30000.00', 'the reversal is its own line');
select is((select s->>'netIncome' from dr), '28000.00', 'net income = income less income reversals');
select is((select count(*)::int from exports.rows where file_id = pg_temp.id('dir')), 4,
  'member balances: one row per person (the leaders'' own money is visible to the Director)');

-- ── One member; transactions; other currency; other network (5) ──
insert into ids select 'one', pg_temp.report(3, 'transactions_csv', 4);
select pg_temp.run();
select ok((select bool_and(data->'member'->>'uid' = pg_temp.uid(4)) from exports.rows where file_id = pg_temp.id('one')),
  'one member: only their movements');
select is((select row_count from exports.files where id = pg_temp.id('one')), 1, 'member 4 has one NGN movement');
insert into ids select 'usd', pg_temp.report(3, 'office_pdf', null, 'USD');
select pg_temp.run();
select is((select summary->>'closing' from exports.files where id = pg_temp.id('usd')), '200.00', 'USD is reported apart');
insert into ids select 'pres', pg_temp.report(1, 'transactions_csv');
select pg_temp.run();
select is((select count(*)::int from exports.rows where file_id = pg_temp.id('pres')
  and data->>'reference' in (select t.reference from ledger.transactions t where t.tenant_id = pg_temp.id('other'))), 0,
  'no other network''s movements, even for the President');
select is((select count(*)::int from exports.rows where file_id = pg_temp.id('pres')), 6,
  'the President sees every NGN movement in the network');

-- ── Reports page (4) ──
create temp table ov as select api.report_overview(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), 'NGN', 'custom',
  to_char((now() at time zone 'Africa/Lagos')::date - 1, 'YYYY-MM-DD'),
  to_char((now() at time zone 'Africa/Lagos')::date, 'YYYY-MM-DD')) as o;
select is((select pg_temp.held(o, 'income') from ov), '15000.00', 'the page totals match the report');
select is((select jsonb_array_length(o->'members'->'top') from ov), 2, 'top members listed');
select is((select (o->>'canExport')::boolean from ov), true, 'and the leader may export');
select throws_ok($$ select api.report_overview(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), 'NGN', 'month',
  to_char(date_trunc('month', now() at time zone 'Africa/Lagos'), 'YYYY-MM-DD'),
  to_char(date_trunc('month', now() at time zone 'Africa/Lagos') + interval '1 month - 1 day', 'YYYY-MM-DD')) $$,
  'P0001', 'authorization_denied', 'members have no Reports page');

select * from finish();
rollback;
