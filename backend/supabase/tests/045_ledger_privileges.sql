-- Blueprint 04 — B6 045: private money schemas, RLS, definer rules, bucket.
begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

select ok(
  not exists (
    select 1 from unnest(array['ledger', 'finance', 'evidence']) s, unnest(array['anon', 'authenticated']) r
    where has_schema_privilege(r, s, 'usage')
  ),
  'anon/authenticated have no usage on ledger, finance, evidence'
);
select ok(
  not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('ledger', 'finance', 'evidence') and c.relkind = 'r' and not c.relrowsecurity
  ),
  'RLS is enabled on every money table'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('ledger', 'finance', 'evidence') and p.prosecdef
  ),
  'only api functions run as definer'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('ledger', 'finance', 'evidence', 'api') and not coalesce(p.proconfig @> array['search_path=""'], false)
  ),
  'every function pins an empty search_path'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api'
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')
           or not has_function_privilege('service_role', p.oid, 'execute'))
  ),
  'every api function is executable by service_role only'
);
select is(
  (select array[public::text, file_size_limit::text] from storage.buckets where id = 'financial-evidence'),
  array['false', '10485760'], 'the evidence bucket is private with the 10 MB limit'
);
select is(
  (select allowed_mime_types from storage.buckets where id = 'financial-evidence'),
  array['application/pdf', 'image/jpeg', 'image/png'], 'only PDF, JPEG and PNG'
);
select ok(
  not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and (coalesce(qual, '') ilike '%financial-evidence%' or coalesce(with_check, '') ilike '%financial-evidence%')
  ),
  'no client policies on evidence objects'
);
select ok(
  (select bool_and(not allowed or role = 'president_team_member') from authz.default_role_permissions where permission_key = 'manage_allocation'),
  'manage_allocation is President-only by default'
);
select ok(
  exists (
    select 1 from pg_constraint
    where conname = 'tenant_events_target_type_check'
      and pg_get_constraintdef(oid) like '%invitation%' and pg_get_constraintdef(oid) like '%income%'
  ),
  'the tenant audit targets are the full union'
);

select * from finish();
rollback;
