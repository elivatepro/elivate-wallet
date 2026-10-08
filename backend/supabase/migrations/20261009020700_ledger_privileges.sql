-- Blueprint 04 — shared edits and privileges.

-- Tenant audit targets: full union of slice 02, Blueprint 03 (invitation) and
-- this slice (allocation_policy, income, evidence).
alter table audit.tenant_events drop constraint if exists tenant_events_target_type_check;
alter table audit.tenant_events add constraint tenant_events_target_type_check
  check (target_type in (
    'tenant', 'office', 'membership', 'role_permission', 'access_assignment', 'reviewer_assignment',
    'invitation',
    'allocation_policy', 'income', 'evidence'
  ));

-- Every api function: service_role only.
do $$
declare
  fn regprocedure;
begin
  for fn in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end;
$$;
