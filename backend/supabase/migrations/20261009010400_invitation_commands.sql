-- Blueprint 03 — B4: invitation commands and reads called by the `invitations`
-- Edge Function. Order in every command: session gate (step-up where
-- required) → workspace → authorization → idempotent replay → state checks →
-- effects, so replays re-check current authority (A-01).
--
-- Lock order (extends Blueprint 02): people → office tree (not here) →
-- tenant/office rows FOR NO KEY UPDATE → invitation row FOR UPDATE → seats
-- (hook) → membership rows → wallet hook (last). Create, reissue and revoke
-- lock at most the invitation row.

create function org.invitation_role_label(p_role org.role)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_role
    when 'member' then 'Member'
    when 'team_leader' then 'Team Leader'
    when 'director' then 'Director'
    when 'world_team_member' then 'World Team Member'
    else 'President Team Member'
  end;
$$;

create function org.clean_email(p_email text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  cleaned text := lower(btrim(p_email));
begin
  if cleaned is null or length(cleaned) not between 3 and 254
    or cleaned !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'email'));
  end if;
  return cleaned;
end;
$$;

create function org.invitation_in_tenant(p_tenant_id uuid, p_invitation_id uuid)
returns org.invitations
language plpgsql
set search_path = ''
as $$
declare
  invitation org.invitations;
begin
  select * into invitation from org.invitations where id = p_invitation_id and tenant_id = p_tenant_id;
  if invitation.id is null then
    perform identity.fail('not_found');
  end if;
  return invitation;
end;
$$;

create function org.invitation_role(p_role text)
returns org.role
language plpgsql
set search_path = ''
as $$
begin
  if p_role is null or p_role not in ('member', 'team_leader', 'director', 'world_team_member', 'president_team_member') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'role'));
  end if;
  return p_role::org.role;
end;
$$;

-- Queues the invitation email for the invitation's current link.
create function org.enqueue_invitation_email(p_invitation org.invitations)
returns uuid
language sql
set search_path = ''
as $$
  select outbox.enqueue_email(
    'invitation.issued',
    'invitation.issued:' || p_invitation.id::text || ':' || p_invitation.issue_count::text,
    'invitation',
    p_invitation.id,
    p_invitation.tenant_id,
    null,
    p_invitation.email,
    jsonb_build_object(
      'network', t.name,
      'office', o.name,
      'role', org.invitation_role_label(p_invitation.role),
      'reference', p_invitation.reference,
      'expiresAt', to_char(p_invitation.expires_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    )
  )
  from org.tenants t, org.offices o
  where t.id = p_invitation.tenant_id and o.id = p_invitation.office_id;
$$;

-- Email delivery as leaders see it, for the invitation's current link.
create function org.invitation_delivery(p_invitation org.invitations)
returns text
language sql
stable
set search_path = ''
as $$
  select case d.status
    when 'sent' then 'sent'
    when 'dead_lettered' then 'failed'
    when 'skipped' then null
    else 'waiting'
  end
  from outbox.events e
  join outbox.deliveries d on d.event_id = e.id
  where e.dedupe_key = 'invitation.issued:' || p_invitation.id::text || ':' || p_invitation.issue_count::text;
$$;

-- ── Leader commands ───────────────────────────────────────────────────────

create function api.create_invitation(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_office_id uuid,
  p_role text,
  p_email text,
  p_token_id uuid,
  p_token_digest text,
  p_reason text,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  office org.offices;
  invite_role org.role;
  clean_email text;
  clean_reason text;
  digest bytea;
  request jsonb;
  replayed jsonb;
  invitation org.invitations;
begin
  perform org.require_writer(p_user_id, p_session_id, p_role is distinct from 'member');
  workspace := org.change_workspace(p_user_id, p_membership_id);
  office := org.office_in_tenant(workspace.tenant_id, p_office_id);
  invite_role := org.invitation_role(p_role);
  perform org.require_invite_authority(p_user_id, workspace, office, invite_role);

  clean_email := org.clean_email(p_email);
  if clean_email = (select lower(btrim(email)) from auth.users where id = p_user_id) then
    perform identity.fail('self_target_forbidden');
  end if;
  if invite_role <> 'member' or p_reason is not null then
    clean_reason := identity.require_reason(p_reason);
  end if;
  digest := org.token_digest(p_token_digest);
  if p_token_id is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'token'));
  end if;

  -- The server-generated token is not part of the request fingerprint, so a
  -- retried create keeps the first commit's link.
  request := jsonb_build_object('membershipId', workspace.id, 'officeId', office.id, 'role', invite_role,
    'email', clean_email, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'create_invitation', request);
  if replayed is not null then
    return replayed;
  end if;

  if (select count(*) from org.invitation_events
      where actor_user_id = p_user_id and action = 'created' and at > now() - interval '1 hour')
     >= org.invitation_hourly_cap() then
    perform identity.fail('rate_limited', jsonb_build_object('retryAfterSeconds', 3600));
  end if;

  -- An overdue invitation for the same place no longer blocks a new one.
  for invitation in
    select * from org.invitations
    where tenant_id = workspace.tenant_id and office_id = office.id and role = invite_role
      and email = clean_email and status = 'pending' and expires_at <= now()
    for update
  loop
    update org.invitations set status = 'expired' where id = invitation.id;
    perform org.record_invitation_event(invitation, 'expired', null);
  end loop;

  begin
    insert into org.invitations (
      reference, tenant_id, office_id, role, email, expires_at, token_id, token_digest,
      invited_by, inviter_membership_id, reason
    ) values (
      refs.issue('INV'), workspace.tenant_id, office.id, invite_role, clean_email,
      now() + org.invitation_ttl(), p_token_id, digest, p_user_id, workspace.id, clean_reason
    )
    returning * into invitation;
  exception when unique_violation then
    perform identity.fail('invitation_exists');
  end;

  perform org.record_invitation_event(invitation, 'created', p_user_id, clean_reason);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'invitation.created', 'invitation', invitation.id::text,
    clean_reason, p_safe_after => jsonb_build_object('reference', invitation.reference, 'officeId', office.id,
      'role', invite_role), p_request_id => p_request_id);
  perform org.enqueue_invitation_email(invitation);

  return identity.store_result(p_user_id, p_idempotency_key, 'create_invitation', request,
    jsonb_build_object('invitationId', invitation.id, 'reference', invitation.reference,
      'status', invitation.status, 'expiresAt', invitation.expires_at));
