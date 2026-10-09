-- Blueprint 12 — B6 123: reversals (W-15): President only, typed confirmation,
-- exact opposite lines, once per transaction, reinstatement, availability.
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

create function pg_temp.tx(p_source text) returns uuid language sql stable as $$
  select i.transaction_id from finance.income_records i where i.source = p_source
$$;
create function pg_temp.ref(p_source text) returns text language sql stable as $$
  select reference from ledger.transactions where id = pg_temp.tx(p_source)
$$;
create function pg_temp.reverse(n int, p_tx uuid, p_confirm text, p_key text default null,
  p_category text default 'recorded_twice', p_note text default 'Same order recorded twice') returns jsonb
language sql volatile as $$
  select api.reverse_transaction(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_tx, p_category, p_note, p_confirm,
    coalesce(p_key, pg_temp.k()))
$$;

-- ── Preview (4) ──
create temp table p1 as select api.reversal_preview(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1),
  lower(replace(pg_temp.ref('Fiverr'), '-', ''))) as r;
select is((select r->'transaction'->>'reference' from p1), pg_temp.ref('Fiverr'),
  'found by reference in any case, dashes optional');
select is((select r->>'blocker' from p1), null, 'an income can be reversed');
select is((select l->>'amount' from p1, jsonb_array_elements(r->'lines') l where l->>'pocket' = 'Point Value'),
  '-4000.00', 'the preview shows the exact opposite lines');
select throws_ok($$ select api.reversal_preview(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.ref('Fiverr')) $$,
  'P0001', 'authorization_denied', 'only the President reverses');

-- ── Refusals (4) ──
select is(pg_temp.fails($$ select pg_temp.reverse(1, pg_temp.tx('Fiverr'), 'INC-0000-0000') $$),
  'conflict:confirmation_mismatch', 'the reference must be typed back');
select throws_ok($$ select pg_temp.reverse(1, pg_temp.tx('Fiverr'), pg_temp.ref('Fiverr'), null, 'other', null) $$,
  'P0001', 'validation_error', '"Other" needs a note');
select throws_ok($$ select pg_temp.reverse(2, pg_temp.tx('Fiverr'), pg_temp.ref('Fiverr')) $$,
  'P0001', 'authorization_denied', 'a Director cannot reverse');
select is(finance.reversible_type('withdrawal'), false, 'a completed withdrawal is corrected with returned funds');

-- ── Reverse (7) ──
create temp table v1 as select pg_temp.reverse(1, pg_temp.tx('Fiverr'), lower(pg_temp.ref('Fiverr')),
  'k-rev-000000000001') as r;
select matches((select r->>'reference' from v1), '^REV-', 'REV reference');
select is(pg_temp.posted(4), 0.00::numeric, 'Point Value gives back its share');
select is(pg_temp.posted(4, 'NGN', 'Upkeep'), 0.00::numeric, 'every pocket gives back its share');
select is((select r->'amounts'->0->>'amount' from v1), '-10000.00', 'the reversal totals the original');
select is((pg_temp.reverse(1, pg_temp.tx('Fiverr'), pg_temp.ref('Fiverr'), 'k-rev-000000000001')->>'replayed')::boolean,
  true, 'same key replays');
select is(pg_temp.fails($$ select pg_temp.reverse(1, pg_temp.tx('Fiverr'), pg_temp.ref('Fiverr')) $$),
  'conflict:already_reversed', 'a transaction is reversed once');
select is(api.my_transaction(pg_temp.u(4), pg_temp.s(4), pg_temp.tx('Fiverr'))->>'status', 'reversed',
  'the original shows Reversed');

-- ── Reinstatement (3) ──
create temp table v2 as select pg_temp.reverse(1, (select (r->>'transactionId')::uuid from v1),
  (select r->>'reference' from v1), null, 'other', 'Reversed by mistake') as r;
select is(pg_temp.posted(4), 4000.00::numeric, 'reversing the reversal reinstates the money');
select is(ledger.in_effect(pg_temp.tx('Fiverr')), true, 'the original is in effect again');
select is((select r->'reverses'->>'type' from v2), 'reversal', 'the reinstatement points at the reversal');

-- ── Availability (2) ──
do $$ begin
  perform api.submit_conversion(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.seg(4, 'USD'), '300.00',
    'NGN', '450000.00', null, 'Grey', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF":00"'), null, null,
    array[pg_temp.proof(3, 'conversion', pg_temp.id('m4'), 'k-cnv-hold-00000001')], 'k-cnv-hold-00000001');
end $$;
select throws_ok($$ select pg_temp.reverse(1, pg_temp.tx('Upwork'), pg_temp.ref('Upwork')) $$, 'P0001',
  'insufficient_funds', 'held money is not taken back');
select is(pg_temp.avail(4, 'USD'), 100.00::numeric, 'a failed reversal changes nothing');

-- ── Ledger (1) ──
select is((select count(*)::int from ledger.verify_balances()), 0, 'projections match the ledger');

select * from finish();
rollback;
