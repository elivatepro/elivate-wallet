-- Recheck current authority on actor-bound replays without repeating mutations.

create or replace function internal.create_membership(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_target_user_id uuid,
  p_office_id uuid,
  p_role_key public.role_key
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  replay_result uuid;
  decision authz.authorization_decision;
  target_account_status public.account_status;
  make_primary boolean;
  membership_id uuid;
begin
  if p_idempotency_key is null
     or p_actor_user_id is null
     or p_tenant_id is null
     or p_target_user_id is null
     or p_office_id is null
     or p_role_key is null then
    raise exception using
      errcode = '22023',
      message = 'membership creation input is invalid';
  end if;

  if p_role_key = 'president_team_member' then
    raise exception using
      errcode = '23514',
      message = 'President authority requires the protected presidency transfer command';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'membership command actor does not match the authenticated user';
  end if;

  request_fingerprint := internal.organization_request_fingerprint(
    'create_membership',
    pg_catalog.jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'tenant_id', p_tenant_id,
      'target_user_id', p_target_user_id,
      'office_id', p_office_id,
      'role_key', p_role_key::text
    )
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  replay_result := internal.organization_replay_result(
    p_idempotency_key,
    'create_membership',
    p_actor_user_id,
    request_fingerprint,
    'membership'
  );
  if replay_result is not null then
  decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'manage_members',
    p_tenant_id,
    p_office_id,
    null,
    p_target_user_id,
    null,
    null,
    null,
    null
  );

  if decision.decision <> 'ALLOW' then
    raise exception using
      errcode = '42501',
      message = 'membership creation is not authorized';
  end if;
    return replay_result;
  end if;

  decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'manage_members',
    p_tenant_id,
    p_office_id,
    null,
    p_target_user_id,
    null,
    null,
    null,
    null
  );

  if decision.decision <> 'ALLOW' then
    raise exception using
      errcode = '42501',
      message = 'membership creation is not authorized';
  end if;

  select account.status
    into target_account_status
    from public.user_accounts account
   where account.user_id = p_target_user_id;

  if target_account_status is null or target_account_status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'membership user account must be active';
  end if;

  perform internal.lock_membership_subject(p_tenant_id, p_target_user_id);
  perform internal.lock_active_office(p_tenant_id, p_office_id);
  perform commercial.assert_seat_capacity(p_tenant_id, p_target_user_id);

  select not exists (
    select 1
      from public.memberships current_membership
     where current_membership.tenant_id = p_tenant_id
       and current_membership.user_id = p_target_user_id
       and current_membership.status <> 'ended'
       and current_membership.is_primary
  ) into make_primary;

  insert into public.memberships (
    tenant_id,
    user_id,
    office_id,
    role_key,
    status,
    is_primary
  )
  values (
    p_tenant_id,
    p_target_user_id,
    p_office_id,
    p_role_key,
    'active',
    make_primary
  )
  returning id into membership_id;

  perform internal.ensure_wallet_for_member(p_target_user_id);
  perform internal.bump_membership_authorization_versions(
    p_tenant_id,
    p_target_user_id
  );

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
    'membership_created',
    'manage_members',
    'membership',
    membership_id,
    true,
    decision.source,
    decision.source_id,
    decision.reason_code,
    pg_catalog.jsonb_build_object(
      'target_user_id', p_target_user_id,
      'office_id', p_office_id,
      'role_key', p_role_key::text,
      'is_primary', make_primary
    )
  );

  perform internal.record_organization_command(
    p_idempotency_key,
    'create_membership',
    p_actor_user_id,
    p_tenant_id,
    request_fingerprint,
    'membership',
    membership_id
  );

  return membership_id;
end;
$$;

create or replace function internal.activate_membership(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  replay_result uuid;
  target_membership public.memberships%rowtype;
  decision authz.authorization_decision;
  make_primary boolean;
begin
  if p_idempotency_key is null
     or p_actor_user_id is null
     or p_membership_id is null then
    raise exception using
      errcode = '22023',
      message = 'membership activation input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'membership command actor does not match the authenticated user';
  end if;

  request_fingerprint := internal.organization_request_fingerprint(
    'activate_membership',
    pg_catalog.jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'membership_id', p_membership_id
    )
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  replay_result := internal.organization_replay_result(
    p_idempotency_key,
    'activate_membership',
    p_actor_user_id,
    request_fingerprint,
    'membership'
  );
  if replay_result is not null then
  select membership.* into target_membership from public.memberships membership where membership.id = p_membership_id;
  decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'suspend_membership',
    target_membership.tenant_id,
    target_membership.office_id,
    target_membership.id,
    target_membership.user_id,
    null,
    null,
    null,
    null
  );

  if decision.decision <> 'ALLOW' then
    raise exception using
      errcode = '42501',
      message = 'membership activation is not authorized';
  end if;
    return replay_result;
  end if;

  select membership.*
    into target_membership
    from public.memberships membership
   where membership.id = p_membership_id;

  if target_membership.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'membership was not found';
  end if;

  perform internal.lock_membership_subject(
    target_membership.tenant_id,
    target_membership.user_id
  );

  select membership.*
    into target_membership
    from public.memberships membership
   where membership.id = p_membership_id
   for update;

  if target_membership.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'membership was not found';
  end if;

  if target_membership.role_key = 'president_team_member' then
    raise exception using
      errcode = '23514',
      message = 'President authority requires the protected presidency transfer command';
  end if;

  decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'suspend_membership',
    target_membership.tenant_id,
    target_membership.office_id,
    target_membership.id,
    target_membership.user_id,
    null,
    null,
    null,
    null
  );

  if decision.decision <> 'ALLOW' then
    raise exception using
      errcode = '42501',
      message = 'membership activation is not authorized';
  end if;

  if target_membership.status = 'ended' then
    raise exception using
      errcode = '23514',
      message = 'an ended membership cannot be activated';
  end if;

  if target_membership.status = 'suspended' then
    perform internal.lock_active_office(
      target_membership.tenant_id,
      target_membership.office_id
    );
    perform commercial.assert_seat_capacity(
      target_membership.tenant_id,
      target_membership.user_id
    );

    select not exists (
      select 1
        from public.memberships current_membership
       where current_membership.tenant_id = target_membership.tenant_id
         and current_membership.user_id = target_membership.user_id
         and current_membership.status <> 'ended'
         and current_membership.is_primary
    ) into make_primary;

    update public.memberships
       set status = 'active',
           is_primary = is_primary or make_primary
     where id = target_membership.id;

    perform internal.ensure_wallet_for_member(target_membership.user_id);
    perform internal.bump_membership_authorization_versions(
      target_membership.tenant_id,
      target_membership.user_id
    );

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
      target_membership.tenant_id,
      'membership_activated',
      'suspend_membership',
      'membership',
      target_membership.id,
      true,
      decision.source,
      decision.source_id,
      decision.reason_code,
      pg_catalog.jsonb_build_object(
        'previous_status', target_membership.status::text,
        'is_primary', target_membership.is_primary or make_primary
      )
    );
  end if;

  perform internal.record_organization_command(
    p_idempotency_key,
    'activate_membership',
    p_actor_user_id,
    target_membership.tenant_id,
    request_fingerprint,
    'membership',
    target_membership.id
  );

  return target_membership.id;
end;
$$;

create or replace function internal.suspend_membership(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  replay_result uuid;
  target_membership public.memberships%rowtype;
  decision authz.authorization_decision;
begin
  if p_idempotency_key is null
     or p_actor_user_id is null
     or p_membership_id is null then
    raise exception using
      errcode = '22023',
      message = 'membership suspension input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'membership command actor does not match the authenticated user';
  end if;

  request_fingerprint := internal.organization_request_fingerprint(
    'suspend_membership',
    pg_catalog.jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'membership_id', p_membership_id
    )
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  replay_result := internal.organization_replay_result(
    p_idempotency_key,
    'suspend_membership',
    p_actor_user_id,
    request_fingerprint,
    'membership'
  );
  if replay_result is not null then
  select membership.* into target_membership from public.memberships membership where membership.id = p_membership_id;
  decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'suspend_membership',
    target_membership.tenant_id,
    target_membership.office_id,
    target_membership.id,
    target_membership.user_id,
    null,
    null,
    null,
    null
  );

  if decision.decision <> 'ALLOW' then
    raise exception using
      errcode = '42501',
      message = 'membership suspension is not authorized';
  end if;
    return replay_result;
  end if;

  select membership.*
    into target_membership
    from public.memberships membership
   where membership.id = p_membership_id;

  if target_membership.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'membership was not found';
  end if;

  perform internal.lock_membership_subject(
    target_membership.tenant_id,
    target_membership.user_id
  );
  perform internal.assert_membership_not_billing_owner(
    target_membership.tenant_id,
    target_membership.id
  );

  select membership.*
    into target_membership
    from public.memberships membership
   where membership.id = p_membership_id
   for update;

  if target_membership.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'membership was not found';
  end if;

  if target_membership.role_key = 'president_team_member' then
    raise exception using
      errcode = '23514',
      message = 'President authority requires the protected presidency transfer command';
  end if;

  decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'suspend_membership',
    target_membership.tenant_id,
    target_membership.office_id,
    target_membership.id,
    target_membership.user_id,
    null,
    null,
    null,
    null
  );

  if decision.decision <> 'ALLOW' then
    raise exception using
      errcode = '42501',
      message = 'membership suspension is not authorized';
  end if;

  if target_membership.status = 'ended' then
    raise exception using
      errcode = '23514',
      message = 'an ended membership cannot be suspended';
  end if;

  if target_membership.status = 'active' then
    update public.memberships
       set status = 'suspended'
     where id = target_membership.id;

    perform internal.bump_membership_authorization_versions(
      target_membership.tenant_id,
      target_membership.user_id
    );

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
      target_membership.tenant_id,
      'membership_suspended',
      'suspend_membership',
      'membership',
      target_membership.id,
      true,
      decision.source,
      decision.source_id,
      decision.reason_code,
      pg_catalog.jsonb_build_object('previous_status', target_membership.status::text)
    );
  end if;

  perform internal.record_organization_command(
    p_idempotency_key,
    'suspend_membership',
    p_actor_user_id,
    target_membership.tenant_id,
    request_fingerprint,
    'membership',
    target_membership.id
  );

  return target_membership.id;
end;
$$;

create or replace function internal.end_membership(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_replacement_primary_membership_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  replay_result uuid;
  target_membership public.memberships%rowtype;
  replacement_membership public.memberships%rowtype;
  decision authz.authorization_decision;
  other_current_count integer;
begin
  if p_idempotency_key is null
     or p_actor_user_id is null
     or p_membership_id is null then
    raise exception using
      errcode = '22023',
      message = 'membership end input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'membership command actor does not match the authenticated user';
  end if;

  request_fingerprint := internal.organization_request_fingerprint(
    'end_membership',
    pg_catalog.jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'membership_id', p_membership_id,
      'replacement_primary_membership_id', p_replacement_primary_membership_id
    )
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  replay_result := internal.organization_replay_result(
    p_idempotency_key,
    'end_membership',
    p_actor_user_id,
    request_fingerprint,
    'membership'
  );
  if replay_result is not null then
  select membership.* into target_membership from public.memberships membership where membership.id = p_membership_id;
  decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'end_membership',
    target_membership.tenant_id,
    target_membership.office_id,
    target_membership.id,
    target_membership.user_id,
    null,
    null,
    null,
    null
  );

  if decision.decision <> 'ALLOW' then
    raise exception using
      errcode = '42501',
      message = 'ending the membership is not authorized';
  end if;
    return replay_result;
  end if;

  select membership.*
    into target_membership
    from public.memberships membership
   where membership.id = p_membership_id;

  if target_membership.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'membership was not found';
  end if;

  perform internal.lock_membership_subject(
    target_membership.tenant_id,
    target_membership.user_id
  );
  perform internal.assert_membership_not_billing_owner(
    target_membership.tenant_id,
    target_membership.id
  );

  select membership.*
    into target_membership
    from public.memberships membership
   where membership.id = p_membership_id
   for update;

  if target_membership.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'membership was not found';
  end if;

  if target_membership.role_key = 'president_team_member' then
    raise exception using
      errcode = '23514',
      message = 'President authority requires the protected presidency transfer command';
  end if;

  decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'end_membership',
    target_membership.tenant_id,
    target_membership.office_id,
    target_membership.id,
    target_membership.user_id,
    null,
    null,
    null,
    null
  );

  if decision.decision <> 'ALLOW' then
    raise exception using
      errcode = '42501',
      message = 'ending the membership is not authorized';
  end if;

  if target_membership.status <> 'ended' then
    select pg_catalog.count(*)
      into other_current_count
      from public.memberships current_membership
     where current_membership.tenant_id = target_membership.tenant_id
       and current_membership.user_id = target_membership.user_id
       and current_membership.id <> target_membership.id
       and current_membership.status <> 'ended';

    if p_replacement_primary_membership_id is not null then
      select membership.*
        into replacement_membership
        from public.memberships membership
       where membership.id = p_replacement_primary_membership_id
         and membership.tenant_id = target_membership.tenant_id
         and membership.user_id = target_membership.user_id
         and membership.id <> target_membership.id
         and membership.status <> 'ended'
       for update;

      if replacement_membership.id is null then
        raise exception using
          errcode = '23514',
          message = 'replacement primary membership is invalid';
      end if;
    end if;

    if target_membership.is_primary
       and other_current_count > 0
       and replacement_membership.id is null then
      raise exception using
        errcode = '23514',
        message = 'ending a primary membership requires a current replacement';
    end if;

    if not target_membership.is_primary
       and replacement_membership.id is not null then
      raise exception using
        errcode = '23514',
        message = 'replacement primary may be supplied only when ending the primary membership';
    end if;

    update public.memberships
       set status = 'ended',
           is_primary = false,
           ended_at = pg_catalog.clock_timestamp()
     where id = target_membership.id;

    if replacement_membership.id is not null then
      update public.memberships
         set is_primary = true
       where id = replacement_membership.id;
    end if;

    perform internal.bump_membership_authorization_versions(
      target_membership.tenant_id,
      target_membership.user_id
    );

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
      target_membership.tenant_id,
      'membership_ended',
      'end_membership',
      'membership',
      target_membership.id,
      true,
      decision.source,
      decision.source_id,
      decision.reason_code,
      pg_catalog.jsonb_build_object(
        'previous_status', target_membership.status::text,
        'replacement_primary_membership_id', replacement_membership.id
      )
    );
  end if;

  perform internal.record_organization_command(
    p_idempotency_key,
    'end_membership',
    p_actor_user_id,
    target_membership.tenant_id,
    request_fingerprint,
    'membership',
    target_membership.id
  );

  return target_membership.id;
