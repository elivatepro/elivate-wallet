create or replace function authz.rebuild_office_closure()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, authz
as $$
declare
  affected_tenant_id uuid;
begin
  affected_tenant_id := coalesce(new.tenant_id, old.tenant_id);

  if tg_op = 'UPDATE' and old.tenant_id <> new.tenant_id then
    raise exception using
      errcode = '23514',
      message = 'office tenant cannot change';
  end if;

  if exists (
    with recursive walk (office_id, path) as (
      select o.id, array[o.id]
        from public.offices o
       where o.tenant_id = affected_tenant_id
      union all
      select child.id, walk.path || child.id
        from walk
        join public.offices child
          on child.parent_office_id = walk.office_id
         and child.tenant_id = affected_tenant_id
       where not child.id = any (walk.path)
    )
    select 1
      from walk
      join public.offices child
        on child.parent_office_id = walk.office_id
       and child.tenant_id = affected_tenant_id
     where child.id = any (walk.path)
  ) then
    raise exception using
      errcode = '23514',
      message = 'office hierarchy cannot contain a cycle';
  end if;

  delete from authz.office_closure
   where tenant_id = affected_tenant_id;

  insert into authz.office_closure (
    tenant_id,
    ancestor_office_id,
    descendant_office_id,
    depth
  )
  with recursive walk (tenant_id, ancestor_office_id, descendant_office_id, depth) as (
    select o.tenant_id, o.id, o.id, 0
      from public.offices o
     where o.tenant_id = affected_tenant_id
    union all
    select walk.tenant_id, walk.ancestor_office_id, child.id, walk.depth + 1
      from walk
      join public.offices child
        on child.parent_office_id = walk.descendant_office_id
       and child.tenant_id = walk.tenant_id
  )
  select tenant_id, ancestor_office_id, descendant_office_id, depth
    from walk;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger offices_rebuild_closure
  after insert or update or delete on public.offices
  for each row execute function authz.rebuild_office_closure();

create or replace function authz.validate_access_assignment()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, authz
as $$
begin
  if not exists (
    select 1
      from public.memberships m
     where m.tenant_id = new.tenant_id
       and m.user_id = new.subject_user_id
       and m.status = 'active'
  ) then
    raise exception using
      errcode = '23514',
      message = 'cross-access subject must have an active membership in the tenant';
  end if;
  return new;
end;
$$;

create trigger access_assignments_validate_subject
  before insert or update on authz.access_assignments
  for each row execute function authz.validate_access_assignment();

create or replace function authz.validate_access_rule()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, authz
as $$
declare
  permission_is_grantable boolean;
  assignment_creator uuid;
  management_decision authz.authorization_decision;
  delegated_decision authz.authorization_decision;
  target_scope_office uuid;
  target_scope_user uuid;
begin
  select grantable
    into permission_is_grantable
    from authz.permission_catalog
   where permission_key = new.permission_key;

  if new.effect = 'allow' and not coalesce(permission_is_grantable, false) then
    raise exception using
      errcode = '23514',
      message = 'permission cannot be explicitly granted';
  end if;

  if new.effect = 'deny' and new.expires_at is not null then
    raise exception using
      errcode = '23514',
      message = 'explicit denies cannot expire';
  end if;

  select created_by_user_id
    into assignment_creator
    from authz.access_assignments
   where tenant_id = new.tenant_id
     and id = new.assignment_id;

  if new.scope_type = 'office_subtree' then
    target_scope_office := new.scope_office_id;
  elsif new.scope_type = 'member' then
    select office_id, user_id
      into target_scope_office, target_scope_user
      from public.memberships
     where tenant_id = new.tenant_id
       and id = new.scope_membership_id;
  end if;

  management_decision := authz.authorize(
    assignment_creator,
    null,
    'manage_access_rules',
    new.tenant_id,
    target_scope_office,
    new.scope_membership_id,
    target_scope_user,
    null,
    null,
    null,
    null
  );

  if management_decision.decision <> 'ALLOW' then
    raise exception using
      errcode = '42501',
      message = 'access-rule creator is outside the proposed management scope';
  end if;

  if new.effect = 'allow' then
    delegated_decision := authz.authorize(
      assignment_creator,
      null,
      new.permission_key,
      new.tenant_id,
      target_scope_office,
      new.scope_membership_id,
      target_scope_user,
      null,
      null,
      null,
      null
    );

    if delegated_decision.decision <> 'ALLOW' then
      raise exception using
        errcode = '42501',
        message = 'access-rule creator cannot delegate a permission they do not hold in scope';
    end if;
  end if;

  return new;
end;
$$;

create trigger access_rules_validate
  before insert or update on authz.access_rules
  for each row execute function authz.validate_access_rule();

create or replace function authz.prevent_audit_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog, authz
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'security audit events are append-only';
end;
$$;

create trigger security_audit_events_append_only
  before update or delete on authz.security_audit_events
  for each row execute function authz.prevent_audit_mutation();

