-- Client roles receive explicit deny policies as defense in depth. The
-- authz schema remains non-exposed and has no ordinary CRUD grants.
create policy invitations_no_client_access
  on public.invitations
  for all to anon, authenticated
  using (false)
  with check (false);

create policy permission_catalog_no_client_access
  on authz.permission_catalog
  for all to anon, authenticated
  using (false)
  with check (false);

create policy default_role_permissions_no_client_access
  on authz.default_role_permissions
  for all to anon, authenticated
  using (false)
  with check (false);

create policy tenant_role_permissions_no_client_access
  on authz.tenant_role_permissions
  for all to anon, authenticated
  using (false)
  with check (false);

create policy office_closure_no_client_access
  on authz.office_closure
  for all to anon, authenticated
  using (false)
  with check (false);

create policy access_assignments_no_client_access
  on authz.access_assignments
  for all to anon, authenticated
  using (false)
  with check (false);

create policy access_rules_no_client_access
  on authz.access_rules
  for all to anon, authenticated
  using (false)
  with check (false);

create policy elevated_sessions_no_client_access
  on authz.elevated_sessions
  for all to anon, authenticated
  using (false)
  with check (false);

create policy action_confirmations_no_client_access
  on authz.action_confirmations
  for all to anon, authenticated
  using (false)
  with check (false);

create policy security_audit_events_no_client_access
  on authz.security_audit_events
  for all to anon, authenticated
  using (false)
  with check (false);

-- Cover every reported foreign key access path. Composite tenant indexes are
-- retained for resolver queries; these single-column indexes support parent
-- updates/deletes and FK checks.
create index access_assignments_subject_user_id
  on authz.access_assignments (subject_user_id);
create index access_assignments_created_by_user_id
  on authz.access_assignments (created_by_user_id);
create index access_assignments_revoked_by_user_id
  on authz.access_assignments (revoked_by_user_id);

create index access_rules_tenant_assignment_id
  on authz.access_rules (tenant_id, assignment_id);
create index access_rules_permission_key
  on authz.access_rules (permission_key);
create index access_rules_revoked_by_user_id
  on authz.access_rules (revoked_by_user_id);

create index action_confirmations_user_id
  on authz.action_confirmations (user_id);
create index default_role_permissions_permission_key
  on authz.default_role_permissions (permission_key);
create index security_audit_events_permission_key
  on authz.security_audit_events (permission_key);
create index tenant_role_permissions_permission_key
  on authz.tenant_role_permissions (permission_key);
create index tenant_role_permissions_updated_by
  on authz.tenant_role_permissions (updated_by);

create index invitations_accepted_user_id
  on public.invitations (accepted_user_id);
create index invitations_tenant_accepted_membership_id
  on public.invitations (tenant_id, accepted_membership_id);
create index invitations_tenant_office_id
  on public.invitations (tenant_id, office_id);
create index memberships_user_id
  on public.memberships (user_id);
