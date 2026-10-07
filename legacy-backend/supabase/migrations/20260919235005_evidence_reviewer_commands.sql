create or replace function authz.authorize_financial_evidence_review(
  p_actor_user_id uuid,
  p_session_id uuid,
  p_target_tenant_id uuid,
  p_target_office_id uuid,
  p_target_membership_id uuid,
  p_target_user_id uuid,
  p_target_wallet_id uuid,
  p_action_key text
)
returns authz.authorization_decision
language plpgsql
security invoker
set search_path = ''
as $$
declare
  base_decision authz.authorization_decision;
  reviewer_assignment_id uuid;
begin
  base_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'review_financial_evidence',
    p_target_tenant_id,
    p_target_office_id,
    p_target_membership_id,
    p_target_user_id,
    p_target_wallet_id,
    p_target_user_id,
    p_action_key,
    null
  );

  -- Preserve global, tenant, membership, scope, and explicit-deny results.
  if base_decision.decision = 'DENY'
     and base_decision.reason_code <> 'no_matching_allow' then
    return base_decision;
  end if;

  select assignment.id
    into reviewer_assignment_id
    from authz.financial_evidence_reviewer_assignments assignment
    join public.memberships membership
      on membership.tenant_id = assignment.tenant_id
     and membership.id = assignment.reviewer_membership_id
     and membership.user_id = assignment.reviewer_user_id
   where assignment.tenant_id = p_target_tenant_id
     and assignment.reviewer_user_id = p_actor_user_id
     and assignment.revoked_at is null
     and membership.status = 'active'
   order by assignment.assigned_at desc
   limit 1;

  if reviewer_assignment_id is null then
    return (
      'DENY',
      'review_financial_evidence',
      p_actor_user_id,
      p_target_tenant_id,
      p_target_office_id,
      p_target_membership_id,
      p_target_user_id,
      p_target_wallet_id,
      'default_deny',
      null,
      'reviewer_assignment_required',
      'none',
      0
    )::authz.authorization_decision;
  end if;

  return (
    'ALLOW',
    'review_financial_evidence',
    p_actor_user_id,
    p_target_tenant_id,
    p_target_office_id,
    p_target_membership_id,
    p_target_user_id,
    p_target_wallet_id,
    'explicit_grant',
    reviewer_assignment_id,
    'matched_financial_evidence_reviewer_assignment',
    'none',
    0
  )::authz.authorization_decision;
end;
$$;

create or replace function authz.configure_financial_evidence_reviewer(
  p_tenant_id uuid,
  p_reviewer_membership_id uuid,
  p_enabled boolean,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  reviewer_membership public.memberships%rowtype;
  authorization_decision authz.authorization_decision;
  target_assignment authz.financial_evidence_reviewer_assignments%rowtype;
  event_name text;
begin
  if p_tenant_id is null
     or p_reviewer_membership_id is null
     or p_enabled is null
     or p_actor_user_id is null then
    raise exception using
      errcode = '22023',
      message = 'financial evidence reviewer configuration input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'reviewer configuration actor does not match the authenticated user';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      p_tenant_id::text || ':' || p_reviewer_membership_id::text,
      0
    )
  );

  select *
    into reviewer_membership
    from public.memberships membership
   where membership.tenant_id = p_tenant_id
     and membership.id = p_reviewer_membership_id
   for update;

  if reviewer_membership.id is null
     or reviewer_membership.status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'financial evidence reviewer requires an active tenant membership';
  end if;

  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'manage_role_permissions',
    p_tenant_id,
    reviewer_membership.office_id,
    reviewer_membership.id,
    reviewer_membership.user_id,
    null,
    null,
    'configure_financial_evidence_reviewer',
    null
  );

  if authorization_decision.decision = 'STEP_UP_REQUIRED' then
    raise exception using
      errcode = '42501',
      message = 'financial evidence reviewer configuration requires fresh authorization';
  end if;

  if authorization_decision.decision <> 'ALLOW' then
    raise exception using
      errcode = '42501',
      message = 'financial evidence reviewer configuration is not authorized';
  end if;

  select *
    into target_assignment
    from authz.financial_evidence_reviewer_assignments assignment
   where assignment.tenant_id = p_tenant_id
     and assignment.reviewer_membership_id = p_reviewer_membership_id
     and assignment.revoked_at is null
   for update;

  if p_enabled and target_assignment.id is not null then
    return target_assignment.id;
  end if;

  if not p_enabled and target_assignment.id is null then
    return null;
  end if;

  if p_enabled then
    insert into authz.financial_evidence_reviewer_assignments (
      tenant_id,
      reviewer_membership_id,
      reviewer_user_id,
      assigned_by_user_id
    )
    values (
      p_tenant_id,
      reviewer_membership.id,
      reviewer_membership.user_id,
      p_actor_user_id
    )
    returning * into target_assignment;

    event_name := 'financial_evidence_reviewer_assigned';
  else
    perform set_config(
      'authz.reviewer_assignment_transition',
      target_assignment.id::text,
      true
    );

    update authz.financial_evidence_reviewer_assignments
       set revoked_by_user_id = p_actor_user_id,
           revoked_at = clock_timestamp()
     where id = target_assignment.id
    returning * into target_assignment;

    perform set_config('authz.reviewer_assignment_transition', '', true);
    event_name := 'financial_evidence_reviewer_revoked';
  end if;

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
    event_name,
    authorization_decision.permission_key,
    'membership',
    reviewer_membership.id,
    true,
    authorization_decision.source,
    authorization_decision.source_id,
    authorization_decision.reason_code,
    jsonb_build_object('assignment_id', target_assignment.id)
  );

  insert into internal.outbox_events (
    tenant_id,
    aggregate_type,
    aggregate_id,
    event_type,
    payload
  )
  values (
    p_tenant_id,
    'financial_evidence_reviewer_assignment',
    target_assignment.id,
    event_name,
    jsonb_build_object(
      'assignment_id', target_assignment.id,
      'reviewer_membership_id', reviewer_membership.id,
      'reviewer_user_id', reviewer_membership.user_id
    )
  );

  return target_assignment.id;
end;
$$;

revoke all on function authz.authorize_financial_evidence_review(
  uuid, uuid, uuid, uuid, uuid, uuid, uuid, text
) from public, anon, authenticated, service_role;

revoke all on function authz.configure_financial_evidence_reviewer(
  uuid, uuid, boolean, uuid, uuid
) from public, anon, authenticated, service_role;
