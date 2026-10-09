-- Blueprint 15 — B6 150: personal statements (W-18). Figures from the posted
-- ledger, reconciled; reversals both ways; equal timestamps; reservations at
-- the cut-off; WAT boundaries; empty periods; one network and one currency;
-- own money after leaving; Presidents have no personal statement there.
begin;
create extension if not exists pgtap with schema extensions;
select plan(40);

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
create function pg_temp.ws(n int, p_tenant uuid default null) returns uuid language sql stable as $$
  select id from org.memberships where user_id = pg_temp.u(n) and status = 'active'
    and (p_tenant is null or tenant_id = p_tenant)
  order by (role = 'member'), started_at limit 1
$$;
create function pg_temp.receipt(n int, p_ws uuid, p_target uuid, p_key text) returns uuid language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_evidence_upload(pg_temp.u(n), pg_temp.s(n), p_ws, p_target, p_key, 'r.pdf',
    'application/pdf', 1000, repeat('b', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), p_ws, e, 1000, repeat('b', 64), 'application/pdf');
  return e;
end $$;
-- Income recorded by n (in workspace p_ws) for the target membership.
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
-- Moves a transaction's posted time (fixtures only; the ledger is immutable).
create function pg_temp.post_at(p_tx uuid, p_at timestamptz) returns void language plpgsql as $$
begin
  set local session_replication_role = replica;
  update ledger.transactions set posted_at = p_at where id = p_tx;
  set local session_replication_role = origin;
end $$;
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
-- Runs one job through the Worker steps; returns the prepare outcome.
create function pg_temp.run(p_worker text default 'w-test') returns jsonb language plpgsql as $$
declare
  job jsonb := api.export_claim(p_worker)->'job';
  prepared jsonb;
  n int;
begin
  if job is null then
    return null;
  end if;
  prepared := api.export_prepare((job->>'exportId')::uuid, p_worker);
  if prepared->>'status' = 'rendering' then
    n := jsonb_array_length(api.export_rows((job->>'exportId')::uuid, p_worker, 0, 1000)->'rows');
    perform api.export_finalize((job->>'exportId')::uuid, p_worker, n,
      case when job->>'format' = 'pdf' then 1 end, 1234, repeat('c', 64), job->>'format' = 'pdf');
  end if;
  return prepared || jsonb_build_object('exportId', job->>'exportId');
end $$;
create function pg_temp.statement(n int, p_tenant uuid, p_currency text, p_kind text, p_from text, p_to text,
  p_format text default 'pdf') returns uuid language sql volatile as $$
  select (api.create_statement(pg_temp.u(n), pg_temp.s(n), p_tenant, p_currency, p_kind, p_from, p_to, p_format,
    pg_temp.k())->>'exportId')::uuid
$$;
create function pg_temp.summary(p_id uuid) returns jsonb language sql stable as
  $$ select summary from exports.files where id = p_id $$;
create function pg_temp.row_of(p_id uuid, p_ref text) returns jsonb language sql stable as
  $$ select data from exports.rows where file_id = p_id and data->>'reference' = p_ref $$;

