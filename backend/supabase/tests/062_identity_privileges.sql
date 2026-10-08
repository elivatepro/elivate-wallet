-- Blueprint 06 — B5: privileges and definer rules for the new identity objects.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

select ok(
  not exists (
    select 1 from unnest(array['identity.nin_records', 'identity.nin_attempts', 'identity.nin_reviews']) t,
      unnest(array['anon', 'authenticated', 'service_role']) r
    where has_table_privilege(r, t, 'select') or has_table_privilege(r, t, 'insert')
  ),
  'no API role reads or writes the NIN tables directly'
);
select ok(
  (select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'identity' and c.relname in ('nin_records', 'nin_attempts', 'nin_reviews')),
  'RLS on the NIN tables'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and p.proname in ('my_profile', 'update_profile', 'set_profile_photo', 'prepare_nin_check',
      'record_nin_check', 'request_nin_review', 'nin_reviews', 'admin_nin_reviews', 'decide_nin_review')
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')
           or not has_function_privilege('service_role', p.oid, 'execute') or not p.prosecdef)
  ),
  'new api commands: definer, service_role only'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'identity' and p.prosecdef
      and (p.proname like '%nin%' or p.proname in ('legal_name', 'identity_state', 'lock_legal_name', 'can_review',
        'review_row', 'profile_view', 'rank_values', 'check_person_name', 'check_middle_names'))
  ),
  'the new identity helpers are not definer'
);

select * from finish();
rollback;
