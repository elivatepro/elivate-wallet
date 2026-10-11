-- Blueprint 27 — B1: the person picker and leaders invited by email.
--
-- Owner decisions 2026-10-11 (W-03/W-05):
-- - Forms that name a person (new office leader, add/replace leader, access
--   rules, President Team) find them by name among the network's people, or
--   by an exact UID or full email address among all accounts (no browsing).
-- - New office may name its leader by email when they have no account: the
--   office is created now and waits for its leader; a leader invitation goes
--   out (reason filled in) and accepting it makes them the leader.
-- - Replace leader by email: the current leader stays until the invitation is
--   accepted; the replacement happens then. If it lapses, nothing changes.
-- - A waiting office whose invitation lapses keeps waiting.
-- - "An active office keeps at least one leader" now reads "an office that
--   has had a leader keeps one": a waiting office has none yet.

alter table org.invitations
  add column replaces_membership_id uuid references org.memberships (id) on delete restrict;
create index invitations_replaces_idx on org.invitations (replaces_membership_id)
  where replaces_membership_id is not null;

create or replace function org.assert_leader_remains(p_office_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  office org.offices;
begin
  select * into office from org.offices where id = p_office_id;
  if office.status = 'active' and not exists (
    select 1 from org.memberships
    where office_id = p_office_id and role = org.leader_role(office.office_type) and status = 'active'
  ) and exists (
    -- Only an office that has had a leader: one still waiting has none to keep.
    select 1 from org.memberships
    where office_id = p_office_id and role = org.leader_role(office.office_type)
  ) then
    perform identity.fail('last_leader');
  end if;
end;
$$;

-- ── Find people (GET /org/people?q=) ──────────────────────────────────────
--
-- For leadership workspaces and members who manage access rules. `q` is one of:
-- - a UID: that account, wherever it is;
-- - a full email address: that account, or `noAccount` when there is none;
-- - otherwise 2–100 characters of a name, matched only among the people the
--   workspace can see in this network (active and suspended memberships).
-- Items: { uid, name, inNetwork, role, officeName } (role/office: their
-- primary visible membership here; null outside the network). At most 8.
create function api.find_people(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_query text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  q text := btrim(coalesce(p_query, ''));
  found uuid;
  people uuid[];
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform org.require_readable_tenant(workspace.tenant_id);
  -- Leadership workspaces, and members granted access-rule management (the
  -- Access page names people too); names still stay within what they see.
  if workspace.role = 'member' and not coalesce((authz.decide(p_user_id, 'manage_access_rules',
      workspace.tenant_id, workspace.office_id, null, workspace.id)->>'allowed')::boolean, false) then
    perform identity.fail('authorization_denied');
  end if;
  if length(q) < 2 or length(q) > 254 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'q'));
  end if;

  if q ~* '^EW-[1-9][0-9]{4,}$' then
    select user_id into found from identity.accounts where uid = upper(q);
    people := case when found is null then '{}'::uuid[] else array[found] end;
  elsif q ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    select id into found from auth.users where lower(btrim(email)) = lower(q);
    if found is null then
      return jsonb_build_object('items', '[]'::jsonb, 'noAccount', true);
    end if;
    people := array[found];
  else
    if length(q) > 100 then
      perform identity.fail('validation_error', jsonb_build_object('field', 'q'));
    end if;
    select coalesce(array_agg(x.user_id order by x.name, x.user_id), '{}'::uuid[]) into people from (
      select distinct m.user_id, coalesce(nullif(btrim(p.display_name), ''),
          btrim(concat_ws(' ', p.first_name, p.last_name))) as name
      from org.memberships m
      join identity.profiles p on p.user_id = m.user_id
      where m.tenant_id = workspace.tenant_id and m.status in ('active', 'suspended')
        and (case when m.office_id is null then workspace.office_id is null
             else org.office_visible(workspace, m.office_id) end)
        and concat_ws(' ', p.display_name, p.first_name, p.last_name)
            ilike '%' || replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%'
      order by 2, 1
      limit 8
    ) x;
  end if;

  return jsonb_build_object('noAccount', false, 'items', coalesce((
    select jsonb_agg(org.person(u) || jsonb_build_object(
      'inNetwork', here.id is not null,
      'role', here.role,
      'officeName', (select o.name from org.offices o where o.id = here.office_id)
    ) order by n)
    from unnest(people) with ordinality as x (u, n)
    left join lateral (
      select m.id, m.role, m.office_id from org.memberships m
      where m.tenant_id = workspace.tenant_id and m.user_id = u and m.status in ('active', 'suspended')
        and (case when m.office_id is null then workspace.office_id is null
             else org.office_visible(workspace, m.office_id) end)
      order by m.is_primary desc, m.started_at, m.id
      limit 1
    ) here on true
  ), '[]'::jsonb));
