-- Blueprint 20 — B5 204: api.home_view equals the separate reads behind
-- /api/home (workspaces → own wallet → latest five + split), resolves the
-- tenant from the membership, and fails where they failed. Also the own
-- money reads by membership (my_wallet, my_activity).
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
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
  where user_id = pg_temp.u(n) and status <> 'ended' and office_id is not distinct from p_office
  order by started_at desc, id limit 1
$$;
create function pg_temp.ws(n int) returns uuid language sql stable as $$
  select id from org.memberships where user_id = pg_temp.u(n) and status = 'active'
  order by (role = 'member'), started_at limit 1
$$;
create function pg_temp.income(p_target uuid, p_currency text, p_amount text, p_source text) returns uuid
language plpgsql as $$
declare
  key text := pg_temp.k();
  e uuid;
begin
  e := (api.create_evidence_upload(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), p_target, key, 'r.pdf',
    'application/pdf', 1000, repeat('b', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), e, 1000, repeat('b', 64), 'application/pdf');
  return (api.record_income(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), p_target, p_currency, p_amount, p_source,
    to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null, array[e], key)->>'transactionId')::uuid;
end $$;
create function pg_temp.fails(p_sql text) returns text language plpgsql as $$
declare
  msg text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics msg = message_text;
  return msg;
end $$;

-- 1 President · 3 TL (T) · 4 member (T) · 5 member (T, suspended) · 6 member (T, ended)
-- 8 founder of a network not yet paid · 9 admin. Session 40 is a second
-- session of member 4 that has not entered the PIN.
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 9) n;
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 9) n;
insert into auth.sessions (id, user_id, created_at, updated_at) values (pg_temp.s(40), pg_temp.u(4), now(), now());
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
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), 'team_leader', 'Team A', null,
  array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('T'), pg_temp.uid(n), pg_temp.k())
  from generate_series(4, 6) n;
end $$;
insert into ids select 'm' || n, pg_temp.m(n, pg_temp.id('T')) from generate_series(3, 6) n;
insert into ids select 'm1', pg_temp.ws(1);
insert into ids select 'm8', pg_temp.ws(8);
do $$ begin
  perform pg_temp.income(pg_temp.id('m4'), case when n % 2 = 0 then 'USD' else 'NGN' end, (n * 1000)::text || '.00',
    'Order ' || n) from generate_series(1, 7) n;
  perform pg_temp.income(pg_temp.id('m5'), 'NGN', '5000.00', 'Before leave');
  perform api.set_membership_status(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('m5'), 'suspended',
    'On leave', pg_temp.k());
  perform api.end_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('m6'), 'Left the team',
    pg_temp.k());
end $$;

