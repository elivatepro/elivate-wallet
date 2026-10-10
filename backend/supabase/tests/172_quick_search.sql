-- Blueprint 17 — B6 172: quick search (P-06). Results never widen authority:
-- people, offices and records come back only where the workspace can already
-- see them; email and phone are masked; references match by prefix; other
-- networks never appear.
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
create function pg_temp.income_receipt(n int, p_target uuid, p_key text) returns uuid language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_target, p_key, 'r.pdf',
    'application/pdf', 1000, repeat('b', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 1000, repeat('b', 64), 'application/pdf');
  return e;
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
  return msg || ':' || coalesce(case when detail like '{%' then detail::jsonb->>'reason' end, '');
end $$;
create function pg_temp.find(n int, p_q text) returns jsonb language sql volatile as
  $$ select api.quick_search(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_q) $$;
create function pg_temp.uids(p_r jsonb) returns text language sql immutable as
  $$ select coalesce(string_agg(e->'person'->>'uid', ',' order by e->'person'->>'uid'), '')
     from jsonb_array_elements(p_r->'people') e $$;
create function pg_temp.offices(p_r jsonb) returns text language sql immutable as
  $$ select coalesce(string_agg(e->>'name', ',' order by e->>'name'), '') from jsonb_array_elements(p_r->'offices') e $$;
create function pg_temp.kinds(p_r jsonb) returns text language sql immutable as
  $$ select coalesce(string_agg(e->>'kind', ',' order by e->>'kind'), '') from jsonb_array_elements(p_r->'records') e $$;

-- 1 President · 2 Director (D) · 3 TL (Team A) · 4 member (A) · 5 TL (Team B) · 6 member (B)
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
  perform api.record_income(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(4, pg_temp.id('T')), 'NGN', '10000.00',
    'Fiverr', to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null,
    array[pg_temp.income_receipt(1, pg_temp.m(4, pg_temp.id('T')), 'k-income-0000000001')], 'k-income-0000000001');
end $$;
insert into identity.profiles (user_id, first_name, last_name, phone, phone_source)
values (pg_temp.u(4), 'Adaeze', 'Nwosu', '+2348012342210', 'self'), (pg_temp.u(6), 'Kemi', 'Okafor', '+2348099990000', 'self')
on conflict (user_id) do update set first_name = excluded.first_name, last_name = excluded.last_name,
  phone = excluded.phone, phone_source = excluded.phone_source;
insert into payout.banks (provider, code, name, active) values ('paystack', '058', 'Guaranty Trust Bank', true);
insert into ids select 'A4', pg_temp.add_account(4, '058', '0123456789', 'ADAEZE NWOSU');
insert into ids select 'w', (api.request_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.seg(4), '500.00',
  pg_temp.id('A4'), pg_temp.k())->>'withdrawalId')::uuid;
create temp table refs as select
  (select reference from finance.withdrawals where id = pg_temp.id('w')) as wdr,
  (select reference from ledger.transactions where owner_user_id = pg_temp.u(4) and type = 'income') as inc;

-- ── People (8) ──
select is(pg_temp.uids(pg_temp.find(3, 'Okafor')), '', 'a Team Leader never finds another team''s member');
select is(pg_temp.uids(pg_temp.find(3, 'Nwosu')), pg_temp.uid(4), 'but finds their own member');
select is(pg_temp.uids(pg_temp.find(2, 'EW-')), (select string_agg(pg_temp.uid(n), ',' order by pg_temp.uid(n))
  from unnest(array[2, 3, 4, 5, 6]) n), 'a Director finds everyone below, and themself, by UID');
select is(pg_temp.uids(pg_temp.find(6, 'Nwosu')), '', 'a member finds nobody else');
select is(pg_temp.uids(pg_temp.find(1, pg_temp.uid(6))), pg_temp.uid(6), 'the President finds anyone by UID');
select is(pg_temp.find(1, 'u6@example')->'people'->0->>'emailMasked', 'u•••••@example.test',
  'by email, returned masked');
select is(pg_temp.find(1, '0801 234 2210')->'people'->0->>'phoneMasked', '+234 •• •••• 2210', 'by phone, masked');
select is((select count(*)::int from jsonb_array_elements(pg_temp.find(1, 'u6@example')->'people') e
  where e::text like '%u6@example.test%'), 0, 'never the raw email');

-- ── Offices (3) ──
select is(pg_temp.offices(pg_temp.find(3, 'Team')), 'Team A', 'a Team Leader sees their office');
select is(pg_temp.offices(pg_temp.find(2, 'Team')), 'Team A,Team B', 'a Director sees the offices below');
select is(pg_temp.offices(pg_temp.find(6, 'Team')), '', 'a member sees no offices');

-- ── Records by reference (8) ──
select is(pg_temp.kinds(pg_temp.find(3, (select wdr from refs))), 'withdrawal', 'the approver finds the withdrawal');
select is(pg_temp.kinds(pg_temp.find(5, (select wdr from refs))), '', 'another team''s leader does not');
select is(pg_temp.kinds(pg_temp.find(4, (select lower(replace(wdr, '-', '')) from refs))), 'withdrawal',
  'the owner finds their own, typed loosely');
select is(pg_temp.kinds(pg_temp.find(6, (select wdr from refs))), '', 'another member does not');
select is(pg_temp.kinds(pg_temp.find(2, (select inc from refs))), 'transaction', 'a Director finds the income');
select is(pg_temp.kinds(pg_temp.find(6, (select inc from refs))), '', 'another member does not');
select is(pg_temp.kinds(pg_temp.find(2, (select left(wdr, 8) from refs))), 'withdrawal', 'a reference prefix is enough');
select is(pg_temp.find(1, (select wdr from refs))->'records'->0->'amount'->>'amount', '500.00',
  'exact amounts with currency');

-- ── Boundaries (3) ──
select is(pg_temp.uids(pg_temp.find(8, 'Nwosu')) || pg_temp.kinds(pg_temp.find(8, (select wdr from refs))), '',
  'another network sees nothing');
select is(pg_temp.fails($$ select pg_temp.find(1, 'a') $$), 'validation_error:', 'two characters at least');
select is(pg_temp.fails($$ select api.quick_search(pg_temp.u(8), pg_temp.s(8), pg_temp.ws(1), 'Nwosu') $$),
  'workspace_invalid:', 'only from one''s own workspace');

select * from finish();
rollback;
