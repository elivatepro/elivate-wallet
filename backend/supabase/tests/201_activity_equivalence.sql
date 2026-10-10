-- Blueprint 20 — B3 201: the page-first ledger.activity returns exactly what
-- the previous whole-history version returned — items, order, cursors,
-- months, total and amounts — on every page and for every filter. The
-- previous function is recreated below (pg_temp.old_activity, verbatim from
-- 20261009120400) on a synthetic multi-currency wallet with a conversion
-- (two currencies in one transaction), a reversal, a pocket move and ties on
-- posted_at.
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
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
create function pg_temp.proof(n int, p_kind text, p_target uuid, p_key text) returns uuid language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_entry_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_kind, p_target, p_key,
    'proof.pdf', 'application/pdf', 3000, repeat('d', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 3000, repeat('d', 64), 'application/pdf');
  return e;
end $$;
create function pg_temp.seg(n int, p_currency text default 'NGN', p_pocket text default 'Point Value') returns uuid
language sql stable as $$
  select b.account_id from ledger.balances b join ledger.pockets p on p.id = b.pocket_id
  where b.owner_user_id = pg_temp.u(n) and p.name = p_pocket and b.currency = p_currency
$$;
create function pg_temp.pocket(p_name text) returns uuid language sql stable as
  $$ select id from ledger.pockets where tenant_id = pg_temp.id('tenant') and name = p_name $$;
create function pg_temp.income(p_currency text, p_amount text, p_source text) returns uuid language plpgsql as $$
declare
  key text := pg_temp.k();
begin
  return (api.record_income(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('m4'), p_currency, p_amount,
    p_source, to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), 'PRV-' || p_source, null, null, null,
    array[pg_temp.income_receipt(1, pg_temp.id('m4'), key)], key)->>'transactionId')::uuid;
end $$;

-- 1 President · 2 Director (D) · 3 TL (T) · 4 member (T) · 7 reviewer member (T) · 8 other founder · 9 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 9) n;
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
end $$;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', null, array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'), array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(4), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(7), pg_temp.k());
  perform api.assign_reviewer(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(7, pg_temp.id('T')), 'Finance lead', pg_temp.k());
end $$;
insert into ids select 'm4', pg_temp.m(4, pg_temp.id('T'));
insert into ids select 'wallet', ledger.wallet_for(pg_temp.u(4));

-- ── The wallet: 14 incomes in two currencies, a conversion, a reversal, a pocket move ──
insert into ids select 'inc' || n,
  pg_temp.income(case when n % 3 = 0 then 'USD' else 'NGN' end,
    case when n % 3 = 0 then (100 * n)::text || '.00' else (25000 * n)::text || '.50' end,
    case when n % 2 = 0 then 'Fiverr order ' || n else 'Upwork contract ' || n end)
from generate_series(1, 14) n;
do $$
declare
  key text := pg_temp.k();
  entry uuid;
begin
  entry := (api.submit_conversion(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.seg(4, 'USD'), '100.00',
    'NGN', '152000.00', '1525', 'Grey', to_char(now() - interval '1 hour', 'YYYY-MM-DD"T"HH24:MI:SSOF":00"'),
    'GRY-1', null, array[pg_temp.proof(3, 'conversion', pg_temp.id('m4'), key)], key)->>'entryId')::uuid;
  perform api.review_entry(pg_temp.u(7), pg_temp.s(7), pg_temp.ws(7), entry, 'clear', 'Checked the statement', pg_temp.k());
  perform api.reverse_transaction(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('inc4'), 'recorded_twice',
    'Same order recorded twice', (select reference from ledger.transactions where id = pg_temp.id('inc4')), pg_temp.k());
  perform api.approve_pocket_transfer(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3),
    (api.request_pocket_transfer(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.seg(4),
      pg_temp.pocket('Savings'), '500.00', pg_temp.k())->>'transferId')::uuid, pg_temp.k());
end $$;

