-- Blueprint 12 — B6 121: adjustments (W-14): authority, reason and evidence
-- always, policy split fixed at submission, review, debit availability twice.
begin;
create extension if not exists pgtap with schema extensions;
select plan(21);

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

create function pg_temp.adjust(n int, p_direction text, p_amount text, p_key text default null,
  p_reason text default 'Goodwill credit from the network') returns jsonb language plpgsql as $$
declare
  key text := coalesce(p_key, pg_temp.k());
begin
  return api.submit_adjustment(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), pg_temp.id('m4'), p_direction, 'NGN',
    p_amount, p_reason, null, array[pg_temp.proof(n, 'adjustment', pg_temp.id('m4'), key)], key);
end $$;

-- ── Authority (4) ──
select throws_ok($$ select pg_temp.adjust(3, 'credit', '10.00') $$, 'P0001', 'authorization_denied',
  'a Team Leader cannot adjust by default');
select throws_ok($$ select pg_temp.adjust(2, 'credit', '10.00') $$, 'P0001', 'authorization_denied',
  'a Director cannot adjust by default');
select throws_ok($$ select api.submit_adjustment(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('m4'),
  'credit', 'NGN', '10.00', 'Goodwill', null, null, pg_temp.k()) $$, 'P0001', 'evidence_required',
  'evidence is always required');
select throws_ok($$ select pg_temp.adjust(1, 'credit', '10.00', null, '  ') $$, 'P0001', 'validation_error',
  'a reason is always required');

-- ── Credit (8) ──
create temp table a1 as select pg_temp.adjust(1, 'credit', '1000.00', 'k-adj-000000000001') as r;
insert into ids select 'a1', (r->>'entryId')::uuid from a1;
select is((select r->>'status' from a1), 'needs_review', 'an adjustment waits for review');
select matches((select r->>'reference' from a1), '^ADJ-', 'ADJ reference');
select is((select string_agg(l->>'amount', ',' order by (l->>'basisPoints')::int desc, l->>'pocket')
  from a1, jsonb_array_elements(r->'lines') l), '400.00,250.00,150.00,100.00,100.00',
  'the split follows the allocation policy');
select is(pg_temp.posted(4), 4000.00::numeric, 'nothing posts before review');
select is((select r->>'status' from (select pg_temp.review(7, pg_temp.id('a1'), 'clear') ->'entry' as r) x),
  'posted', 'the reviewer clears it');
select is(pg_temp.posted(4), 4400.00::numeric, 'Point Value gets its 40%');
select is(pg_temp.posted(4, 'NGN', 'Upkeep'), 2750.00::numeric, 'Upkeep gets its 25%');
select is((select count(*)::int from audit.tenant_events where action = 'adjustment.posted'
  and safe_after->>'membershipId' = pg_temp.id('m4')::text), 1, 'the posting is recorded for the member notice');

-- ── Debit (7) ──
select throws_ok($$ select pg_temp.adjust(1, 'debit', '20000.00') $$, 'P0001', 'insufficient_funds',
  'a debit share beyond a pocket fails at once');
create temp table d1 as select pg_temp.adjust(1, 'debit', '9000.00', null, 'Recovered overpayment') as r;
create temp table d2 as select pg_temp.adjust(1, 'debit', '9000.00', null, 'Recovered overpayment') as r;
select is((select r->>'direction' from d1), 'debit', 'debits are accepted when they fit');
select is((pg_temp.review(7, (select (r->>'entryId')::uuid from d1), 'clear')->>'status'), 'posted',
  'the first debit posts');
select is(pg_temp.posted(4), 4400.00 - 3600.00, 'the debit leaves each pocket by its share');
select throws_ok($$ select pg_temp.review(7, (select (r->>'entryId')::uuid from d2), 'clear') $$, 'P0001',
  'insufficient_funds', 'availability is checked again when it posts');
select is((select status from finance.entries where id = (select (r->>'entryId')::uuid from d2)), 'needs_review',
  'a failed clearance leaves the case open');
select is((pg_temp.review(7, (select (r->>'entryId')::uuid from d2), 'reject')->>'status'), 'rejected',
  'the reviewer can reject it instead');

-- ── Ledger (2) ──
select is((select count(*)::int from ledger.verify_balances()), 0, 'projections match the ledger');
select is((select count(*)::int from jsonb_array_elements(api.my_activity(pg_temp.u(4), pg_temp.s(4),
  p_type => 'adjustment')->'items')), 2, 'activity shows the posted adjustments');

select * from finish();
rollback;
