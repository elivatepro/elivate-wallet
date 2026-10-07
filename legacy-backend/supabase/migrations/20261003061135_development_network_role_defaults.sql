-- Initialize approved tenant defaults without changing commercial restrictions.
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

  -- The resolver reads tenant policies; a membership alone grants no permission.
  perform authz.seed_tenant_role_permissions(new_tenant_id);

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

-- Keep the existing narrow command_api transport as the sole runtime entry.
revoke all on function internal.bootstrap_development_network(uuid, bytea, text)
  from public, anon, authenticated, service_role;

-- Repair only registered development networks with a completely absent policy.
-- A sparse or denied existing policy is configuration, not a repair candidate.
-- Block concurrent policy writes while selecting empty candidates and seeding.
-- Ordinary authorization reads remain available during this bounded migration.
do $$
declare
  repaired_tenant_id uuid;
begin
  lock table authz.tenant_role_permissions in share row exclusive mode;
  for repaired_tenant_id in
    select network.tenant_id
      from internal.development_networks network
     where not exists (
       select 1 from authz.tenant_role_permissions policy
        where policy.tenant_id = network.tenant_id
     )
     order by network.tenant_id
  loop
    perform authz.seed_tenant_role_permissions(repaired_tenant_id);

    update public.tenants
       set authz_version = authz_version + 1
     where id = repaired_tenant_id;
    update public.user_accounts account
       set authz_version = account.authz_version + 1
     where exists (
       select 1 from public.memberships membership
        where membership.tenant_id = repaired_tenant_id
          and membership.user_id = account.user_id
          and membership.status <> 'ended'
     );

    insert into authz.security_audit_events (
      actor_user_id, tenant_id, event_type, target_type, target_id,
      allowed, source, reason_code, metadata
    ) values (
      null, repaired_tenant_id, 'development_network_role_defaults_initialized',
      'tenant', repaired_tenant_id, true, 'system_rule',
      'empty_development_policy_repair',
      jsonb_build_object('migration', '20261003061135_development_network_role_defaults')
    );
  end loop;
end;
$$;
