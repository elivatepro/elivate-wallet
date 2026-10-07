create or replace function commercial.prevent_immutable_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception using
    errcode = '55000',
    message = format('%I.%I is immutable', tg_table_schema, tg_table_name);
end;
$$;

create trigger plans_prevent_mutation
  before update or delete on commercial.plans
  for each row execute function commercial.prevent_immutable_mutation();

create trigger plan_versions_prevent_mutation
  before update or delete on commercial.plan_versions
  for each row execute function commercial.prevent_immutable_mutation();

create trigger extra_catalog_prevent_mutation
  before update or delete on commercial.extra_catalog
  for each row execute function commercial.prevent_immutable_mutation();

create trigger subscription_status_events_prevent_mutation
  before update or delete on commercial.subscription_status_events
  for each row execute function commercial.prevent_immutable_mutation();

create or replace function commercial.prepare_subscription_status()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.status_changed_at := coalesce(new.status_changed_at, clock_timestamp());
    return new;
  end if;

  if old.status is distinct from new.status then
    new.status_changed_at := clock_timestamp();
  elsif old.status_reason is distinct from new.status_reason then
    raise exception using
      errcode = '23514',
      message = 'subscription status reason changes only with status';
  end if;

  return new;
end;
$$;

create trigger tenant_subscriptions_prepare_status
  before insert or update on commercial.tenant_subscriptions
  for each row execute function commercial.prepare_subscription_status();

create or replace function commercial.record_subscription_status_event()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or old.status is distinct from new.status then
    insert into commercial.subscription_status_events (
      tenant_id,
      subscription_id,
      previous_status,
      new_status,
      reason,
      actor_user_id,
      occurred_at
    )
    values (
      new.tenant_id,
      new.id,
      case when tg_op = 'INSERT' then null else old.status end,
      new.status,
      new.status_reason,
      new.status_changed_by_user_id,
      new.status_changed_at
    );
  end if;

  return new;
end;
$$;

create trigger tenant_subscriptions_record_status
  after insert or update of status on commercial.tenant_subscriptions
  for each row execute function commercial.record_subscription_status_event();

create trigger tenant_subscriptions_prevent_delete
  before delete on commercial.tenant_subscriptions
  for each row execute function commercial.prevent_immutable_mutation();

create or replace function commercial.guard_billing_owner_history()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception using
      errcode = '55000',
      message = 'commercial.billing_owner_assignments is append-only';
  end if;

  if old.ended_at is not null
     or new.id is distinct from old.id
     or new.tenant_id is distinct from old.tenant_id
     or new.membership_id is distinct from old.membership_id
     or new.owner_user_id is distinct from old.owner_user_id
     or new.assigned_by_user_id is distinct from old.assigned_by_user_id
     or new.assignment_reason is distinct from old.assignment_reason
     or new.started_at is distinct from old.started_at
     or new.ended_at is null
     or new.ended_by_user_id is null
     or new.end_reason is null then
    raise exception using
      errcode = '55000',
      message = 'billing owner history is immutable except for ending the current assignment';
  end if;

  return new;
end;
$$;

create trigger billing_owner_assignments_guard_history
  before update or delete on commercial.billing_owner_assignments
  for each row execute function commercial.guard_billing_owner_history();

create or replace function commercial.count_billable_users(
  p_tenant_id uuid
)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(distinct membership.user_id)::integer
    from public.memberships membership
    join public.user_accounts account
      on account.user_id = membership.user_id
   where membership.tenant_id = p_tenant_id
     and membership.status in ('active', 'suspended')
     and account.status in ('active', 'suspended');
$$;

create or replace function commercial.is_tenant_commercially_restricted(
  p_tenant_id uuid,
  p_at timestamptz default clock_timestamp()
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from commercial.tenant_subscriptions subscription
     where subscription.tenant_id = p_tenant_id
       and subscription.is_current
       and (
         subscription.status = 'suspended'
         or (
           subscription.status = 'cancelled'
           and (
             subscription.service_ends_at is null
             or subscription.service_ends_at <= p_at
           )
         )
       )
  );
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
  subscription_status commercial.subscription_status;