end;
$$;

create function api.reissue_invitation(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_invitation_id uuid,
  p_token_id uuid,
  p_token_digest text,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  invitation org.invitations;
  office org.offices;
  digest bytea;
  request jsonb;
  replayed jsonb;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  invitation := org.invitation_in_tenant(workspace.tenant_id, p_invitation_id);
  if invitation.role <> 'member' then
    perform identity.require_session(p_user_id, p_session_id, p_step_up => true);
  end if;
  office := org.office_in_tenant(workspace.tenant_id, invitation.office_id);
  perform org.require_invite_authority(p_user_id, workspace, office, invitation.role);
  digest := org.token_digest(p_token_digest);
  if p_token_id is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'token'));
  end if;

  request := jsonb_build_object('membershipId', workspace.id, 'invitationId', invitation.id);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'reissue_invitation', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into invitation from org.invitations where id = invitation.id for update;
  if org.invitation_effective_status(invitation) <> 'pending' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'not_pending'));
  end if;
  if invitation.issue_count >= org.invitation_max_issues() then
    perform identity.fail('conflict', jsonb_build_object('reason', 'reissue_limit'));
  end if;
  if invitation.last_issued_at > now() - org.invitation_reissue_cooldown() then
    perform identity.fail('rate_limited', jsonb_build_object('retryAfterSeconds',
      ceil(extract(epoch from invitation.last_issued_at + org.invitation_reissue_cooldown() - now()))::int));
  end if;

  update org.invitations
  set token_id = p_token_id, token_digest = digest, expires_at = now() + org.invitation_ttl(),
      issue_count = issue_count + 1, last_issued_at = now()
  where id = invitation.id
  returning * into invitation;

  perform org.record_invitation_event(invitation, 'reissued', p_user_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'invitation.reissued', 'invitation', invitation.id::text,
    p_safe_after => jsonb_build_object('reference', invitation.reference, 'issueCount', invitation.issue_count),
    p_request_id => p_request_id);
  perform org.enqueue_invitation_email(invitation);

  return identity.store_result(p_user_id, p_idempotency_key, 'reissue_invitation', request,
    jsonb_build_object('invitationId', invitation.id, 'reference', invitation.reference, 'status', invitation.status,
      'expiresAt', invitation.expires_at, 'issueCount', invitation.issue_count));
end;
$$;