create or replace function authz.is_active_member_in_tenant(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, authz
as $$
  select exists (
    select 1
      from public.memberships m
     where m.tenant_id = p_tenant_id
       and m.user_id = auth.uid()
       and m.status = 'active'
  );
$$;

create or replace function authz.can_read_office(p_office_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, authz
as $$
  select exists (
    select 1
      from public.offices target
      join public.memberships actor_membership
        on actor_membership.tenant_id = target.tenant_id
       and actor_membership.user_id = auth.uid()
       and actor_membership.status = 'active'
      left join authz.office_closure closure
        on closure.tenant_id = target.tenant_id
       and closure.ancestor_office_id = actor_membership.office_id
       and closure.descendant_office_id = target.id
     where target.id = p_office_id
       and (actor_membership.office_id is null or closure.descendant_office_id is not null)
  );
$$;

create or replace function authz.can_read_membership(p_membership_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, authz
as $$
  select exists (
    select 1
      from public.memberships target
     where target.id = p_membership_id
       and (
         target.user_id = auth.uid()
         or exists (
           select 1
             from public.memberships actor_membership
             left join authz.office_closure closure
               on closure.tenant_id = target.tenant_id
              and closure.ancestor_office_id = actor_membership.office_id
              and closure.descendant_office_id = target.office_id
            where actor_membership.tenant_id = target.tenant_id
              and actor_membership.user_id = auth.uid()
              and actor_membership.status = 'active'
              and (actor_membership.office_id is null or closure.descendant_office_id is not null)
         )
       )
  );
$$;

create or replace function authz.is_elevated_session_valid(
  p_session_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, authz
as $$
  select exists (
    select 1
      from authz.elevated_sessions
     where session_id = p_session_id
       and user_id = p_user_id
       and revoked_at is null
       and valid_until > clock_timestamp()
  );
$$;

create or replace function authz.consume_action_confirmation(
  p_session_id uuid,
  p_user_id uuid,
  p_action_key text,
  p_target_type text,
  p_target_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public, authz
as $$
begin
  update authz.action_confirmations
     set consumed_at = clock_timestamp()
   where id = (
     select id
       from authz.action_confirmations
      where session_id = p_session_id
        and user_id = p_user_id
        and action_key = p_action_key
        and target_type = p_target_type
        and target_id is not distinct from p_target_id
        and consumed_at is null
        and expires_at > clock_timestamp()
      order by confirmed_at
      for update skip locked
      limit 1
   );
  return found;
end;
$$;

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
    select tenant_id, office_id, user_id
      into target_membership_tenant, target_membership_office, target_membership_user
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
    return (
      'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
      effective_target_office, p_target_membership_id, effective_target_user,
      p_target_wallet_id, 'system_rule', null, 'wallet_domain_not_initialized',
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

create or replace function authz.seed_default_role_policy(p_tenant_id uuid)
returns void
language sql
set search_path = pg_catalog, public, authz
as $$
  select authz.seed_tenant_role_permissions(p_tenant_id);
$$;

revoke all on function authz.rebuild_office_closure() from public, anon, authenticated;
revoke all on function authz.validate_access_assignment() from public, anon, authenticated;
revoke all on function authz.validate_access_rule() from public, anon, authenticated;
revoke all on function authz.prevent_audit_mutation() from public, anon, authenticated;
revoke all on function authz.is_elevated_session_valid(uuid, uuid) from public, anon, authenticated;
revoke all on function authz.consume_action_confirmation(uuid, uuid, text, text, uuid) from public, anon, authenticated;
revoke all on function authz.authorize(uuid, uuid, text, uuid, uuid, uuid, uuid, uuid, uuid, text, numeric) from public, anon, authenticated;
revoke all on function authz.seed_default_role_policy(uuid) from public, anon, authenticated;

grant execute on function authz.is_active_member_in_tenant(uuid) to authenticated;
grant execute on function authz.can_read_office(uuid) to authenticated;
grant execute on function authz.can_read_membership(uuid) to authenticated;

create policy user_accounts_self_read
  on public.user_accounts
  for select to authenticated
  using ((select auth.uid()) = user_id);

create policy user_profiles_self_read
  on public.user_profiles
  for select to authenticated
  using ((select auth.uid()) = user_id);

create policy user_profiles_self_update
  on public.user_profiles
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy tenants_active_member_read
  on public.tenants
  for select to authenticated
  using (authz.is_active_member_in_tenant(id));

create policy offices_authorized_scope_read
  on public.offices
  for select to authenticated
  using (authz.can_read_office(id));

create policy memberships_self_or_scope_read
  on public.memberships
  for select to authenticated
  using (authz.can_read_membership(id));

revoke all on table authz.permission_catalog, authz.default_role_permissions,
  authz.tenant_role_permissions, authz.office_closure, authz.access_assignments,
  authz.access_rules, authz.elevated_sessions, authz.action_confirmations,
  authz.security_audit_events from public, anon, authenticated;
