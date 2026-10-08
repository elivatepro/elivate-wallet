-- Blueprint 04 — B6 042: per-network pockets and split, versions, allocation.
begin;
create extension if not exists pgtap with schema extensions;
select plan(36);

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
create function pg_temp.pocket(p_name text) returns uuid language sql stable as $$
  select id from ledger.pockets where tenant_id = pg_temp.id('tenant') and name = p_name and status = 'active'
$$;
create function pg_temp.policy() returns uuid language sql stable as
  $$ select policy_id from ledger.active_allocation_policies where tenant_id = pg_temp.id('tenant') $$;
create function pg_temp.split(p_amount numeric, p_currency text default 'NGN') returns text[] language sql stable as $$
  select array_agg(a.amount::text order by l.sort_order)
  from ledger.allocate(pg_temp.policy(), p_currency, p_amount) a
  join ledger.allocation_policy_lines l on l.policy_id = pg_temp.policy() and l.pocket_id = a.pocket_id
$$;
create function pg_temp.p(p_id uuid, p_name text, p_bps int) returns jsonb language sql immutable as
  $$ select jsonb_strip_nulls(jsonb_build_object('pocketId', p_id, 'name', p_name, 'basisPoints', p_bps)) $$;
create function pg_temp.set(n int, p_version int, p_pockets jsonb, p_reason text default 'New split', p_key text default null)
returns jsonb language sql volatile as $$
  select api.set_allocation(pg_temp.u(n), pg_temp.s(n), pg_temp.m(n, case when n = 3 then pg_temp.id('D') end),
    p_version, p_pockets, p_reason, coalesce(p_key, pg_temp.k()))
$$;

-- 1 President · 3 Director · 6 member · 9 founder of a network awaiting payment · 10 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 10) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 10) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 10) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
insert into ids
select 'pending', (api.start_network(pg_temp.u(9), pg_temp.s(9), 'Abuja Network', 'ABJ', pg_temp.k())->>'tenantId')::uuid;
do $$ begin perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), 'Pilot', pg_temp.k()); end $$;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', null, array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('D'), pg_temp.uid(6), pg_temp.k());
end $$;

-- ── Seeding at activation (Q1, Q3) ──
select is(
  (select array_agg(name order by sort_order) from ledger.pockets where tenant_id = pg_temp.id('tenant')),
  array['Point Value', 'Business Investment', 'Personal Investment', 'Upkeep', 'Savings', 'Debt'],
  'activation creates the five pockets and Debt, in display order'
);
select is(
  (select array_agg(basis_points order by sort_order) from ledger.allocation_policy_lines where policy_id = pg_temp.policy()),
  array[4000, 1000, 1500, 2500, 1000], 'version 1 is the default split 40/10/15/25/10'
);
select ok(not exists (select 1 from ledger.pockets where tenant_id = pg_temp.id('pending')), 'a network awaiting payment has no pockets yet');
select lives_ok($$ set constraints all immediate $$, 'the seeded version passes its commit checks');
set constraints all deferred;

-- ── Allocation (Q5) ──
select is(pg_temp.split(0.01), array['0.01', '0.00', '0.00', '0.00', '0.00'], 'one kobo goes to the largest fraction');
select is(pg_temp.split(0.03), array['0.01', '0.00', '0.01', '0.01', '0.00'], 'leftover kobo follow the largest remainders');
select is(pg_temp.split(1000), array['400.00', '100.00', '150.00', '250.00', '100.00'], 'exact split when it divides');
create temp table amounts as
select round((random() * 10000000)::numeric, 2) + 0.01 as amount from generate_series(1, 1000);
select ok(
  not exists (
    select 1 from amounts x
    cross join lateral (select sum(a.amount) as total, bool_and(abs(a.amount - x.amount * a.basis_points / 10000) < 0.01) as close
                        from ledger.allocate(pg_temp.policy(), 'NGN', x.amount) a) r
    where r.total <> x.amount or not r.close
  ),
  '1,000 random amounts: lines sum exactly and each is within one kobo of its share'
);
select ok(
  not exists (select 1 from amounts x where pg_temp.split(x.amount) <> pg_temp.split(x.amount)),
  'the split is deterministic'
);
select throws_ok($$ select * from ledger.allocate(pg_temp.policy(), 'NGN', 0.001) $$, 'P0001', 'validation_error',
  'amounts beyond the scale cannot be split');

