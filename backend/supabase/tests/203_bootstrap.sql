-- Blueprint 20 — B5 203: api.app_bootstrap equals the separate reads behind
-- /api/session (state → profile → workspaces → capabilities → brand, with the
-- profile and the brand best-effort), and fails exactly where they fail.
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(20);

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
create function pg_temp.separate(n int, p_session uuid, p_membership uuid) returns jsonb language plpgsql as $$
declare
  state jsonb;
  profile jsonb;
  workspace jsonb;
  capabilities jsonb;
  brand jsonb;
begin
  state := api.security_state(pg_temp.u(n), p_session);
  if state->>'gate' <> 'ready' then
    return jsonb_build_object('state', state, 'profile', null, 'workspace', null, 'capabilities', null, 'brand', null);
  end if;
  begin
    profile := api.my_profile(pg_temp.u(n), p_session);
    -- What GET /identity/profile sends: the photo key becomes a flag.
    profile := (profile - 'photoKey') || jsonb_build_object('hasPhoto', jsonb_typeof(profile->'photoKey') is not distinct from 'string');
  exception when others then
    profile := null;
  end;
  select w.value into workspace from jsonb_array_elements(api.my_workspaces(pg_temp.u(n), p_session)) w
  where w.value->>'membershipId' = p_membership::text;
  if workspace is not null then
    capabilities := api.my_capabilities(pg_temp.u(n), p_session, p_membership);
    begin
      brand := api.workspace_brand(pg_temp.u(n), p_session, p_membership);
    exception when others then
      brand := null;
    end;
  end if;
  return jsonb_build_object('state', state, 'profile', profile, 'workspace', workspace, 'capabilities', capabilities,
    'brand', brand);
end $$;
create function pg_temp.boot(n int, p_membership uuid, p_session uuid default null) returns jsonb language sql volatile as
  $$ select api.app_bootstrap(pg_temp.u(n), coalesce(p_session, pg_temp.s(n)), p_membership) $$;

-- ── Equal to the separate reads (8) ──
select is(pg_temp.boot(4, pg_temp.id('m4')), pg_temp.separate(4, pg_temp.s(4), pg_temp.id('m4')),
  'a member in their workspace');
select is(pg_temp.boot(3, pg_temp.id('m3')), pg_temp.separate(3, pg_temp.s(3), pg_temp.id('m3')),
  'a Team Leader in theirs');
select is(pg_temp.boot(1, pg_temp.id('m1')), pg_temp.separate(1, pg_temp.s(1), pg_temp.id('m1')),
  'the President in theirs');
select is(pg_temp.boot(4, null), pg_temp.separate(4, pg_temp.s(4), null), 'no workspace chosen');
select is(pg_temp.boot(8, pg_temp.id('m8')), pg_temp.separate(8, pg_temp.s(8), pg_temp.id('m8')),
  'a network not yet paid: capabilities, no brand');
select is(pg_temp.boot(8, pg_temp.id('m8'))->'brand', 'null'::jsonb, 'the brand failing leaves it null');
select ok(jsonb_array_length(pg_temp.boot(4, pg_temp.id('m4'))->'capabilities'->'permissions') > 0,
  'the capabilities are filled');
select is(pg_temp.boot(4, pg_temp.id('m4'))->'brand'->>'tenantId', pg_temp.id('tenant')::text, 'and the brand');

-- ── The profile as the app shows it (2) ──
select is(pg_temp.boot(4, null)->'profile'->>'hasPhoto', 'false', 'the photo is a flag');
select ok(not (pg_temp.boot(4, null)->'profile' ? 'photoKey'), 'its storage key never leaves');

-- ── Not one of the caller's workspaces (3) ──
select is(pg_temp.boot(4, pg_temp.id('m3')), pg_temp.separate(4, pg_temp.s(4), pg_temp.id('m3')),
  'someone else''s membership: as before');
select is(pg_temp.boot(4, pg_temp.id('m3'))->'workspace', 'null'::jsonb, 'no workspace, no capabilities');
select is(pg_temp.boot(6, pg_temp.id('m6')), pg_temp.separate(6, pg_temp.s(6), pg_temp.id('m6')),
  'an ended membership: no workspace');

-- ── Listed but not usable (2) ──
select is(pg_temp.fails($$ select pg_temp.boot(5, pg_temp.id('m5')) $$), 'workspace_invalid',
  'a suspended membership is workspace_invalid');
select is(pg_temp.fails($$ select pg_temp.separate(5, pg_temp.s(5), pg_temp.id('m5')) $$), 'workspace_invalid',
  'exactly like the capabilities read');

-- ── The PIN gate and the session (3) ──
select is(pg_temp.boot(4, pg_temp.id('m4'), pg_temp.s(40)), pg_temp.separate(4, pg_temp.s(40), pg_temp.id('m4')),
  'before the PIN: the state only');
select is(pg_temp.boot(4, pg_temp.id('m4'), pg_temp.s(40))->'state'->>'gate', 'pin_required', 'which says so');
select is(pg_temp.fails($$ select pg_temp.boot(4, pg_temp.id('m4'), pg_temp.s(1)) $$), 'authentication_required',
  'another user''s session is refused');

-- ── Privileges (2) ──
select ok(has_function_privilege('service_role', 'api.app_bootstrap(uuid, uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'api.app_bootstrap(uuid, uuid, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'api.app_bootstrap(uuid, uuid, uuid)', 'execute'),
  'service_role only');
select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc
  where oid = 'api.app_bootstrap(uuid, uuid, uuid)'::regprocedure), 'definer with an empty search_path');

select * from finish();
rollback;