end;
$$;

-- The invitation itself (rate limit, overdue clean-up, insert, event, audit,
-- email), shared by api.create_invitation and api.create_office_inviting_leader.
create function org.issue_invitation(
  p_workspace org.memberships,
  p_office_id uuid,
  p_role org.role,
  p_email text,
  p_token_id uuid,
  p_digest bytea,
  p_reason text,
  p_actor_user_id uuid,
  p_request_id text,
  p_replaces_membership_id uuid default null
)
returns org.invitations
language plpgsql
set search_path = ''
as $$
declare
  invitation org.invitations;
begin
  if (select count(*) from org.invitation_events
      where actor_user_id = p_actor_user_id and action = 'created' and at > now() - interval '1 hour')
     >= org.invitation_hourly_cap() then
    perform identity.fail('rate_limited', jsonb_build_object('retryAfterSeconds', 3600));
  end if;

  -- An overdue invitation for the same place no longer blocks a new one.
  for invitation in
    select * from org.invitations
    where tenant_id = p_workspace.tenant_id and office_id = p_office_id and role = p_role
      and email = p_email and status = 'pending' and expires_at <= now()
    for update
  loop
    update org.invitations set status = 'expired' where id = invitation.id;
    perform org.record_invitation_event(invitation, 'expired', null);
  end loop;

  begin
    insert into org.invitations (
      reference, tenant_id, office_id, role, email, expires_at, token_id, token_digest,
      invited_by, inviter_membership_id, reason, replaces_membership_id
    ) values (
      refs.issue('INV'), p_workspace.tenant_id, p_office_id, p_role, p_email,
      now() + org.invitation_ttl(), p_token_id, p_digest, p_actor_user_id, p_workspace.id, p_reason, p_replaces_membership_id
    )
    returning * into invitation;
  exception when unique_violation then
    perform identity.fail('invitation_exists');
  end;

  perform org.record_invitation_event(invitation, 'created', p_actor_user_id, p_reason);
  perform audit.record_tenant(p_workspace.tenant_id, p_actor_user_id, 'invitation.created', 'invitation', invitation.id::text,
    p_reason, p_safe_after => jsonb_build_object('reference', invitation.reference, 'officeId', p_office_id,
      'role', p_role), p_request_id => p_request_id);
  perform org.enqueue_invitation_email(invitation);
  return invitation;
end;
$$;

drop function api.create_invitation(uuid, uuid, uuid, uuid, text, text, uuid, text, text, text, text);

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
  p_request_id text default null,
  p_replaces_membership_id uuid default null
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
  outgoing org.memberships;
begin
  perform org.require_writer(p_user_id, p_session_id, p_role is distinct from 'member');
  workspace := org.change_workspace(p_user_id, p_membership_id);
  office := org.office_in_tenant(workspace.tenant_id, p_office_id);
  invite_role := org.invitation_role(p_role);
  perform org.require_invite_authority(p_user_id, workspace, office, invite_role);
  -- Blueprint 27: a leader invitation may replace a current leader of the
  -- office; the replacement happens when it is accepted (W-05 replacement rule).
  if p_replaces_membership_id is not null then
    outgoing := org.membership_in_tenant(workspace.tenant_id, p_replaces_membership_id);
    if invite_role = 'member' or outgoing.office_id is distinct from office.id or outgoing.role <> invite_role
       or outgoing.status = 'ended' then
      perform identity.fail('validation_error', jsonb_build_object('field', 'replacesMembershipId'));
    end if;
    perform authz.require(p_user_id, 'manage_members', workspace.tenant_id, office.id, outgoing.user_id, workspace.id);
  end if;

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
    'email', clean_email, 'reason', clean_reason,
    'replacesMembershipId', p_replaces_membership_id);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'create_invitation', request);
  if replayed is not null then
    return replayed;
  end if;

  invitation := org.issue_invitation(workspace, office.id, invite_role, clean_email, p_token_id, digest,
    clean_reason, p_user_id, p_request_id, p_replaces_membership_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'create_invitation', request,
    jsonb_build_object('invitationId', invitation.id, 'reference', invitation.reference,
      'status', invitation.status, 'expiresAt', invitation.expires_at));
end;
$$;

