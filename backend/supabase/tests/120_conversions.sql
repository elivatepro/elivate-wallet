-- Blueprint 12 — B6 120: conversions (W-12): submit with evidence and hold,
-- refusals, independent review (W-11), two-journal posting, rejection.
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(33);

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
  -- Member 4: ₦10,000 and $1,000 of income (Point Value gets 40%).
  perform api.record_income(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(4, pg_temp.id('T')), 'NGN', '10000.00',
    'Fiverr', to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null,
    array[pg_temp.income_receipt(1, pg_temp.m(4, pg_temp.id('T')), 'k-income-0000000001')], 'k-income-0000000001');
  perform api.record_income(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(4, pg_temp.id('T')), 'USD', '1000.00',
    'Upwork', to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null,
    array[pg_temp.income_receipt(1, pg_temp.m(4, pg_temp.id('T')), 'k-income-0000000002')], 'k-income-0000000002');
end $$;
insert into ids select 'm4', pg_temp.m(4, pg_temp.id('T'));

create function pg_temp.convert(n int, p_amount text, p_received text, p_key text default null,
  p_currency text default 'NGN', p_with_proof boolean default true) returns jsonb language plpgsql as $$
declare
  key text := coalesce(p_key, pg_temp.k());
begin
  return api.submit_conversion(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), pg_temp.seg(4, 'USD'), p_amount,
    p_currency, p_received, '1525', 'Grey', to_char(now() - interval '1 hour', 'YYYY-MM-DD"T"HH24:MI:SSOF":00"'),
    'GRY-1', null,
    case when p_with_proof then array[pg_temp.proof(n, 'conversion', pg_temp.id('m4'), key)] end, key);
end $$;

-- ── Submit and hold (9) ──
select is(pg_temp.avail(4, 'USD'), 400.00::numeric, 'USD Point Value holds 40% of $1,000');
create temp table c1 as select pg_temp.convert(3, '100.00', '152000.00', 'k-cnv-000000000001') as r;
insert into ids select 'c1', (r->>'entryId')::uuid from c1;
select is((select r->>'status' from c1), 'needs_review', 'a conversion waits for review');
select matches((select r->>'reference' from c1), '^CNV-', 'CNV reference');
select is((select r->'conversion'->>'effectiveRate' from c1), '1520.000000', 'effective rate in NGN per $1');
select is((select r->'conversion'->>'quotedRate' from c1), '1525', 'the quoted rate is kept');
select is(pg_temp.avail(4, 'USD'), 300.00::numeric, 'the converted dollars are held at once');
select is(pg_temp.posted(4, 'USD'), 400.00::numeric, 'nothing posts before review');
select is((api.submit_conversion(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.seg(4, 'USD'), '100.00',
  'NGN', '152000.00', '1525', 'Grey', (select r->>'observedAt' from c1), 'GRY-1', null,
  array[(select (r->'evidence'->0->>'evidenceId')::uuid from c1)], 'k-cnv-000000000001')->>'replayed')::boolean, true,
  'same key replays');
select is(pg_temp.avail(4, 'USD'), 300.00::numeric, 'a replay never holds twice');

-- ── Refusals (7) ──
select is(pg_temp.fails($$ select pg_temp.convert(3, '10.00', '10.00', null, 'USD') $$), 'validation_error:same_currency',
  'source and destination currencies differ');
select throws_ok($$ select pg_temp.convert(3, '300.01', '1.00') $$, 'P0001', 'insufficient_funds',
  'no more than available');
select throws_ok($$ select api.submit_conversion(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.seg(4, 'USD'),
  '1.00', 'NGN', '1500.00', null, 'Grey', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF":00"'), null, null, null,
  pg_temp.k()) $$, 'P0001', 'evidence_required', 'evidence is required');
select throws_ok($$ select api.submit_conversion(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.seg(4, 'USD'),
  '1.00', 'NGN', '1500.00', null, 'Grey', to_char(now() + interval '1 day', 'YYYY-MM-DD"T"HH24:MI:SSOF":00"'), null,
  null, array[gen_random_uuid()], pg_temp.k()) $$, 'P0001', 'validation_error', 'not converted in the future');
