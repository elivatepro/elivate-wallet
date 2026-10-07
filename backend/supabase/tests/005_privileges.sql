begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api'
      and (has_function_privilege('anon', p.oid, 'execute')
        or has_function_privilege('authenticated', p.oid, 'execute'))
  ),
  'anon/authenticated cannot execute any api function'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and not has_function_privilege('service_role', p.oid, 'execute')
  ),
  'service_role can execute every api function'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('api', 'identity', 'audit', 'refs')
      and p.prosecdef
      and not coalesce(p.proconfig @> array['search_path=""'], false)
  ),
  'every security definer function pins an empty search_path'
);
select ok(not has_schema_privilege('anon', 'identity', 'usage'), 'anon has no identity access');
select ok(not has_schema_privilege('authenticated', 'identity', 'usage'), 'authenticated has no identity access');
select ok(not has_schema_privilege('authenticated', 'audit', 'usage'), 'authenticated has no audit access');
select ok(not has_schema_privilege('authenticated', 'refs', 'usage'), 'authenticated has no refs access');
select ok(
  not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('identity', 'audit', 'refs') and c.relkind = 'r' and not c.relrowsecurity
  ),
  'RLS is enabled on every private table'
);

select * from finish();
rollback;
