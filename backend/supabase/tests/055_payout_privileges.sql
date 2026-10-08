-- Blueprint 05 — B6 test 6: private schema, RLS, definer rules and grants.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

select ok(not has_schema_privilege('anon', 'payout', 'usage'), 'anon has no payout access');
select ok(not has_schema_privilege('authenticated', 'payout', 'usage'), 'authenticated has no payout access');
select ok(not has_schema_privilege('service_role', 'payout', 'usage'), 'service_role reaches payout only through api');
select ok(
  not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'payout' and c.relkind = 'r' and not c.relrowsecurity
  ),
  'RLS is enabled on every payout table'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'payout' and p.prosecdef
  ),
  'no payout function runs as definer'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname = 'payout' or p.oid::regprocedure::text like 'api.%payout%'
        or p.proname in ('list_banks', 'refresh_banks', 'prepare_account_lookup', 'record_account_lookup', 'legal_name'))
      and not coalesce(p.proconfig @> array['search_path=""'], false)
  ),
  'every payout function pins an empty search_path'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api'
      and p.proname in ('list_banks', 'refresh_banks', 'prepare_account_lookup', 'record_account_lookup',
        'confirm_payout_account', 'list_payout_accounts', 'set_primary_payout_account',
        'deactivate_payout_account', 'reveal_payout_account')
      and (has_function_privilege('anon', p.oid, 'execute')
        or has_function_privilege('authenticated', p.oid, 'execute')
        or not has_function_privilege('service_role', p.oid, 'execute')
        or not p.prosecdef)
  ),
  'payout api functions: definer, service_role only'
);
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'api'
     and p.proname in ('list_banks', 'refresh_banks', 'prepare_account_lookup', 'record_account_lookup',
       'confirm_payout_account', 'list_payout_accounts', 'set_primary_payout_account',
       'deactivate_payout_account', 'reveal_payout_account')),
  9, 'all nine payout api functions exist'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'payout'
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))
  ),
  'anon/authenticated cannot execute payout internals'
);

select * from finish();
rollback;