create function api.revoke_invitation(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_invitation_id uuid,
  p_reason text,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  invitation org.invitations;
  office org.offices;
  clean_reason text;
  request jsonb;
  replayed jsonb;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  invitation := org.invitation_in_tenant(workspace.tenant_id, p_invitation_id);
  office := org.office_in_tenant(workspace.tenant_id, invitation.office_id);
  perform org.require_invite_authority(p_user_id, workspace, office, invitation.role);
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('membershipId', workspace.id, 'invitationId', invitation.id, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'revoke_invitation', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into invitation from org.invitations where id = invitation.id for update;
  if invitation.status = 'revoked' then
    return identity.store_result(p_user_id, p_idempotency_key, 'revoke_invitation', request,
      jsonb_build_object('invitationId', invitation.id, 'status', 'revoked', 'changed', false));
  end if;
  if org.invitation_effective_status(invitation) <> 'pending' then
    perform identity.fail('conflict', jsonb_build_object('reason',
      case when invitation.status = 'accepted' then 'accepted' else 'not_pending' end));
  end if;

  update org.invitations
  set status = 'revoked', revoked_at = now(), revoked_by = p_user_id, revoke_reason = clean_reason
  where id = invitation.id;
  perform org.record_invitation_event(invitation, 'revoked', p_user_id, clean_reason);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'invitation.revoked', 'invitation', invitation.id::text,
    clean_reason, jsonb_build_object('status', 'pending'), jsonb_build_object('status', 'revoked'), p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'revoke_invitation', request,
    jsonb_build_object('invitationId', invitation.id, 'status', 'revoked', 'changed', true));
end;
$$;

create function api.list_invitations(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_office_id uuid default null,
  p_status text default null,
  p_cursor text default null,
  p_limit int default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  scope_office_id uuid;
  page_size int;
  after jsonb;
  rows jsonb;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  scope_office_id := coalesce(p_office_id, workspace.office_id);
  if scope_office_id is not null then
    perform org.office_in_tenant(workspace.tenant_id, scope_office_id);
  end if;
  perform authz.require(p_user_id, 'invite_members', workspace.tenant_id, scope_office_id, null, workspace.id);
  if p_status is not null and p_status not in ('pending', 'accepted', 'expired', 'revoked') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'status'));
  end if;
  page_size := org.page_limit(p_limit);
  after := org.decode_cursor(p_cursor);

  select coalesce(jsonb_agg(item order by item->>'createdAt' desc, item->>'invitationId' desc), '[]'::jsonb) into rows
  from (
    select jsonb_build_object(
      'invitationId', i.id,
      'reference', i.reference,
      'email', i.email,
      'officeId', i.office_id,
      'officeName', o.name,
      'role', i.role,
      'status', org.invitation_effective_status(i),
      'expiresAt', i.expires_at,
      'invitedBy', org.person(i.invited_by),
      'issueCount', i.issue_count,
      'delivery', case when org.invitation_effective_status(i) = 'pending' then org.invitation_delivery(i) end,
      'createdAt', to_char(i.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'acceptedAt', i.accepted_at,
      'revokedAt', i.revoked_at
    ) as item
    from org.invitations i
    join org.offices o on o.id = i.office_id
    where i.tenant_id = workspace.tenant_id
      and (scope_office_id is null or exists (
        select 1 from org.office_closure c where c.ancestor_id = scope_office_id and c.descendant_id = i.office_id))
      and (p_status is null or org.invitation_effective_status(i) = p_status::org.invitation_status)
      and (authz.decide(p_user_id, 'invite_members', workspace.tenant_id, i.office_id, null, workspace.id)->>'allowed')::boolean
      and (after is null or (to_char(i.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), i.id::text)
                            < (after->>'c', after->>'id'))
    order by i.created_at desc, i.id desc
    limit page_size + 1
  ) page;

  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(e) from jsonb_array_elements(rows) with ordinality as x (e, n) where n <= page_size), '[]'::jsonb),
    'nextCursor', case when jsonb_array_length(rows) > page_size
      then org.encode_cursor(jsonb_build_object('c', rows->(page_size - 1)->>'createdAt', 'id', rows->(page_size - 1)->>'invitationId'))
    end
  );
end;
$$;

-- ── Invitee reads and commands ────────────────────────────────────────────

