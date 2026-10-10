-- Blueprint 08 — B6 081: activity search, status filter, month summaries,
-- time zone basis and the detail additions (W-07 Activity).
begin;
create extension if not exists pgtap with schema extensions;
select plan(22);

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
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
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

-- ── Every item shows its durable status and title ──
select is(pg_temp.n(pg_temp.act()), 3, 'all currencies and dates until filtered');
select ok(
  (select bool_and(i->>'status' = 'posted') from jsonb_array_elements(pg_temp.act()->'items') i),
  'every ledger movement carries its durable status'
);
select is(
  (select i->>'title' from jsonb_array_elements(pg_temp.act()->'items') i where (i->>'transactionId')::uuid = pg_temp.id('fiverr')),
  'Fiverr order', 'income items carry their source as title'
);
select is(
  (select (i->>'pocketCount')::int from jsonb_array_elements(pg_temp.act()->'items') i where (i->>'transactionId')::uuid = pg_temp.id('fiverr')),
  5, 'and how many pockets they touched'
);

-- ── Search ──
select is(pg_temp.n(pg_temp.act('fiverr')), 1, 'search by source, case-insensitive');
select is(pg_temp.n(pg_temp.act('PRV-Toptal')), 1, 'search by provider reference');
select is(
  pg_temp.n(pg_temp.act(lower((select reference from ledger.transactions where id = pg_temp.id('upwork'))))), 1,
  'search by reference, case-insensitive'
);
select is(
  pg_temp.n(pg_temp.act(replace((select reference from ledger.transactions where id = pg_temp.id('upwork')), '-', ''))), 1,
  'reference without dashes'
);
select is(pg_temp.n(pg_temp.act('₦180,000.00')), 1, 'search by formatted amount');
select is(pg_temp.n(pg_temp.act('420')), 1, 'search by plain amount');
select is(pg_temp.n(pg_temp.act('nothing like this')), 0, 'no match is an authoritative empty');
select is(pg_temp.n(pg_temp.act('%_q')), 0, 'wildcards in the search are literal');

-- ── Status and direction ──
select is(pg_temp.n(pg_temp.act(p_status => 'posted')), 3, 'status filter: posted');
select throws_ok($$ select pg_temp.act(p_status => 'pending') $$, 'P0001', 'validation_error',
  'unknown statuses are refused, not silently empty');
select is(pg_temp.n(pg_temp.act(p_direction => 'out')), 0, 'money out is empty (nothing has left)');

-- ── Month summaries (aggregate read, per currency) ──
select is(
  (select c->>'in' from jsonb_array_elements(pg_temp.act()->'months'->0->'currencies') c where c->>'currency' = 'NGN'),
  '420000.00', 'money in per month and currency, from the full set'
);
select is(
  (select c->>'in' from jsonb_array_elements(pg_temp.act()->'months'->0->'currencies') c where c->>'currency' = 'USD'),
  '420.00', 'currencies are never added together'
);
select is(
  (select c->>'in' from jsonb_array_elements(
    api.my_activity(pg_temp.u(6), pg_temp.s(6), p_limit => 1)->'months'->0->'currencies') c where c->>'currency' = 'NGN'),
  '420000.00', 'the summary does not shrink to the page'
);

-- ── Time zone basis ──
select is(pg_temp.act(p_tz => 'Africa/Lagos')->>'timeZone', 'Africa/Lagos', 'an explicit zone is used');
select throws_ok($$ select pg_temp.act(p_tz => 'Mars/Olympus') $$, 'P0001', 'validation_error', 'unknown zones are refused');

-- ── Managed activity and detail ──
select is(
  jsonb_array_length(api.managed_wallet_activity(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), ledger.wallet_for(pg_temp.u(6)),
    p_query => 'upwork')->'items'), 1,
  'a leader can search a managed wallet'
);
select is(
  api.my_transaction(pg_temp.u(6), pg_temp.s(6), pg_temp.id('fiverr'))->'recordedBy'->>'uid', pg_temp.uid(4),
  'detail names who recorded it'
);

select * from finish();
rollback;
