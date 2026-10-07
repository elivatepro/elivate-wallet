-- A suspended development network permits only three account-flow test seats.
-- Its commercial suspension continues to deny money-moving permissions.
create table internal.development_networks (
  tenant_id uuid primary key references public.tenants (id) on delete restrict,
  setup_token_digest bytea not null unique
    check (pg_catalog.octet_length(setup_token_digest) = 32),
  created_by_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp()
);

alter table internal.development_networks enable row level security;
alter table internal.development_networks force row level security;
revoke all on internal.development_networks from public, anon, authenticated, service_role;

create or replace function internal.bootstrap_development_network(
  p_actor_user_id uuid,
  p_setup_token_digest bytea,
  p_network_name text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  clean_name text := pg_catalog.btrim(p_network_name);
  account_state public.account_status;
  verified_at timestamptz;
  new_tenant_id uuid;
  root_office_id uuid;
  director_office_id uuid;
begin
  if p_actor_user_id is null
     or p_setup_token_digest is null
     or pg_catalog.octet_length(p_setup_token_digest) <> 32
     or clean_name is null
     or pg_catalog.length(clean_name) < 3
     or pg_catalog.length(clean_name) > 80 then
    raise exception using errcode = '22023',
      message = 'development network setup input is invalid';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'development-network-token:' || pg_catalog.encode(p_setup_token_digest, 'hex'), 0
    )
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('development-network-user:' || p_actor_user_id::text, 0)
  );

  select account.status, identity.email_confirmed_at
    into account_state, verified_at
    from public.user_accounts account
    join auth.users identity on identity.id = account.user_id
   where account.user_id = p_actor_user_id
   for update of account;

  if account_state <> 'active' or verified_at is null then
    raise exception using errcode = '42501',
      message = 'a verified active account is required for network setup';
  end if;
  if exists (
    select 1 from public.memberships
     where user_id = p_actor_user_id and status <> 'ended'
  ) then
    raise exception using errcode = '23514',
      message = 'account already has a current network membership';
  end if;
  if exists (
    select 1 from internal.development_networks
     where setup_token_digest = p_setup_token_digest
  ) then
    raise exception using errcode = '23505',
      message = 'development setup token has already been used';
  end if;

  insert into public.tenants (name)
  values (clean_name)
  returning id into new_tenant_id;

  insert into public.offices (tenant_id, office_type, name)
  values (new_tenant_id, 'world_team', clean_name || ' World Team')
  returning id into root_office_id;

  insert into public.offices (tenant_id, parent_office_id, office_type, name)
  values (new_tenant_id, root_office_id, 'director', clean_name || ' Director Office')
  returning id into director_office_id;

  insert into public.offices (tenant_id, parent_office_id, office_type, name)
  values (new_tenant_id, director_office_id, 'team_leader', clean_name || ' Team')
  returning id into root_office_id;

  insert into public.memberships (
    tenant_id, user_id, office_id, role_key, status, is_primary
  )
  values (
    new_tenant_id, p_actor_user_id, null, 'president_team_member', 'active', true
  );

  insert into commercial.tenant_subscriptions (
    tenant_id, plan_version_id, status, starts_at,
    status_reason, created_by_user_id
  )
  values (
    new_tenant_id, 'c1000000-0000-4000-8000-000000000001',
    'suspended', pg_catalog.clock_timestamp(),
    'development_preview_no_payment', p_actor_user_id
  );

  insert into internal.development_networks (
    tenant_id, setup_token_digest, created_by_user_id
  )
  values (new_tenant_id, p_setup_token_digest, p_actor_user_id);

  perform internal.bump_membership_authorization_versions(
    new_tenant_id, p_actor_user_id
  );

  insert into authz.security_audit_events (
    actor_user_id, tenant_id, event_type, target_type, target_id,
    allowed, source, reason_code
  )
  values (
    p_actor_user_id, new_tenant_id, 'development_network_created',
    'tenant', new_tenant_id, true, 'system_rule', 'one_time_setup_token'
  );

  return new_tenant_id;
end;
$$;

revoke all on function internal.bootstrap_development_network(uuid, bytea, text)
  from public, anon, authenticated;
grant execute on function internal.bootstrap_development_network(uuid, bytea, text)
  to service_role;

create or replace function commercial.evaluate_seat_capacity(
  p_tenant_id uuid,
  p_candidate_user_id uuid,
  p_at timestamptz default pg_catalog.clock_timestamp()
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
  subscription_state commercial.subscription_status;
begin
  if p_tenant_id is null or p_candidate_user_id is null then
    return (
      false, p_tenant_id, p_candidate_user_id, 0, 0, null,
      'invalid_capacity_context'
    )::commercial.seat_capacity_decision;
  end if;

  select version.maximum_covered_users, subscription.status
    into capacity_limit, subscription_state
    from commercial.tenant_subscriptions subscription
    join commercial.plan_versions version
      on version.id = subscription.plan_version_id
   where subscription.tenant_id = p_tenant_id
     and subscription.is_current;

  if not found then
    return (
      false, p_tenant_id, p_candidate_user_id, 0, 0, null,
      'current_subscription_required'
    )::commercial.seat_capacity_decision;
  end if;

  current_count := commercial.count_billable_users(p_tenant_id);
  select exists (
    select 1
      from public.memberships membership
      join public.user_accounts account on account.user_id = membership.user_id
     where membership.tenant_id = p_tenant_id
       and membership.user_id = p_candidate_user_id
       and membership.status in ('active', 'suspended')
       and account.status in ('active', 'suspended')
  ) into candidate_already_counted;
  select exists (
    select 1 from public.user_accounts account
     where account.user_id = p_candidate_user_id
       and account.status in ('active', 'suspended')
  ) into candidate_billable;
  projected_count := current_count
    + case when candidate_already_counted then 0 else 1 end;

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

  if subscription_state = 'suspended'
     and exists (
       select 1 from internal.development_networks network
        where network.tenant_id = p_tenant_id
     ) then
    return (
      projected_count <= 3, p_tenant_id, p_candidate_user_id, current_count,
      projected_count, 3,
      case when projected_count <= 3
        then 'development_preview_seat'
        else 'development_preview_limit_reached' end
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

revoke all on function commercial.evaluate_seat_capacity(uuid, uuid, timestamptz)
  from public, anon, authenticated, service_role;