end;
$$;

create or replace function internal.move_membership(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_destination_office_id uuid,
  p_destination_role_key public.role_key
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  replay_result uuid;
  source_membership public.memberships%rowtype;
  source_decision authz.authorization_decision;
  destination_decision authz.authorization_decision;
  new_membership_id uuid;
begin
  if p_idempotency_key is null
     or p_actor_user_id is null
     or p_membership_id is null
     or p_destination_office_id is null
     or p_destination_role_key is null then
    raise exception using
      errcode = '22023',
      message = 'membership move input is invalid';
  end if;

  if p_destination_role_key = 'president_team_member' then
    raise exception using
      errcode = '23514',
      message = 'President authority requires the protected presidency transfer command';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'membership command actor does not match the authenticated user';
  end if;

  request_fingerprint := internal.organization_request_fingerprint(
    'move_membership',
    pg_catalog.jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'membership_id', p_membership_id,
      'destination_office_id', p_destination_office_id,
      'destination_role_key', p_destination_role_key::text
    )
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  replay_result := internal.organization_replay_result(
    p_idempotency_key,
    'move_membership',
    p_actor_user_id,
    request_fingerprint,
    'membership'
  );
  if replay_result is not null then
  select membership.* into source_membership from public.memberships membership where membership.id = p_membership_id;
  source_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'move_membership',
    source_membership.tenant_id,
    source_membership.office_id,
    source_membership.id,
    source_membership.user_id,
    null,
    null,
    null,
    null
  );

  destination_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'move_membership',
    source_membership.tenant_id,
    p_destination_office_id,
    null,
    source_membership.user_id,
    null,
    null,
    null,
    null
  );

  if source_decision.decision <> 'ALLOW'
     or destination_decision.decision <> 'ALLOW' then
    raise exception using
      errcode = '42501',
      message = 'membership move is not authorized for both source and destination';
  end if;
    return replay_result;
  end if;

  select membership.*
    into source_membership
    from public.memberships membership
   where membership.id = p_membership_id;

  if source_membership.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'membership was not found';
  end if;

  perform internal.lock_membership_subject(
    source_membership.tenant_id,
    source_membership.user_id
  );
  perform internal.assert_membership_not_billing_owner(
    source_membership.tenant_id,
    source_membership.id
  );

  select membership.*
    into source_membership
    from public.memberships membership
   where membership.id = p_membership_id
   for update;

  if source_membership.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'membership was not found';
  end if;

  if source_membership.status = 'ended' then
    raise exception using
      errcode = '23514',
      message = 'an ended membership cannot be moved';
  end if;

  if source_membership.role_key = 'president_team_member' then
    raise exception using
      errcode = '23514',
      message = 'President authority requires the protected presidency transfer command';
  end if;

  source_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'move_membership',
    source_membership.tenant_id,
    source_membership.office_id,
    source_membership.id,
    source_membership.user_id,
    null,
    null,
    null,
    null
  );

  destination_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'move_membership',
    source_membership.tenant_id,
    p_destination_office_id,
    null,
    source_membership.user_id,
    null,
    null,
    null,
    null
  );

  if source_decision.decision <> 'ALLOW'
     or destination_decision.decision <> 'ALLOW' then
    raise exception using
      errcode = '42501',
      message = 'membership move is not authorized for both source and destination';
  end if;

  perform internal.lock_active_office(
    source_membership.tenant_id,
    p_destination_office_id
  );
  perform commercial.assert_seat_capacity(
    source_membership.tenant_id,
    source_membership.user_id
  );

  update public.memberships
     set status = 'ended',
         is_primary = false,
         ended_at = pg_catalog.clock_timestamp()
   where id = source_membership.id;

  insert into public.memberships (
    tenant_id,
    user_id,
    office_id,
    role_key,
    status,
    is_primary
  )
  values (
    source_membership.tenant_id,
    source_membership.user_id,
    p_destination_office_id,
    p_destination_role_key,
    'active',
    source_membership.is_primary
  )
  returning id into new_membership_id;

  perform internal.ensure_wallet_for_member(source_membership.user_id);
  perform internal.bump_membership_authorization_versions(
    source_membership.tenant_id,
    source_membership.user_id
  );

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
    source_membership.tenant_id,
    'membership_moved',
    'move_membership',
    'membership',
    source_membership.id,
    true,
    source_decision.source,
    source_decision.source_id,
    source_decision.reason_code,
    pg_catalog.jsonb_build_object(
      'new_membership_id', new_membership_id,
      'destination_office_id', p_destination_office_id,
      'destination_role_key', p_destination_role_key::text,
      'was_primary', source_membership.is_primary,
      'destination_authorization_source', destination_decision.source::text,
      'destination_authorization_source_id', destination_decision.source_id,
      'destination_authorization_reason_code', destination_decision.reason_code
    )
  );

  perform internal.record_organization_command(
    p_idempotency_key,
    'move_membership',
    p_actor_user_id,
    source_membership.tenant_id,
    request_fingerprint,
    'membership',
    new_membership_id
  );

  return new_membership_id;
end;
$$;

create or replace function financial_ops.submit_withdrawal(
  p_idempotency_key uuid,
  p_source_ledger_account_id uuid,
  p_payout_account_id uuid,
  p_requested_amount numeric,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.withdrawal_command_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.withdrawal_command_idempotency%rowtype;
  source_account ledger.ledger_accounts%rowtype;
  payout_account financial_ops.payout_accounts%rowtype;
  target_membership public.memberships%rowtype;
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
  authorization_decision authz.authorization_decision;
  owner_status public.account_status;
  tenant_status public.tenant_status;
  office_status public.office_status;
  currency_scale smallint;
  transfer_out_allowed boolean;
  posted_balance numeric(38, 18);
  reserved_total numeric(38, 18);
  target_permission text;
begin
  if p_idempotency_key is null
     or p_source_ledger_account_id is null
     or p_payout_account_id is null
     or p_requested_amount is null
     or p_requested_amount <= 0
     or p_actor_user_id is null then
    raise exception using
      errcode = '22023',
      message = 'withdrawal submission input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'withdrawal command actor does not match the authenticated user';
  end if;

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'payout_account_id', p_payout_account_id,
      'requested_amount', p_requested_amount::text,
      'source_ledger_account_id', p_source_ledger_account_id
    )::text,
    'sha256'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  select *
    into existing_command
    from financial_ops.withdrawal_command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.command_type <> 'submit_withdrawal'
       or existing_command.request_fingerprint <> request_fingerprint
       or existing_command.actor_user_id <> p_actor_user_id then
      raise exception using
        errcode = '23505',
        message = 'idempotency key already used with different withdrawal command data';
    end if;

    select *
      into target_withdrawal
      from financial_ops.withdrawal_requests withdrawal
     where withdrawal.id = existing_command.withdrawal_id;

  target_permission := case when p_actor_user_id = target_withdrawal.owner_user_id then 'initiate_own_withdrawal' else 'withdraw_on_behalf' end;
  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    target_permission,
    target_withdrawal.tenant_id,
    target_withdrawal.office_id,
    target_withdrawal.membership_id,
    target_withdrawal.owner_user_id,
    target_withdrawal.wallet_id,
    target_withdrawal.owner_user_id,
    'submit_withdrawal',
    p_requested_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);
    return (
      target_withdrawal.id,
      target_withdrawal.withdrawal_reference,
      existing_command.result_status,
      true
    )::financial_ops.withdrawal_command_result;
  end if;

  select *
    into source_account
    from ledger.ledger_accounts account
   where account.id = p_source_ledger_account_id
   for update;

  if source_account.id is null or source_account.account_class <> 'member_value' then
    raise exception using
      errcode = '23514',
      message = 'withdrawal source must be a member-value ledger account';
  end if;

  select definition.minor_unit_scale
    into currency_scale
    from ledger.currency_definitions definition
   where definition.currency_code = source_account.currency_code;

  select definition.transfer_out_allowed
    into transfer_out_allowed
    from public.pocket_definitions definition
   where definition.pocket_key = source_account.pocket_key;

  if currency_scale is null
     or p_requested_amount <> round(p_requested_amount, currency_scale) then
    raise exception using
      errcode = '22003',
      message = 'withdrawal amount exceeds the currency minor-unit scale';
  end if;

  if not coalesce(transfer_out_allowed, false) then
    raise exception using
      errcode = '23514',
      message = 'selected pocket does not allow withdrawal funding';
  end if;

  select *
    into target_membership
    from public.memberships membership
   where membership.id = source_account.membership_id;

  select account.status
    into owner_status
    from public.user_accounts account
   where account.user_id = source_account.owner_user_id;

  select tenant.status
    into tenant_status
    from public.tenants tenant
   where tenant.id = source_account.tenant_id;

  select office.status
    into office_status
    from public.offices office
   where office.tenant_id = source_account.tenant_id
     and office.id = source_account.office_id;

  if target_membership.id is null
     or target_membership.status <> 'active'
     or target_membership.user_id <> source_account.owner_user_id
     or target_membership.office_id <> source_account.office_id
     or owner_status <> 'active'
     or tenant_status <> 'active'
     or office_status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'withdrawal source requires active account and organizational provenance';
  end if;

  select *
    into payout_account
    from financial_ops.payout_accounts account
   where account.id = p_payout_account_id;

  if payout_account.id is null
     or payout_account.wallet_id <> source_account.wallet_id
     or payout_account.owner_user_id <> source_account.owner_user_id
     or payout_account.status <> 'active'
     or payout_account.verification_status <> 'verified' then
    raise exception using
      errcode = '23514',
      message = 'withdrawal requires an active verified payout destination owned by the Wallet holder';
  end if;

  target_permission := case
    when p_actor_user_id = source_account.owner_user_id
      then 'initiate_own_withdrawal'
    else 'withdraw_on_behalf'
  end;

  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    target_permission,
    source_account.tenant_id,
    source_account.office_id,
    source_account.membership_id,
    source_account.owner_user_id,
    source_account.wallet_id,
    source_account.owner_user_id,
    'submit_withdrawal',
    p_requested_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);

  select projection.balance
    into posted_balance
    from ledger.wallet_balance_projections projection
   where projection.ledger_account_id = source_account.id;

  select coalesce(sum(reservation.amount), 0)
    into reserved_total
    from financial_ops.funding_reservations reservation
   where reservation.ledger_account_id = source_account.id
     and reservation.status = 'active';

  if coalesce(posted_balance, 0) - reserved_total < p_requested_amount then
    raise exception using
      errcode = '23514',
      message = 'insufficient available balance for withdrawal reservation';
  end if;

  insert into financial_ops.withdrawal_requests (
    tenant_id,
    office_id,
    membership_id,
    wallet_id,
    owner_user_id,
    source_ledger_account_id,
    source_currency_code,
    source_pocket_key,
    requested_amount,
    payout_account_id,
    initiated_by_user_id
  )
  values (
    source_account.tenant_id,
    source_account.office_id,
    source_account.membership_id,
    source_account.wallet_id,
    source_account.owner_user_id,
    source_account.id,
    source_account.currency_code,
    source_account.pocket_key,
    p_requested_amount,
    payout_account.id,
    p_actor_user_id
  )
  returning * into target_withdrawal;

  insert into financial_ops.withdrawal_destination_snapshots (
    withdrawal_id,
    source_payout_account_id,
    institution_code,
    institution_name,
    account_reference,
    account_holder_name,
    payout_rail,
    payout_currency,
    country_code,
    verification_status,
    verification_method
  )
  values (
    target_withdrawal.id,
    payout_account.id,
    payout_account.institution_code,
    payout_account.institution_name,
    payout_account.account_reference,
    payout_account.account_holder_name,
    payout_account.payout_rail,
    payout_account.payout_currency,
    payout_account.country_code,
    payout_account.verification_status,
    payout_account.verification_method
  );

  insert into financial_ops.funding_reservations (
    withdrawal_id,
    ledger_account_id,
    amount
  )
  values (
    target_withdrawal.id,
    source_account.id,
    p_requested_amount
  );

  insert into financial_ops.withdrawal_command_idempotency (
    idempotency_key,
    command_type,
    request_fingerprint,
    withdrawal_id,
    actor_user_id,
    result_status
  )
  values (
    p_idempotency_key,
    'submit_withdrawal',
    request_fingerprint,
    target_withdrawal.id,
    p_actor_user_id,
    target_withdrawal.status
  );

  perform financial_ops.record_authorization_audit(
    authorization_decision,
    p_session_id,
    'withdrawal_requested',
    target_withdrawal.id,
    jsonb_build_object('withdrawal_reference', target_withdrawal.withdrawal_reference)
  );

  return (
    target_withdrawal.id,
    target_withdrawal.withdrawal_reference,
    target_withdrawal.status,
    false
  )::financial_ops.withdrawal_command_result;