-- Spread the movements over four months in groups of three that share one
-- posted_at (ties broken by id, then currency). The first group sits at
-- 23:30 UTC on 31 July, already August in Lagos. The ledger is append-only,
-- so the triggers are bypassed for this synthetic fixture only.
set local session_replication_role = replica;
update ledger.transactions t
set posted_at = timestamptz '2026-07-31 23:30:00+00' + (x.rn / 3) * interval '19 days'
from (select id, row_number() over (order by posted_at, id) - 1 as rn from ledger.transactions
      where wallet_id = pg_temp.id('wallet')) x
where t.id = x.id;
set local session_replication_role = origin;

-- ── The previous ledger.activity, verbatim (20261009120400) ──

create function pg_temp.old_activity(
  p_wallet_id uuid,
  p_tenant_id uuid,
  p_account_ids uuid[],
  p_currency text,
  p_pocket_id uuid,
  p_direction text,
  p_type text,
  p_from text,
  p_to text,
  p_cursor text,
  p_limit int,
  p_query text default null,
  p_status text default null,
  p_tz text default null
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  page_size int;
  after jsonb;
  after_at timestamptz;
  after_id uuid;
  from_date date;
  to_date date;
  zone text;
  query_text text;
  query_pattern text;
  query_reference text;
  query_amount numeric;
  result jsonb;
begin
  if p_currency is not null and p_currency !~ '^[A-Z]{3}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'currency'));
  end if;
  if p_direction is not null and p_direction not in ('in', 'out') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'direction'));
  end if;
  if p_type is not null and p_type not in ('income', 'reversal', 'withdrawal', 'pocket_transfer', 'conversion',
                                           'adjustment', 'returned_funds') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'type'));
  end if;
  -- Durable statuses of ledger movements (owner decision 2026-10-08): a
  -- movement is `posted`, or `reversed` once a reversal points at it.
  if p_status is not null and p_status not in ('posted', 'reversed') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'status'));
  end if;
  if p_query is not null and (length(btrim(p_query)) = 0 or length(p_query) > 100) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'q'));
  end if;
  zone := ledger.time_zone(p_tz);
  from_date := ledger.date_filter(p_from, 'from');
  to_date := ledger.date_filter(p_to, 'to');
  page_size := org.page_limit(p_limit);
  after := org.decode_cursor(p_cursor);
  if after is not null then
    begin
      after_at := (after->>'s')::timestamptz;
      after_id := (after->>'id')::uuid;
    exception when others then
      perform identity.fail('validation_error', jsonb_build_object('field', 'cursor'));
    end;
    if after_at is null or after_id is null or after->>'c' is null then
      perform identity.fail('validation_error', jsonb_build_object('field', 'cursor'));
    end if;
  end if;

  query_text := btrim(p_query);
  query_pattern := '%' || replace(replace(replace(query_text, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  query_reference := upper(regexp_replace(coalesce(query_text, ''), '[^A-Za-z0-9]', '', 'g'));
  query_amount := ledger.search_amount(query_text);

  with moves as (
    select t.id, t.reference, t.type, t.posted_at, t.tenant_id, j.currency, sum(p.amount) as amount,
      count(distinct a.pocket_id) as pocket_count
    from ledger.transactions t
    join ledger.journals j on j.transaction_id = t.id
    join ledger.postings p on p.journal_id = j.id
    join ledger.accounts a on a.id = p.account_id
    where t.wallet_id = p_wallet_id and a.wallet_id = p_wallet_id
      and (p_tenant_id is null or t.tenant_id = p_tenant_id)
      and (p_account_ids is null or a.id = any (p_account_ids))
      and (p_currency is null or j.currency = p_currency)
      and (p_pocket_id is null or a.pocket_id = p_pocket_id)
      and (p_type is null or t.type = p_type)
      and (from_date is null or t.posted_at >= from_date::timestamp at time zone zone)
      and (to_date is null or t.posted_at < (to_date + 1)::timestamp at time zone zone)
    group by t.id, t.reference, t.type, t.posted_at, t.tenant_id, j.currency
  ),
  filtered as (
    select m.*, case when rv.link is null then 'posted' else 'reversed' end as status,
      rv.link as reversal,
      coalesce(i.source, wd.bank_name || ' •• ' || wd.account_last4, sp.name || ' → ' || dp.name,
        case en.kind
          when 'conversion' then en.currency || ' → ' || en.destination_currency
          when 'adjustment' then en.reason
          when 'returned_funds' then en.provider
        end,
        case when m.type = 'reversal' then 'Reverses ' || ot.reference end) as title,
      pt.amount as moved_amount,
      to_char(m.posted_at at time zone zone, 'YYYY-MM') as month
    from moves m
    left join finance.income_records i on i.transaction_id = m.id
    left join finance.withdrawals wd on wd.transaction_id = m.id
    left join finance.pocket_transfers pt on pt.transaction_id = m.id
    left join ledger.pockets sp on sp.id = pt.source_pocket_id
    left join ledger.pockets dp on dp.id = pt.destination_pocket_id
    left join finance.entries en on en.transaction_id = m.id
    left join finance.reversals rr on rr.transaction_id = m.id
    left join ledger.transactions ot on ot.id = rr.original_transaction_id
    cross join lateral (select ledger.reversed_by(m.id) as link) rv
    where (p_direction is null or (p_direction = 'in' and m.amount > 0) or (p_direction = 'out' and m.amount < 0))
      and (query_text is null
        or (length(query_reference) >= 3 and replace(m.reference, '-', '') like '%' || query_reference || '%')
        or (length(query_reference) >= 3 and replace(ot.reference, '-', '') like '%' || query_reference || '%')
        or i.source ilike query_pattern
        or i.provider_reference ilike query_pattern
        or wd.bank_name ilike query_pattern
        or en.provider ilike query_pattern
        or en.reason ilike query_pattern
        or en.external_reference ilike query_pattern
        or (query_amount is not null and pt.amount = query_amount)
        or (query_amount is not null and abs(m.amount) = query_amount))
  ),
  shown_status as (select * from filtered where p_status is null or filtered.status = p_status),
  page as (
    select f.*, row_number() over (order by f.posted_at desc, f.id desc, f.currency desc) as n
    from shown_status f
    where after is null or (f.posted_at, f.id, f.currency) < (after_at, after_id, after->>'c')
    order by f.posted_at desc, f.id desc, f.currency desc
    limit page_size + 1
  ),
  shown as (select * from page where n <= page_size)
  select jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'transactionId', s.id,
        'reference', s.reference,
        'type', s.type,
        'status', s.status,
        'title', s.title,
        'postedAt', s.posted_at,
        'tenantId', s.tenant_id,
        'currency', s.currency,
        'amount', ledger.money(s.amount, s.currency),
        'pocketCount', s.pocket_count,
        'reversedAt', s.reversal->'postedAt',
        'movedAmount', case when s.moved_amount is not null then ledger.money(s.moved_amount, s.currency) end
      ) order by s.n)
      from shown s
    ), '[]'::jsonb),
    'nextCursor', (
      select org.encode_cursor(jsonb_build_object(
        's', to_char(s.posted_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'id', s.id,
        'c', s.currency))
      from shown s
      where s.n = page_size and exists (select 1 from page where page.n > page_size)
    ),
    'months', coalesce((
      select jsonb_agg(jsonb_build_object('month', mo.month, 'currencies', mo.currencies) order by mo.month desc)
      from (
        select c.month, jsonb_agg(jsonb_build_object(
          'currency', c.currency,
          'in', ledger.money(c.money_in, c.currency),
          'out', ledger.money(c.money_out, c.currency)
        ) order by c.currency) as currencies
        from (
          select f.month, f.currency,
            coalesce(sum(f.amount) filter (where f.amount > 0), 0) as money_in,
            coalesce(sum(f.amount) filter (where f.amount < 0), 0) as money_out
          from shown_status f
          where f.month in (select shown.month from shown)
          group by f.month, f.currency
        ) c
        group by c.month
      ) mo
    ), '[]'::jsonb),
    'total', (select count(*) from shown_status),
    'timeZone', zone
  ) into result;

  return result;
