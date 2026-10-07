create index tenant_subscriptions_plan_version_id
  on commercial.tenant_subscriptions (plan_version_id);

create index tenant_subscriptions_status_changed_by_user_id
  on commercial.tenant_subscriptions (status_changed_by_user_id);

create index tenant_subscriptions_created_by_user_id
  on commercial.tenant_subscriptions (created_by_user_id);

create index subscription_status_events_tenant_subscription
  on commercial.subscription_status_events (tenant_id, subscription_id);

create index subscription_status_events_actor_user_id
  on commercial.subscription_status_events (actor_user_id);

create index billing_owner_assignments_tenant_membership
  on commercial.billing_owner_assignments (tenant_id, membership_id);

create index billing_owner_assignments_owner_user_id
  on commercial.billing_owner_assignments (owner_user_id);

create index billing_owner_assignments_assigned_by_user_id
  on commercial.billing_owner_assignments (assigned_by_user_id);

create index billing_owner_assignments_ended_by_user_id
  on commercial.billing_owner_assignments (ended_by_user_id);

create or replace function commercial.evaluate_seat_capacity(
  p_tenant_id uuid,
  p_candidate_user_id uuid,
  p_at timestamptz default clock_timestamp()
)
returns commercial.seat_capacity_decision
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  current_count integer;
  projected_count integer;
  capacity_limit integer;
  candidate_already_counted boolean;
  candidate_billable boolean;
begin
  if p_tenant_id is null or p_candidate_user_id is null then
    return (
      false, p_tenant_id, p_candidate_user_id, 0, 0, null, 'invalid_capacity_context'
    )::commercial.seat_capacity_decision;
  end if;

  select version.maximum_covered_users
    into capacity_limit
    from commercial.tenant_subscriptions subscription
    join commercial.plan_versions version
      on version.id = subscription.plan_version_id
   where subscription.tenant_id = p_tenant_id
     and subscription.is_current;

  if not found then
    return (
      false, p_tenant_id, p_candidate_user_id, 0, 0, null, 'current_subscription_required'
    )::commercial.seat_capacity_decision;
  end if;

  current_count := commercial.count_billable_users(p_tenant_id);

  select exists (
    select 1
      from public.memberships membership
      join public.user_accounts account
        on account.user_id = membership.user_id
     where membership.tenant_id = p_tenant_id
       and membership.user_id = p_candidate_user_id
       and membership.status in ('active', 'suspended')
       and account.status in ('active', 'suspended')
  ) into candidate_already_counted;

  select exists (
    select 1
      from public.user_accounts account
     where account.user_id = p_candidate_user_id
       and account.status in ('active', 'suspended')
  ) into candidate_billable;

  projected_count := current_count + case when candidate_already_counted then 0 else 1 end;

  if not candidate_billable then
    return (
      false, p_tenant_id, p_candidate_user_id, current_count,
      projected_count, capacity_limit, 'candidate_account_not_billable'
    )::commercial.seat_capacity_decision;
  end if;

  if commercial.is_tenant_commercially_restricted(p_tenant_id, p_at) then
    return (
      false, p_tenant_id, p_candidate_user_id, current_count,
      projected_count, capacity_limit, 'subscription_restricted'
    )::commercial.seat_capacity_decision;
  end if;

  if capacity_limit is not null and projected_count > capacity_limit then
    return (
      false, p_tenant_id, p_candidate_user_id, current_count,
      projected_count, capacity_limit, 'seat_capacity_reached'
    )::commercial.seat_capacity_decision;
  end if;

  return (
    true, p_tenant_id, p_candidate_user_id, current_count,
    projected_count, capacity_limit,
    case when candidate_already_counted then 'user_already_covered' else 'seat_available' end
  )::commercial.seat_capacity_decision;
end;
$$;

revoke all on function commercial.evaluate_seat_capacity(uuid, uuid, timestamptz)
  from public, anon, authenticated, service_role;