create or replace function api.accept_invitation(
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
  outgoing org.memberships;
  existing record;
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

  if invitation.replaces_membership_id is not null then
    perform org.lock_people(invitation.tenant_id, array[p_user_id,
      (select m.user_id from org.memberships m where m.id = invitation.replaces_membership_id)]);
  else
    perform org.lock_person(invitation.tenant_id, p_user_id);
  end if;
  perform 1 from org.offices where id = invitation.office_id for no key update;
  select * into invitation from org.invitations where id = invitation.id for update;

  -- Already accepted by this person (another device, possibly at the same
  -- moment): the same result, checked under the lock.
  if invitation.status = 'accepted' and invitation.accepted_user_id = p_user_id then
    return identity.store_result(p_user_id, p_idempotency_key, 'accept_invitation', request,
      (select jsonb_build_object('invitationId', invitation.id, 'membershipId', m.id, 'tenantId', m.tenant_id,
         'officeId', m.office_id, 'role', m.role, 'isPrimary', m.is_primary)
       from org.memberships m where m.id = invitation.accepted_membership_id));
  end if;
  -- Re-validated under the lock; a link replaced by a concurrent reissue no
  -- longer works.
  if org.invitation_effective_status(invitation) <> 'pending'
    or (p_token_digest is not null and invitation.token_digest <> org.token_digest(p_token_digest))
    or (select status from org.tenants where id = invitation.tenant_id) <> 'active'
    or (select status from org.offices where id = invitation.office_id) <> 'active' then
    perform identity.fail('invitation_unavailable');
  end if;

  if invitation.replaces_membership_id is not null then
    for existing in
      select id from org.memberships
      where office_id = invitation.office_id and user_id = p_user_id and status <> 'ended'
    loop
      perform org.end_membership(existing.id, invitation.reason, invitation.invited_by);
      perform org.end_reviewer_for(existing.id, invitation.reason, invitation.invited_by, p_request_id);
    end loop;
  end if;

  created := org.create_membership(invitation.tenant_id, invitation.office_id, p_user_id, invitation.role, p_user_id);

  -- Blueprint 27: the incoming leader replaces the outgoing one, if that
  -- leader still holds the office; otherwise they simply join as a leader.
  if invitation.replaces_membership_id is not null then
    select * into outgoing from org.memberships where id = invitation.replaces_membership_id for update;
    if outgoing.status <> 'ended' and outgoing.office_id = invitation.office_id and outgoing.role = invitation.role
       and outgoing.user_id <> p_user_id then
      perform org.end_membership(outgoing.id, invitation.reason, invitation.invited_by, 'replaced', created.id);
      perform org.end_reviewer_for(outgoing.id, invitation.reason, invitation.invited_by, p_request_id);
      perform org.ensure_primary(invitation.tenant_id, outgoing.user_id);
      perform org.ensure_primary(invitation.tenant_id, p_user_id);
      perform audit.record_tenant(invitation.tenant_id, invitation.invited_by, 'office.leader_replaced', 'office',
        invitation.office_id::text, invitation.reason, jsonb_build_object('membershipId', outgoing.id),
        jsonb_build_object('membershipId', created.id), p_request_id);
    end if;
  end if;

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

create or replace function api.office_detail(p_user_id uuid, p_session_id uuid, p_membership_id uuid, p_office_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  office org.offices;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  office := org.office_in_tenant(workspace.tenant_id, p_office_id);
  if not org.office_visible(workspace, office.id) then
    perform identity.fail('not_found');
  end if;

  return jsonb_build_object(
    'id', office.id,
    'name', office.name,
    'type', office.office_type,
    'status', office.status,
    'parentOfficeId', office.parent_office_id,
    'createdAt', office.created_at,
    'leaders', org.office_leaders(office.id),
    -- Blueprint 27: leader invitations still open (the office waits for its
    -- leader, or a replacement waits to be accepted). Emails only for those
    -- who may invite into the office (null for others: not shown, not "none").
    'pendingLeaders', case when (authz.decide(p_user_id, 'invite_members', workspace.tenant_id, office.id, null,
        workspace.id)->>'allowed')::boolean then coalesce((
      select jsonb_agg(jsonb_build_object(
        'invitationId', i.id, 'email', i.email, 'expiresAt', i.expires_at,
        'replaces', case when i.replaces_membership_id is not null then
          (select org.person(m.user_id) from org.memberships m where m.id = i.replaces_membership_id) end
      ) order by i.created_at, i.id)
      from org.invitations i
      where i.office_id = office.id and i.role = org.leader_role(office.office_type)
        and i.status = 'pending' and i.expires_at > now()
    ), '[]'::jsonb) end,
    -- Root first, the office itself last.
    'path', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'type', a.office_type) order by c.depth desc)
      from org.office_closure c join org.offices a on a.id = c.ancestor_id
      where c.descendant_id = office.id
    ), '[]'::jsonb),
    'children', coalesce((
      select jsonb_agg(jsonb_build_object('id', ch.id, 'name', ch.name, 'type', ch.office_type) order by ch.name, ch.id)
      from org.offices ch where ch.parent_office_id = office.id and ch.status = 'active'
    ), '[]'::jsonb),
    'memberCount', (select count(distinct l.user_id) from org.office_closure c
                    join org.memberships l on l.office_id = c.descendant_id
                    where c.ancestor_id = office.id and l.status = 'active'),
    'ownMemberCount', (select count(distinct l.user_id) from org.memberships l
                       where l.office_id = office.id and l.status = 'active'),
    'pendingInvitations', (select count(*) from org.invitations i
                           where i.office_id = office.id and i.status = 'pending' and i.expires_at > now()),
    'closure', (select jsonb_build_object('at', e.at, 'reason', e.reason, 'by', org.person(e.actor_user_id))
                from audit.tenant_events e
                where e.tenant_id = office.tenant_id and e.action = 'office.closed' and e.target_id = office.id::text
                order by e.id desc limit 1),
    'canManage', (authz.decide(p_user_id, 'manage_members', workspace.tenant_id,
                    case when office.status = 'active' then office.id end, null, workspace.id)->>'allowed')::boolean
                 and office.status = 'active',
    'canLeadAssign', office.status = 'active' and (workspace.office_id is null or exists (
                    select 1 from org.office_closure c
                    where c.ancestor_id = workspace.office_id and c.descendant_id = office.id and c.depth > 0))
  );