end;
$$;

-- Every page of the old and the new read, following each one's own cursor.
create function pg_temp.same(p jsonb, p_limit int, p_wallet uuid default null) returns text language plpgsql as $$
declare
  w uuid := coalesce(p_wallet, pg_temp.id('wallet'));
  accounts uuid[] := (select array_agg(x::uuid) from jsonb_array_elements_text(p->'accounts') x);
  c_old text;
  c_new text;
  a jsonb;
  b jsonb;
  pages int := 0;
begin
  loop
    a := pg_temp.old_activity(w, (p->>'tenant')::uuid, accounts, p->>'currency', (p->>'pocket')::uuid,
      p->>'direction', p->>'type', p->>'from', p->>'to', c_old, p_limit, p->>'q', p->>'status', p->>'tz');
    b := ledger.activity(w, (p->>'tenant')::uuid, accounts, p->>'currency', (p->>'pocket')::uuid,
      p->>'direction', p->>'type', p->>'from', p->>'to', c_new, p_limit, p->>'q', p->>'status', p->>'tz');
    if a is distinct from b then
      return format('page %s differs: old %s new %s', pages + 1, a, b);
    end if;
    pages := pages + 1;
    c_old := a->>'nextCursor';
    c_new := b->>'nextCursor';
    exit when c_old is null or pages > 200;
  end loop;
  return 'same, ' || pages || ' pages';