end;
$$;

create or replace function financial_ops.approve_withdrawal(
  p_idempotency_key uuid,
  p_withdrawal_id uuid,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.withdrawal_command_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.withdrawal_command_idempotency%rowtype;
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
  target_reservation financial_ops.funding_reservations%rowtype;
  authorization_decision authz.authorization_decision;
  owner_status public.account_status;
  membership_status public.membership_status;
begin
  if p_idempotency_key is null or p_withdrawal_id is null or p_actor_user_id is null then
    raise exception using
      errcode = '22023',
      message = 'withdrawal approval input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'withdrawal command actor does not match the authenticated user';
  end if;

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'withdrawal_id', p_withdrawal_id
    )::text,
    'sha256'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  select *
    into existing_command
    from financial_ops.withdrawal_command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.command_type <> 'approve_withdrawal'
       or existing_command.request_fingerprint <> request_fingerprint
       or existing_command.actor_user_id <> p_actor_user_id then
      raise exception using
        errcode = '23505',
        message = 'idempotency key already used with different withdrawal command data';
    end if;

    select *
      into target_withdrawal
      from financial_ops.withdrawal_requests withdrawal
     where withdrawal.id = existing_command.withdrawal_id;

  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'approve_withdrawal',
    target_withdrawal.tenant_id,
    target_withdrawal.office_id,
    target_withdrawal.membership_id,
    target_withdrawal.owner_user_id,
    target_withdrawal.wallet_id,
    target_withdrawal.owner_user_id,
    'approve_withdrawal',
    target_withdrawal.requested_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);
    return (
      target_withdrawal.id,
      target_withdrawal.withdrawal_reference,
      existing_command.result_status,
      true
    )::financial_ops.withdrawal_command_result;
  end if;

  select *
    into target_withdrawal
    from financial_ops.withdrawal_requests withdrawal
   where withdrawal.id = p_withdrawal_id
   for update;

  if target_withdrawal.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'withdrawal request was not found';
  end if;

  if target_withdrawal.status <> 'requested' then
    raise exception using
      errcode = '55000',
      message = 'only requested withdrawals may be approved';
  end if;

  select *
    into target_reservation
    from financial_ops.funding_reservations reservation
   where reservation.withdrawal_id = target_withdrawal.id
   for update;

  if target_reservation.id is null or target_reservation.status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'withdrawal approval requires an active funding reservation';
  end if;

  select account.status
    into owner_status
    from public.user_accounts account
   where account.user_id = target_withdrawal.owner_user_id;

  select membership.status
    into membership_status
    from public.memberships membership
   where membership.id = target_withdrawal.membership_id
     and membership.tenant_id = target_withdrawal.tenant_id;

  if owner_status <> 'active' or membership_status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'withdrawal approval requires active owner and membership context';
  end if;

  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'approve_withdrawal',
    target_withdrawal.tenant_id,
    target_withdrawal.office_id,
    target_withdrawal.membership_id,
    target_withdrawal.owner_user_id,
    target_withdrawal.wallet_id,
    target_withdrawal.owner_user_id,
    'approve_withdrawal',
    target_withdrawal.requested_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);

  perform set_config(
    'financial_ops.withdrawal_transition',
    target_withdrawal.id::text,
    true
  );

  update financial_ops.withdrawal_requests
     set status = 'approved',
         version = version + 1,
         approved_by_user_id = p_actor_user_id,
         approved_at = clock_timestamp()
   where id = target_withdrawal.id
  returning * into target_withdrawal;

  perform set_config('financial_ops.withdrawal_transition', '', true);

  insert into financial_ops.withdrawal_command_idempotency (
    idempotency_key,
    command_type,
    request_fingerprint,
    withdrawal_id,
    actor_user_id,
    result_status
  )
  values (
    p_idempotency_key,
    'approve_withdrawal',
    request_fingerprint,
    target_withdrawal.id,
    p_actor_user_id,
    target_withdrawal.status
  );

  perform financial_ops.record_authorization_audit(
    authorization_decision,
    p_session_id,
    'withdrawal_approved',
    target_withdrawal.id,
    jsonb_build_object('withdrawal_reference', target_withdrawal.withdrawal_reference)
  );

  return (
    target_withdrawal.id,
    target_withdrawal.withdrawal_reference,
    target_withdrawal.status,
    false
  )::financial_ops.withdrawal_command_result;
end;
$$;

create or replace function financial_ops.reject_withdrawal(
  p_idempotency_key uuid,
  p_withdrawal_id uuid,
  p_actor_user_id uuid,
  p_reason text,
  p_session_id uuid default null
)
returns financial_ops.withdrawal_command_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.withdrawal_command_idempotency%rowtype;
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
  target_reservation financial_ops.funding_reservations%rowtype;
  authorization_decision authz.authorization_decision;
begin
  if p_idempotency_key is null
     or p_withdrawal_id is null
     or p_actor_user_id is null
     or p_reason is null
     or length(btrim(p_reason)) = 0 then
    raise exception using
      errcode = '22023',
      message = 'withdrawal rejection input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'withdrawal command actor does not match the authenticated user';
  end if;

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'reason', btrim(p_reason),
      'withdrawal_id', p_withdrawal_id
    )::text,
    'sha256'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  select *
    into existing_command
    from financial_ops.withdrawal_command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.command_type <> 'reject_withdrawal'
       or existing_command.request_fingerprint <> request_fingerprint
       or existing_command.actor_user_id <> p_actor_user_id then
      raise exception using
        errcode = '23505',
        message = 'idempotency key already used with different withdrawal command data';
    end if;

    select *
      into target_withdrawal
      from financial_ops.withdrawal_requests withdrawal
     where withdrawal.id = existing_command.withdrawal_id;

  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'approve_withdrawal',
    target_withdrawal.tenant_id,
    target_withdrawal.office_id,
    target_withdrawal.membership_id,
    target_withdrawal.owner_user_id,
    target_withdrawal.wallet_id,
    target_withdrawal.owner_user_id,
    'reject_withdrawal',
    target_withdrawal.requested_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);
    return (
      target_withdrawal.id,
      target_withdrawal.withdrawal_reference,
      existing_command.result_status,
      true
    )::financial_ops.withdrawal_command_result;
  end if;

  select *
    into target_withdrawal
    from financial_ops.withdrawal_requests withdrawal
   where withdrawal.id = p_withdrawal_id
   for update;

  if target_withdrawal.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'withdrawal request was not found';
  end if;

  if target_withdrawal.status <> 'requested' then
    raise exception using
      errcode = '55000',
      message = 'only requested withdrawals may be rejected';
  end if;

  select *
    into target_reservation
    from financial_ops.funding_reservations reservation
   where reservation.withdrawal_id = target_withdrawal.id
   for update;

  if target_reservation.id is null or target_reservation.status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'withdrawal rejection requires an active funding reservation';
  end if;

  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'approve_withdrawal',
    target_withdrawal.tenant_id,
    target_withdrawal.office_id,
    target_withdrawal.membership_id,
    target_withdrawal.owner_user_id,
    target_withdrawal.wallet_id,
    target_withdrawal.owner_user_id,
    'reject_withdrawal',
    target_withdrawal.requested_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);

  perform set_config(
    'financial_ops.withdrawal_transition',
    target_withdrawal.id::text,
    true
  );
  perform set_config(
    'financial_ops.reservation_transition',
    target_reservation.id::text,
    true
  );

  update financial_ops.withdrawal_requests
     set status = 'rejected',
         version = version + 1,
         rejected_by_user_id = p_actor_user_id,
         rejected_at = clock_timestamp(),
         rejection_reason = btrim(p_reason)
   where id = target_withdrawal.id
  returning * into target_withdrawal;

  update financial_ops.funding_reservations
     set status = 'released',
         released_at = clock_timestamp(),
         release_reason = 'withdrawal rejected: ' || btrim(p_reason)
   where id = target_reservation.id;

  perform set_config('financial_ops.withdrawal_transition', '', true);
  perform set_config('financial_ops.reservation_transition', '', true);

  insert into financial_ops.withdrawal_command_idempotency (
    idempotency_key,
    command_type,
    request_fingerprint,
    withdrawal_id,
    actor_user_id,
    result_status
  )
  values (
    p_idempotency_key,
    'reject_withdrawal',
    request_fingerprint,
    target_withdrawal.id,
    p_actor_user_id,
    target_withdrawal.status
  );

  perform financial_ops.record_authorization_audit(
    authorization_decision,
    p_session_id,
    'withdrawal_rejected',
    target_withdrawal.id,
    jsonb_build_object('withdrawal_reference', target_withdrawal.withdrawal_reference)
  );

  return (
    target_withdrawal.id,
    target_withdrawal.withdrawal_reference,
    target_withdrawal.status,
    false
  )::financial_ops.withdrawal_command_result;
end;
$$;

create or replace function financial_ops.cancel_withdrawal(
  p_idempotency_key uuid,
  p_withdrawal_id uuid,
  p_actor_user_id uuid,
  p_reason text,
  p_session_id uuid default null
)
returns financial_ops.withdrawal_command_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.withdrawal_command_idempotency%rowtype;
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
  target_reservation financial_ops.funding_reservations%rowtype;
  authorization_decision authz.authorization_decision;
  target_permission text;
begin
  if p_idempotency_key is null
     or p_withdrawal_id is null
     or p_actor_user_id is null
     or p_reason is null
     or length(btrim(p_reason)) = 0 then
    raise exception using
      errcode = '22023',
      message = 'withdrawal cancellation input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'withdrawal command actor does not match the authenticated user';
  end if;

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'reason', btrim(p_reason),
      'withdrawal_id', p_withdrawal_id
    )::text,
    'sha256'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  select *
    into existing_command
    from financial_ops.withdrawal_command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.command_type <> 'cancel_withdrawal'
       or existing_command.request_fingerprint <> request_fingerprint
       or existing_command.actor_user_id <> p_actor_user_id then
      raise exception using
        errcode = '23505',
        message = 'idempotency key already used with different withdrawal command data';
    end if;

    select *
      into target_withdrawal
      from financial_ops.withdrawal_requests withdrawal
     where withdrawal.id = existing_command.withdrawal_id;

  if target_withdrawal.approved_at is null then
    if p_actor_user_id <> target_withdrawal.owner_user_id then
      raise exception using errcode = '42501', message = 'requested withdrawal may only be cancelled by its Wallet owner';
    end if;
    target_permission := 'initiate_own_withdrawal';
  else
    target_permission := 'approve_withdrawal';
  end if;
  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    target_permission,
    target_withdrawal.tenant_id,
    target_withdrawal.office_id,
    target_withdrawal.membership_id,
    target_withdrawal.owner_user_id,
    target_withdrawal.wallet_id,
    target_withdrawal.owner_user_id,
    'cancel_withdrawal',
    target_withdrawal.requested_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);
    return (
      target_withdrawal.id,
      target_withdrawal.withdrawal_reference,
      existing_command.result_status,
      true
    )::financial_ops.withdrawal_command_result;
  end if;

  select *
    into target_withdrawal
    from financial_ops.withdrawal_requests withdrawal
   where withdrawal.id = p_withdrawal_id
   for update;

  if target_withdrawal.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'withdrawal request was not found';
  end if;

  if target_withdrawal.status not in ('requested', 'approved') then
    raise exception using
      errcode = '55000',
      message = 'only requested or approved withdrawals may be cancelled';
  end if;

  select *
    into target_reservation
    from financial_ops.funding_reservations reservation
   where reservation.withdrawal_id = target_withdrawal.id
   for update;

  if target_reservation.id is null or target_reservation.status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'withdrawal cancellation requires an active funding reservation';
  end if;

  if target_withdrawal.status = 'requested' then
    if p_actor_user_id <> target_withdrawal.owner_user_id then
      raise exception using
        errcode = '42501',
        message = 'requested withdrawal may only be cancelled by its Wallet owner';
    end if;
    target_permission := 'initiate_own_withdrawal';
  else
    target_permission := 'approve_withdrawal';
  end if;

  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    target_permission,
    target_withdrawal.tenant_id,
    target_withdrawal.office_id,
    target_withdrawal.membership_id,
    target_withdrawal.owner_user_id,
    target_withdrawal.wallet_id,
    target_withdrawal.owner_user_id,
    'cancel_withdrawal',
    target_withdrawal.requested_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);

  perform set_config(
    'financial_ops.withdrawal_transition',
    target_withdrawal.id::text,
    true
  );
  perform set_config(
    'financial_ops.reservation_transition',
    target_reservation.id::text,
    true
  );

  update financial_ops.withdrawal_requests
     set status = 'cancelled',
         version = version + 1,
         cancelled_by_user_id = p_actor_user_id,
         cancelled_at = clock_timestamp(),
         cancellation_reason = btrim(p_reason)
   where id = target_withdrawal.id
  returning * into target_withdrawal;

  update financial_ops.funding_reservations
     set status = 'released',
         released_at = clock_timestamp(),
         release_reason = 'withdrawal cancelled: ' || btrim(p_reason)
   where id = target_reservation.id;

  perform set_config('financial_ops.withdrawal_transition', '', true);
  perform set_config('financial_ops.reservation_transition', '', true);

  insert into financial_ops.withdrawal_command_idempotency (
    idempotency_key,
    command_type,
    request_fingerprint,
    withdrawal_id,
    actor_user_id,
    result_status
  )
  values (
    p_idempotency_key,
    'cancel_withdrawal',
    request_fingerprint,
    target_withdrawal.id,
    p_actor_user_id,
    target_withdrawal.status
  );

  perform financial_ops.record_authorization_audit(
    authorization_decision,
    p_session_id,
    'withdrawal_cancelled',
    target_withdrawal.id,
    jsonb_build_object('withdrawal_reference', target_withdrawal.withdrawal_reference)
  );

  return (
    target_withdrawal.id,
    target_withdrawal.withdrawal_reference,
    target_withdrawal.status,
    false
  )::financial_ops.withdrawal_command_result;
