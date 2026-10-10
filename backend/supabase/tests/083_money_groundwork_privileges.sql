-- Blueprint 08 — B6 083: the new reads are service-only api functions; the
-- helpers stay private and invoker.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

select ok(
  not exists (
    select 1 from unnest(array[
      'api.command_outcome(uuid, uuid, text, text)',
      'api.leadership_overview(uuid, uuid, uuid, text)',
      'api.my_activity(uuid, uuid, uuid, text, uuid, text, text, text, text, text, integer, text, text, text, uuid)',
      'api.managed_wallet_activity(uuid, uuid, uuid, uuid, text, uuid, text, text, text, text, text, integer, text, text, text)'
    ]) f
    where not has_function_privilege('service_role', f::regprocedure, 'execute')
       or has_function_privilege('anon', f::regprocedure, 'execute')
       or has_function_privilege('authenticated', f::regprocedure, 'execute')
  ),
  'new api reads are executable by service_role only'
);
select ok(
  (select bool_and(p.prosecdef) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'api' and p.proname in ('command_outcome', 'leadership_overview', 'my_activity', 'managed_wallet_activity')),
  'they run as definer'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'ledger' and p.proname in ('activity', 'time_zone', 'search_amount') and p.prosecdef
  ),
  'ledger helpers are not definer'
);
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'api' and p.proname in ('my_activity', 'managed_wallet_activity')),
  2, 'no stale activity overloads remain'
);
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'ledger' and p.proname = 'activity'),
  1, 'one ledger.activity'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('api', 'ledger') and p.proname in ('command_outcome', 'leadership_overview', 'activity', 'time_zone', 'search_amount')
      and not coalesce(p.proconfig @> array['search_path=""'], false)
  ),
  'every new function pins an empty search_path'
);

select * from finish();
rollback;