select throws_ok($$ select pg_temp.convert(5, '1.00', '1500.00') $$, 'P0001', 'authorization_denied',
  'a sibling Team Leader cannot convert');
select throws_ok($$ select api.submit_conversion(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.seg(4, 'USD'),
  '1.00', 'NGN', '1500.00', null, 'Grey', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF":00"'), null, null,
  array[gen_random_uuid()], pg_temp.k()) $$, 'P0001', 'self_target_forbidden', 'nobody converts their own money');
select throws_ok($$ select api.submit_conversion(pg_temp.u(8), pg_temp.s(8), pg_temp.ws(8), pg_temp.seg(4, 'USD'),
  '1.00', 'NGN', '1500.00', null, 'Grey', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF":00"'), null, null,
  array[gen_random_uuid()], pg_temp.k()) $$, 'P0001', 'not_found', 'nothing across networks');

-- ── Review and posting (11) ──
select throws_ok($$ select pg_temp.review(3, pg_temp.id('c1'), 'clear') $$, 'P0001', 'authorization_denied',
  'the recording leader is not a reviewer');
select is((api.review_queue(pg_temp.u(7), pg_temp.s(7), pg_temp.ws(7), 'assigned', null, null)->'items'->0->>'kind'),
  'conversion', 'the case is in the reviewer''s queue');
select is((api.review_case(pg_temp.u(7), pg_temp.s(7), pg_temp.ws(7), pg_temp.id('c1'))->>'canDecide')::boolean, true,
  'the reviewer opens the case');
create temp table c1r as select pg_temp.review(7, pg_temp.id('c1'), 'clear', 'k-rev-000000000001') as r;
select is((select r->>'status' from c1r), 'posted', 'clearing posts the conversion');
select is(pg_temp.posted(4, 'USD'), 300.00::numeric, 'dollars leave the pocket');
select is(pg_temp.avail(4, 'USD'), 300.00::numeric, 'the hold is consumed');
select is(pg_temp.posted(4, 'NGN'), 4000.00 + 152000.00, 'naira arrive in the same pocket');
select is((select count(*)::int from ledger.journals j join finance.entries e on e.transaction_id = j.transaction_id
  where e.id = pg_temp.id('c1')), 2, 'one journal per currency');
select is((select count(*)::int from ledger.verify_balances()), 0, 'projections match the ledger');
select is((pg_temp.review(7, pg_temp.id('c1'), 'clear', 'k-rev-000000000001')->>'replayed')::boolean, true,
  'a decision replays');
select is(pg_temp.fails($$ select pg_temp.review(7, pg_temp.id('c1'), 'reject') $$), 'conflict:entry_state',
  'a decided case cannot be decided again');

-- ── Activity and detail (3) ──
select is((select count(*)::int from jsonb_array_elements(api.my_activity(pg_temp.u(4), pg_temp.s(4),
  p_type => 'conversion')->'items')), 2, 'activity shows the conversion in both currencies');
select is((select r->>'title' from (select jsonb_array_elements(api.my_activity(pg_temp.u(4), pg_temp.s(4),
  p_type => 'conversion')->'items') as r) x limit 1), 'USD → NGN', 'the row is titled by currencies');
select is(api.my_transaction(pg_temp.u(4), pg_temp.s(4), (select (r->'entry'->>'transactionId')::uuid from c1r))
  ->'entry'->'conversion'->>'destinationAmount', '152000.00', 'the detail carries the conversion facts');

-- ── Rejection (3) ──
create temp table c2 as select pg_temp.convert(3, '50.00', '76000.00') as r;
select is(pg_temp.avail(4, 'USD'), 250.00::numeric, 'a second conversion holds');
select is((pg_temp.review(7, (select (r->>'entryId')::uuid from c2), 'reject')->>'status'), 'rejected',
  'the reviewer rejects');
select is(pg_temp.avail(4, 'USD'), 300.00::numeric, 'rejection releases the hold, nothing posts');

select * from finish();
rollback;