end;
$$;

create or replace function financial_ops.submit_payout_assertion(
  p_idempotency_key uuid,
  p_withdrawal_id uuid,
  p_wallet_debit_amount numeric,
  p_beneficiary_payout_amount numeric,
  p_payout_currency text,
  p_provider text,
  p_paid_at timestamptz,
  p_evidence_items jsonb,
  p_actor_user_id uuid,
  p_provider_fee_amount numeric default 0,
  p_provider_reference text default null,
  p_notes text default null,
  p_session_id uuid default null
)
returns financial_ops.payout_assertion_command_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.payout_command_idempotency%rowtype;
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
  target_reservation financial_ops.funding_reservations%rowtype;
  target_assertion financial_ops.payout_completion_assertions%rowtype;
  target_revision financial_ops.payout_assertion_revisions%rowtype;
  authorization_decision authz.authorization_decision;
  next_assertion_number smallint;
begin
  if p_idempotency_key is null
     or p_withdrawal_id is null
     or p_actor_user_id is null
     or p_provider is null
     or length(btrim(p_provider)) = 0 then
    raise exception using
      errcode = '22023',
      message = 'payout assertion input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'payout assertion actor does not match the authenticated user';
  end if;

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'beneficiary_payout_amount', p_beneficiary_payout_amount,
      'evidence_items', p_evidence_items,
      'notes', nullif(btrim(p_notes), ''),
      'paid_at', p_paid_at,
      'payout_currency', p_payout_currency,
      'provider', btrim(p_provider),
      'provider_fee_amount', p_provider_fee_amount,
      'provider_reference', nullif(btrim(p_provider_reference), ''),
      'wallet_debit_amount', p_wallet_debit_amount,
      'withdrawal_id', p_withdrawal_id
    )::text,
    'sha256'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  select *
    into existing_command
    from financial_ops.payout_command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.command_type <> 'submit_payout_assertion'
       or existing_command.request_fingerprint <> request_fingerprint
       or existing_command.actor_user_id <> p_actor_user_id then
      raise exception using
        errcode = '23505',
        message = 'idempotency key already used with different payout command data';
    end if;

  select withdrawal.* into target_withdrawal from financial_ops.withdrawal_requests withdrawal where withdrawal.id = p_withdrawal_id;
  if target_withdrawal.approved_by_user_id <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'only the withdrawal approver may record payout completion';
  end if;
  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'approve_withdrawal',
    target_withdrawal.tenant_id,
    target_withdrawal.office_id,
    target_withdrawal.membership_id,
    target_withdrawal.owner_user_id,
    target_withdrawal.wallet_id,
    target_withdrawal.owner_user_id,
    'record_payout_completion',
    p_wallet_debit_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);
    return (
      existing_command.payout_assertion_id,
      existing_command.result_assertion_status,
      p_withdrawal_id,
      existing_command.result_withdrawal_status,
      true
    )::financial_ops.payout_assertion_command_result;
  end if;

  select *
    into target_withdrawal
    from financial_ops.withdrawal_requests withdrawal
   where withdrawal.id = p_withdrawal_id
   for update;

  if target_withdrawal.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'withdrawal request was not found';
  end if;

  if target_withdrawal.status <> 'approved'
     or target_withdrawal.approved_by_user_id <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'payout assertion must be submitted by the withdrawal approving actor';
  end if;

  select *
    into target_reservation
    from financial_ops.funding_reservations reservation
   where reservation.withdrawal_id = target_withdrawal.id
   for update;

  if target_reservation.id is null or target_reservation.status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'payout assertion requires an active funding reservation';
  end if;

  if exists (
    select 1
      from financial_ops.payout_completion_assertions assertion
     where assertion.withdrawal_id = target_withdrawal.id
       and assertion.status in ('submitted', 'correction_required', 'needs_review')
  ) then
    raise exception using
      errcode = '55000',
      message = 'withdrawal already has an unresolved payout assertion';
  end if;

  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'approve_withdrawal',
    target_withdrawal.tenant_id,
    target_withdrawal.office_id,
    target_withdrawal.membership_id,
    target_withdrawal.owner_user_id,
    target_withdrawal.wallet_id,
    target_withdrawal.owner_user_id,
    'record_payout_completion',
    p_wallet_debit_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);

  perform financial_ops.validate_direct_payout_facts(
    target_withdrawal.id,
    p_wallet_debit_amount,
    p_beneficiary_payout_amount,
    p_payout_currency,
    p_provider_fee_amount,
    p_paid_at
  );

  select (coalesce(max(assertion.assertion_number), 0) + 1)::smallint
    into next_assertion_number
    from financial_ops.payout_completion_assertions assertion
   where assertion.withdrawal_id = target_withdrawal.id;

  insert into financial_ops.payout_completion_assertions (
    withdrawal_id,
    assertion_number,
    submitted_by_user_id
  )
  values (
    target_withdrawal.id,
    next_assertion_number,
    p_actor_user_id
  )
  returning * into target_assertion;

  insert into financial_ops.payout_assertion_revisions (
    payout_assertion_id,
    revision_number,
    wallet_debit_amount,
    beneficiary_payout_amount,
    payout_currency,
    provider_fee_amount,
    provider_fee_currency,
    provider,
    provider_reference,
    paid_at,
    notes,
    submitted_by_user_id
  )
  values (
    target_assertion.id,
    1,
    p_wallet_debit_amount,
    p_beneficiary_payout_amount,
    p_payout_currency,
    p_provider_fee_amount,
    case when p_provider_fee_amount > 0 then p_payout_currency end,
    btrim(p_provider),
    nullif(btrim(p_provider_reference), ''),
    p_paid_at,
    nullif(btrim(p_notes), ''),
    p_actor_user_id
  )
  returning * into target_revision;

  perform evidence.attach_payout_evidence(
    target_withdrawal.tenant_id,
    target_revision.id,
    p_actor_user_id,
    p_evidence_items
  );

  insert into financial_ops.payout_command_idempotency (
    idempotency_key,
    command_type,
    request_fingerprint,
    payout_assertion_id,
    actor_user_id,
    result_assertion_status,
    result_withdrawal_status
  )
  values (
    p_idempotency_key,
    'submit_payout_assertion',
    request_fingerprint,
    target_assertion.id,
    p_actor_user_id,
    target_assertion.status,
    target_withdrawal.status
  );

  perform financial_ops.record_authorization_audit(
    authorization_decision,
    p_session_id,
    'payout_assertion_submitted',
    target_withdrawal.id,
    jsonb_build_object(
      'payout_assertion_id', target_assertion.id,
      'revision_number', 1
    )
  );

  return (
    target_assertion.id,
    target_assertion.status,
    target_withdrawal.id,
    target_withdrawal.status,
    false
  )::financial_ops.payout_assertion_command_result;
end;
$$;

create or replace function financial_ops.correct_payout_assertion(
  p_idempotency_key uuid,
  p_payout_assertion_id uuid,
  p_wallet_debit_amount numeric,
  p_beneficiary_payout_amount numeric,
  p_payout_currency text,
  p_provider text,
  p_paid_at timestamptz,
  p_evidence_items jsonb,
  p_actor_user_id uuid,
  p_provider_fee_amount numeric default 0,
  p_provider_reference text default null,
  p_notes text default null,
  p_session_id uuid default null
)
returns financial_ops.payout_assertion_command_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.payout_command_idempotency%rowtype;
  target_assertion financial_ops.payout_completion_assertions%rowtype;
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
  target_revision financial_ops.payout_assertion_revisions%rowtype;
  authorization_decision authz.authorization_decision;
begin
  if p_idempotency_key is null
     or p_payout_assertion_id is null
     or p_actor_user_id is null
     or p_provider is null
     or length(btrim(p_provider)) = 0 then
    raise exception using
      errcode = '22023',
      message = 'payout assertion correction input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'payout assertion actor does not match the authenticated user';
  end if;

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'beneficiary_payout_amount', p_beneficiary_payout_amount,
      'evidence_items', p_evidence_items,
      'notes', nullif(btrim(p_notes), ''),
      'paid_at', p_paid_at,
      'payout_assertion_id', p_payout_assertion_id,
      'payout_currency', p_payout_currency,
      'provider', btrim(p_provider),
      'provider_fee_amount', p_provider_fee_amount,
      'provider_reference', nullif(btrim(p_provider_reference), ''),
      'wallet_debit_amount', p_wallet_debit_amount
    )::text,
    'sha256'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  select *
    into existing_command
    from financial_ops.payout_command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.command_type <> 'correct_payout_assertion'
       or existing_command.request_fingerprint <> request_fingerprint
       or existing_command.actor_user_id <> p_actor_user_id then
      raise exception using
        errcode = '23505',
        message = 'idempotency key already used with different payout command data';
    end if;

    select *
      into target_assertion
      from financial_ops.payout_completion_assertions assertion
     where assertion.id = existing_command.payout_assertion_id;

    select *
      into target_withdrawal
      from financial_ops.withdrawal_requests withdrawal
     where withdrawal.id = target_assertion.withdrawal_id;

  if target_withdrawal.approved_by_user_id <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'only the withdrawal approver may record payout completion';
  end if;
  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'approve_withdrawal',
    target_withdrawal.tenant_id,
    target_withdrawal.office_id,
    target_withdrawal.membership_id,
    target_withdrawal.owner_user_id,
    target_withdrawal.wallet_id,
    target_withdrawal.owner_user_id,
    'correct_payout_completion',
    p_wallet_debit_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);
    return (
      existing_command.payout_assertion_id,
      existing_command.result_assertion_status,
      target_withdrawal.id,
      existing_command.result_withdrawal_status,
      true
    )::financial_ops.payout_assertion_command_result;
  end if;

  select *
    into target_assertion
    from financial_ops.payout_completion_assertions assertion
   where assertion.id = p_payout_assertion_id
   for update;

  if target_assertion.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'payout completion assertion was not found';
  end if;

  select *
    into target_withdrawal
    from financial_ops.withdrawal_requests withdrawal
   where withdrawal.id = target_assertion.withdrawal_id
   for update;

  if target_assertion.status <> 'correction_required'
     or target_assertion.current_revision_number <> 1
     or target_assertion.submitted_by_user_id <> p_actor_user_id
     or target_withdrawal.status <> 'approved'
     or target_withdrawal.approved_by_user_id <> p_actor_user_id then
    raise exception using
      errcode = '55000',
      message = 'payout assertion does not allow another correction';
  end if;

  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'approve_withdrawal',
    target_withdrawal.tenant_id,
    target_withdrawal.office_id,
    target_withdrawal.membership_id,
    target_withdrawal.owner_user_id,
    target_withdrawal.wallet_id,
    target_withdrawal.owner_user_id,
    'correct_payout_completion',
    p_wallet_debit_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);

  perform financial_ops.validate_direct_payout_facts(
    target_withdrawal.id,
    p_wallet_debit_amount,
    p_beneficiary_payout_amount,
    p_payout_currency,
    p_provider_fee_amount,
    p_paid_at
  );

  insert into financial_ops.payout_assertion_revisions (
    payout_assertion_id,
    revision_number,
    wallet_debit_amount,
    beneficiary_payout_amount,
    payout_currency,
    provider_fee_amount,
    provider_fee_currency,
    provider,
    provider_reference,
    paid_at,
    notes,
    submitted_by_user_id
  )
  values (
    target_assertion.id,
    2,
    p_wallet_debit_amount,
    p_beneficiary_payout_amount,
    p_payout_currency,
    p_provider_fee_amount,
    case when p_provider_fee_amount > 0 then p_payout_currency end,
    btrim(p_provider),
    nullif(btrim(p_provider_reference), ''),
    p_paid_at,
    nullif(btrim(p_notes), ''),
    p_actor_user_id
  )
  returning * into target_revision;

  perform evidence.attach_payout_evidence(
    target_withdrawal.tenant_id,
    target_revision.id,
    p_actor_user_id,
    p_evidence_items
  );

  perform set_config(
    'financial_ops.payout_assertion_transition',
    target_assertion.id::text,
    true
  );

  update financial_ops.payout_completion_assertions
     set status = 'submitted',
         current_revision_number = 2,
         version = version + 1
   where id = target_assertion.id
  returning * into target_assertion;

  perform set_config('financial_ops.payout_assertion_transition', '', true);

  insert into financial_ops.payout_command_idempotency (
    idempotency_key,
    command_type,
    request_fingerprint,
    payout_assertion_id,
    actor_user_id,
    result_assertion_status,
    result_withdrawal_status
  )
  values (
    p_idempotency_key,
    'correct_payout_assertion',
    request_fingerprint,
    target_assertion.id,
    p_actor_user_id,
    target_assertion.status,
    target_withdrawal.status
  );

  perform financial_ops.record_authorization_audit(
    authorization_decision,
    p_session_id,
    'payout_assertion_corrected',
    target_withdrawal.id,
    jsonb_build_object(
      'payout_assertion_id', target_assertion.id,
      'revision_number', 2
    )
  );

  return (
    target_assertion.id,
    target_assertion.status,
    target_withdrawal.id,
    target_withdrawal.status,
    false
  )::financial_ops.payout_assertion_command_result;
