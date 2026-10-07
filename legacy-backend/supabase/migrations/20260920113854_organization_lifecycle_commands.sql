create or replace function internal.organization_request_fingerprint(
  p_command_type text,
  p_payload jsonb
)
returns bytea
language sql
immutable
security invoker
set search_path = ''
as $$
  select extensions.digest(
    pg_catalog.jsonb_build_object(
      'command_type', p_command_type,
      'payload', p_payload
    )::text,
    'sha256'
  );
$$;

create or replace function internal.organization_replay_result(
  p_idempotency_key uuid,
  p_command_type text,
  p_actor_user_id uuid,
  p_request_fingerprint bytea,
  p_result_type text
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  existing_command internal.organization_command_idempotency%rowtype;
begin
  select command.*
    into existing_command
    from internal.organization_command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if not found then
    return null;
  end if;

  if existing_command.command_type <> p_command_type
     or existing_command.actor_user_id <> p_actor_user_id
     or existing_command.request_fingerprint <> p_request_fingerprint
     or existing_command.result_type <> p_result_type then
    raise exception using
      errcode = '23505',
      message = 'idempotency key already used with different organization command data';
  end if;

  return existing_command.result_id;
end;
$$;

create or replace function internal.record_organization_command(
  p_idempotency_key uuid,
  p_command_type text,
  p_actor_user_id uuid,
  p_tenant_id uuid,
  p_request_fingerprint bytea,
  p_result_type text,
  p_result_id uuid
)
returns void
language sql
security invoker
set search_path = ''
as $$
  insert into internal.organization_command_idempotency (
    idempotency_key,
    command_type,
    actor_user_id,
    tenant_id,
    request_fingerprint,
    result_type,
    result_id
  )
  values (
    p_idempotency_key,
    p_command_type,
    p_actor_user_id,
    p_tenant_id,
    p_request_fingerprint,
    p_result_type,
    p_result_id
  );
$$;

create or replace function internal.lock_membership_subject(
  p_tenant_id uuid,
  p_user_id uuid
)
returns void
language sql
security invoker
set search_path = ''
as $$
  select pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'organization-membership:' || p_tenant_id::text || ':' || p_user_id::text,
      0
    )
  );
$$;