-- W-02 step 1 (no session): the bound email only. Every failure looks the same.
create function api.invitation_preview(p_token_digest text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation org.invitations;
begin
  invitation := org.live_invitation_by_digest(org.token_digest(p_token_digest));
  if invitation.id is null then
    perform identity.fail('invitation_unavailable');
  end if;
  return jsonb_build_object('email', invitation.email);
end;
$$;

-- W-02 step 3 (no session): returns the bound email so the Edge Function can
-- ask Auth to send the sign-in email. 60 s cooldown, 5 per 24 h per invitation.
create function api.request_invitation_verification(p_token_digest text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation org.invitations;
  last_requested timestamptz;
begin
  invitation := org.live_invitation_by_digest(org.token_digest(p_token_digest));
  if invitation.id is null then
    perform identity.fail('invitation_unavailable');
  end if;

  perform 1 from org.invitations where id = invitation.id for update;
  select max(requested_at) into last_requested from org.invitation_verifications where invitation_id = invitation.id;
  if last_requested > now() - interval '60 seconds' then
    perform identity.fail('rate_limited', jsonb_build_object('retryAfterSeconds',
      ceil(extract(epoch from last_requested + interval '60 seconds' - now()))::int));
  end if;
  if (select count(*) from org.invitation_verifications
      where invitation_id = invitation.id and requested_at > now() - interval '24 hours') >= 5 then
    perform identity.fail('rate_limited', jsonb_build_object('retryAfterSeconds', 3600));
  end if;

  insert into org.invitation_verifications (invitation_id) values (invitation.id);
  return jsonb_build_object('email', invitation.email);
end;
$$;

-- Owner decision 8: pending invitations for the signed-in person's verified email.
create function api.my_invitations(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  account_email text;
begin
  account_email := org.require_join_session(p_user_id, p_session_id);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'invitationId', i.id,
      'reference', i.reference,
      'tenantName', t.name,
      'officeName', o.name,
      'role', i.role,
      'expiresAt', i.expires_at
    ) order by i.created_at, i.id)
    from org.invitations i
    join org.tenants t on t.id = i.tenant_id
    join org.offices o on o.id = i.office_id
    where i.email = account_email and i.status = 'pending' and i.expires_at > now()
      and t.status = 'active' and o.status = 'active' and i.invited_by <> p_user_id
  ), '[]'::jsonb);
end;
$$;

-- W-02/W-03: joins with exactly the office and role the invitation names.
-- Allowed at gate `pin_setup_required` (owner decision 7). Exactly one of the
-- link token digest or (owner decision 8) the invitation id.
create function api.accept_invitation(
  p_user_id uuid,
  p_session_id uuid,
  p_token_digest text,
  p_invitation_id uuid,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  account_email text;
  invitation org.invitations;
  request jsonb;
  replayed jsonb;
  created org.memberships;
begin
  if (p_token_digest is null) = (p_invitation_id is null) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'token'));
  end if;
  account_email := org.require_join_session(p_user_id, p_session_id);

  if p_token_digest is not null then
    select * into invitation from org.invitations where token_digest = org.token_digest(p_token_digest);
  else
    select * into invitation from org.invitations where id = p_invitation_id;
  end if;
  if invitation.id is null
    or (invitation.status = 'accepted' and invitation.accepted_user_id <> p_user_id) then
    perform identity.fail('invitation_unavailable');
  end if;
  if invitation.email <> account_email then
    if p_token_digest is null then
      perform identity.fail('invitation_unavailable');
    end if;
    perform identity.fail('invitation_email_mismatch');
  end if;
  if invitation.invited_by = p_user_id then
    perform identity.fail('self_target_forbidden');
  end if;

  request := jsonb_build_object('invitationId', invitation.id);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'accept_invitation', request);
  if replayed is not null then
    return replayed;
  end if;

  -- Already accepted by this person (e.g. another device): same result.
  if invitation.status = 'accepted' then
    return identity.store_result(p_user_id, p_idempotency_key, 'accept_invitation', request,
      (select jsonb_build_object('invitationId', invitation.id, 'membershipId', m.id, 'tenantId', m.tenant_id,
         'officeId', m.office_id, 'role', m.role, 'isPrimary', m.is_primary)
       from org.memberships m where m.id = invitation.accepted_membership_id));
  end if;

  perform org.lock_person(invitation.tenant_id, p_user_id);
  perform 1 from org.offices where id = invitation.office_id for no key update;
  select * into invitation from org.invitations where id = invitation.id for update;
  if org.invitation_effective_status(invitation) <> 'pending'
    or (select status from org.tenants where id = invitation.tenant_id) <> 'active'
    or (select status from org.offices where id = invitation.office_id) <> 'active' then
    perform identity.fail('invitation_unavailable');
  end if;

  created := org.create_membership(invitation.tenant_id, invitation.office_id, p_user_id, invitation.role, p_user_id);

  update org.invitations
  set status = 'accepted', accepted_at = now(), accepted_user_id = p_user_id, accepted_membership_id = created.id
  where id = invitation.id;
  perform org.record_invitation_event(invitation, 'accepted', p_user_id);
  perform org.bump_authz_version(invitation.tenant_id);
  perform audit.record_tenant(invitation.tenant_id, p_user_id, 'invitation.accepted', 'invitation', invitation.id::text,
    p_safe_after => jsonb_build_object('reference', invitation.reference, 'membershipId', created.id,
      'officeId', created.office_id, 'role', created.role), p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'accept_invitation', request,
    jsonb_build_object('invitationId', invitation.id, 'membershipId', created.id, 'tenantId', created.tenant_id,
      'officeId', created.office_id, 'role', created.role, 'isPrimary', created.is_primary));
end;
$$;

-- ── Privileges ────────────────────────────────────────────────────────────

do $$
declare
  fn regprocedure;
begin
  for fn in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end;
$$;