end;
$$;

create or replace function financial_ops.review_payout_assertion(
  p_idempotency_key uuid,
  p_payout_assertion_id uuid,
  p_decision evidence.review_decision,
  p_review_note text,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.payout_assertion_command_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.payout_command_idempotency%rowtype;
  target_assertion financial_ops.payout_completion_assertions%rowtype;
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
  authorization_decision authz.authorization_decision;
  reviewer_assignment_id uuid;
begin
  if p_idempotency_key is null
     or p_payout_assertion_id is null
     or p_decision is null
     or p_review_note is null
     or length(btrim(p_review_note)) = 0
     or p_actor_user_id is null then
    raise exception using
      errcode = '22023',
      message = 'financial evidence review input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'financial evidence reviewer does not match the authenticated user';
  end if;

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'decision', p_decision,
      'payout_assertion_id', p_payout_assertion_id,
      'review_note', btrim(p_review_note)
    )::text,
    'sha256'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  select *
    into existing_command
    from financial_ops.payout_command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.command_type <> 'review_payout_assertion'
       or existing_command.request_fingerprint <> request_fingerprint
       or existing_command.actor_user_id <> p_actor_user_id then
      raise exception using
        errcode = '23505',
        message = 'idempotency key already used with different payout command data';
    end if;

    select *
      into target_assertion
      from financial_ops.payout_completion_assertions assertion
     where assertion.id = existing_command.payout_assertion_id;

    select *
      into target_withdrawal
      from financial_ops.withdrawal_requests withdrawal
     where withdrawal.id = target_assertion.withdrawal_id;

  if target_assertion.submitted_by_user_id = p_actor_user_id then
    raise exception using errcode = '42501', message = 'financial evidence reviewer cannot review their own payout operation';
  end if;
  authorization_decision := authz.authorize_financial_evidence_review(
    p_actor_user_id,
    p_session_id,
    target_withdrawal.tenant_id,
    target_withdrawal.office_id,
    target_withdrawal.membership_id,
    target_withdrawal.owner_user_id,
    target_withdrawal.wallet_id,
    'review_payout_assertion'
  );

  perform financial_ops.enforce_authorization(authorization_decision);
    return (
      existing_command.payout_assertion_id,
      existing_command.result_assertion_status,
      target_withdrawal.id,
      existing_command.result_withdrawal_status,
      true
    )::financial_ops.payout_assertion_command_result;
  end if;

  select *
    into target_assertion
    from financial_ops.payout_completion_assertions assertion
   where assertion.id = p_payout_assertion_id
   for update;

  if target_assertion.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'payout completion assertion was not found';
  end if;

  select *
    into target_withdrawal
    from financial_ops.withdrawal_requests withdrawal
   where withdrawal.id = target_assertion.withdrawal_id
   for update;

  if target_assertion.status <> 'needs_review' then
    raise exception using
      errcode = '55000',
      message = 'payout assertion is not awaiting financial evidence review';
  end if;

  if target_assertion.submitted_by_user_id = p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'financial evidence reviewer cannot review their own payout operation';
  end if;

  authorization_decision := authz.authorize_financial_evidence_review(
    p_actor_user_id,
    p_session_id,
    target_withdrawal.tenant_id,
    target_withdrawal.office_id,
    target_withdrawal.membership_id,
    target_withdrawal.owner_user_id,
    target_withdrawal.wallet_id,
    'review_payout_assertion'
  );

  perform financial_ops.enforce_authorization(authorization_decision);
  reviewer_assignment_id := authorization_decision.source_id;

  insert into evidence.review_decisions (
    payout_assertion_id,
    reviewer_assignment_id,
    reviewer_user_id,
    decision,
    review_note
  )
  values (
    target_assertion.id,
    reviewer_assignment_id,
    p_actor_user_id,
    p_decision,
    btrim(p_review_note)
  );

  if p_decision = 'clear' then
    perform financial_ops.complete_withdrawal_from_assertion(
      target_assertion.id,
      'manual_clear',
      p_actor_user_id
    );
  else
    perform set_config(
      'financial_ops.payout_assertion_transition',
      target_assertion.id::text,
      true
    );

    update financial_ops.payout_completion_assertions
       set status = 'rejected',
           version = version + 1
     where id = target_assertion.id;

    perform set_config('financial_ops.payout_assertion_transition', '', true);
  end if;

  select *
    into target_assertion
    from financial_ops.payout_completion_assertions assertion
   where assertion.id = p_payout_assertion_id;

  select *
    into target_withdrawal
    from financial_ops.withdrawal_requests withdrawal
   where withdrawal.id = target_assertion.withdrawal_id;

  insert into financial_ops.payout_command_idempotency (
    idempotency_key,
    command_type,
    request_fingerprint,
    payout_assertion_id,
    actor_user_id,
    result_assertion_status,
    result_withdrawal_status
  )
  values (
    p_idempotency_key,
    'review_payout_assertion',
    request_fingerprint,
    target_assertion.id,
    p_actor_user_id,
    target_assertion.status,
    target_withdrawal.status
  );

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
    target_withdrawal.tenant_id,
    case
      when p_decision = 'clear' then 'payout_evidence_cleared'
      else 'payout_evidence_rejected'
    end,
    authorization_decision.permission_key,
    'payout_assertion',
    target_assertion.id,
    true,
    authorization_decision.source,
    authorization_decision.source_id,
    authorization_decision.reason_code,
    jsonb_build_object(
      'decision', p_decision,
      'withdrawal_id', target_withdrawal.id
    )
  );

  insert into internal.outbox_events (
    tenant_id,
    aggregate_type,
    aggregate_id,
    event_type,
    payload
  )
  values (
    target_withdrawal.tenant_id,
    'payout_assertion',
    target_assertion.id,
    case
      when p_decision = 'clear' then 'payout_evidence_cleared'
      else 'payout_evidence_rejected'
    end,
    jsonb_build_object(
      'payout_assertion_id', target_assertion.id,
      'withdrawal_id', target_withdrawal.id,
      'status', target_assertion.status
    )
  );

  return (
    target_assertion.id,
    target_assertion.status,
    target_withdrawal.id,
    target_withdrawal.status,
    false
  )::financial_ops.payout_assertion_command_result;
end;
$$;

create or replace function financial_ops.replace_payout_account(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_existing_payout_account_id uuid,
  p_country_code text,
  p_payout_currency text,
  p_payout_rail text,
  p_institution_code text,
  p_institution_name text,
  p_account_reference text,
  p_account_holder_name text,
  p_make_primary boolean default false
)
returns financial_ops.payout_account_command_result
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.payout_account_command_idempotency%rowtype;
  old_account financial_ops.payout_accounts%rowtype;
  new_account_id uuid;
  membership_id uuid;
  decision authz.authorization_decision;
  should_be_primary boolean;
begin
  if p_idempotency_key is null or p_actor_user_id is null or p_session_id is null
     or p_tenant_id is null or p_existing_payout_account_id is null
     or p_country_code !~ '^[A-Z]{2}$'
     or p_payout_currency is null or p_payout_rail !~ '^[a-z][a-z0-9_]*$'
     or length(btrim(p_institution_code)) = 0
     or length(btrim(p_institution_name)) = 0
     or length(btrim(p_account_reference)) = 0
     or length(btrim(p_account_holder_name)) = 0 then
    raise exception using errcode = '22023', message = 'payout-account replacement input is invalid';
  end if;
  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'payout-account actor mismatch';
  end if;

  request_fingerprint := financial_ops.payout_account_request_fingerprint(
    'replace_payout_account', pg_catalog.jsonb_build_object(
      'actor_user_id', p_actor_user_id, 'tenant_id', p_tenant_id,
      'existing_payout_account_id', p_existing_payout_account_id,
      'country_code', p_country_code, 'payout_currency', p_payout_currency,
      'payout_rail', p_payout_rail, 'institution_code', btrim(p_institution_code),
      'institution_name', btrim(p_institution_name), 'account_reference', btrim(p_account_reference),
      'account_holder_name', btrim(p_account_holder_name), 'make_primary', p_make_primary
    )
  );
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('payout-account:' || p_existing_payout_account_id::text, 0));

  select command.* into existing_command
    from financial_ops.payout_account_command_idempotency command
   where command.idempotency_key = p_idempotency_key;
  if found then
    if existing_command.command_type <> 'replace_payout_account'
       or existing_command.actor_user_id <> p_actor_user_id
       or existing_command.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '23505', message = 'idempotency key already used with different payout-account data';
    end if;
  select account.* into old_account from financial_ops.payout_accounts account where account.id = p_existing_payout_account_id;
  if old_account.id is null or old_account.owner_user_id <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'payout account ownership required';
  end if;
  select membership.id into membership_id
    from public.memberships membership
   where membership.tenant_id = p_tenant_id
     and membership.user_id = p_actor_user_id
     and membership.status = 'active'
     and membership.role_key <> 'president_team_member'
   order by membership.is_primary desc, membership.id
   limit 1;
  if membership_id is null then
    raise exception using errcode = '42501', message = 'Wallet owner has no active membership in the target tenant';
  end if;

  decision := authz.authorize(
    p_actor_user_id, p_session_id, 'manage_own_payout_accounts', p_tenant_id,
    null, membership_id, p_actor_user_id, old_account.wallet_id, p_actor_user_id,
    'manage_own_payout_accounts', null
  );
  perform financial_ops.enforce_authorization(decision);
    return (existing_command.payout_account_id, existing_command.result_status, true)::financial_ops.payout_account_command_result;
  end if;

  select account.* into old_account
    from financial_ops.payout_accounts account
   where account.id = p_existing_payout_account_id
   for update;
  if old_account.id is null or old_account.owner_user_id <> p_actor_user_id or old_account.status <> 'active' then
    raise exception using errcode = 'P0002', message = 'active payout account was not found for the actor';
  end if;

  select membership.id into membership_id
    from public.memberships membership
   where membership.tenant_id = p_tenant_id
     and membership.user_id = p_actor_user_id
     and membership.status = 'active'
     and membership.role_key <> 'president_team_member'
   order by membership.is_primary desc, membership.id
   limit 1;
  if membership_id is null then
    raise exception using errcode = '42501', message = 'Wallet owner has no active membership in the target tenant';
  end if;

  decision := authz.authorize(
    p_actor_user_id, p_session_id, 'manage_own_payout_accounts', p_tenant_id,
    null, membership_id, p_actor_user_id, old_account.wallet_id, p_actor_user_id,
    'manage_own_payout_accounts', null
  );
  perform financial_ops.enforce_authorization(decision);

  should_be_primary := p_make_primary or old_account.is_primary;
  insert into financial_ops.payout_accounts (
    wallet_id, owner_user_id, country_code, payout_currency, payout_rail,
    institution_code, institution_name, account_reference, account_holder_name,
    verification_status, is_primary
  ) values (
    old_account.wallet_id, p_actor_user_id, p_country_code, p_payout_currency, p_payout_rail,
    btrim(p_institution_code), btrim(p_institution_name), btrim(p_account_reference),
    btrim(p_account_holder_name), 'pending', false
  ) returning id into new_account_id;

  perform pg_catalog.set_config('financial_ops.payout_account_transition', old_account.id::text, true);
  update financial_ops.payout_accounts
     set status = 'replaced', is_primary = false,
         replaced_by_account_id = new_account_id,
         deactivated_at = clock_timestamp()
   where id = old_account.id;

  if should_be_primary then
    perform financial_ops.clear_primary_payout_accounts(old_account.wallet_id, p_payout_currency, p_payout_rail);
    perform pg_catalog.set_config('financial_ops.payout_account_transition', new_account_id::text, true);
    update financial_ops.payout_accounts set is_primary = true where id = new_account_id;
  end if;

  insert into financial_ops.payout_account_command_idempotency (
    idempotency_key, command_type, request_fingerprint, payout_account_id,
    actor_user_id, tenant_id, result_status
  ) values (
    p_idempotency_key, 'replace_payout_account', request_fingerprint, new_account_id,
    p_actor_user_id, p_tenant_id, 'active'
  );
  perform financial_ops.record_payout_account_change(
    decision, p_session_id, p_tenant_id, new_account_id, 'payout_account_replaced',
    pg_catalog.jsonb_build_object(
      'replaced_account_id', old_account.id,
      'payout_currency', p_payout_currency,
      'payout_rail', p_payout_rail,
      'is_primary', should_be_primary,
      'verification_status', 'pending'
    )
  );
  return (new_account_id, 'active'::financial_ops.payout_account_status, false)::financial_ops.payout_account_command_result;