-- The previous chain, as the app server ran it.
create function pg_temp.separate(n int, p_membership uuid) returns jsonb language plpgsql as $$
declare
  workspace jsonb;
  wallet jsonb;
  network jsonb;
  allocation jsonb;
  split jsonb;
  -- Blueprint 44: Home also carries the open withdrawals (Activity's first page).
  empty constant jsonb := jsonb_build_object('network', null, 'activity', '[]'::jsonb, 'pending', '[]'::jsonb,
    'split', null);
begin
  select w.value into workspace from jsonb_array_elements(api.my_workspaces(pg_temp.u(n), pg_temp.s(n))) w
  where w.value->>'membershipId' = p_membership::text;
  if workspace is null then
    perform identity.fail('workspace_invalid');
  end if;
  begin
    wallet := api.my_wallet(pg_temp.u(n), pg_temp.s(n));
  exception when others then
    if sqlerrm <> 'no_wallet' then raise; end if;
  end;
  select x.value into network from jsonb_array_elements(wallet->'networks') x
  where x.value->>'tenantId' = workspace->>'tenantId';
  if network is null then
    return empty;
  end if;
  begin
    allocation := api.allocation_policy(pg_temp.u(n), pg_temp.s(n), p_membership);
    split := coalesce((select jsonb_agg(jsonb_build_object('pocketId', p.value->'pocketId', 'percent', p.value->'percent')
      order by p.ordinality) from jsonb_array_elements(allocation->'pockets') with ordinality p), '[]'::jsonb);
  exception when others then
    split := null;
  end;
  return jsonb_build_object('network', network,
    'activity', api.my_activity(pg_temp.u(n), pg_temp.s(n), (workspace->>'tenantId')::uuid, p_limit => 5)->'items',
    'pending', coalesce((select jsonb_agg(x.value order by x.ordinality) from jsonb_array_elements(
      api.my_activity(pg_temp.u(n), pg_temp.s(n), (workspace->>'tenantId')::uuid)->'pending') with ordinality x
      where x.ordinality <= 5), '[]'::jsonb),
    'split', split);
end $$;
create function pg_temp.home(n int, p_membership uuid, p_session uuid default null) returns jsonb language sql volatile as
  $$ select api.home_view(pg_temp.u(n), coalesce(p_session, pg_temp.s(n)), p_membership) $$;

-- ── Equal to the separate reads (8) ──
select is(pg_temp.home(4, pg_temp.id('m4')), pg_temp.separate(4, pg_temp.id('m4')), 'a member with money');
select is(jsonb_array_length(pg_temp.home(4, pg_temp.id('m4'))->'activity'), 5, 'the latest five movements');
select is(pg_temp.home(4, pg_temp.id('m4'))->'network'->>'tenantId', pg_temp.id('tenant')::text,
  'the network comes from the membership');
select ok(jsonb_array_length(pg_temp.home(4, pg_temp.id('m4'))->'split') > 0
  and pg_temp.home(4, pg_temp.id('m4'))->'split'->0 ?& array['pocketId', 'percent'], 'the split percentages');
select is(pg_temp.home(3, pg_temp.id('m3')), pg_temp.separate(3, pg_temp.id('m3')), 'a Team Leader with no money yet');
select is(pg_temp.home(1, pg_temp.id('m1')), pg_temp.separate(1, pg_temp.id('m1')), 'the President Team');
select is(pg_temp.home(5, pg_temp.id('m5')), pg_temp.separate(5, pg_temp.id('m5')),
  'a suspended membership still shows its balances');
select is(pg_temp.home(5, pg_temp.id('m5'))->'split', 'null'::jsonb, 'without the split (it needs an active workspace)');

-- ── Failures (5) ──
select is(pg_temp.fails($$ select pg_temp.home(4, pg_temp.id('m3')) $$), 'workspace_invalid',
  'someone else''s membership');
select is(pg_temp.fails($$ select pg_temp.home(6, pg_temp.id('m6')) $$), 'workspace_invalid', 'an ended membership');
select is(pg_temp.fails($$ select pg_temp.home(4, null) $$), 'workspace_invalid', 'no membership');
select is(pg_temp.fails($$ select pg_temp.home(4, pg_temp.id('m4'), pg_temp.s(40)) $$), 'pin_required',
  'the PIN gate is not ready');
select is(pg_temp.fails($$ select pg_temp.home(4, pg_temp.id('m4'), pg_temp.s(1)) $$), 'authentication_required',
  'another user''s session');

-- ── Own money reads by membership (7) ──
select is(api.my_activity(pg_temp.u(4), pg_temp.s(4), p_membership_id => pg_temp.id('m4'), p_limit => 3),
  api.my_activity(pg_temp.u(4), pg_temp.s(4), pg_temp.id('tenant'), p_limit => 3),
  'activity by membership = activity by tenant');
select is(api.my_activity(pg_temp.u(4), pg_temp.s(4), p_membership_id => pg_temp.id('m4'), p_currency => 'USD',
    p_cursor => api.my_activity(pg_temp.u(4), pg_temp.s(4), pg_temp.id('tenant'), p_currency => 'USD', p_limit => 1)->>'nextCursor',
    p_limit => 1),
  api.my_activity(pg_temp.u(4), pg_temp.s(4), pg_temp.id('tenant'), p_currency => 'USD',
    p_cursor => api.my_activity(pg_temp.u(4), pg_temp.s(4), pg_temp.id('tenant'), p_currency => 'USD', p_limit => 1)->>'nextCursor',
    p_limit => 1),
  'with filters and a cursor too');
select is(pg_temp.fails($$ select api.my_activity(pg_temp.u(4), pg_temp.s(4), pg_temp.id('tenant'),
  p_membership_id => pg_temp.id('m4')) $$), 'validation_error', 'not both a tenant and a membership');
select is(pg_temp.fails($$ select api.my_activity(pg_temp.u(4), pg_temp.s(4), p_membership_id => pg_temp.id('m3')) $$),
  'workspace_invalid', 'never someone else''s membership');
select is(api.my_wallet(pg_temp.u(4), pg_temp.s(4), pg_temp.id('m4'))->'networks',
  (select jsonb_agg(x.value) from jsonb_array_elements(api.my_wallet(pg_temp.u(4), pg_temp.s(4))->'networks') x
   where x.value->>'tenantId' = pg_temp.id('tenant')::text),
  'the wallet by membership is that network''s part of the whole wallet');
select is(api.my_wallet(pg_temp.u(4), pg_temp.s(4))->>'walletId',
  api.my_wallet(pg_temp.u(4), pg_temp.s(4), pg_temp.id('m4'))->>'walletId', 'the same wallet');
select is(pg_temp.fails($$ select api.my_wallet(pg_temp.u(4), pg_temp.s(4), pg_temp.id('m6')) $$),
  'workspace_invalid', 'never another person''s membership');

-- ── Privileges (2) ──
select ok(not exists (
    select 1 from unnest(array['api.home_view(uuid, uuid, uuid)', 'api.my_wallet(uuid, uuid, uuid)',
      'api.my_activity(uuid, uuid, uuid, text, uuid, text, text, text, text, text, integer, text, text, text, uuid)']) f
    where not has_function_privilege('service_role', f::regprocedure, 'execute')
       or has_function_privilege('anon', f::regprocedure, 'execute')
       or has_function_privilege('authenticated', f::regprocedure, 'execute')),
  'service_role only');
select ok((select bool_and(prosecdef and proconfig @> array['search_path=""']) from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api' and p.proname in ('home_view', 'my_wallet', 'my_activity')), 'definers with an empty search_path');

select * from finish();
rollback;