end $$;
create function pg_temp.rows(p jsonb) returns int language sql stable as $$
  select jsonb_array_length(pg_temp.old_activity(pg_temp.id('wallet'), (p->>'tenant')::uuid, null, p->>'currency',
    (p->>'pocket')::uuid, p->>'direction', p->>'type', p->>'from', p->>'to', null, 100, p->>'q', p->>'status',
    p->>'tz')->'items')
$$;
create function pg_temp.ref(p_name text) returns text language sql stable as
  $$ select reference from ledger.transactions where id = pg_temp.id(p_name) $$;

-- ── The fixture covers what it should (5) ──
select is(pg_temp.rows('{}'), 18, '14 incomes, a two-currency conversion, a reversal and a pocket move: 18 rows');
select is(pg_temp.rows('{"status": "reversed"}'), 1, 'one reversed movement');
select is(pg_temp.rows('{"type": "conversion"}'), 2, 'the conversion has a row per currency (same posted_at and id)');
select ok((select count(*) > count(distinct posted_at) from ledger.transactions where wallet_id = pg_temp.id('wallet')),
  'posted_at has ties');
select ok(jsonb_array_length(pg_temp.old_activity(pg_temp.id('wallet'), null, null, null, null, null, null, null,
  null, null, 100, null, null, 'Africa/Lagos')->'months') >= 4, 'four months or more');

-- ── Unfiltered, every page size (6) ──
select is(pg_temp.same('{}', 1), 'same, 18 pages', 'limit 1: every row is its own page, ties included');
select is(pg_temp.same('{}', 2), 'same, 9 pages', 'limit 2');
select is(pg_temp.same('{}', 3), 'same, 6 pages', 'limit 3');
select is(pg_temp.same('{}', 5), 'same, 4 pages', 'limit 5 (Home)');
select is(pg_temp.same('{}', 18), 'same, 1 pages', 'exactly one full page');
select is(pg_temp.same('{}', null), 'same, 1 pages', 'the default page size');