end;
$$;

create or replace function financial_ops.deactivate_payout_account(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_payout_account_id uuid
)
returns financial_ops.payout_account_command_result
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.payout_account_command_idempotency%rowtype;
  account_record financial_ops.payout_accounts%rowtype;
  membership_id uuid;
  decision authz.authorization_decision;
begin
  request_fingerprint := financial_ops.payout_account_request_fingerprint(
    'deactivate_payout_account', pg_catalog.jsonb_build_object(
      'actor_user_id', p_actor_user_id, 'tenant_id', p_tenant_id,
      'payout_account_id', p_payout_account_id
    )
  );
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('payout-account:' || p_payout_account_id::text, 0));
  select command.* into existing_command from financial_ops.payout_account_command_idempotency command where command.idempotency_key = p_idempotency_key;
  if found then
    if existing_command.command_type <> 'deactivate_payout_account' or existing_command.actor_user_id <> p_actor_user_id or existing_command.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '23505', message = 'idempotency key already used with different payout-account data';
    end if;
  select account.* into account_record from financial_ops.payout_accounts account where account.id = p_payout_account_id;
  if account_record.id is null or account_record.owner_user_id <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'payout account ownership required';
  end if;
  select membership.id into membership_id from public.memberships membership where membership.tenant_id = p_tenant_id and membership.user_id = p_actor_user_id and membership.status = 'active' and membership.role_key <> 'president_team_member' order by membership.is_primary desc, membership.id limit 1;
  if membership_id is null then raise exception using errcode = '42501', message = 'Wallet owner has no active membership in the target tenant'; end if;
  decision := authz.authorize(p_actor_user_id, p_session_id, 'manage_own_payout_accounts', p_tenant_id, null, membership_id, p_actor_user_id, account_record.wallet_id, p_actor_user_id, 'manage_own_payout_accounts', null);
  perform financial_ops.enforce_authorization(decision);
    return (existing_command.payout_account_id, existing_command.result_status, true)::financial_ops.payout_account_command_result;
  end if;
  select account.* into account_record from financial_ops.payout_accounts account where account.id = p_payout_account_id for update;
  if account_record.id is null or account_record.owner_user_id <> p_actor_user_id or account_record.status <> 'active' then
    raise exception using errcode = 'P0002', message = 'active payout account was not found for the actor';
  end if;
  select membership.id into membership_id from public.memberships membership where membership.tenant_id = p_tenant_id and membership.user_id = p_actor_user_id and membership.status = 'active' and membership.role_key <> 'president_team_member' order by membership.is_primary desc, membership.id limit 1;
  if membership_id is null then raise exception using errcode = '42501', message = 'Wallet owner has no active membership in the target tenant'; end if;
  decision := authz.authorize(p_actor_user_id, p_session_id, 'manage_own_payout_accounts', p_tenant_id, null, membership_id, p_actor_user_id, account_record.wallet_id, p_actor_user_id, 'manage_own_payout_accounts', null);
  perform financial_ops.enforce_authorization(decision);
  perform pg_catalog.set_config('financial_ops.payout_account_transition', account_record.id::text, true);
  update financial_ops.payout_accounts set status = 'deactivated', is_primary = false, deactivated_at = clock_timestamp() where id = account_record.id;
  insert into financial_ops.payout_account_command_idempotency values (p_idempotency_key, 'deactivate_payout_account', request_fingerprint, account_record.id, p_actor_user_id, p_tenant_id, 'deactivated');
  perform financial_ops.record_payout_account_change(decision, p_session_id, p_tenant_id, account_record.id, 'payout_account_deactivated', pg_catalog.jsonb_build_object('payout_currency', account_record.payout_currency, 'payout_rail', account_record.payout_rail));
  return (account_record.id, 'deactivated'::financial_ops.payout_account_status, false)::financial_ops.payout_account_command_result;
end;
$$;

create or replace function financial_ops.set_primary_payout_account(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_payout_account_id uuid
)
returns financial_ops.payout_account_command_result
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.payout_account_command_idempotency%rowtype;
  account_record financial_ops.payout_accounts%rowtype;
  membership_id uuid;
  decision authz.authorization_decision;
begin
  request_fingerprint := financial_ops.payout_account_request_fingerprint('set_primary_payout_account', pg_catalog.jsonb_build_object('actor_user_id', p_actor_user_id, 'tenant_id', p_tenant_id, 'payout_account_id', p_payout_account_id));
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('payout-account:' || p_payout_account_id::text, 0));
  select command.* into existing_command from financial_ops.payout_account_command_idempotency command where command.idempotency_key = p_idempotency_key;
  if found then
    if existing_command.command_type <> 'set_primary_payout_account' or existing_command.actor_user_id <> p_actor_user_id or existing_command.request_fingerprint <> request_fingerprint then raise exception using errcode = '23505', message = 'idempotency key already used with different payout-account data'; end if;
  select account.* into account_record from financial_ops.payout_accounts account where account.id = p_payout_account_id;
  if account_record.id is null or account_record.owner_user_id <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'payout account ownership required';
  end if;
  select membership.id into membership_id from public.memberships membership where membership.tenant_id = p_tenant_id and membership.user_id = p_actor_user_id and membership.status = 'active' and membership.role_key <> 'president_team_member' order by membership.is_primary desc, membership.id limit 1;
  if membership_id is null then raise exception using errcode = '42501', message = 'Wallet owner has no active membership in the target tenant'; end if;
  decision := authz.authorize(p_actor_user_id, p_session_id, 'manage_own_payout_accounts', p_tenant_id, null, membership_id, p_actor_user_id, account_record.wallet_id, p_actor_user_id, 'manage_own_payout_accounts', null);
  perform financial_ops.enforce_authorization(decision);
    return (existing_command.payout_account_id, existing_command.result_status, true)::financial_ops.payout_account_command_result;
  end if;
  select account.* into account_record from financial_ops.payout_accounts account where account.id = p_payout_account_id for update;
  if account_record.id is null or account_record.owner_user_id <> p_actor_user_id or account_record.status <> 'active' or account_record.verification_status <> 'verified' then raise exception using errcode = '23514', message = 'only an active verified payout account may become primary'; end if;
  select membership.id into membership_id from public.memberships membership where membership.tenant_id = p_tenant_id and membership.user_id = p_actor_user_id and membership.status = 'active' and membership.role_key <> 'president_team_member' order by membership.is_primary desc, membership.id limit 1;
  if membership_id is null then raise exception using errcode = '42501', message = 'Wallet owner has no active membership in the target tenant'; end if;
  decision := authz.authorize(p_actor_user_id, p_session_id, 'manage_own_payout_accounts', p_tenant_id, null, membership_id, p_actor_user_id, account_record.wallet_id, p_actor_user_id, 'manage_own_payout_accounts', null);
  perform financial_ops.enforce_authorization(decision);
  perform financial_ops.clear_primary_payout_accounts(account_record.wallet_id, account_record.payout_currency, account_record.payout_rail);
  perform pg_catalog.set_config('financial_ops.payout_account_transition', account_record.id::text, true);
  update financial_ops.payout_accounts set is_primary = true where id = account_record.id;
  insert into financial_ops.payout_account_command_idempotency values (p_idempotency_key, 'set_primary_payout_account', request_fingerprint, account_record.id, p_actor_user_id, p_tenant_id, account_record.status);
  perform financial_ops.record_payout_account_change(decision, p_session_id, p_tenant_id, account_record.id, 'payout_account_primary_changed', pg_catalog.jsonb_build_object('payout_currency', account_record.payout_currency, 'payout_rail', account_record.payout_rail));
  return (account_record.id, account_record.status, false)::financial_ops.payout_account_command_result;
end;
$$;

create or replace function tenant_config.update_team_configuration(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_team_display_name text,
  p_team_short_name text,
  p_support_contact_name text,
  p_support_contact_email text,
  p_support_contact_phone text,
  p_locale_code text,
  p_timezone_name text,
  p_primary_logo_asset_id uuid,
  p_square_app_icon_asset_id uuid,
  p_light_logo_asset_id uuid,
  p_dark_logo_asset_id uuid,
  p_theme_key text,
  p_team_slogan text,
  p_support_url text,
  p_revision_reason text
)
returns tenant_config.configuration_revisions
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command tenant_config.command_idempotency%rowtype;
  decision authz.authorization_decision;
  new_revision tenant_config.configuration_revisions%rowtype;
  next_revision_number integer;
begin
  if p_idempotency_key is null or p_actor_user_id is null or p_session_id is null
     or p_tenant_id is null or p_team_display_name is null
     or p_locale_code is null or p_timezone_name is null
     or p_revision_reason is null then
    raise exception using errcode = '22023', message = 'team configuration input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'team configuration actor mismatch';
  end if;

  request_fingerprint := tenant_config.request_fingerprint(
    'update_team_configuration',
    pg_catalog.jsonb_build_object(
      'tenant_id', p_tenant_id,
      'team_display_name', p_team_display_name,
      'team_short_name', p_team_short_name,
      'support_contact_name', p_support_contact_name,
      'support_contact_email', p_support_contact_email,
      'support_contact_phone', p_support_contact_phone,
      'locale_code', p_locale_code,
      'timezone_name', p_timezone_name,
      'primary_logo_asset_id', p_primary_logo_asset_id,
      'square_app_icon_asset_id', p_square_app_icon_asset_id,
      'light_logo_asset_id', p_light_logo_asset_id,
      'dark_logo_asset_id', p_dark_logo_asset_id,
      'theme_key', p_theme_key,
      'team_slogan', p_team_slogan,
      'support_url', p_support_url,
      'revision_reason', p_revision_reason
    )
  );

  select command.* into existing_command
    from tenant_config.command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.command_type <> 'update_team_configuration'
       or existing_command.tenant_id <> p_tenant_id
       or existing_command.actor_user_id <> p_actor_user_id
       or existing_command.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '23505', message = 'idempotency key already used with different team configuration data';
    end if;

    select revision.* into new_revision
      from tenant_config.configuration_revisions revision
     where revision.id = existing_command.result_id;
  decision := authz.authorize(
    p_actor_user_id, p_session_id, 'manage_tenant_configuration', p_tenant_id,
    null, null, null, null, null, 'update_team_configuration', null
  );

  if decision.decision <> 'ALLOW' then
    insert into authz.security_audit_events (
      actor_user_id, session_id, tenant_id, event_type, permission_key,
      allowed, source, source_id, reason_code, metadata
    ) values (
      p_actor_user_id, p_session_id, p_tenant_id, 'team_configuration_update_denied',
      'manage_tenant_configuration', false, decision.source, decision.source_id,
      decision.reason_code, '{}'::jsonb
    );
    raise exception using errcode = '42501', message = decision.reason_code;
  end if;
    return new_revision;
  end if;

  decision := authz.authorize(
    p_actor_user_id, p_session_id, 'manage_tenant_configuration', p_tenant_id,
    null, null, null, null, null, 'update_team_configuration', null
  );

  if decision.decision <> 'ALLOW' then
    insert into authz.security_audit_events (
      actor_user_id, session_id, tenant_id, event_type, permission_key,
      allowed, source, source_id, reason_code, metadata
    ) values (
      p_actor_user_id, p_session_id, p_tenant_id, 'team_configuration_update_denied',
      'manage_tenant_configuration', false, decision.source, decision.source_id,
      decision.reason_code, '{}'::jsonb
    );
    raise exception using errcode = '42501', message = decision.reason_code;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('tenant-configuration:' || p_tenant_id::text, 0)
  );

  if exists (
    select 1
      from tenant_config.brand_assets asset
     where asset.tenant_id = p_tenant_id
       and asset.id in (
         p_primary_logo_asset_id,
         p_square_app_icon_asset_id,
         p_light_logo_asset_id,
         p_dark_logo_asset_id
       )
       and asset.status <> 'active'
  ) then
    raise exception using errcode = '23514', message = 'configuration references a retired brand asset';
  end if;

  if exists (
    select 1
      from unnest(array[
        p_primary_logo_asset_id,
        p_square_app_icon_asset_id,
        p_light_logo_asset_id,
        p_dark_logo_asset_id
      ]) asset_id
     where asset_id is not null
       and not exists (
         select 1 from tenant_config.brand_assets asset
          where asset.tenant_id = p_tenant_id and asset.id = asset_id
       )
  ) then
    raise exception using errcode = '23503', message = 'configuration asset belongs to another tenant';
  end if;

  select coalesce(max(revision_number), 0) + 1
    into next_revision_number
    from tenant_config.configuration_revisions
   where tenant_id = p_tenant_id;

  insert into tenant_config.configuration_revisions (
    tenant_id, revision_number, team_display_name, team_short_name,
    support_contact_name, support_contact_email, support_contact_phone,
    locale_code, timezone_name, primary_logo_asset_id, square_app_icon_asset_id,
    light_logo_asset_id, dark_logo_asset_id, theme_key, team_slogan, support_url,
    revision_reason, created_by_user_id
  ) values (
    p_tenant_id, next_revision_number, btrim(p_team_display_name),
    nullif(btrim(p_team_short_name), ''), nullif(btrim(p_support_contact_name), ''),
    nullif(btrim(p_support_contact_email), ''), nullif(btrim(p_support_contact_phone), ''),
    p_locale_code, btrim(p_timezone_name), p_primary_logo_asset_id,
    p_square_app_icon_asset_id, p_light_logo_asset_id, p_dark_logo_asset_id,
    nullif(btrim(p_theme_key), ''), nullif(btrim(p_team_slogan), ''),
    nullif(btrim(p_support_url), ''), btrim(p_revision_reason), p_actor_user_id
  ) returning * into new_revision;

  insert into tenant_config.active_configuration (tenant_id, revision_id)
  values (p_tenant_id, new_revision.id)
  on conflict (tenant_id) do update
    set revision_id = excluded.revision_id,
        activated_at = clock_timestamp();

  insert into public.tenant_member_branding_read (
    tenant_id, revision_id, revision_number, team_display_name, team_short_name,
    primary_logo_asset_id, square_app_icon_asset_id, light_logo_asset_id,
    dark_logo_asset_id, theme_key, team_slogan, support_url, refreshed_at
  ) values (
    new_revision.tenant_id, new_revision.id, new_revision.revision_number,
    new_revision.team_display_name, new_revision.team_short_name,
    new_revision.primary_logo_asset_id, new_revision.square_app_icon_asset_id,
    new_revision.light_logo_asset_id, new_revision.dark_logo_asset_id,
    new_revision.theme_key, new_revision.team_slogan, new_revision.support_url,
    clock_timestamp()
  )
  on conflict (tenant_id) do update
    set revision_id = excluded.revision_id,
        revision_number = excluded.revision_number,
        team_display_name = excluded.team_display_name,
        team_short_name = excluded.team_short_name,
        primary_logo_asset_id = excluded.primary_logo_asset_id,
        square_app_icon_asset_id = excluded.square_app_icon_asset_id,
        light_logo_asset_id = excluded.light_logo_asset_id,
        dark_logo_asset_id = excluded.dark_logo_asset_id,
        theme_key = excluded.theme_key,
        team_slogan = excluded.team_slogan,
        support_url = excluded.support_url,
        refreshed_at = clock_timestamp();

  insert into tenant_config.command_idempotency (
    idempotency_key, command_type, request_fingerprint, tenant_id,
    actor_user_id, result_id
  ) values (
    p_idempotency_key, 'update_team_configuration', request_fingerprint,
    p_tenant_id, p_actor_user_id, new_revision.id
  );

  insert into authz.security_audit_events (
    actor_user_id, session_id, tenant_id, event_type, permission_key,
    target_type, target_id, allowed, source, source_id, reason_code, metadata
  ) values (
    p_actor_user_id, p_session_id, p_tenant_id, 'team_configuration_updated',
    'manage_tenant_configuration', 'configuration_revision', new_revision.id,
    true, decision.source, decision.source_id, decision.reason_code,
    pg_catalog.jsonb_build_object('revision_number', new_revision.revision_number)
  );

  return new_revision;
