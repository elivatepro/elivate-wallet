-- Blueprint 03 — B6 tests 11, 14: the wallet hook runs once per created
-- membership on every path, inside the transaction; private schemas, RLS,
-- definer and search_path rules extend to invitations and the outbox.
begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

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

-- ── Privileges (14) ──
select ok(not has_schema_privilege('authenticated', 'outbox', 'usage') and not has_schema_privilege('anon', 'outbox', 'usage'),
  'anon/authenticated have no outbox access');
select ok(
  not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('org', 'outbox') and c.relkind = 'r' and not c.relrowsecurity
  ),
  'RLS is enabled on every org/outbox table'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('org', 'authz', 'outbox') and p.prosecdef
  ),
  'only api functions run as definer'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('org', 'outbox', 'api') and not coalesce(p.proconfig @> array['search_path=""'], false)
  ),
  'every org/outbox/api function pins an empty search_path'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api'
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))
  ),
  'no api function is executable by anon or authenticated'
);
select ok(
  (select bool_and(has_function_privilege('service_role', p.oid, 'execute'))
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'api' and (p.proname like '%invitation%' or p.proname like 'outbox_%')),
  'service_role executes the new api functions'
);
select ok(not has_function_privilege('authenticated', 'outbox.enqueue_email(text, text, text, uuid, uuid, uuid, text, jsonb)', 'execute'),
  'enqueue is internal');

-- ── Wallet hook (11) ──
create temp table hook_calls (membership_id uuid, seen boolean);
create or replace function org.on_membership_created(p_membership org.memberships)
returns void language plpgsql set search_path = '' as $$
begin
  insert into pg_temp.hook_calls
  values (p_membership.id, exists (select 1 from org.memberships where id = p_membership.id));
end;
$$;

insert into auth.users (id, email, aud, role, email_confirmed_at)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated', now() from generate_series(1, 10) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 10) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 7) n; end $$;
do $$ begin perform api.set_pin(pg_temp.u(10), pg_temp.s(10), repeat('a', 64)); end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');

insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), 'Pilot network', pg_temp.k()); end $$;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', null, array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'), array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(4), pg_temp.k());
  perform api.add_office_leader(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(5), 'Co-leader', pg_temp.k());
  perform api.replace_office_leader(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.m(5, pg_temp.id('T')), pg_temp.uid(6), 'Handover', pg_temp.k());
  perform api.move_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(4, pg_temp.id('T')), pg_temp.id('D'), 'Moved up', pg_temp.k());
  perform api.add_president(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(7), 'Co-founder', pg_temp.k());
  perform api.create_invitation(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('T')), pg_temp.id('T'), 'member',
    'u8@example.test', gen_random_uuid(), encode(sha256('t8'::bytea), 'hex'), null, pg_temp.k());
  perform api.accept_invitation(pg_temp.u(8), pg_temp.s(8), encode(sha256('t8'::bytea), 'hex'), null, pg_temp.k());
end $$;

select is((select count(*)::int from pg_temp.hook_calls), (select count(*)::int from org.memberships),
  'the hook runs once per created membership on every path (start, office, add, leader add/replace, move, president, accept)');
select is((select count(distinct membership_id)::int from pg_temp.hook_calls), (select count(*)::int from org.memberships),
  'never twice for the same membership');
select ok((select bool_and(seen) from pg_temp.hook_calls), 'the membership row exists when the hook runs');
select ok(not exists (
  select 1 from org.membership_events e where e.action = 'reactivated'
), 'sanity: no reactivation happened');

-- Reactivation is not a new belonging.
do $$ begin
  perform api.set_membership_status(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(8, pg_temp.id('T')), 'suspended', 'Pause', pg_temp.k());
  perform api.set_membership_status(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), (select id from org.memberships where user_id = pg_temp.u(8)), 'active', 'Back', pg_temp.k());
end $$;
select is((select count(*)::int from pg_temp.hook_calls), (select count(*)::int from org.memberships), 'reactivation does not call the hook');

-- A failing hook rolls the acceptance back.
create or replace function org.on_membership_created(p_membership org.memberships)
returns void language plpgsql set search_path = '' as $$
begin
  perform identity.fail('conflict', jsonb_build_object('reason', 'wallet_unavailable'));
end;
$$;
do $$ begin
  perform api.create_invitation(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('T')), pg_temp.id('T'), 'member',
    'u9@example.test', gen_random_uuid(), encode(sha256('t9'::bytea), 'hex'), null, pg_temp.k());
end $$;
select throws_ok(
  $$ select api.accept_invitation(pg_temp.u(9), pg_temp.s(9), encode(sha256('t9'::bytea), 'hex'), null, pg_temp.k()) $$,
  'P0001', 'conflict', 'a failing hook fails the acceptance'
);
select is((select count(*)::int from org.memberships where user_id = pg_temp.u(9)), 0, 'no membership is left behind');
select is((select status::text from org.invitations where email = 'u9@example.test'), 'pending', 'the invitation stays pending');

-- ── Tenant audit accepts invitation targets and stays append-only ──
select ok(exists (select 1 from audit.tenant_events where target_type = 'invitation'), 'invitation targets are recorded');
select throws_ok($$ update org.invitation_events set reason = 'x' $$, 'P0001', 'invariant_violation', 'invitation history is append-only');

select * from finish();
rollback;