create or replace function internal.bump_membership_authorization_versions(
  p_tenant_id uuid,
  p_user_id uuid
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update public.tenants
     set authz_version = authz_version + 1
   where id = p_tenant_id;

  update public.user_accounts
     set authz_version = authz_version + 1
   where user_id = p_user_id;
end;
$$;

create or replace function internal.ensure_wallet_for_member(
  p_user_id uuid
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  wallet_id uuid;
begin
  insert into public.wallets (owner_user_id)
  values (p_user_id)
  on conflict (owner_user_id) do nothing
  returning id into wallet_id;

  if wallet_id is null then
    select wallet.id
      into wallet_id
      from public.wallets wallet
     where wallet.owner_user_id = p_user_id;
  end if;

  return wallet_id;
end;
$$;

create or replace function internal.assert_membership_not_billing_owner(
  p_tenant_id uuid,
  p_membership_id uuid
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'commercial.billing-owner:' || p_tenant_id::text,
      0
    )
  );

  if exists (
    select 1
      from commercial.billing_owner_assignments assignment
     where assignment.tenant_id = p_tenant_id
       and assignment.membership_id = p_membership_id
       and assignment.ended_at is null
  ) then
    raise exception using
      errcode = '23514',
      message = 'current billing owner must be reassigned before membership authority changes';
  end if;
end;
$$;

create or replace function internal.lock_active_office(
  p_tenant_id uuid,
  p_office_id uuid
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  office_state public.office_status;
begin
  select office.status
    into office_state
    from public.offices office
   where office.tenant_id = p_tenant_id
     and office.id = p_office_id
   for share;

  if office_state is null or office_state <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'membership office must be active';
  end if;
end;
$$;

create or replace function internal.create_invitation(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_office_id uuid,
  p_role_key public.role_key,
  p_email text,
  p_token_digest bytea,
  p_expires_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_email text;
  request_fingerprint bytea;
  replay_result uuid;
  decision authz.authorization_decision;
  invitation_id uuid;
begin
  normalized_email := pg_catalog.lower(pg_catalog.btrim(p_email));

  if p_idempotency_key is null
     or p_actor_user_id is null
     or p_tenant_id is null
     or p_office_id is null
     or p_role_key is null
     or normalized_email is null
     or pg_catalog.length(normalized_email) <= 3
     or p_token_digest is null
     or pg_catalog.octet_length(p_token_digest) <> 32
     or p_expires_at is null
     or p_expires_at <= pg_catalog.clock_timestamp() then
    raise exception using
      errcode = '22023',
      message = 'invitation command input is invalid';
  end if;

  if p_role_key = 'president_team_member' then
    raise exception using
      errcode = '23514',
      message = 'President authority requires the protected presidency transfer command';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'invitation command actor does not match the authenticated user';
  end if;

  request_fingerprint := internal.organization_request_fingerprint(
    'create_invitation',
    pg_catalog.jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'tenant_id', p_tenant_id,
      'office_id', p_office_id,
      'role_key', p_role_key::text,
      'email', normalized_email,
      'token_digest', pg_catalog.encode(p_token_digest, 'hex'),
      'expires_at', p_expires_at
    )
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  replay_result := internal.organization_replay_result(
    p_idempotency_key,
    'create_invitation',
    p_actor_user_id,
    request_fingerprint,
    'invitation'
  );
  if replay_result is not null then
    return replay_result;
  end if;

  decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'invite_members',
    p_tenant_id,
    p_office_id,
    null,
    null,
    null,
    null,
    null,
    null
  );

  if decision.decision <> 'ALLOW' then
    raise exception using
      errcode = '42501',
      message = 'invitation creation is not authorized';
  end if;

  perform internal.lock_active_office(p_tenant_id, p_office_id);

  insert into public.invitations (
    tenant_id,
    office_id,
    role_key,
    email,
    token_digest,
    expires_at
  )
  values (
    p_tenant_id,
    p_office_id,
    p_role_key,
    normalized_email,
    p_token_digest,
    p_expires_at
  )
  returning id into invitation_id;

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
    'invitation_created',
    'invite_members',
    'invitation',
    invitation_id,
    true,
    decision.source,
    decision.source_id,
    decision.reason_code,
    pg_catalog.jsonb_build_object(
      'office_id', p_office_id,
      'role_key', p_role_key::text
    )
  );

  perform internal.record_organization_command(
    p_idempotency_key,
    'create_invitation',
    p_actor_user_id,
    p_tenant_id,
    request_fingerprint,
    'invitation',
    invitation_id
  );

  return invitation_id;
end;
$$;

create or replace function internal.revoke_invitation(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_invitation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  replay_result uuid;
  invitation public.invitations%rowtype;
  decision authz.authorization_decision;
begin
  if p_idempotency_key is null
     or p_actor_user_id is null
     or p_invitation_id is null then
    raise exception using
      errcode = '22023',
      message = 'invitation revocation input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'invitation command actor does not match the authenticated user';
  end if;

  request_fingerprint := internal.organization_request_fingerprint(
    'revoke_invitation',
    pg_catalog.jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'invitation_id', p_invitation_id
    )
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  replay_result := internal.organization_replay_result(
    p_idempotency_key,
    'revoke_invitation',
    p_actor_user_id,
    request_fingerprint,
    'invitation'
  );
  if replay_result is not null then
    return replay_result;
  end if;

  select target.*
    into invitation
    from public.invitations target
   where target.id = p_invitation_id
   for update;

  if invitation.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'invitation was not found';
  end if;

  decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'invite_members',
    invitation.tenant_id,
    invitation.office_id,
    null,
    null,
    null,
    null,
    null,
    null
  );

  if decision.decision <> 'ALLOW' then
    raise exception using
      errcode = '42501',
      message = 'invitation revocation is not authorized';
  end if;

  if invitation.status = 'accepted' then
    raise exception using
      errcode = '23514',
      message = 'an accepted invitation cannot be revoked';
  end if;

  if invitation.status = 'pending' then
    update public.invitations
       set status = 'revoked'
     where id = invitation.id;

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
      invitation.tenant_id,
      'invitation_revoked',
      'invite_members',
      'invitation',
      invitation.id,
      true,
      decision.source,
      decision.source_id,
      decision.reason_code,
      pg_catalog.jsonb_build_object('previous_status', invitation.status::text)
    );
  end if;

  perform internal.record_organization_command(
    p_idempotency_key,
    'revoke_invitation',
    p_actor_user_id,
    invitation.tenant_id,
    request_fingerprint,
    'invitation',
    invitation.id
  );

  return invitation.id;
end;
$$;