end;
$$;

create or replace function tenant_config.request_brand_asset_upload(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_asset_kind text,
  p_mime_type text,
  p_file_size_bytes bigint,
  p_sha256_hex text,
  p_width_pixels integer,
  p_height_pixels integer
)
returns tenant_config.brand_asset_upload_intents
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_intent tenant_config.brand_asset_upload_intents%rowtype;
  decision authz.authorization_decision;
  new_intent tenant_config.brand_asset_upload_intents%rowtype;
begin
  if p_idempotency_key is null or p_actor_user_id is null
     or p_session_id is null or p_tenant_id is null
     or p_asset_kind not in (
       'primary_logo', 'square_app_icon', 'light_logo', 'dark_logo'
     )
     or p_mime_type not in (
       'image/png', 'image/jpeg', 'image/webp', 'image/svg+xml'
     )
     or p_file_size_bytes is null
     or p_file_size_bytes not between 1 and 5242880
     or p_sha256_hex is null
     or p_sha256_hex !~ '^[0-9A-Fa-f]{64}$'
     or (p_width_pixels is not null and p_width_pixels <= 0)
     or (p_height_pixels is not null and p_height_pixels <= 0) then
    raise exception using errcode = '22023',
      message = 'brand asset upload input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501',
      message = 'brand asset upload actor mismatch';
  end if;

  request_fingerprint := tenant_config.request_fingerprint(
    'request_brand_asset_upload',
    pg_catalog.jsonb_build_object(
      'tenant_id', p_tenant_id,
      'asset_kind', p_asset_kind,
      'mime_type', p_mime_type,
      'file_size_bytes', p_file_size_bytes,
      'sha256_hex', lower(p_sha256_hex),
      'width_pixels', p_width_pixels,
      'height_pixels', p_height_pixels
    )
  );

  select intent.* into existing_intent
    from tenant_config.brand_asset_upload_intents intent
   where intent.idempotency_key = p_idempotency_key;
  if found then
    if existing_intent.tenant_id <> p_tenant_id
       or existing_intent.submitted_by_user_id <> p_actor_user_id
       or tenant_config.request_fingerprint(
         'request_brand_asset_upload',
         pg_catalog.jsonb_build_object(
           'tenant_id', existing_intent.tenant_id,
           'asset_kind', existing_intent.asset_kind,
           'mime_type', existing_intent.mime_type,
           'file_size_bytes', existing_intent.file_size_bytes,
           'sha256_hex', encode(existing_intent.sha256, 'hex'),
           'width_pixels', existing_intent.width_pixels,
           'height_pixels', existing_intent.height_pixels
         )
       ) <> request_fingerprint then
      raise exception using errcode = '23505',
        message = 'idempotency key already used with different asset upload data';
    end if;
  decision := authz.authorize(
    p_actor_user_id, p_session_id, 'manage_tenant_configuration', p_tenant_id,
    null, null, null, null, null, 'request_brand_asset_upload', null
  );
  if decision.decision <> 'ALLOW' then
    insert into authz.security_audit_events (
      actor_user_id, session_id, tenant_id, event_type, permission_key,
      allowed, source, source_id, reason_code, metadata
    ) values (
      p_actor_user_id, p_session_id, p_tenant_id,
      'brand_asset_upload_request_denied', 'manage_tenant_configuration', false,
      decision.source, decision.source_id, decision.reason_code, '{}'::jsonb
    );
    raise exception using errcode = '42501', message = decision.reason_code;
  end if;
    return existing_intent;
  end if;

  decision := authz.authorize(
    p_actor_user_id, p_session_id, 'manage_tenant_configuration', p_tenant_id,
    null, null, null, null, null, 'request_brand_asset_upload', null
  );
  if decision.decision <> 'ALLOW' then
    insert into authz.security_audit_events (
      actor_user_id, session_id, tenant_id, event_type, permission_key,
      allowed, source, source_id, reason_code, metadata
    ) values (
      p_actor_user_id, p_session_id, p_tenant_id,
      'brand_asset_upload_request_denied', 'manage_tenant_configuration', false,
      decision.source, decision.source_id, decision.reason_code, '{}'::jsonb
    );
    raise exception using errcode = '42501', message = decision.reason_code;
  end if;

  insert into tenant_config.brand_asset_upload_intents (
    idempotency_key, tenant_id, submitted_by_user_id, asset_kind,
    storage_bucket_id, storage_object_path, mime_type, file_size_bytes, sha256,
    width_pixels, height_pixels, expires_at
  ) values (
    p_idempotency_key, p_tenant_id, p_actor_user_id, p_asset_kind,
    'tenant-brand-assets',
    p_tenant_id::text || '/' || extensions.gen_random_uuid()::text,
    p_mime_type, p_file_size_bytes, decode(lower(p_sha256_hex), 'hex'),
    p_width_pixels, p_height_pixels, clock_timestamp() + interval '15 minutes'
  ) returning * into new_intent;

  return new_intent;
end;
$$;

create or replace function authz.set_account_status(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_target_user_id uuid,
  p_new_status public.account_status,
  p_reason text
)
returns public.user_accounts
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command authz.account_status_command_idempotency%rowtype;
  actor_status public.account_status;
  target_account public.user_accounts%rowtype;
  previous_status public.account_status;
begin
  if p_idempotency_key is null or p_actor_user_id is null
     or p_session_id is null or p_target_user_id is null
     or p_new_status is null or p_reason is null
     or length(btrim(p_reason)) = 0 then
    raise exception using errcode = '22023',
      message = 'account status input is invalid';
  end if;

  if p_new_status not in ('active', 'restricted', 'suspended', 'deactivated') then
    raise exception using errcode = '22023',
      message = 'account status is not administratively assignable';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501',
      message = 'account status actor mismatch';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('account-status-command:' || p_idempotency_key::text, 0)
  );

  request_fingerprint := authz.account_status_request_fingerprint(
    p_target_user_id, p_new_status, p_reason
  );

  select account.status into actor_status
    from public.user_accounts account
   where account.user_id = p_actor_user_id;

  if actor_status is null or actor_status <> 'active'
     or not authz.is_platform_admin(p_actor_user_id)
     or not authz.is_elevated_session_valid(p_session_id, p_actor_user_id) then
    insert into authz.security_audit_events (
      actor_user_id, session_id, event_type, permission_key, allowed,
      source, reason_code, target_type, target_id, metadata
    ) values (
      p_actor_user_id, p_session_id, 'account_status_change_denied',
      'manage_account_status', false, 'system_rule', 'platform_admin_step_up_required',
      'user_account', p_target_user_id, '{}'::jsonb
    );
    raise exception using errcode = '42501',
      message = 'platform admin step-up authorization required';
  end if;

  select command.*
    into existing_command
    from authz.account_status_command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.actor_user_id <> p_actor_user_id
       or existing_command.target_user_id <> p_target_user_id
       or existing_command.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '23505',
        message = 'idempotency key already used with different account status data';
    end if;

    select account.* into target_account
      from public.user_accounts account
     where account.user_id = p_target_user_id;
    return target_account;
  end if;



  select account.* into target_account
    from public.user_accounts account
   where account.user_id = p_target_user_id
   for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'target account not found';
  end if;

  previous_status := target_account.status;

  update public.user_accounts
     set status = p_new_status
   where user_id = p_target_user_id
  returning * into target_account;

  insert into authz.account_status_command_idempotency (
    idempotency_key, actor_user_id, target_user_id, request_fingerprint
  ) values (
    p_idempotency_key, p_actor_user_id, p_target_user_id, request_fingerprint
  );

  insert into authz.security_audit_events (
    actor_user_id, session_id, event_type, permission_key, allowed,
    source, reason_code, target_type, target_id, metadata
  ) values (
    p_actor_user_id, p_session_id, 'account_status_changed',
    'manage_account_status', true, 'system_rule', 'platform_admin',
    'user_account', p_target_user_id,
    pg_catalog.jsonb_build_object(
      'previous_status', previous_status,
      'new_status', p_new_status,
      'reason', btrim(p_reason)
    )
  );

  return target_account;
end;
$$;

create or replace function tenant_config.finalize_brand_asset_upload(
  p_intent_id uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_verified_file_size_bytes bigint,
  p_verified_sha256_hex text
)
returns tenant_config.brand_assets
language plpgsql
security definer
set search_path = ''
as $$
declare
  intent tenant_config.brand_asset_upload_intents%rowtype;
  new_asset tenant_config.brand_assets%rowtype;
begin
  if p_intent_id is null or p_actor_user_id is null or p_session_id is null
     or p_verified_file_size_bytes is null
     or p_verified_sha256_hex is null
     or p_verified_sha256_hex !~ '^[0-9A-Fa-f]{64}$' then
    raise exception using errcode = '22023',
      message = 'brand asset finalization input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501',
      message = 'brand asset finalization actor mismatch';
  end if;

  select upload.* into intent
    from tenant_config.brand_asset_upload_intents upload
   where upload.id = p_intent_id
   for update;
  if not found then
    raise exception using errcode = 'P0002',
      message = 'brand asset upload intent was not found';
  end if;

  if intent.submitted_by_user_id <> p_actor_user_id then
    raise exception using errcode = '42501',
      message = 'only the upload submitter may finalize the brand asset';
  end if;
  perform command_api.read_brand_asset_upload_intent(p_intent_id, p_actor_user_id, p_session_id);
  if intent.status = 'finalized' then
    select asset.* into new_asset
      from tenant_config.brand_assets asset
     where asset.id = intent.finalized_asset_id;
    return new_asset;
  end if;
  if intent.status <> 'pending' or intent.expires_at <= clock_timestamp() then
    raise exception using errcode = '55000',
      message = 'brand asset upload intent is no longer pending';
  end if;
  if p_verified_file_size_bytes <> intent.file_size_bytes
     or lower(p_verified_sha256_hex) <> encode(intent.sha256, 'hex') then
    raise exception using errcode = '23514',
      message = 'uploaded brand asset does not match its upload intent';
  end if;

  select * into new_asset
    from tenant_config.register_brand_asset(
      intent.idempotency_key,
      p_actor_user_id,
      p_session_id,
      intent.tenant_id,
      intent.asset_kind,
      intent.storage_object_path,
      intent.mime_type,
      intent.file_size_bytes,
      encode(intent.sha256, 'hex'),
      intent.width_pixels,
      intent.height_pixels
    );

  update tenant_config.brand_asset_upload_intents
     set status = 'finalized',
         finalized_asset_id = new_asset.id,
         finalized_at = clock_timestamp()
   where id = intent.id;

  return new_asset;
