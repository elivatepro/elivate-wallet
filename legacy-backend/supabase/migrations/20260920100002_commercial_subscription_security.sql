alter function authz.authorize(
  uuid, uuid, text, uuid, uuid, uuid, uuid, uuid, uuid, text, numeric
) rename to authorize_without_commercial_restriction;

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
set search_path = ''
as $$
declare
  permission_record authz.permission_catalog%rowtype;
  account_state public.account_status;
  tenant_state public.tenant_status;
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

  select permission.*
    into permission_record
    from authz.permission_catalog permission
   where permission.permission_key = p_permission_key;

  if not found then
    return (
      'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
      p_target_office_id, p_target_membership_id, p_target_user_id,
      p_target_wallet_id, 'system_rule', null, 'unknown_permission', 'none', 0
    )::authz.authorization_decision;
  end if;

  select account.status
    into account_state
    from public.user_accounts account
   where account.user_id = p_actor_user_id;

  if account_state is null or account_state <> 'active' then
    return (
      'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
      p_target_office_id, p_target_membership_id, p_target_user_id,
      p_target_wallet_id, 'system_rule', null, 'account_not_active',
      permission_record.step_up_mode, 300
    )::authz.authorization_decision;
  end if;

  select tenant.status
    into tenant_state
    from public.tenants tenant
   where tenant.id = p_target_tenant_id;

  if tenant_state is null or tenant_state <> 'active' then
    return (
      'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
      p_target_office_id, p_target_membership_id, p_target_user_id,
      p_target_wallet_id, 'system_rule', null, 'tenant_not_active',
      permission_record.step_up_mode, 300
    )::authz.authorization_decision;
  end if;

  if permission_record.blocked_during_commercial_restriction
     and commercial.is_tenant_commercially_restricted(p_target_tenant_id) then
    return (
      'DENY', p_permission_key, p_actor_user_id, p_target_tenant_id,
      p_target_office_id, p_target_membership_id, p_target_user_id,
      p_target_wallet_id, 'system_rule', null,
      'commercial_money_movement_restricted',
      permission_record.step_up_mode, 300
    )::authz.authorization_decision;
  end if;

  return authz.authorize_without_commercial_restriction(
    p_actor_user_id,
    p_session_id,
    p_permission_key,
    p_target_tenant_id,
    p_target_office_id,
    p_target_membership_id,
    p_target_user_id,
    p_target_wallet_id,
    p_resource_owner_user_id,
    p_action_key,
    p_amount
  );
end;
$$;

alter table commercial.plans enable row level security;
alter table commercial.plan_versions enable row level security;
alter table commercial.extra_catalog enable row level security;
alter table commercial.tenant_subscriptions enable row level security;
alter table commercial.subscription_status_events enable row level security;
alter table commercial.billing_owner_assignments enable row level security;

alter table commercial.plans force row level security;
alter table commercial.plan_versions force row level security;
alter table commercial.extra_catalog force row level security;
alter table commercial.tenant_subscriptions force row level security;
alter table commercial.subscription_status_events force row level security;
alter table commercial.billing_owner_assignments force row level security;

create policy plans_private_deny
  on commercial.plans as restrictive for all to public
  using (false) with check (false);
create policy plan_versions_private_deny
  on commercial.plan_versions as restrictive for all to public
  using (false) with check (false);
create policy extra_catalog_private_deny
  on commercial.extra_catalog as restrictive for all to public
  using (false) with check (false);
create policy tenant_subscriptions_private_deny
  on commercial.tenant_subscriptions as restrictive for all to public
  using (false) with check (false);
create policy subscription_status_events_private_deny
  on commercial.subscription_status_events as restrictive for all to public
  using (false) with check (false);
create policy billing_owner_assignments_private_deny
  on commercial.billing_owner_assignments as restrictive for all to public
  using (false) with check (false);

revoke all on schema commercial from public, anon, authenticated, service_role;
revoke all on all tables in schema commercial
  from public, anon, authenticated, service_role;
revoke all on all sequences in schema commercial
  from public, anon, authenticated, service_role;
revoke all on all functions in schema commercial
  from public, anon, authenticated, service_role;

revoke all on function authz.authorize_without_commercial_restriction(
  uuid, uuid, text, uuid, uuid, uuid, uuid, uuid, uuid, text, numeric
) from public, anon, authenticated, service_role;
revoke all on function authz.authorize(
  uuid, uuid, text, uuid, uuid, uuid, uuid, uuid, uuid, text, numeric
) from public, anon, authenticated, service_role;

comment on function commercial.assert_seat_capacity(uuid, uuid, timestamptz) is
  'Concurrency-safe guard required by future trusted membership activation commands.';
comment on function commercial.set_billing_owner(uuid, uuid, uuid, uuid, text) is
  'Private audited command requiring manage_subscription plus a fresh elevated session.';
comment on function authz.authorize_without_commercial_restriction(
  uuid, uuid, text, uuid, uuid, uuid, uuid, uuid, uuid, text, numeric
) is
  'Private resolver core. Call authz.authorize so effective commercial restrictions cannot be bypassed.';