create or replace function internal.expire_invitations(
  p_at timestamptz default pg_catalog.clock_timestamp()
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  expired_count bigint;
begin
  if p_at is null then
    raise exception using
      errcode = '22023',
      message = 'invitation expiration time is required';
  end if;

  with expired as (
    update public.invitations invitation
       set status = 'expired'
     where invitation.status = 'pending'
       and invitation.expires_at <= p_at
    returning invitation.id, invitation.tenant_id
  ), audited as (
    insert into authz.security_audit_events (
      tenant_id,
      event_type,
      target_type,
      target_id,
      allowed,
      source,
      reason_code
    )
    select
      expired.tenant_id,
      'invitation_expired',
      'invitation',
      expired.id,
      true,
      'system_rule'::authz.authorization_source,
      'invitation_expired'
    from expired
    returning 1
  )
  select pg_catalog.count(*) into expired_count from audited;

  return expired_count;
end;
$$;

create or replace function internal.accept_invitation(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_token_digest bytea
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  replay_result uuid;
  invitation public.invitations%rowtype;
  authenticated_email text;
  account_state public.account_status;
  tenant_state public.tenant_status;
  make_primary boolean;
  membership_id uuid;
begin
  if p_idempotency_key is null
     or p_actor_user_id is null
     or p_token_digest is null
     or pg_catalog.octet_length(p_token_digest) <> 32 then
    raise exception using
      errcode = '22023',
      message = 'invitation acceptance input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'invitation command actor does not match the authenticated user';
  end if;

  request_fingerprint := internal.organization_request_fingerprint(
    'accept_invitation',
    pg_catalog.jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'token_digest', pg_catalog.encode(p_token_digest, 'hex')
    )
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  replay_result := internal.organization_replay_result(
    p_idempotency_key,
    'accept_invitation',
    p_actor_user_id,
    request_fingerprint,
    'membership'
  );
  if replay_result is not null then
    return replay_result;
  end if;

  select target.*
    into invitation
    from public.invitations target
   where target.token_digest = p_token_digest
   for update;

  if invitation.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'invitation was not found';
  end if;

  if invitation.status = 'accepted' then
    if invitation.accepted_user_id <> p_actor_user_id then
      raise exception using
        errcode = '23514',
        message = 'invitation has already been accepted';
    end if;

    perform internal.record_organization_command(
      p_idempotency_key,
      'accept_invitation',
      p_actor_user_id,
      invitation.tenant_id,
      request_fingerprint,
      'membership',
      invitation.accepted_membership_id
    );
    return invitation.accepted_membership_id;
  end if;

  if invitation.status <> 'pending' then
    raise exception using
      errcode = '23514',
      message = 'invitation is not pending';
  end if;

  if invitation.expires_at <= pg_catalog.clock_timestamp() then
    raise exception using
      errcode = '23514',
      message = 'invitation has expired';
  end if;

  if invitation.role_key = 'president_team_member' then
    raise exception using
      errcode = '23514',
      message = 'President authority requires the protected presidency transfer command';
  end if;

  select pg_catalog.lower(pg_catalog.btrim(identity.email))
    into authenticated_email
    from auth.users identity
   where identity.id = p_actor_user_id;

  if authenticated_email is null
     or authenticated_email <> pg_catalog.lower(pg_catalog.btrim(invitation.email)) then
    raise exception using
      errcode = '42501',
      message = 'authenticated user does not match the invitation';
  end if;

  select account.status
    into account_state
    from public.user_accounts account
   where account.user_id = p_actor_user_id;

  select tenant.status
    into tenant_state
    from public.tenants tenant
   where tenant.id = invitation.tenant_id;

  if account_state is null or account_state <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'invited account must be active';
  end if;

  if tenant_state is null or tenant_state <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'invitation tenant must be active';
  end if;

  perform internal.lock_membership_subject(invitation.tenant_id, p_actor_user_id);
  perform internal.lock_active_office(invitation.tenant_id, invitation.office_id);
  perform commercial.assert_seat_capacity(invitation.tenant_id, p_actor_user_id);

  select not exists (
    select 1
      from public.memberships current_membership
     where current_membership.tenant_id = invitation.tenant_id
       and current_membership.user_id = p_actor_user_id
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
    invitation.tenant_id,
    p_actor_user_id,
    invitation.office_id,
    invitation.role_key,
    'active',
    make_primary
  )
  returning id into membership_id;

  update public.invitations
     set status = 'accepted',
         accepted_user_id = p_actor_user_id,
         accepted_membership_id = membership_id
   where id = invitation.id;

  perform internal.ensure_wallet_for_member(p_actor_user_id);
  perform internal.bump_membership_authorization_versions(
    invitation.tenant_id,
    p_actor_user_id
  );

  insert into authz.security_audit_events (
    actor_user_id,
    tenant_id,
    event_type,
    target_type,
    target_id,
    allowed,
    source,
    reason_code,
    metadata
  )
  values (
    p_actor_user_id,
    invitation.tenant_id,
    'invitation_accepted',
    'membership',
    membership_id,
    true,
    'system_rule',
    'valid_invitation',
    pg_catalog.jsonb_build_object(
      'invitation_id', invitation.id,
      'office_id', invitation.office_id,
      'role_key', invitation.role_key::text,
      'is_primary', make_primary
    )
  );

  perform internal.record_organization_command(
    p_idempotency_key,
    'accept_invitation',
    p_actor_user_id,
    invitation.tenant_id,
    request_fingerprint,
    'membership',
    membership_id
  );

  return membership_id;
end;
$$;

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
