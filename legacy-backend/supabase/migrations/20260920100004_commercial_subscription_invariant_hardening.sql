create or replace function commercial.prepare_subscription_status()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.service_ends_at is not null and new.status <> 'cancelled' then
    raise exception using
      errcode = '23514',
      message = 'service end timestamp requires a cancelled subscription';
  end if;

  if tg_op = 'INSERT' then
    new.status_changed_at := coalesce(new.status_changed_at, clock_timestamp());
    return new;
  end if;

  if old.is_current = false then
    raise exception using
      errcode = '55000',
      message = 'historical tenant subscriptions are immutable';
  end if;

  if new.id is distinct from old.id
     or new.tenant_id is distinct from old.tenant_id
     or new.plan_version_id is distinct from old.plan_version_id
     or new.starts_at is distinct from old.starts_at
     or new.created_by_user_id is distinct from old.created_by_user_id
     or new.created_at is distinct from old.created_at
     or (old.is_current = false and new.is_current = true) then
    raise exception using
      errcode = '55000',
      message = 'tenant subscription identity and plan history are immutable';
  end if;

  if old.status is distinct from new.status then
    new.status_changed_at := clock_timestamp();
  elsif old.status_reason is distinct from new.status_reason
     or old.status_changed_at is distinct from new.status_changed_at
     or old.status_changed_by_user_id is distinct from new.status_changed_by_user_id then
    raise exception using
      errcode = '23514',
      message = 'subscription status metadata changes only with status';
  end if;

  return new;
end;
$$;

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

  if candidate_already_counted then
    return (
      true, p_tenant_id, p_candidate_user_id, current_count,
      projected_count, capacity_limit, 'user_already_covered'
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
    projected_count, capacity_limit, 'seat_available'
  )::commercial.seat_capacity_decision;
end;
$$;

revoke all on function commercial.prepare_subscription_status()
  from public, anon, authenticated, service_role;
revoke all on function commercial.evaluate_seat_capacity(uuid, uuid, timestamptz)
  from public, anon, authenticated, service_role;