end;
$$;
-- ── New office with an invited leader (POST /invitations/office) ──────────
--
-- President Team, reason filled in ("Leader of new office <name>"), PIN. The
-- office is created without leaders and the leader invitation goes out in the
-- same transaction; accepting it makes the invitee its leader.
create function api.create_office_inviting_leader(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_type text,
  p_name text,
  p_parent_office_id uuid,
  p_email text,
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
  clean_name text;
  clean_email text;
  digest bytea;
  request jsonb;
  replayed jsonb;
  office org.offices;
  invitation org.invitations;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform authz.require_president(workspace);

  if p_type is null or p_type not in ('world_team', 'director', 'team_leader') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'type'));
  end if;
  clean_name := org.require_text(p_name, 'name', 2, 100);
  if p_parent_office_id is not null then
    perform org.office_in_tenant(workspace.tenant_id, p_parent_office_id);
  end if;
  clean_email := org.clean_email(p_email);
  if clean_email = (select lower(btrim(email)) from auth.users where id = p_user_id) then
    perform identity.fail('self_target_forbidden');
  end if;
  digest := org.token_digest(p_token_digest);
  if p_token_id is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'token'));
  end if;

  request := jsonb_build_object('membershipId', workspace.id, 'type', p_type, 'name', clean_name,
    'parentOfficeId', p_parent_office_id, 'email', clean_email);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'create_office_inviting_leader', request);
  if replayed is not null then
    return replayed;
  end if;

  perform org.lock_tree(workspace.tenant_id);
  insert into org.offices (tenant_id, parent_office_id, office_type, name, created_by)
  values (workspace.tenant_id, p_parent_office_id, p_type::org.office_type, clean_name, p_user_id)
  returning * into office;
  perform org.require_invite_authority(p_user_id, workspace, office, org.leader_role(office.office_type));

  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'office.created', 'office', office.id::text,
    p_safe_after => jsonb_build_object('name', office.name, 'type', office.office_type,
      'parentOfficeId', office.parent_office_id, 'leaders', 0, 'leaderInvited', true),
    p_request_id => p_request_id);
  invitation := org.issue_invitation(workspace, office.id, org.leader_role(office.office_type), clean_email,
    p_token_id, digest, 'Leader of new office ' || clean_name, p_user_id, p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'create_office_inviting_leader', request,
    jsonb_build_object('officeId', office.id, 'invitationId', invitation.id, 'reference', invitation.reference,
      'expiresAt', invitation.expires_at));
end;
$$;

-- ── Privileges ────────────────────────────────────────────────────────────

revoke all on function org.issue_invitation(org.memberships, uuid, org.role, text, uuid, bytea, text, uuid, text, uuid)
  from public, anon, authenticated;
revoke all on function api.find_people(uuid, uuid, uuid, text) from public, anon, authenticated;
grant execute on function api.find_people(uuid, uuid, uuid, text) to service_role;
revoke all on function api.create_invitation(uuid, uuid, uuid, uuid, text, text, uuid, text, text, text, text, uuid)
  from public, anon, authenticated;
grant execute on function api.create_invitation(uuid, uuid, uuid, uuid, text, text, uuid, text, text, text, text, uuid)
  to service_role;
revoke all on function api.create_office_inviting_leader(uuid, uuid, uuid, text, text, uuid, text, uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function api.create_office_inviting_leader(uuid, uuid, uuid, text, text, uuid, text, uuid, text, text, text)
  to service_role;
