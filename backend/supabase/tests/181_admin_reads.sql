-- Blueprint 18 — B6 181: platform Admin reads (W-23). Only platform admins
-- (never a President by role); masked contact details; no PINs, NINs, full
-- account numbers or IPs; global search by every key; the merged,
-- immutable audit with filters and a cursor; paged lists.
begin;
create extension if not exists pgtap with schema extensions;
select plan(35);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('18100000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('28100000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
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
create function pg_temp.a(p_fn text) returns jsonb language plpgsql as $$
declare
  result jsonb;
begin
  execute format('select api.%s(%L::uuid, %L::uuid)', p_fn, pg_temp.u(9), pg_temp.s(9)) into result;
  return result;
end $$;

-- 1 President Cedar (Ifeoma Okaforqz) · 2 member Cedar (Chidi Okaforqz) · 3 President Pine · 9 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'person' || n || '@example.test', 'authenticated', 'authenticated' from unnest(array[1, 2, 3, 9]) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from unnest(array[1, 2, 3, 9]) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from unnest(array[1, 2, 3, 9]) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(9), 'Test admin');
update identity.profiles set first_name = 'Ifeoma', last_name = 'Okaforqz', phone = '+2348012342210', phone_source = 'self' where user_id = pg_temp.u(1);
update identity.profiles set first_name = 'Chidi', last_name = 'Okaforqz' where user_id = pg_temp.u(2);
-- Other test files may commit their own networks (169 uses dblink): count from a baseline.
create temp table base as select (select count(*)::int from org.tenants) as networks,
  (select count(*)::int from org.tenants where status = 'pending_payment') as pending;
insert into ids select 'cedar', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Cedar Kxq Network', 'CDR', pg_temp.k())
  ->>'tenantId')::uuid;
insert into ids select 'pine', (api.start_network(pg_temp.u(3), pg_temp.s(3), 'Pine Kxq Network', 'PIN', pg_temp.k())
  ->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('cedar'), 'Pilot', pg_temp.k());
end $$;
insert into ids select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), 'team_leader', 'Lagos Kxq office', null,
  array[pg_temp.uid(1)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('T'), pg_temp.uid(2), pg_temp.k());
end $$;
-- A saved bank account (fingerprint only) and synthetic secrets that must never show.
insert into identity.nin_records (user_id, nin_fingerprint, nin_last4, given_name, surname, method, verified_at)
values (pg_temp.u(2), repeat('f', 64), '4321', 'Chidi', 'Okaforqz', 'provider', now());
insert into identity.sign_ins (user_id, session_id, method, ip, device, unusual, reasons)
values (pg_temp.u(2), pg_temp.s(2), 'password', '203.0.113.7', 'Chrome on Android', true, array['new_device']);

-- ── Only platform admins (6) ──
select is(pg_temp.fails($$ select api.admin_overview(pg_temp.u(1), pg_temp.s(1)) $$), 'authorization_denied:',
  'a President cannot open the overview');
select is(pg_temp.fails($$ select api.admin_tenants(pg_temp.u(1), pg_temp.s(1)) $$), 'authorization_denied:',
  'nor list networks');
select is(pg_temp.fails($$ select api.admin_search(pg_temp.u(2), pg_temp.s(2), 'Okaforqz') $$), 'authorization_denied:',
  'nor search');
select is(pg_temp.fails($$ select api.admin_audit(pg_temp.u(1), pg_temp.s(1)) $$), 'authorization_denied:',
  'nor read the platform audit');
select is((api.admin_me(pg_temp.u(1), pg_temp.s(1))->>'isAdmin')::boolean, false, 'admin_me says no to a President');
select is((pg_temp.a('admin_me')->>'isAdmin')::boolean, true, 'and yes to an admin');

-- ── Overview and networks (7) ──
select is((pg_temp.a('admin_overview')->'networks'->>'total')::int, (select networks + 2 from base), 'two more networks');
select is((pg_temp.a('admin_overview')->'networks'->'byState'->>'pending_payment')::int, (select pending + 1 from base),
  'one more waiting for payment');
select is(jsonb_array_length(pg_temp.a('admin_overview')->'switches'), 8, 'the switch strip');
select is((api.admin_tenants(pg_temp.u(9), pg_temp.s(9), 'kxq', 'pending_payment')->'items'->0->>'name'),
  'Pine Kxq Network', 'filter by state');
select is(jsonb_array_length(api.admin_tenants(pg_temp.u(9), pg_temp.s(9), 'Ifeoma')->'items'), 1,
  'search networks by President');
