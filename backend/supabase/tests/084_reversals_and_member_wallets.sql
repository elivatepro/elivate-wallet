-- Blueprint 08 — B6 084: reversals in activity and detail (Q03), the type
-- and status filters and total, and the member-wallet list/detail fields (Q04/Q05).
begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

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
create function pg_temp.ws(n int) returns uuid language sql stable as $$
  select id from org.memberships where user_id = pg_temp.u(n) and status = 'active'
  order by (role = 'member'), started_at limit 1
$$;
create function pg_temp.inc(n int, p_target uuid, p_amount text, p_currency text, p_source text) returns jsonb
language plpgsql as $$
declare
  key text := pg_temp.k();
  e uuid;
begin
  e := (api.create_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_target, key, 'receipt.pdf',
    'application/pdf', 1000, repeat('b', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 1000, repeat('b', 64), 'application/pdf');
  return api.record_income(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_target, p_currency, p_amount, p_source,
    to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), 'PRV-' || p_source, null, null, null, array[e], key);
end $$;
create function pg_temp.act(p_query text default null, p_status text default null, p_tz text default null,
  p_direction text default null) returns jsonb language sql volatile as
  $$ select api.my_activity(pg_temp.u(6), pg_temp.s(6), p_query => p_query, p_status => p_status, p_tz => p_tz,
       p_direction => p_direction) $$;
create function pg_temp.n(p jsonb) returns int language sql immutable as
  $$ select jsonb_array_length(p->'items') $$;

-- 1 President · 4 Team Leader · 5 sibling Team Leader · 6 member · 10 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from unnest(array[1, 4, 5, 6, 10]) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from unnest(array[1, 4, 5, 6, 10]) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from unnest(array[1, 4, 5, 6, 10]) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');
insert into ids select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), 'Pilot', pg_temp.k()); end $$;
insert into ids select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), 'team_leader', 'Team A', null,
  array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
insert into ids select 'T2', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), 'team_leader', 'Team B', null,
  array[pg_temp.uid(5)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('T'), pg_temp.uid(6), pg_temp.k());
end $$;
insert into ids select 'm6', pg_temp.ws(6);
insert into ids select 'fiverr', (pg_temp.inc(4, pg_temp.id('m6'), '180000.00', 'NGN', 'Fiverr order')->>'transactionId')::uuid;
insert into ids select 'toptal', (pg_temp.inc(4, pg_temp.id('m6'), '420.00', 'USD', 'Toptal milestone')->>'transactionId')::uuid;
insert into ids select 'upwork', (pg_temp.inc(1, pg_temp.id('m6'), '240000.00', 'NGN', 'Upwork contract')->>'transactionId')::uuid;


-- The reversal slice (W-15) adds the `reversal` type; here the constraint is
-- widened inside this test transaction only, to post one through ledger.post.
set constraints all immediate;
alter table ledger.transactions drop constraint transactions_type_check;
alter table ledger.transactions add constraint transactions_type_check check (type in ('income', 'reversal'));
set constraints all deferred;
insert into ids
select 'rev', ledger.post('reversal', refs.issue('REV'), pg_temp.id('m6'), pg_temp.u(1), pg_temp.k(),
  jsonb_build_array(jsonb_build_object('currency', 'NGN', 'postings', (
    select jsonb_agg(jsonb_build_object('accountId', p.account_id, 'amount', (-p.amount)::text))
    from ledger.postings p join ledger.journals j on j.id = p.journal_id
    where j.transaction_id = pg_temp.id('fiverr')))),
  '[]'::jsonb, jsonb_build_object('reversesTransactionId', pg_temp.id('fiverr')));

select is(
  (select i->>'status' from jsonb_array_elements(pg_temp.act()->'items') i where (i->>'transactionId')::uuid = pg_temp.id('fiverr')),
  'reversed', 'the original shows as reversed'
);
select is(
  (select i->>'amount' from jsonb_array_elements(pg_temp.act()->'items') i where (i->>'transactionId')::uuid = pg_temp.id('rev')),
  '-180000.00', 'the reversal is its own row with the opposite sign'
);
select is(jsonb_array_length(pg_temp.act(p_status => 'reversed')->'items'), 1, 'status filter: reversed');
select is((pg_temp.act(p_status => 'posted')->>'total')::int, 3, 'total counts the filtered set');
select is(
  jsonb_array_length(api.my_activity(pg_temp.u(6), pg_temp.s(6), p_type => 'reversal')->'items'), 1,
  'type filter: reversal'
);
select throws_ok($$ select api.my_activity(pg_temp.u(6), pg_temp.s(6), p_type => 'conversion') $$, 'P0001',
  'validation_error', 'types that do not exist yet are refused');
select is(
  api.my_transaction(pg_temp.u(6), pg_temp.s(6), pg_temp.id('fiverr'))->'reversedBy'->>'transactionId',
  pg_temp.id('rev')::text, 'detail links the original to its reversal'
);
select is(api.my_transaction(pg_temp.u(6), pg_temp.s(6), pg_temp.id('fiverr'))->>'status', 'reversed',
  'and says it was reversed');
select is(
  api.my_transaction(pg_temp.u(6), pg_temp.s(6), pg_temp.id('rev'))->'reverses'->>'reference',
  (select reference from ledger.transactions where id = pg_temp.id('fiverr')), 'the reversal links back'
);
select is((pg_temp.act()->'months'->0->'currencies'->0->>'out'), '-180000.00', 'month money out counts the reversal');

-- ── Member wallets (Q04/Q05) ──
select is((api.list_managed_wallets(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4))->>'people')::int, 1, 'people count');
select is(api.list_managed_wallets(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4))->'items'->0->>'status', 'active',
  'membership status per person');
select is(api.list_managed_wallets(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4))->'scope'->>'name', 'Team A',
  'scope name for the header');
select is(
  api.managed_wallet(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), ledger.wallet_for(pg_temp.u(6)))->'memberships'->0->>'officeName',
  'Team A', 'wallet header: role and office here'
);
select is(
  (select c->>'available' from jsonb_array_elements(
    api.list_managed_wallets(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4))->'items'->0->'currencies') c where c->>'currency' = 'NGN'),
  '240000.00', 'the list shows available per currency'
);

select * from finish();
rollback;