begin
  if p_tenant_id is null or p_candidate_user_id is null then
    return (
      false, p_tenant_id, p_candidate_user_id, 0, 0, null, 'invalid_capacity_context'
    )::commercial.seat_capacity_decision;
  end if;

  select
    version.maximum_covered_users,
    subscription.status
    into capacity_limit, subscription_status
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

create or replace function commercial.assert_seat_capacity(
  p_tenant_id uuid,
  p_candidate_user_id uuid,
  p_at timestamptz default clock_timestamp()
)
returns commercial.seat_capacity_decision
language plpgsql
security definer
set search_path = ''
as $$
declare
  decision commercial.seat_capacity_decision;
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('commercial.seat:' || p_tenant_id::text, 0)
  );

  decision := commercial.evaluate_seat_capacity(
    p_tenant_id,
    p_candidate_user_id,
    p_at
  );

  if not decision.allowed then
    raise exception using
      errcode = '23514',
      message = 'tenant cannot add or activate this covered user',
      detail = decision.reason_code;
  end if;

  return decision;
end;
$$;

create or replace function commercial.set_billing_owner(
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_membership_id uuid,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  decision authz.authorization_decision;
  target_membership public.memberships%rowtype;
  current_assignment commercial.billing_owner_assignments%rowtype;
  new_assignment_id uuid;
begin
  if p_actor_user_id is null
     or p_tenant_id is null
     or p_membership_id is null
     or p_reason is null
     or length(btrim(p_reason)) = 0 then
    raise exception using
      errcode = '22023',
      message = 'billing owner assignment input is invalid';
  end if;

  decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'manage_subscription',
    p_tenant_id,
    null,
    p_membership_id,
    null,
    null,
    null,
    null,
    null
  );

  if decision.decision <> 'ALLOW' then
    raise exception using
      errcode = '42501',
      message = 'billing owner change is not authorized';
  end if;

  if p_session_id is null
     or not authz.is_elevated_session_valid(p_session_id, p_actor_user_id) then
    raise exception using
      errcode = '42501',
      message = 'billing owner change requires fresh step-up authentication';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('commercial.billing-owner:' || p_tenant_id::text, 0)
  );

  select membership.*
    into target_membership
    from public.memberships membership
    join public.user_accounts account
      on account.user_id = membership.user_id
   where membership.id = p_membership_id
     and membership.tenant_id = p_tenant_id
     and membership.status = 'active'
     and account.status = 'active';

  if target_membership.id is null then
    raise exception using
      errcode = '23514',
      message = 'billing owner must have an active tenant membership and account';
  end if;

  select assignment.*
    into current_assignment
    from commercial.billing_owner_assignments assignment
   where assignment.tenant_id = p_tenant_id
     and assignment.ended_at is null
   for update;

  if current_assignment.membership_id = p_membership_id then
    return current_assignment.id;
  end if;

  if current_assignment.id is not null then
    update commercial.billing_owner_assignments
       set ended_at = clock_timestamp(),
           ended_by_user_id = p_actor_user_id,
           end_reason = p_reason
     where id = current_assignment.id;
  end if;

  insert into commercial.billing_owner_assignments (
    tenant_id,
    membership_id,
    owner_user_id,
    assigned_by_user_id,
    assignment_reason
  )
  values (
    p_tenant_id,
    target_membership.id,
    target_membership.user_id,
    p_actor_user_id,
    p_reason
  )
  returning id into new_assignment_id;

  insert into authz.security_audit_events (
    actor_user_id,
    session_id,
    tenant_id,
    event_type,
    permission_key,
    target_type,
    target_id,
    allowed,
    source,
    source_id,
    reason_code,
    metadata
  )
  values (
    p_actor_user_id,
    p_session_id,
    p_tenant_id,
    'billing_owner_changed',
    'manage_subscription',
    'membership',
    p_membership_id,
    true,
    decision.source,
    decision.source_id,
    decision.reason_code,
    jsonb_build_object(
      'assignment_id', new_assignment_id,
      'previous_assignment_id', current_assignment.id
    )
  );

  return new_assignment_id;
end;
$$;
