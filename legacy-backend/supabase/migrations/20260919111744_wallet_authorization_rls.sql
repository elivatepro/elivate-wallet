create or replace function authz.is_active_account()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.user_accounts ua
     where ua.user_id = (select auth.uid())
       and ua.status = 'active'
  );
$$;

create or replace function authz.can_read_wallet(p_wallet_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.wallets w
      join public.user_accounts ua on ua.user_id = w.owner_user_id
     where w.id = p_wallet_id
       and w.owner_user_id = (select auth.uid())
       and ua.status = 'active'
       and exists (
         select 1
           from public.memberships m
           join public.tenants t on t.id = m.tenant_id
          where m.user_id = w.owner_user_id
            and m.status = 'active'
            and m.role_key <> 'president_team_member'
            and t.status = 'active'
       )
  );
$$;

revoke all on function authz.is_active_account() from public, anon, authenticated;
revoke all on function authz.can_read_wallet(uuid) from public, anon, authenticated;
grant execute on function authz.is_active_account() to authenticated;
grant execute on function authz.can_read_wallet(uuid) to authenticated;

create policy wallets_self_read
  on public.wallets
  for select to authenticated
  using ((select authz.can_read_wallet(id)));

create policy pocket_definitions_authenticated_read
  on public.pocket_definitions
  for select to authenticated
  using ((select authz.is_active_account()));

create policy allocation_policy_versions_tenant_member_read
  on public.allocation_policy_versions
  for select to authenticated
  using ((select authz.is_active_member_in_tenant(tenant_id)));

create policy allocation_policy_rules_tenant_member_read
  on public.allocation_policy_rules
  for select to authenticated
  using ((select authz.is_active_member_in_tenant(tenant_id)));

create policy tenant_active_allocation_policies_member_read
  on public.tenant_active_allocation_policies
  for select to authenticated
  using ((select authz.is_active_member_in_tenant(tenant_id)));

create or replace function authz.authorize(
  p_actor_user_id uuid,
  p_session_id uuid,
  p_permission_key text,
  p_target_tenant_id uuid,
  p_target_office_id uuid default null,
  p_target_membership_id uuid default null,
  p_target_user_id uuid default null,
  p_target_wallet_id uuid default null,
  p_resource_owner_user_id uuid default null,
  p_action_key text default null,
  p_amount numeric default null
)
returns authz.authorization_decision
language plpgsql
security definer
set search_path = pg_catalog, public, authz
as $$
declare
  permission_record authz.permission_catalog%rowtype;
  account_state public.account_status;
  tenant_state public.tenant_status;
  target_membership_tenant uuid;
  target_membership_office uuid;
  target_membership_user uuid;
  target_membership_status public.membership_status;
  target_membership_role public.role_key;
  target_wallet_owner uuid;
  effective_target_office uuid;
  effective_target_user uuid;
  has_active_membership boolean := false;
  explicit_deny_id uuid;
  explicit_grant_id uuid;
  role_policy_id uuid;
  now_at timestamptz := clock_timestamp();
  elevated_valid boolean := false;
