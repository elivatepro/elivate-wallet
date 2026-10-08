-- Blueprint 06 — the wizard's Welcome screen (W-02 step 1) comes before the
-- PIN, so it cannot use my_workspaces (gate `ready`). This read is allowed at
-- `ready` or `pin_setup_required` and returns only the caller's own active
-- membership: network, office and role, nothing else.

create function api.onboarding_workspace(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  gate text;
  result jsonb;
begin
  perform identity.require_live_session(p_user_id, p_session_id);
  gate := identity.pin_gate(p_user_id, p_session_id);
  if gate not in ('ready', 'pin_setup_required') then
    perform identity.fail(gate);
  end if;

  select jsonb_build_object(
    'membershipId', m.id,
    'tenantName', t.name,
    'officeName', o.name,
    'role', m.role
  ) into result
  from org.memberships m
  join org.tenants t on t.id = m.tenant_id
  left join org.offices o on o.id = m.office_id
  where m.id = p_membership_id and m.user_id = p_user_id and m.status = 'active';
  if result is null then
    perform identity.fail('workspace_invalid');
  end if;
  return result;
end;
$$;

revoke all on function api.onboarding_workspace(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function api.onboarding_workspace(uuid, uuid, uuid) to service_role;