-- ── Who may change the split (decision 11) ──
select throws_ok(
  $$ select pg_temp.set(3, 1, jsonb_build_array(pg_temp.p(pg_temp.pocket('Point Value'), 'Point Value', 10000))) $$,
  'P0001', 'authorization_denied', 'a Director cannot change the split'
);
select throws_ok(
  $$ select api.set_role_permission(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'manage_allocation', true, 'Delegate', pg_temp.k()) $$,
  'P0001', 'permission_not_grantable', 'manage_allocation is protected'
);
select is(
  (select array[protected, grantable] from authz.permission_catalog where key = 'manage_allocation'),
  array[true, false], 'manage_allocation is in the catalogue, protected and not grantable'
);
select throws_ok(
  $$ select pg_temp.set(1, 1, jsonb_build_array(pg_temp.p(pg_temp.pocket('Point Value'), 'Point Value', 10000)), '') $$,
  'P0001', 'validation_error', 'a reason is required'
);
update identity.session_pin_proofs set verified_at = now() - interval '10 minutes' where user_id = pg_temp.u(1);
select throws_ok(
  $$ select pg_temp.set(1, 1, jsonb_build_array(pg_temp.p(pg_temp.pocket('Point Value'), 'Point Value', 10000))) $$,
  'P0001', 'step_up_required', 'the PIN is required'
);
update identity.session_pin_proofs set verified_at = now() where user_id = pg_temp.u(1);

-- ── Validation ──
select throws_ok(
  $$ select pg_temp.set(1, 1, jsonb_build_array(pg_temp.p(pg_temp.pocket('Point Value'), 'Point Value', 9999))) $$,
  'P0001', 'policy_invalid', 'the split must total 100%'
);
select throws_ok(
  $$ select pg_temp.set(1, 1, jsonb_build_array(pg_temp.p(null, 'Fun', 5000), pg_temp.p(null, 'fun', 5000))) $$,
  'P0001', 'policy_invalid', 'pocket names are unique'
);
select throws_ok(
  $$ select pg_temp.set(1, 1, jsonb_build_array(pg_temp.p((select id from ledger.pockets where tenant_id = pg_temp.id('tenant') and kind = 'debt'), 'Debt', 10000))) $$,
  'P0001', 'policy_invalid', 'Debt is fixed and takes no income'
);
select throws_ok(
  $$ select pg_temp.set(1, 7, jsonb_build_array(pg_temp.p(pg_temp.pocket('Point Value'), 'Point Value', 10000))) $$,
  'P0001', 'conflict', 'a stale version is refused'
);

-- ── Rename, add, reorder, change percentages ──
insert into ids values ('pv', pg_temp.pocket('Point Value')), ('bi', pg_temp.pocket('Business Investment')),
  ('pi', pg_temp.pocket('Personal Investment')), ('up', pg_temp.pocket('Upkeep')), ('sv', pg_temp.pocket('Savings'));
create temp table keys as select pg_temp.k() as k;
create temp table v2 as
select pg_temp.set(1, 1, jsonb_build_array(
  pg_temp.p(pg_temp.id('sv'), 'Savings', 2000),
  pg_temp.p(pg_temp.id('pv'), 'Points', 3000),
  pg_temp.p(pg_temp.id('bi'), 'Business Investment', 1000),
  pg_temp.p(pg_temp.id('pi'), 'Personal Investment', 1000),
  pg_temp.p(pg_temp.id('up'), 'Upkeep', 2000),
  pg_temp.p(null, 'Emergency', 1000)), 'Pilot review', (select k from keys)) as r;
select is((select (r->>'version')::int from v2), 2, 'a change creates version 2');
select is(
  (select array_agg(name order by sort_order) from ledger.pockets where tenant_id = pg_temp.id('tenant') and status = 'active'),
  array['Savings', 'Points', 'Business Investment', 'Personal Investment', 'Upkeep', 'Emergency', 'Debt'],
  'pockets are renamed, reordered and added'
);
select is(
  (select array_agg(l.name order by l.sort_order) from ledger.allocation_policy_lines l
   join ledger.allocation_policies p on p.id = l.policy_id where p.tenant_id = pg_temp.id('tenant') and p.version = 1),
  array['Point Value', 'Business Investment', 'Personal Investment', 'Upkeep', 'Savings'],
  'version 1 keeps its own snapshot'
);
select is(
  (select pg_temp.set(1, 1, jsonb_build_array(
    pg_temp.p(pg_temp.id('sv'), 'Savings', 2000), pg_temp.p(pg_temp.id('pv'), 'Points', 3000),
    pg_temp.p(pg_temp.id('bi'), 'Business Investment', 1000), pg_temp.p(pg_temp.id('pi'), 'Personal Investment', 1000),
    pg_temp.p(pg_temp.id('up'), 'Upkeep', 2000), pg_temp.p(null, 'Emergency', 1000)), 'Pilot review', (select k from keys))->>'replayed'),
  'true', 'the same request replays'
);
select is((select count(*)::int from audit.tenant_events where tenant_id = pg_temp.id('tenant') and action = 'allocation.changed'), 1,
  'the change is in the network audit log');

