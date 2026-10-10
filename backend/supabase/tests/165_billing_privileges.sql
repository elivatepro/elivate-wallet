-- Blueprint 16 — B6 165: the billing schema is private; billing api
-- functions (user, webhook and worker entry points) are service-only.
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(9);

select ok(not has_schema_privilege('anon', 'billing', 'usage'), 'anon cannot use the billing schema');
select ok(not has_schema_privilege('authenticated', 'billing', 'usage'), 'authenticated cannot use the billing schema');
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'billing' and c.relkind = 'r'
    and (has_table_privilege('authenticated', c.oid, 'select') or has_table_privilege('anon', c.oid, 'select'))), 0, 'no client reads billing tables');
select is((select count(*)::int from pg_tables t where t.schemaname = 'billing' and not t.rowsecurity), 0,
  'row security everywhere');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api' and (p.proname like 'billing\_%' or p.proname = 'change_billing_owner')
    and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))),
  0, 'no billing api function is callable by clients');
select ok(has_function_privilege('service_role', 'api.billing_apply_verified(text, bigint, text, timestamptz, bigint, text, boolean, text)',
  'execute'), 'the function (service role) applies verified payments');
select ok(not has_function_privilege('authenticated', 'billing.run_lifecycle()', 'execute'), 'clients cannot run the lifecycle');
select ok(not has_function_privilege('authenticated',
  'authz.require(uuid, text, uuid, uuid, uuid, uuid, boolean)', 'execute'), 'the resolver stays private');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('api', 'billing') and (p.proname like 'billing%' or p.proname in ('change_billing_owner', 'start_network',
    'activate_tenant'))
    and p.prosecdef and not exists (select 1 from unnest(p.proconfig) c where c = 'search_path=""')), 0,
  'every security definer billing function pins search_path');

select * from finish();
rollback;