-- ── Filters (22) ──
select matches(pg_temp.same('{"currency": "NGN"}', 2), '^same', 'currency NGN');
select matches(pg_temp.same('{"currency": "USD"}', 2), '^same', 'currency USD');
select matches(pg_temp.same('{"direction": "in"}', 3), '^same', 'money in');
select matches(pg_temp.same('{"direction": "out"}', 1), '^same', 'money out');
select matches(pg_temp.same('{"type": "income"}', 4), '^same', 'type income');
select matches(pg_temp.same('{"type": "reversal"}', 1), '^same', 'type reversal');
select matches(pg_temp.same('{"type": "conversion"}', 1), '^same', 'type conversion');
select matches(pg_temp.same('{"type": "pocket_transfer"}', 1), '^same', 'type pocket move');
select matches(pg_temp.same('{"status": "posted"}', 4), '^same', 'status posted');
select matches(pg_temp.same('{"status": "reversed"}', 1), '^same', 'status reversed');
select matches(pg_temp.same('{"q": "fiverr"}', 2), '^same', 'search by source');
select matches(pg_temp.same('{"q": "PRV-Upwork"}', 2), '^same', 'search by provider reference');
select matches(pg_temp.same(jsonb_build_object('q', lower(replace(pg_temp.ref('inc4'), '-', ''))), 1), '^same',
  'search by reference (finds the original and its reversal)');
select matches(pg_temp.same('{"q": "500"}', 1), '^same', 'search by amount (the pocket move)');
select matches(pg_temp.same('{"q": "₦50,001.00"}', 1), '^same', 'search by formatted amount');
select matches(pg_temp.same('{"q": "Grey"}', 1), '^same', 'search by provider (the conversion)');
select matches(pg_temp.same('{"from": "2026-08-15", "to": "2026-09-20"}', 2), '^same', 'date range');
select matches(pg_temp.same('{"from": "2026-08-01", "to": "2026-08-01", "tz": "Africa/Lagos"}', 1), '^same',
  'date range in a zone (the 23:30 UTC group is 1 August in Lagos)');
select matches(pg_temp.same('{"tz": "America/New_York"}', 3), '^same', 'months in another zone');
select matches(pg_temp.same(jsonb_build_object('pocket', pg_temp.pocket('Savings')), 2), '^same', 'one pocket');
select matches(pg_temp.same(jsonb_build_object('tenant', pg_temp.id('tenant'), 'currency', 'NGN', 'direction', 'in',
  'q', 'upwork'), 2), '^same', 'filters combined, in the network');
select matches(pg_temp.same(jsonb_build_object('tenant', pg_temp.id('other')), 2), '^same', 'another network: empty');

-- ── Managed view: only some segments (2) ──
select matches(pg_temp.same(jsonb_build_object('accounts', jsonb_build_array(pg_temp.seg(4), pg_temp.seg(4, 'USD'))), 2),
  '^same', 'limited to two segments');
select matches(pg_temp.same(jsonb_build_object('accounts', jsonb_build_array(pg_temp.seg(4, 'USD')), 'q', 'grey'), 1),
  '^same', 'limited segments and a search');

-- ── Refusals stay the same (2) ──
select throws_ok($$ select ledger.activity(pg_temp.id('wallet'), null, null, null, null, null, null, null, null,
  'not-a-cursor', 5) $$, 'P0001', 'validation_error', 'a bad cursor is refused');
select throws_ok($$ select ledger.activity(pg_temp.id('wallet'), null, null, 'ngn', null, null, null, null, null,
  null, 5) $$, 'P0001', 'validation_error', 'a bad currency is refused');

-- ── Without months (Home) (3) ──
select is(
  ledger.activity(pg_temp.id('wallet'), null, null, null, null, null, null, null, null, null, 5, p_months => false)
    - 'months',
  ledger.activity(pg_temp.id('wallet'), null, null, null, null, null, null, null, null, null, 5) - 'months' - 'total',
  'without months: the same items, cursor and zone'
);
select is(
  ledger.activity(pg_temp.id('wallet'), null, null, null, null, null, null, null, null, null, 5, p_months => false)
    ->'months', '[]'::jsonb, 'and no month summaries');
select ok(
  not ledger.activity(pg_temp.id('wallet'), null, null, null, null, null, null, null, null, null, 5, p_months => false)
    ? 'total', 'and no total');

select * from finish();
rollback;
