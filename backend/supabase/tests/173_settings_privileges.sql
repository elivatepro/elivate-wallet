-- Blueprint 17 — B6 173: settings, backups and search stay private. The
-- backups schema is closed; settings tables have row security and no client
-- grants; the new api functions are service-only and pin search_path.
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(8);

select ok(not has_schema_privilege('anon', 'backups', 'usage'), 'anon cannot use the backups schema');
select ok(not has_schema_privilege('authenticated', 'backups', 'usage'), 'authenticated cannot use the backups schema');
select is((select count(*)::int from pg_tables t where t.schemaname = 'backups' and not t.rowsecurity), 0,
  'row security on every backups table');
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where (n.nspname = 'backups' or (n.nspname = 'org' and c.relname in ('tenant_settings', 'tenant_setting_revisions')))
    and c.relkind = 'r'
    and (has_table_privilege('authenticated', c.oid, 'select') or has_table_privilege('anon', c.oid, 'select'))), 0,
  'no client reads settings or backups');
select ok((select bool_and(rowsecurity) from pg_tables
  where schemaname = 'org' and tablename in ('tenant_settings', 'tenant_setting_revisions')), 'settings tables have row security');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api' and p.proname in ('team_settings', 'workspace_brand', 'brand_asset_key', 'brand_upload_key',
    'update_team_settings', 'restore_team_settings_revision', 'export_brand', 'backup_vault', 'start_backup',
    'authorize_backup_download', 'request_restore', 'cancel_restore_request', 'platform_advance_restore',
    'backup_claim', 'backup_prepare', 'backup_rows', 'backup_finalize', 'backup_fail', 'backup_expired',
    'backup_deleted', 'quick_search')
    and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))),
  0, 'no new api function is callable by clients');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('api', 'backups', 'org') and p.prosecdef
    and not exists (select 1 from unnest(p.proconfig) c where c = 'search_path=""')), 0,
  'every security definer function pins search_path');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('backups', 'org') and p.prosecdef), 0, 'only api functions are security definer');

select * from finish();
rollback;