-- Swapping two names in one change is fine.
select lives_ok(
  $$ select pg_temp.set(1, 2, jsonb_build_array(
       pg_temp.p(pg_temp.id('sv'), 'Points', 2000), pg_temp.p(pg_temp.id('pv'), 'Savings', 3000),
       pg_temp.p(pg_temp.id('bi'), 'Business Investment', 1000), pg_temp.p(pg_temp.id('pi'), 'Personal Investment', 1000),
       pg_temp.p(pg_temp.id('up'), 'Upkeep', 2000), pg_temp.p(pg_temp.pocket('Emergency'), 'Emergency', 1000))) $$,
  'two pockets can swap names'
);
select lives_ok($$ set constraints all immediate $$, 'names stay unique and versions total 100% at commit');
set constraints all deferred;

-- ── Retire only at zero (decision 11) ──
create function pg_temp.fund(p_pocket uuid) returns void language plpgsql as $$
begin
  perform ledger.post('income', refs.issue('INC'), pg_temp.m(6, pg_temp.id('D')), pg_temp.u(1), pg_temp.k(),
    jsonb_build_array(jsonb_build_object('currency', 'USD', 'postings', jsonb_build_array(
      jsonb_build_object('accountId', ledger.system_account(pg_temp.id('tenant'), 'USD', 'external_inflow'), 'amount', '-5'),
      jsonb_build_object('accountId', ledger.segment_account(ledger.wallet_for(pg_temp.u(6)), pg_temp.m(6, pg_temp.id('D')), 'USD', p_pocket), 'amount', '5')))));
end $$;
do $$ begin perform pg_temp.fund(pg_temp.id('up')); end $$;
select throws_ok(
  $$ select pg_temp.set(1, 3, jsonb_build_array(
       pg_temp.p(pg_temp.id('sv'), 'Points', 4000), pg_temp.p(pg_temp.id('pv'), 'Savings', 3000),
       pg_temp.p(pg_temp.id('bi'), 'Business Investment', 1000), pg_temp.p(pg_temp.id('pi'), 'Personal Investment', 1000),
       pg_temp.p(pg_temp.pocket('Emergency'), 'Emergency', 1000))) $$,
  'P0001', 'conflict', 'a pocket holding money in any currency cannot be retired'
);
select lives_ok(
  $$ select pg_temp.set(1, 3, jsonb_build_array(
       pg_temp.p(pg_temp.id('sv'), 'Points', 2000), pg_temp.p(pg_temp.id('pv'), 'Savings', 4000),
       pg_temp.p(pg_temp.id('bi'), 'Business Investment', 1000), pg_temp.p(pg_temp.id('pi'), 'Personal Investment', 1000),
       pg_temp.p(pg_temp.id('up'), 'Upkeep', 2000))) $$,
  'an empty pocket can be retired'
);
select is((select status from ledger.pockets where name = 'Emergency' and tenant_id = pg_temp.id('tenant')), 'retired', 'it is retired');
select throws_ok(
  $$ select pg_temp.set(1, 4, jsonb_build_array(
       pg_temp.p((select id from ledger.pockets where name = 'Emergency' and tenant_id = pg_temp.id('tenant')), 'Emergency', 10000))) $$,
  'P0001', 'policy_invalid', 'a retired pocket cannot come back'
);
select throws_ok($$ update ledger.pockets set name = 'Owed' where kind = 'debt' $$, 'P0001', 'invariant_violation',
  'Debt cannot be renamed');

-- ── Reads ──
select is((api.allocation_policy(pg_temp.u(6), pg_temp.s(6), pg_temp.m(6, pg_temp.id('D')))->>'version')::int, 4,
  'members read the current split');
select is(
  (api.allocation_policy(pg_temp.u(6), pg_temp.s(6), pg_temp.m(6, pg_temp.id('D')))->'pockets'->1->>'percent'), '40.00',
  'percentages are exact strings'
);
select is(jsonb_array_length(api.allocation_versions(pg_temp.u(6), pg_temp.s(6), pg_temp.m(6, pg_temp.id('D')))->'items'), 4,
  'members read every version');
select is(jsonb_array_length(api.admin_allocation_versions(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'))->'items'), 4,
  'Elivate admins read versions (decision 14)');
select throws_ok($$ select api.admin_allocation_versions(pg_temp.u(1), pg_temp.s(1), pg_temp.id('tenant')) $$,
  'P0001', 'authorization_denied', 'only admins use the admin read');

select * from finish();
rollback;
