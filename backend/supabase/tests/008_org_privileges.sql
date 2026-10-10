-- Blueprint 02 — B6 test 15: private schemas, RLS, append-only history.
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(8);

select ok(not has_schema_privilege('authenticated', 'org', 'usage'), 'authenticated has no org access');
select ok(not has_schema_privilege('authenticated', 'authz', 'usage'), 'authenticated has no authz access');
select ok(not has_schema_privilege('anon', 'org', 'usage') and not has_schema_privilege('anon', 'authz', 'usage'), 'anon has no org/authz access');
select ok(
  not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('org', 'authz') and c.relkind = 'r' and not c.relrowsecurity
  ),
  'RLS is enabled on every org/authz table'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('org', 'authz') and p.prosecdef
  ),
  'only api functions run as definer'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('org', 'authz') and not coalesce(p.proconfig @> array['search_path=""'], false)
  ),
  'every org/authz function pins an empty search_path'
);

insert into auth.users (id, email, aud, role)
values ('10000000-0000-0000-0000-000000000001', 'u1@example.test', 'authenticated', 'authenticated');
insert into org.tenants (id, name, short_name, created_by)
values ('30000000-0000-0000-0000-000000000001', 'Test Network', 'TN', '10000000-0000-0000-0000-000000000001');
do $$ begin
  perform audit.record_tenant('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
    'tenant.created', 'tenant', '30000000-0000-0000-0000-000000000001');
end $$;

select throws_ok(
  $$ update audit.tenant_events set reason = 'changed' $$,
  'P0001', 'invariant_violation', 'tenant audit log is append-only'
);
select throws_ok(
  $$ update authz.permission_catalog set protected = false where key = 'view_own_wallet' $$,
  'P0001', 'invariant_violation', 'the permission catalog is immutable'
);

select * from finish();
rollback;