-- 1 President (Lagos) · 3 TL (Team A) · 5 TL (Team B) · 4 member (Team A and Team B, and Abuja)
-- 6 TL (Abuja Team) · 8 founder (Abuja) · 9 admin
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
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', null,
  array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T2', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team B', null,
  array[pg_temp.uid(5)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'X', (api.create_office(pg_temp.u(8), pg_temp.s(8), pg_temp.m(8), 'team_leader', 'Abuja Team', null,
  array[pg_temp.uid(6)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(4), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), pg_temp.uid(4), pg_temp.k());
  perform api.add_membership(pg_temp.u(8), pg_temp.s(8), pg_temp.m(8), pg_temp.id('X'), pg_temp.uid(4), pg_temp.k());
end $$;
insert into ids select 'm4a', pg_temp.m(4, pg_temp.id('T'));
insert into ids select 'm4b', pg_temp.m(4, pg_temp.id('T2'));
insert into ids select 'm4x', pg_temp.m(4, pg_temp.id('X'));

-- Lagos, NGN: ₦5,000 in August (opening), ₦10,000 and ₦2,000 on 2 Sep at the
-- very same instant (Team A and Team B), ₦20,000 on 15 Sep reversed on 23 Sep,
-- ₦1,000 on 1 Oct 00:00 WAT (outside September). USD $300 on 3 Sep.
-- Abuja: ₦70,000 for the same person, never on a Lagos statement.
insert into ids select 'aug', pg_temp.income(1, pg_temp.m(1), pg_temp.id('m4a'), 'NGN', '5000.00', 'August pay');
insert into ids select 'sepA', pg_temp.income(1, pg_temp.m(1), pg_temp.id('m4a'), 'NGN', '10000.00', 'Sep pay A');
insert into ids select 'sepB', pg_temp.income(1, pg_temp.m(1), pg_temp.id('m4b'), 'NGN', '2000.00', 'Sep pay B');
insert into ids select 'mid', pg_temp.income(1, pg_temp.m(1), pg_temp.id('m4a'), 'NGN', '20000.00', 'Twice');
insert into ids select 'oct', pg_temp.income(1, pg_temp.m(1), pg_temp.id('m4a'), 'NGN', '1000.00', 'October pay');
insert into ids select 'usd', pg_temp.income(1, pg_temp.m(1), pg_temp.id('m4a'), 'USD', '300.00', 'Dollar pay');
insert into ids select 'abuja', pg_temp.income(8, pg_temp.m(8), pg_temp.id('m4x'), 'NGN', '70000.00', 'Abuja pay');
do $$ begin
  perform api.reverse_transaction(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('mid'), 'recorded_twice',
    'Same order recorded twice', (select reference from ledger.transactions where id = pg_temp.id('mid')), pg_temp.k());
end $$;
insert into ids select 'rev', transaction_id from finance.reversals where original_transaction_id = pg_temp.id('mid');
select pg_temp.post_at(pg_temp.id('aug'), '2026-08-20 10:00+01');
select pg_temp.post_at(pg_temp.id('sepA'), '2026-09-02 09:00+01');
select pg_temp.post_at(pg_temp.id('sepB'), '2026-09-02 09:00+01');
select pg_temp.post_at(pg_temp.id('mid'), '2026-09-15 12:00+01');
select pg_temp.post_at(pg_temp.id('rev'), '2026-09-23 12:00+01');
select pg_temp.post_at(pg_temp.id('oct'), '2026-10-01 00:00+01');
select pg_temp.post_at(pg_temp.id('usd'), '2026-09-03 08:00+01');
select pg_temp.post_at(pg_temp.id('abuja'), '2026-09-05 08:00+01');

-- A pocket move requested on 28 Sep and still waiting holds ₦1,500 at the cut-off.
do $$
declare
  t uuid;
begin
  t := (api.request_pocket_transfer(pg_temp.u(4), pg_temp.s(4), pg_temp.id('m4a'),
    (select b.account_id from ledger.balances b join ledger.pockets p on p.id = b.pocket_id
     where b.membership_id = pg_temp.id('m4a') and b.currency = 'NGN' and p.name = 'Point Value'),
    (select id from ledger.pockets where tenant_id = pg_temp.id('tenant') and name = 'Savings'),
    '1500.00', pg_temp.k())->>'transferId')::uuid;
  set local session_replication_role = replica;
  update ledger.reservations set created_at = '2026-09-28 10:00+01'
  where id = (select reservation_id from finance.pocket_transfers where id = t);
  set local session_replication_role = origin;
end $$;

-- ── Options (3) ──
create temp table opts as select api.statement_options(pg_temp.u(4), pg_temp.s(4)) as o;
select is((select jsonb_array_length(o->'networks') from opts), 2, 'two networks: the builder shows the choice');
select is((select o->>'timeZone' from opts), 'Africa/Lagos', 'periods are WAT');
select is((select jsonb_array_length(o->'networks') from (select api.statement_options(pg_temp.u(1), pg_temp.s(1)) o) x),
  0, 'a President has no personal statement in their own network');

-- ── Requests (6) ──
select is(pg_temp.fails($$ select pg_temp.statement(4, null, 'NGN', 'month', '2026-09-01', '2026-09-30') $$),
  'validation_error:', 'two networks: the network must be chosen');
select is(pg_temp.fails($$ select pg_temp.statement(1, pg_temp.id('tenant'), 'NGN', 'month', '2026-09-01', '2026-09-30') $$),
  'not_found:', 'no statement for a network without own money');
select is(pg_temp.fails($$ select pg_temp.statement(4, pg_temp.id('tenant'), 'NGN', 'month', '2026-09-01', '2026-09-29') $$),
  'validation_error:', 'a month is a whole month');
select is(pg_temp.fails($$ select pg_temp.statement(4, pg_temp.id('tenant'), 'NGN', 'custom', '2099-01-01', '2099-01-02') $$),
  'conflict:period_in_future', 'a period must have started');
select is(pg_temp.fails($$ select pg_temp.statement(4, pg_temp.id('tenant'), 'EUR', 'month', '2026-09-01', '2026-09-30') $$),
  'validation_error:', 'unknown currency');
create temp table rq as select api.create_statement(pg_temp.u(4), pg_temp.s(4), pg_temp.id('tenant'), 'NGN', 'month',
  '2026-09-01', '2026-09-30', 'pdf', 'k-statement-00000001') as r;
select is((select api.create_statement(pg_temp.u(4), pg_temp.s(4), pg_temp.id('tenant'), 'NGN', 'month',
  '2026-09-01', '2026-09-30', 'pdf', 'k-statement-00000001')->>'exportId'), (select r->>'exportId' from rq),
  'the same key returns the same file');
insert into ids select 'sep', (r->>'exportId')::uuid from rq;

-- ── September NGN, figures (10) ──
select is((select r->>'status' from rq), 'queued', 'a new file waits for the Worker');
select is((pg_temp.run()->>'status'), 'rendering', 'prepared for rendering');
select is((select status from exports.files where id = pg_temp.id('sep')), 'ready', 'finalized: ready');
select is(pg_temp.summary(pg_temp.id('sep'))->>'opening', '5000.00', 'opening = everything posted before 1 Sep WAT');
select is(pg_temp.summary(pg_temp.id('sep'))->>'moneyIn', '32000.00', 'money in: ₦10,000 + ₦2,000 + ₦20,000');
select is(pg_temp.summary(pg_temp.id('sep'))->>'moneyOut', '-20000.00', 'money out: the reversal');
select is(pg_temp.summary(pg_temp.id('sep'))->>'closing', '17000.00', 'closing = opening + in + out');
select is(pg_temp.summary(pg_temp.id('sep'))->>'reserved', '1500.00', 'reserved at the cut-off: the waiting pocket move');
select is(pg_temp.summary(pg_temp.id('sep'))->>'available', '15500.00', 'available = closing − reserved');
select is((select sum(((p->>'closing')::numeric)) from jsonb_array_elements(pg_temp.summary(pg_temp.id('sep'))->'pockets') p),
  17000.00::numeric, 'pocket closings add up to the closing balance');

-- ── Rows (9) ──
select is((select row_count from exports.files where id = pg_temp.id('sep')), 4, 'four posted movements in September');
select is((select count(*)::int from exports.rows where file_id = pg_temp.id('sep')), 0,
  'prepared rows are removed once the file is ready');
-- Prepare again (a retry) to read the rows before they are finalized.
update exports.files set status = 'queued', attempts = 0, finished_at = null, expires_at = null, sha256 = null,
  byte_size = null, row_count = null where id = pg_temp.id('sep');
select is((api.export_prepare((api.export_claim('w-rows')->'job'->>'exportId')::uuid, 'w-rows')->>'rowCount')::int, 4,
  'the same four on a second preparation');
select is((select array_agg(seq order by seq) from exports.rows where file_id = pg_temp.id('sep')), array[1, 2, 3, 4],
  'rows are numbered without gaps');
select is((select count(*)::int from exports.rows where file_id = pg_temp.id('sep')
  and data->>'transactionId' in (pg_temp.id('sepA')::text, pg_temp.id('sepB')::text)), 2,
  'two movements at the same instant: both there, once each');
select is(pg_temp.row_of(pg_temp.id('sep'), (select reference from ledger.transactions where id = pg_temp.id('mid')))->>'status',
  'reversed', 'the original shows Reversed');
select is(pg_temp.row_of(pg_temp.id('sep'), (select reference from ledger.transactions where id = pg_temp.id('rev')))->>'reverses',
  (select reference from ledger.transactions where id = pg_temp.id('mid')), 'the reversal is its own row, linked to the original');
select is((select data->>'balance' from exports.rows where file_id = pg_temp.id('sep') order by seq desc limit 1),
  '17000.00', 'the running balance ends at the closing balance');
select is((select count(*)::int from exports.rows where file_id = pg_temp.id('sep')
  and data->>'transactionId' in (pg_temp.id('abuja')::text, pg_temp.id('usd')::text, pg_temp.id('oct')::text)), 0,
  'no other network, other currency or later movement');

-- ── Other periods and currencies (6) ──
insert into ids select 'aug_cut', pg_temp.statement(4, pg_temp.id('tenant'), 'NGN', 'month', '2026-08-01', '2026-08-31');
select pg_temp.run();
select is((select status from exports.files where id = pg_temp.id('aug_cut')), 'ready', 'August is ready too');
insert into ids select 'jul', pg_temp.statement(4, pg_temp.id('tenant'), 'NGN', 'month', '2026-07-01', '2026-07-31');
select pg_temp.run();
select ok((select status = 'ready' and row_count = 0 from exports.files where id = pg_temp.id('jul')),
  'an empty period is a valid, ready statement');
select is(pg_temp.summary(pg_temp.id('jul'))->>'closing', '0.00', 'with zero balances, not unavailable');
insert into ids select 'usd_sep', pg_temp.statement(4, pg_temp.id('tenant'), 'USD', 'month', '2026-09-01', '2026-09-30', 'csv');
select pg_temp.run();
select is(pg_temp.summary(pg_temp.id('usd_sep'))->>'moneyIn', '300.00', 'USD is its own statement');
insert into ids select 'abj', pg_temp.statement(4, pg_temp.id('other'), 'NGN', 'month', '2026-09-01', '2026-09-30');
select pg_temp.run();
select is(pg_temp.summary(pg_temp.id('abj'))->>'closing', '70000.00', 'the Abuja statement holds only Abuja money');
select is(pg_temp.summary(pg_temp.id('abj'))->'network'->>'name', 'Abuja Network', 'with that network''s name');

-- ── WAT boundary and limits (4) ──
insert into ids select 'oct_m', pg_temp.statement(4, pg_temp.id('tenant'), 'NGN', 'custom', '2026-10-01', '2026-10-01');
select pg_temp.run();
select is(pg_temp.summary(pg_temp.id('oct_m'))->>'moneyIn', '1000.00', '00:00 WAT on 1 Oct belongs to 1 Oct');
create or replace function exports.row_limit(p_format text) returns int
language sql immutable set search_path = '' as $$ select 2 $$;
insert into ids select 'big', pg_temp.statement(4, pg_temp.id('tenant'), 'NGN', 'month', '2026-09-01', '2026-09-30');
select is((pg_temp.run()->>'status'), 'too_large', 'over the row limit: too large');
select ok((select status = 'too_large' and row_count = 4 and sha256 is null from exports.files where id = pg_temp.id('big')),
  'too large is final and has no file');
select is((select count(*)::int from exports.rows where file_id = pg_temp.id('big')), 0, 'and keeps no rows');

-- ── Own money after leaving (2) ──
do $$ begin
  set local session_replication_role = replica;
  update org.memberships set status = 'ended', ended_at = now(), is_primary = false
  where user_id = pg_temp.u(4) and tenant_id = pg_temp.id('other');
  set local session_replication_role = origin;
end $$;
select ok(exists (select 1 from exports.statement_networks(pg_temp.u(4)) n where n.tenant_id = pg_temp.id('other')),
  'a network left is still in the list while the person holds money there');
select isnt(pg_temp.statement(4, pg_temp.id('other'), 'NGN', 'year_to_date', to_char(date_trunc('year', now() at time zone 'Africa/Lagos'), 'YYYY-MM-DD'),
  to_char(now() at time zone 'Africa/Lagos', 'YYYY-MM-DD')), null, 'and a statement can still be made');

select * from finish();
rollback;