create temp table page1 as select api.admin_tenants(pg_temp.u(9), pg_temp.s(9), 'kxq', null, null, 1) as r;
select is((select api.admin_tenants(pg_temp.u(9), pg_temp.s(9), 'kxq', null, r->>'nextCursor', 1)->'items'->0->>'name'
  from page1), 'Pine Kxq Network', 'the cursor pages on');
select is((api.admin_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('cedar'))->'organization'->>'people')::int, 2,
  'network detail counts people');

-- ── Accounts (8) ──
create temp table acct as select api.admin_account(pg_temp.u(9), pg_temp.s(9), lower(pg_temp.uid(2))) as r;
select is((select r->>'email' from acct), 'p•••••@example.test', 'emails are masked');
select is((select r->'security'->>'unusualSignIns7d' from acct), '1', 'unusual sign-ins are counted');
select ok((select r::text not like '%203.0.113%' from acct), 'no IP address is shown');
select ok((select r::text not like '%4321%' and r::text not like '%ffffffff%' from acct), 'no NIN is shown');
select ok((select r::text not like '%pin_hash%' from acct), 'no PIN material is shown');
select is((select r->'security'->>'pin' from acct), 'set', 'only the PIN state');
select is(jsonb_array_length(api.admin_accounts(pg_temp.u(9), pg_temp.s(9), 'okaforqz')->'items'), 2,
  'accounts by name');
select is(api.admin_account(pg_temp.u(9), pg_temp.s(9), pg_temp.uid(1))->>'phone', '+234 •• •••• 2210',
  'phones are masked');

-- ── Global search (8) ──
select is(api.admin_search(pg_temp.u(9), pg_temp.s(9), pg_temp.uid(2))->'accounts'->0->>'matchedOn', 'uid', 'by UID');
select is(jsonb_array_length(api.admin_search(pg_temp.u(9), pg_temp.s(9), 'Okaforqz')->'accounts'), 2, 'by name');
select is(api.admin_search(pg_temp.u(9), pg_temp.s(9), 'person2@example')->'accounts'->0->>'matchedOn', 'email',
  'by email prefix');
select is(api.admin_search(pg_temp.u(9), pg_temp.s(9), '0801 234 2210')->'accounts'->0->>'matchedOn', 'phone',
  'by phone digits');
select is(api.admin_search(pg_temp.u(9), pg_temp.s(9), '•••• 2210', null, null,
  encode(extensions.digest('phone:8012342210', 'sha256'), 'hex'))->'accounts'->0->>'matchedOn', 'phone',
  'a 10-digit search also matches the phone, by hash only');
select is(api.admin_search(pg_temp.u(9), pg_temp.s(9), 'lagos kxq')->'offices'->0->>'name', 'Lagos Kxq office', 'by office');
select is(api.admin_search(pg_temp.u(9), pg_temp.s(9), 'pine kxq')->'networks'->0->>'name', 'Pine Kxq Network',
  'by network');
select is(pg_temp.fails($$ select api.admin_search(pg_temp.u(9), pg_temp.s(9), 'x', array['nothex']) $$),
  'validation_error:', 'bank fingerprints are validated');

-- ── Platform audit (6) ──
create temp table aud as select api.admin_audit(pg_temp.u(9), pg_temp.s(9)) as r;
select ok((select jsonb_array_length(r->'items') from aud) > 0, 'platform and network events in one list');
select ok((select bool_and(at >= coalesce(next_at, '-infinity')) from (
  select (x->>'at')::timestamptz as at, lead((x->>'at')::timestamptz) over (order by n) as next_at
  from aud, jsonb_array_elements(r->'items') with ordinality as e(x, n)) o), 'newest first');
select ok((select bool_and(x->>'group' = 'controls') from jsonb_array_elements(
  api.admin_audit(pg_temp.u(9), pg_temp.s(9), null, 'controls')->'items') x), 'filter by action group');
select ok((select bool_and(x->>'tenantId' = pg_temp.id('cedar')::text) from jsonb_array_elements(
  api.admin_audit(pg_temp.u(9), pg_temp.s(9), null, null, null, pg_temp.id('cedar'))->'items') x
  where x->>'tenantId' is not null), 'filter by network');
create temp table ap1 as select api.admin_audit(pg_temp.u(9), pg_temp.s(9), null, null, null, null, null, null, null, 2) as r;
select ok((select (api.admin_audit(pg_temp.u(9), pg_temp.s(9), null, null, null, null, null, null, r->>'nextCursor', 2)
  ->'items'->0->>'eventId') not in (select x->>'eventId' from ap1, jsonb_array_elements(r->'items') x) from ap1),
  'the cursor never repeats an event');
select ok(pg_temp.a('admin_admins') @> jsonb_build_array(jsonb_build_object('uid', pg_temp.uid(9), 'isYou', true)),
  'the admin is listed as you');

select * from finish();
rollback;