begin
  if p_actor_user_id is null or p_target_tenant_id is null then
    return (
      'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
      p_target_office_id, p_target_membership_id, p_target_user_id,
      p_target_wallet_id, 'system_rule', null, 'missing_authorization_context',
      'none', 0
    )::authz.authorization_decision;
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    return (
      'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
      p_target_office_id, p_target_membership_id, p_target_user_id,
      p_target_wallet_id, 'system_rule', null, 'actor_mismatch', 'none', 0
    )::authz.authorization_decision;
  end if;

  select * into permission_record
    from authz.permission_catalog
   where permission_key = p_permission_key;

  if not found then
    return (
      'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
      p_target_office_id, p_target_membership_id, p_target_user_id,
      p_target_wallet_id, 'system_rule', null, 'unknown_permission', 'none', 0
    )::authz.authorization_decision;
  end if;

  select status into account_state
    from public.user_accounts
   where user_id = p_actor_user_id;

  if account_state is null or account_state <> 'active' then
    return (
      'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
      p_target_office_id, p_target_membership_id, p_target_user_id,
      p_target_wallet_id, 'system_rule', null, 'account_not_active',
      permission_record.step_up_mode, 300
    )::authz.authorization_decision;
  end if;

  select status into tenant_state
    from public.tenants
   where id = p_target_tenant_id;

  if tenant_state is null or tenant_state <> 'active' then
    return (
      'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
      p_target_office_id, p_target_membership_id, p_target_user_id,
      p_target_wallet_id, 'system_rule', null, 'tenant_not_active',
      permission_record.step_up_mode, 300
    )::authz.authorization_decision;
  end if;

  effective_target_office := p_target_office_id;
  effective_target_user := coalesce(p_target_user_id, p_resource_owner_user_id);

  if p_target_membership_id is not null then
    select tenant_id, office_id, user_id, status, role_key
      into target_membership_tenant, target_membership_office,
           target_membership_user, target_membership_status, target_membership_role
      from public.memberships
     where id = p_target_membership_id;

    if target_membership_tenant is null
       or target_membership_tenant <> p_target_tenant_id
       or (p_target_office_id is not null and p_target_office_id <> target_membership_office)
       or (p_target_user_id is not null and p_target_user_id <> target_membership_user) then
      return (
        'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
        p_target_office_id, p_target_membership_id, p_target_user_id,
        p_target_wallet_id, 'system_rule', null, 'target_context_mismatch',
        permission_record.step_up_mode, 300
      )::authz.authorization_decision;
    end if;

    effective_target_office := target_membership_office;
    effective_target_user := coalesce(effective_target_user, target_membership_user);
  end if;

  if effective_target_office is not null and not exists (
    select 1 from public.offices
     where id = effective_target_office
       and tenant_id = p_target_tenant_id
       and status = 'active'
  ) then
    return (
      'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
      effective_target_office, p_target_membership_id, effective_target_user,
      p_target_wallet_id, 'system_rule', null, 'target_office_not_active',
      permission_record.step_up_mode, 300
    )::authz.authorization_decision;
  end if;

  if p_target_wallet_id is not null then
    select owner_user_id
      into target_wallet_owner
      from public.wallets
     where id = p_target_wallet_id;

    if target_wallet_owner is null then
      return (
        'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
        effective_target_office, p_target_membership_id, effective_target_user,
        p_target_wallet_id, 'system_rule', null, 'target_wallet_not_found',
        permission_record.step_up_mode, 300
      )::authz.authorization_decision;
    end if;

    if effective_target_user is null then
      effective_target_user := target_wallet_owner;
    elsif effective_target_user <> target_wallet_owner then
      return (
        'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
        effective_target_office, p_target_membership_id, effective_target_user,
        p_target_wallet_id, 'system_rule', null, 'wallet_owner_mismatch',
        permission_record.step_up_mode, 300
      )::authz.authorization_decision;
    end if;
  end if;

  if not permission_record.can_target_own_wallet
     and p_target_wallet_id is not null
     and effective_target_user = p_actor_user_id then
    return (
      'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
      effective_target_office, p_target_membership_id, effective_target_user,
      p_target_wallet_id, 'system_rule', null, 'leadership_self_wallet_forbidden',
      permission_record.step_up_mode, 300
    )::authz.authorization_decision;
  end if;

  if permission_record.wallet_holder_baseline and effective_target_user = p_actor_user_id then
    if p_target_wallet_id is null then
      return (
        'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
        effective_target_office, p_target_membership_id, effective_target_user,
        p_target_wallet_id, 'system_rule', null, 'wallet_context_required',
        permission_record.step_up_mode, 300
      )::authz.authorization_decision;
    end if;

    if target_wallet_owner <> p_actor_user_id then
      return (
        'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
        effective_target_office, p_target_membership_id, effective_target_user,
        p_target_wallet_id, 'system_rule', null, 'wallet_owner_mismatch',
        permission_record.step_up_mode, 300
      )::authz.authorization_decision;
    end if;

    if p_target_membership_id is not null then
      has_active_membership := target_membership_user = p_actor_user_id
        and target_membership_status = 'active'
        and target_membership_role <> 'president_team_member';
    else
      select exists (
        select 1
          from public.memberships m
         where m.tenant_id = p_target_tenant_id
           and m.user_id = p_actor_user_id
           and m.status = 'active'
           and m.role_key <> 'president_team_member'
           and (
             effective_target_office is null
             or m.office_id = effective_target_office
           )
      ) into has_active_membership;
    end if;

    if not has_active_membership then
      return (
        'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
        effective_target_office, p_target_membership_id, effective_target_user,
        p_target_wallet_id, 'system_rule', null, 'no_active_wallet_membership',
        permission_record.step_up_mode, 300
      )::authz.authorization_decision;
    end if;

    if permission_record.step_up_mode <> 'none' then
      elevated_valid := p_session_id is not null
        and authz.is_elevated_session_valid(p_session_id, p_actor_user_id);

      if not elevated_valid then
        return (
          'STEP_UP_REQUIRED', p_permission_key, p_actor_user_id, p_target_tenant_id,
          effective_target_office, p_target_membership_id, effective_target_user,
          p_target_wallet_id, 'protected_baseline', null, 'step_up_required',
          permission_record.step_up_mode, 300
        )::authz.authorization_decision;
      end if;
    end if;

    return (
      'ALLOW', p_permission_key, p_actor_user_id, p_target_tenant_id,
      effective_target_office, p_target_membership_id, effective_target_user,
      p_target_wallet_id, 'protected_baseline', null, 'wallet_holder_baseline',
      permission_record.step_up_mode, 300
    )::authz.authorization_decision;
  end if;

  if p_target_wallet_id is not null and p_target_membership_id is null then
    return (
      'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
      effective_target_office, p_target_membership_id, effective_target_user,
      p_target_wallet_id, 'system_rule', null, 'target_membership_required',
      permission_record.step_up_mode, 300
    )::authz.authorization_decision;
  end if;

  select exists (
    select 1
      from public.memberships m
     where m.tenant_id = p_target_tenant_id
       and m.user_id = p_actor_user_id
       and m.status = 'active'
  ) into has_active_membership;

  if has_active_membership then
    select r.id
      into explicit_deny_id
      from authz.access_rules r
      join authz.access_assignments a on a.tenant_id = r.tenant_id and a.id = r.assignment_id
     where a.tenant_id = p_target_tenant_id
       and a.subject_user_id = p_actor_user_id
       and a.revoked_at is null
       and r.permission_key = p_permission_key
       and r.effect = 'deny'
       and r.revoked_at is null
       and r.starts_at <= now_at
       and (
         r.scope_type = 'tenant'
         or (r.scope_type = 'office_subtree' and effective_target_office is not null and exists (
           select 1 from authz.office_closure c
            where c.tenant_id = r.tenant_id
              and c.ancestor_office_id = r.scope_office_id
              and c.descendant_office_id = effective_target_office
         ))
         or (r.scope_type = 'member' and r.scope_membership_id = p_target_membership_id)
       )
     order by r.created_at desc
     limit 1;

    if explicit_deny_id is not null then
      return (
        'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
        effective_target_office, p_target_membership_id, effective_target_user,
        p_target_wallet_id, 'explicit_deny', explicit_deny_id, 'explicit_deny',
        permission_record.step_up_mode, 300
      )::authz.authorization_decision;
    end if;

    select r.id
      into explicit_grant_id
      from authz.access_rules r
      join authz.access_assignments a on a.tenant_id = r.tenant_id and a.id = r.assignment_id
     where a.tenant_id = p_target_tenant_id
       and a.subject_user_id = p_actor_user_id
       and a.revoked_at is null
       and r.permission_key = p_permission_key
       and r.effect = 'allow'
       and r.revoked_at is null
       and r.starts_at <= now_at
       and (r.expires_at is null or r.expires_at > now_at)
       and (
         r.scope_type = 'tenant'
         or (r.scope_type = 'office_subtree' and effective_target_office is not null and exists (
           select 1 from authz.office_closure c
            where c.tenant_id = r.tenant_id
              and c.ancestor_office_id = r.scope_office_id
              and c.descendant_office_id = effective_target_office
         ))
         or (r.scope_type = 'member' and r.scope_membership_id = p_target_membership_id)
       )
     order by r.created_at desc
     limit 1;
  end if;

  if explicit_grant_id is null then
    select m.id
      into role_policy_id
      from public.memberships m
      join authz.tenant_role_permissions rp
        on rp.tenant_id = m.tenant_id
       and rp.role_key = m.role_key
       and rp.permission_key = p_permission_key
       and rp.allowed
     where m.tenant_id = p_target_tenant_id
       and m.user_id = p_actor_user_id
       and m.status = 'active'
       and (
         permission_record.default_scope_mode = 'entire_tenant'
         or (
           permission_record.default_scope_mode = 'role_office'
           and (
             m.office_id is null
             or (
               effective_target_office is not null
               and exists (
                 select 1 from authz.office_closure c
                  where c.tenant_id = m.tenant_id
                    and c.ancestor_office_id = m.office_id
                    and c.descendant_office_id = effective_target_office
               )
             )
           )
         )
       )
     order by m.id
     limit 1;
  end if;

  if explicit_grant_id is null and role_policy_id is null then
    return (
      'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
      effective_target_office, p_target_membership_id, effective_target_user,
      p_target_wallet_id, 'default_deny', null, 'no_matching_allow',
      permission_record.step_up_mode, 300
    )::authz.authorization_decision;
  end if;

  if permission_record.step_up_mode <> 'none' then
    elevated_valid := p_session_id is not null
      and authz.is_elevated_session_valid(p_session_id, p_actor_user_id);

    if not elevated_valid then
      return (
        'STEP_UP_REQUIRED', p_permission_key, p_actor_user_id, p_target_tenant_id,
        effective_target_office, p_target_membership_id, effective_target_user,
        p_target_wallet_id,
        case when explicit_grant_id is not null then 'explicit_grant' else 'role_policy' end,
        coalesce(explicit_grant_id, role_policy_id), 'step_up_required',
        permission_record.step_up_mode, 300
      )::authz.authorization_decision;
    end if;

    if permission_record.step_up_mode = 'elevated_and_confirmed'
       and not exists (
         select 1
           from authz.action_confirmations c
          where c.session_id = p_session_id
            and c.user_id = p_actor_user_id
            and c.action_key = p_action_key
            and c.target_id is not distinct from p_target_tenant_id
            and c.consumed_at is null
            and c.expires_at > now_at
       ) then
      return (
        'STEP_UP_REQUIRED', p_permission_key, p_actor_user_id, p_target_tenant_id,
        effective_target_office, p_target_membership_id, effective_target_user,
        p_target_wallet_id,
        case when explicit_grant_id is not null then 'explicit_grant' else 'role_policy' end,
        coalesce(explicit_grant_id, role_policy_id), 'action_confirmation_required',
        permission_record.step_up_mode, 300
      )::authz.authorization_decision;
    end if;
  end if;

  return (
    'ALLOW', p_permission_key, p_actor_user_id, p_target_tenant_id,
    effective_target_office, p_target_membership_id, effective_target_user,
    p_target_wallet_id,
    case when explicit_grant_id is not null then 'explicit_grant' else 'role_policy' end,
    coalesce(explicit_grant_id, role_policy_id), 'matched_allow',
    permission_record.step_up_mode, 300
  )::authz.authorization_decision;
end;
$$;

revoke all on function authz.authorize(
  uuid, uuid, text, uuid, uuid, uuid, uuid, uuid, uuid, text, numeric
) from public, anon, authenticated;