end;
$$;


create or replace function tenant_config.register_brand_asset(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_asset_kind text,
  p_storage_object_path text,
  p_mime_type text,
  p_byte_size bigint,
  p_checksum_sha256 text,
  p_width_pixels integer,
  p_height_pixels integer
)
returns tenant_config.brand_assets
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command tenant_config.command_idempotency%rowtype;
  decision authz.authorization_decision;
  new_asset tenant_config.brand_assets%rowtype;
begin
  if p_idempotency_key is null or p_actor_user_id is null or p_session_id is null
     or p_tenant_id is null or p_asset_kind is null
     or p_storage_object_path is null or p_mime_type is null
     or p_byte_size is null or p_checksum_sha256 is null then
    raise exception using errcode = '22023', message = 'brand asset input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'brand asset actor mismatch';
  end if;

  request_fingerprint := tenant_config.request_fingerprint(
    'register_brand_asset',
    pg_catalog.jsonb_build_object(
      'tenant_id', p_tenant_id,
      'asset_kind', p_asset_kind,
      'storage_object_path', p_storage_object_path,
      'mime_type', p_mime_type,
      'byte_size', p_byte_size,
      'checksum_sha256', p_checksum_sha256,
      'width_pixels', p_width_pixels,
      'height_pixels', p_height_pixels
    )
  );

  select command.* into existing_command
    from tenant_config.command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.command_type <> 'register_brand_asset'
       or existing_command.tenant_id <> p_tenant_id
       or existing_command.actor_user_id <> p_actor_user_id
       or existing_command.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '23505', message = 'idempotency key already used with different brand asset data';
    end if;

    select asset.* into new_asset
      from tenant_config.brand_assets asset
     where asset.id = existing_command.result_id;
  decision := authz.authorize(
    p_actor_user_id, p_session_id, 'manage_tenant_configuration', p_tenant_id,
    null, null, null, null, null, 'register_brand_asset', null
  );

  if decision.decision <> 'ALLOW' then
    insert into authz.security_audit_events (
      actor_user_id, session_id, tenant_id, event_type, permission_key,
      allowed, source, source_id, reason_code, metadata
    ) values (
      p_actor_user_id, p_session_id, p_tenant_id, 'brand_asset_registration_denied',
      'manage_tenant_configuration', false, decision.source, decision.source_id,
      decision.reason_code, '{}'::jsonb
    );
    raise exception using errcode = '42501', message = decision.reason_code;
  end if;
    return new_asset;
  end if;

  decision := authz.authorize(
    p_actor_user_id, p_session_id, 'manage_tenant_configuration', p_tenant_id,
    null, null, null, null, null, 'register_brand_asset', null
  );

  if decision.decision <> 'ALLOW' then
    insert into authz.security_audit_events (
      actor_user_id, session_id, tenant_id, event_type, permission_key,
      allowed, source, source_id, reason_code, metadata
    ) values (
      p_actor_user_id, p_session_id, p_tenant_id, 'brand_asset_registration_denied',
      'manage_tenant_configuration', false, decision.source, decision.source_id,
      decision.reason_code, '{}'::jsonb
    );
    raise exception using errcode = '42501', message = decision.reason_code;
  end if;

  insert into tenant_config.brand_assets (
    tenant_id, asset_kind, storage_object_path, mime_type, byte_size,
    checksum_sha256, width_pixels, height_pixels, created_by_user_id
  ) values (
    p_tenant_id, p_asset_kind, p_storage_object_path, p_mime_type, p_byte_size,
    lower(p_checksum_sha256), p_width_pixels, p_height_pixels, p_actor_user_id
  ) returning * into new_asset;

  insert into tenant_config.command_idempotency (
    idempotency_key, command_type, request_fingerprint, tenant_id,
    actor_user_id, result_id
  ) values (
    p_idempotency_key, 'register_brand_asset', request_fingerprint,
    p_tenant_id, p_actor_user_id, new_asset.id
  );

  insert into authz.security_audit_events (
    actor_user_id, session_id, tenant_id, event_type, permission_key,
    target_type, target_id, allowed, source, source_id, reason_code, metadata
  ) values (
    p_actor_user_id, p_session_id, p_tenant_id, 'brand_asset_registered',
    'manage_tenant_configuration', 'brand_asset', new_asset.id, true,
    decision.source, decision.source_id, decision.reason_code,
    pg_catalog.jsonb_build_object('asset_kind', new_asset.asset_kind)
  );

  return new_asset;
end;
$$;


create or replace function evidence.request_financial_evidence_upload(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_target_type text,
  p_target_id uuid,
  p_evidence_type text,
  p_original_filename text,
  p_mime_type text,
  p_file_size_bytes bigint,
  p_sha256_hex text
)
returns evidence.financial_upload_intents
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_intent evidence.financial_upload_intents%rowtype;
  target_tenant_id uuid;
  target_submitter_user_id uuid;
  new_intent evidence.financial_upload_intents%rowtype;
begin
  if p_idempotency_key is null or p_actor_user_id is null
     or p_target_id is null or p_evidence_type is null
     or p_original_filename is null or p_mime_type is null
     or p_file_size_bytes is null or p_sha256_hex is null
     or p_sha256_hex !~ '^[0-9A-Fa-f]{64}$'
     or p_file_size_bytes not between 1 and 52428800
     or length(btrim(p_original_filename)) not between 1 and 255
     or p_mime_type not in ('application/pdf', 'image/jpeg', 'image/png') then
    raise exception using errcode = '22023',
      message = 'financial evidence upload input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501',
      message = 'financial evidence upload actor mismatch';
  end if;

  if (p_evidence_type = 'income' and p_target_type <> 'income_record')
     or (p_evidence_type = 'currency_conversion'
       and p_target_type <> 'currency_conversion_revision')
     or (p_evidence_type = 'administrative_adjustment'
       and p_target_type <> 'administrative_adjustment_revision')
     or (p_evidence_type = 'returned_funds'
       and p_target_type <> 'returned_fund_revision') then
    raise exception using errcode = '23514',
      message = 'financial evidence type does not match its target';
  end if;

  request_fingerprint := evidence.financial_upload_request_fingerprint(
    p_target_type, p_target_id, p_evidence_type, btrim(p_original_filename),
    p_mime_type, p_file_size_bytes, lower(p_sha256_hex)
  );

  select intent.* into existing_intent
    from evidence.financial_upload_intents intent
   where intent.idempotency_key = p_idempotency_key;
  if found then
    if existing_intent.tenant_id is null
       or existing_intent.target_type <> p_target_type
       or existing_intent.target_id <> p_target_id
       or existing_intent.evidence_type <> p_evidence_type
       or existing_intent.submitted_by_user_id <> p_actor_user_id
       or evidence.financial_upload_request_fingerprint(
         existing_intent.target_type, existing_intent.target_id,
         existing_intent.evidence_type, existing_intent.original_filename,
         existing_intent.mime_type, existing_intent.file_size_bytes,
         encode(existing_intent.sha256, 'hex')
       ) <> request_fingerprint then
      raise exception using errcode = '23505',
        message = 'idempotency key already used with different upload data';
    end if;
    perform command_api.read_financial_upload_intent(existing_intent.id, p_actor_user_id);
    return existing_intent;
  end if;

  select target.tenant_id, target.submitter_user_id
    into target_tenant_id, target_submitter_user_id
    from evidence.resolve_financial_operation_target(p_target_type, p_target_id)
      target;

  if target_submitter_user_id <> p_actor_user_id then
    raise exception using errcode = '42501',
      message = 'only the operation submitter may upload its evidence';
  end if;

  if not exists (select 1 from public.user_accounts account where account.user_id = p_actor_user_id and account.status = 'active')
    or not exists (select 1 from public.tenants tenant where tenant.id = target_tenant_id and tenant.status = 'active')
    or not exists (select 1 from public.memberships membership
      where membership.user_id = p_actor_user_id and membership.tenant_id = target_tenant_id
        and membership.status = 'active' and (membership.office_id is null or exists (
          select 1 from public.offices office where office.id = membership.office_id
            and office.tenant_id = target_tenant_id and office.status = 'active'))) then
    raise exception using errcode = '42501', message = 'financial evidence requires active organizational context';
  end if;
  insert into evidence.financial_upload_intents (
    idempotency_key, tenant_id, target_type, target_id, evidence_type,
    submitted_by_user_id, storage_bucket_id, storage_object_path,
    original_filename, mime_type, file_size_bytes, sha256, expires_at
  ) values (
    p_idempotency_key, target_tenant_id, p_target_type, p_target_id,
    p_evidence_type, p_actor_user_id, 'financial-evidence',
    target_tenant_id::text || '/' || extensions.gen_random_uuid()::text,
    btrim(p_original_filename), p_mime_type, p_file_size_bytes,
    decode(lower(p_sha256_hex), 'hex'), clock_timestamp() + interval '15 minutes'
  ) returning * into new_intent;

  return new_intent;
end;
$$;


create or replace function evidence.finalize_financial_evidence_upload(
  p_intent_id uuid,
  p_actor_user_id uuid,
  p_verified_file_size_bytes bigint,
  p_verified_sha256_hex text,
  p_observed_at timestamptz,
  p_provider text default null,
  p_provider_reference text default null,
  p_notes text default null
)
returns evidence.financial_evidence
language plpgsql
security definer
set search_path = ''
as $$
declare
  intent evidence.financial_upload_intents%rowtype;
  target_evidence evidence.financial_evidence%rowtype;
  attached_count integer;
begin
  if p_intent_id is null or p_actor_user_id is null
     or p_verified_file_size_bytes is null
     or p_verified_sha256_hex !~ '^[0-9A-Fa-f]{64}$'
     or p_observed_at is null then
    raise exception using errcode = '22023',
      message = 'financial evidence finalization input is invalid';
  end if;

  select upload.* into intent
    from evidence.financial_upload_intents upload
   where upload.id = p_intent_id
   for update;
  if not found then
    raise exception using errcode = 'P0002',
      message = 'financial evidence upload intent was not found';
  end if;

  if intent.submitted_by_user_id <> p_actor_user_id then
    raise exception using errcode = '42501',
      message = 'only the upload submitter may finalize evidence';
  end if;
  perform command_api.read_financial_upload_intent(p_intent_id, p_actor_user_id);
  if intent.status = 'finalized' then
    select evidence.* into target_evidence
      from evidence.financial_evidence evidence
     where evidence.id = intent.finalized_evidence_id;
    return target_evidence;
  end if;
  if intent.status <> 'pending' or intent.expires_at <= clock_timestamp() then
    update evidence.financial_upload_intents
       set status = case when status = 'pending' then 'expired' else status end
     where id = intent.id;
    raise exception using errcode = '40901',
      message = 'financial evidence upload intent is no longer valid';
  end if;

  if p_verified_file_size_bytes <> intent.file_size_bytes
     or decode(lower(p_verified_sha256_hex), 'hex') <> intent.sha256 then
    raise exception using errcode = '23514',
      message = 'uploaded object metadata does not match the upload intent';
  end if;

  select evidence.attach_financial_operation_evidence(
    intent.tenant_id,
    p_actor_user_id,
    intent.evidence_type,
    intent.target_type,
    intent.target_id,
    pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'storage_bucket_id', intent.storage_bucket_id,
        'storage_object_path', intent.storage_object_path,
        'original_filename', intent.original_filename,
        'mime_type', intent.mime_type,
        'file_size_bytes', intent.file_size_bytes,
        'sha256_hex', encode(intent.sha256, 'hex'),
        'observed_at', p_observed_at,
        'provider', p_provider,
        'provider_reference', p_provider_reference,
        'notes', p_notes
      )
    )
  ) into attached_count;

  if attached_count <> 1 then
    raise exception using errcode = 'XX000',
      message = 'financial evidence upload finalization failed';
  end if;

  select evidence.* into target_evidence
    from evidence.financial_evidence evidence
   where evidence.storage_bucket_id = intent.storage_bucket_id
     and evidence.storage_object_path = intent.storage_object_path;

  update evidence.financial_upload_intents
     set status = 'finalized', finalized_evidence_id = target_evidence.id,
         finalized_at = clock_timestamp()
   where id = intent.id;

  return target_evidence;
end;
$$;
