-- Blueprint 07 — Org management (member build plan, slice 1).
--
-- 1. api.close_office: the President Team closes an empty office (no open
--    child offices, no open non-leader memberships). Its leaders' memberships
--    end with the reason, pending invitations into it are revoked, reviewer
--    assignments held through those memberships end. Money stays where it is
--    (Blueprint 04 decision 23 already keeps it visible above).
-- 2. api.change_membership_role (W-05 "classification"): ends the current
--    membership and creates the new one in the same office (member <-> the
--    office kind's leader role). Never an in-place edit.
-- 3. Reads for the org screens: api.office_detail, api.member_detail;
--    api.list_offices gains `leaders` and `childCount`; api.list_members gains
--    a name/UID search (`q`) and a masked email.
-- 4. A membership can be created only in an active office (trigger), so a
--    concurrent add cannot slip into an office being closed.

-- ── Helpers ───────────────────────────────────────────────────────────────

-- "a•••••@example.com": the first character and the domain only (P-06 privacy).
create function org.masked_email(p_user_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when u.email is null or position('@' in u.email) < 2 then null
    else left(u.email, 1) || '•••••' || substr(u.email, position('@' in u.email))
  end
  from auth.users u where u.id = p_user_id;
$$;

-- The office's active leaders, oldest first.
create function org.office_leaders(p_office_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'membershipId', m.id,
      'person', org.person(m.user_id),
      'startedAt', m.started_at
    ) order by m.started_at, m.id), '[]'::jsonb)
  from org.memberships m
  join org.offices o on o.id = m.office_id
  where m.office_id = p_office_id and m.role = org.leader_role(o.office_type) and m.status = 'active';
$$;

-- Can the actor see this office from the workspace? (Own subtree; President Team: all.)
create function org.office_visible(p_workspace org.memberships, p_office_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_workspace.office_id is null or exists (
    select 1 from org.office_closure c
    where c.ancestor_id = p_workspace.office_id and c.descendant_id = p_office_id
  );
$$;

-- Ends a reviewer assignment held through a membership that just ended.
create function org.end_reviewer_for(
  p_membership_id uuid,
  p_reason text,
  p_actor_user_id uuid,
  p_request_id text
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  assignment authz.reviewer_assignments;
begin
  select * into assignment from authz.reviewer_assignments
  where membership_id = p_membership_id and ended_at is null
  for update;
  if assignment.id is null then
    return;
  end if;
  update authz.reviewer_assignments
  set ended_at = now(), ended_by = p_actor_user_id, end_reason = p_reason
  where id = assignment.id;
  perform audit.record_tenant(assignment.tenant_id, p_actor_user_id, 'reviewer.ended', 'reviewer_assignment',
    assignment.id::text, p_reason, p_request_id => p_request_id);
end;
$$;

-- ── 4. Memberships only in active offices ─────────────────────────────────

create or replace function org.check_membership_role()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  kind org.office_type;
  office_status org.office_status;
begin
  if tg_op = 'UPDATE' and (
    new.tenant_id <> old.tenant_id or new.user_id <> old.user_id or new.role <> old.role
    or new.office_id is distinct from old.office_id or old.status = 'ended'
  ) then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'org.memberships'));
  end if;

  if new.office_id is not null then
    if tg_op = 'INSERT' then
      -- FOR SHARE waits for a concurrent close_office (FOR NO KEY UPDATE) to finish.
      select office_type, status into kind, office_status from org.offices where id = new.office_id for share;
      if office_status <> 'active' then
        perform identity.fail('conflict', jsonb_build_object('reason', 'office_closed'));
      end if;
    else
      select office_type into kind from org.offices where id = new.office_id;
    end if;
    if new.role <> 'member' and org.leader_role(kind) <> new.role then
      perform identity.fail('role_office_mismatch');
    end if;
  end if;
  return new;
end;
$$;

-- Invitations only into active offices: FOR SHARE waits for a concurrent
-- close_office, then sees `closed` (an invitation cannot outlive its office).
create function org.check_invitation_office()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (select status from org.offices where id = new.office_id for share) <> 'active' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'office_closed'));
  end if;
  return new;
end;
$$;

create trigger invitations_office_active
before insert on org.invitations
for each row execute function org.check_invitation_office();

-- ── 1. Close an office ────────────────────────────────────────────────────

create function api.close_office(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_office_id uuid,
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
  clean_reason text;
  request jsonb;
  replayed jsonb;
  leader record;
  invitation org.invitations;
  ended_ids uuid[] := '{}'::uuid[];
  revoked int := 0;
  locked_people uuid[];
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform authz.require_president(workspace);
  office := org.office_in_tenant(workspace.tenant_id, p_office_id);
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('officeId', office.id, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'close_office', request);
  if replayed is not null then
    return replayed;
  end if;

  -- Lock order: people (the office's open memberships) → office tree → office row.
  locked_people := array(select distinct user_id from org.memberships where office_id = office.id and status <> 'ended');
  perform org.lock_people(workspace.tenant_id, locked_people);
  perform org.lock_tree(workspace.tenant_id);
  select * into office from org.offices where id = office.id for no key update;
  -- Someone joined between the person locks and the office lock: never take a
  -- person lock after the office lock (deadlock with role changes); ask for a retry.
  if exists (
    select 1 from org.memberships
    where office_id = office.id and status <> 'ended' and not (user_id = any (locked_people))
  ) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'office_changed'));
  end if;

  if office.status = 'closed' then
    return identity.store_result(p_user_id, p_idempotency_key, 'close_office', request,
      jsonb_build_object('officeId', office.id, 'status', 'closed', 'changed', false,
        'endedMembershipIds', '[]'::jsonb, 'revokedInvitations', 0));
  end if;
  if exists (select 1 from org.offices where parent_office_id = office.id and status = 'active') then
    perform identity.fail('conflict', jsonb_build_object('reason', 'has_child_offices'));
  end if;
  if exists (
    select 1 from org.memberships
    where office_id = office.id and status <> 'ended' and role <> org.leader_role(office.office_type)
  ) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'office_not_empty'));
  end if;

  update org.offices set status = 'closed' where id = office.id;

  for leader in
    select id, user_id from org.memberships
    where office_id = office.id and status <> 'ended'
    order by started_at, id
  loop
    perform org.end_membership(leader.id, clean_reason, p_user_id);
    perform org.ensure_primary(workspace.tenant_id, leader.user_id);
    perform org.end_reviewer_for(leader.id, clean_reason, p_user_id, p_request_id);
    ended_ids := ended_ids || leader.id;
  end loop;

  for invitation in
    select * from org.invitations where office_id = office.id and status = 'pending' for update
  loop
    update org.invitations
    set status = 'revoked', revoked_at = now(), revoked_by = p_user_id, revoke_reason = clean_reason
    where id = invitation.id;
    perform org.record_invitation_event(invitation, 'revoked', p_user_id, clean_reason);
    revoked := revoked + 1;
  end loop;

  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'office.closed', 'office', office.id::text, clean_reason,
    jsonb_build_object('status', 'active'),
    jsonb_build_object('status', 'closed', 'endedMemberships', cardinality(ended_ids), 'revokedInvitations', revoked),
    p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'close_office', request,
    jsonb_build_object('officeId', office.id, 'status', 'closed', 'changed', true,
      'endedMembershipIds', to_jsonb(ended_ids), 'revokedInvitations', revoked));
end;
$$;

-- ── 2. Change a membership's role (end + new) ─────────────────────────────

create function api.change_membership_role(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_target_membership_id uuid,
  p_role text,
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
  target org.memberships;
  office org.offices;
  clean_reason text;
  request jsonb;
  replayed jsonb;
  created org.memberships;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  target := org.membership_in_tenant(workspace.tenant_id, p_target_membership_id);
  if target.office_id is null then
    perform identity.fail('conflict', jsonb_build_object('reason', 'president_membership'));
  end if;
  office := org.office_in_tenant(workspace.tenant_id, target.office_id);
  if p_role is null or p_role not in ('member', org.leader_role(office.office_type)::text)
    or p_role = target.role::text then
    perform identity.fail('validation_error', jsonb_build_object('field', 'role'));
  end if;
  perform authz.require(p_user_id, 'manage_members', workspace.tenant_id, office.id, target.user_id, workspace.id);
  -- One side of the change is always the office's leader role (W-03/W-05 rule).
  perform org.require_below_own_office(workspace, office.id);
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('targetMembershipId', target.id, 'role', p_role, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'change_membership_role', request);
  if replayed is not null then
    return replayed;
  end if;

  perform org.lock_people(workspace.tenant_id, array[target.user_id]);
  perform 1 from org.offices where id = office.id for no key update;
  select * into target from org.memberships where id = target.id for update;
  if target.status <> 'active' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'membership_not_active'));
  end if;

  created := org.create_membership(workspace.tenant_id, office.id, target.user_id, p_role::org.role, p_user_id, false);
  perform org.end_membership(target.id, clean_reason, p_user_id, 'replaced', created.id);
  if target.is_primary then
    update org.memberships set is_primary = true where id = created.id;
  end if;
  perform org.end_reviewer_for(target.id, clean_reason, p_user_id, p_request_id);
  perform org.assert_leader_remains(office.id);
  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'membership.role_changed', 'membership', target.id::text,
    clean_reason, jsonb_build_object('role', target.role, 'officeId', office.id),
    jsonb_build_object('role', p_role, 'membershipId', created.id), p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'change_membership_role', request,
    jsonb_build_object('endedMembershipId', target.id, 'membershipId', created.id, 'role', p_role));
end;
$$;

-- ── 3. Reads ──────────────────────────────────────────────────────────────

create or replace function api.list_offices(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_type text default null,
  p_query text default null,
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
  page_size int;
  after jsonb;
  rows jsonb;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform org.require_active_tenant(workspace.tenant_id);
  if p_type is not null and p_type not in ('world_team', 'director', 'team_leader') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'type'));
  end if;
  if p_status is not null and p_status not in ('active', 'closed') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'status'));
  end if;
  if p_query is not null and length(p_query) > 100 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'q'));
  end if;
  page_size := org.page_limit(p_limit);
  after := org.decode_cursor(p_cursor);

  select coalesce(jsonb_agg(item order by item->>'name', item->>'id'), '[]'::jsonb) into rows
  from (
    select jsonb_build_object(
      'id', o.id,
      'name', o.name,
      'type', o.office_type,
      'status', o.status,
      'parentOfficeId', o.parent_office_id,
      'leaderCount', (select count(*) from org.memberships l
                      where l.office_id = o.id and l.role = org.leader_role(o.office_type) and l.status = 'active'),
      'memberCount', (select count(distinct l.user_id) from org.office_closure c
                      join org.memberships l on l.office_id = c.descendant_id
                      where c.ancestor_id = o.id and l.status = 'active'),
      'childCount', (select count(*) from org.offices ch where ch.parent_office_id = o.id and ch.status = 'active'),
      'leaders', (select coalesce(jsonb_agg(x.p order by x.started_at, x.id), '[]'::jsonb) from (
                    select org.person(l.user_id) as p, l.started_at, l.id from org.memberships l
                    where l.office_id = o.id and l.role = org.leader_role(o.office_type) and l.status = 'active'
                    order by l.started_at, l.id limit 3) x)
    ) as item
    from org.offices o
    where o.tenant_id = workspace.tenant_id
      and org.office_visible(workspace, o.id)
      and (p_type is null or o.office_type = p_type::org.office_type)
      and (p_status is null or o.status = p_status::org.office_status)
      and (p_query is null or o.name ilike '%' || replace(replace(replace(p_query, '\', '\\'), '%', '\%'), '_', '\_') || '%')
      and (after is null or (o.name, o.id::text) > (after->>'name', after->>'id'))
    order by o.name, o.id
    limit page_size + 1
  ) page;

  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(e) from jsonb_array_elements(rows) with ordinality as x (e, n) where n <= page_size), '[]'::jsonb),
    'nextCursor', case when jsonb_array_length(rows) > page_size
      then org.encode_cursor(jsonb_build_object('name', rows->(page_size - 1)->>'name', 'id', rows->(page_size - 1)->>'id'))
    end
  );
end;
$$;

-- One office (O07): leaders, its place in the tree, rolled-up counts.
create function api.office_detail(p_user_id uuid, p_session_id uuid, p_membership_id uuid, p_office_id uuid)
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
    'canManage', (authz.decide(p_user_id, 'manage_members', workspace.tenant_id,
                    case when office.status = 'active' then office.id end, null, workspace.id)->>'allowed')::boolean
                 and office.status = 'active',
    'canLeadAssign', office.status = 'active' and (workspace.office_id is null or exists (
                    select 1 from org.office_closure c
                    where c.ancestor_id = workspace.office_id and c.descendant_id = office.id and c.depth > 0))
  );
end;
$$;

drop function api.list_members(uuid, uuid, uuid, uuid, text, text, text, int);

create function api.list_members(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_office_id uuid default null,
  p_role text default null,
  p_status text default null,
  p_cursor text default null,
  p_limit int default null,
  p_query text default null
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
  needle text;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  scope_office_id := coalesce(p_office_id, workspace.office_id);
  if scope_office_id is not null then
    perform org.office_in_tenant(workspace.tenant_id, scope_office_id);
  end if;
  if not (authz.decide(p_user_id, 'manage_members', workspace.tenant_id, scope_office_id, null, workspace.id)->>'allowed')::boolean
    and not (authz.decide(p_user_id, 'view_managed_wallets', workspace.tenant_id, scope_office_id, null, workspace.id)->>'allowed')::boolean then
    perform identity.fail('authorization_denied');
  end if;
  if p_role is not null and p_role not in ('member', 'team_leader', 'director', 'world_team_member', 'president_team_member') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'role'));
  end if;
  if p_status is not null and p_status not in ('active', 'suspended', 'ended') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'status'));
  end if;
  if p_query is not null and (length(btrim(p_query)) not between 1 and 100) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'q'));
  end if;
  needle := case when p_query is not null
    then '%' || replace(replace(replace(btrim(p_query), '\', '\\'), '%', '\%'), '_', '\_') || '%' end;
  page_size := org.page_limit(p_limit);
  after := org.decode_cursor(p_cursor);

  select coalesce(jsonb_agg(item order by item->>'startedAt', item->>'membershipId'), '[]'::jsonb) into rows
  from (
    select jsonb_build_object(
      'membershipId', m.id,
      'person', org.person(m.user_id),
      'emailMasked', org.masked_email(m.user_id),
      'role', m.role,
      'status', m.status,
      'officeId', m.office_id,
      'officeName', o.name,
      'isPrimary', m.is_primary,
      'startedAt', m.started_at,
      'endedAt', m.ended_at
    ) as item
    from org.memberships m
    left join org.offices o on o.id = m.office_id
    join identity.accounts a on a.user_id = m.user_id
    left join identity.profiles pr on pr.user_id = m.user_id
    where m.tenant_id = workspace.tenant_id
      and (
        (scope_office_id is null)
        or exists (select 1 from org.office_closure c where c.ancestor_id = scope_office_id and c.descendant_id = m.office_id)
      )
      and (p_role is null or m.role = p_role::org.role)
      and (case when p_status is null then m.status <> 'ended' else m.status = p_status::org.membership_status end)
      and (needle is null
           or a.uid ilike needle
           or concat_ws(' ', pr.first_name, pr.last_name) ilike needle
           or coalesce(pr.display_name, '') ilike needle)
      and (m.user_id = p_user_id
           or (authz.decide(p_user_id, 'manage_members', workspace.tenant_id, m.office_id, m.user_id, workspace.id)->>'allowed')::boolean
           or (authz.decide(p_user_id, 'view_managed_wallets', workspace.tenant_id, m.office_id, m.user_id, workspace.id)->>'allowed')::boolean)
      and (after is null or (to_char(m.started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'), m.id::text)
                            > (after->>'s', after->>'id'))
    order by m.started_at, m.id
    limit page_size + 1
  ) page;

  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(e) from jsonb_array_elements(rows) with ordinality as x (e, n) where n <= page_size), '[]'::jsonb),
    'nextCursor', case when jsonb_array_length(rows) > page_size then (
      select org.encode_cursor(jsonb_build_object(
        's', to_char(m.started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'), 'id', m.id))
      from org.memberships m where m.id = (rows->(page_size - 1)->>'membershipId')::uuid
    ) end
  );
end;
$$;

-- One membership (R07): the person, the office, its history, the person's
-- other open memberships the actor may see, and which lifecycle actions the
-- actor holds (navigation hints; every command re-checks).
create function api.member_detail(p_user_id uuid, p_session_id uuid, p_membership_id uuid, p_target_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  target org.memberships;
  office org.offices;
  can_see boolean;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  target := org.membership_in_tenant(workspace.tenant_id, p_target_membership_id);
  if target.office_id is not null then
    select * into office from org.offices where id = target.office_id;
  end if;

  -- Same visibility as list_members; a closed office is checked against the tenant (President Team).
  can_see := target.user_id = p_user_id
    or (target.office_id is null and workspace.role = 'president_team_member')
    or (target.office_id is not null and office.status = 'active' and (
          (authz.decide(p_user_id, 'manage_members', workspace.tenant_id, office.id, target.user_id, workspace.id)->>'allowed')::boolean
          or (authz.decide(p_user_id, 'view_managed_wallets', workspace.tenant_id, office.id, target.user_id, workspace.id)->>'allowed')::boolean))
    or (target.office_id is not null and office.status = 'closed' and workspace.role = 'president_team_member');
  if not can_see then
    perform identity.fail('not_found');
  end if;

  return jsonb_build_object(
    'membershipId', target.id,
    'person', org.person(target.user_id),
    'emailMasked', org.masked_email(target.user_id),
    'role', target.role,
    'status', target.status,
    'isPrimary', target.is_primary,
    'startedAt', target.started_at,
    'endedAt', target.ended_at,
    'office', case when office.id is null then null else jsonb_build_object(
      'id', office.id, 'name', office.name, 'type', office.office_type, 'status', office.status) end,
    'officeLeaders', case when office.id is null then '[]'::jsonb else org.office_leaders(office.id) end,
    'isSelf', target.user_id = p_user_id,
    'walletId', (select w.id from ledger.wallets w where w.owner_user_id = target.user_id),
    'memberships', coalesce((
      select jsonb_agg(jsonb_build_object(
        'membershipId', m.id, 'role', m.role, 'status', m.status, 'isPrimary', m.is_primary,
        'officeId', m.office_id, 'officeName', mo.name
      ) order by m.is_primary desc, m.started_at, m.id)
      from org.memberships m left join org.offices mo on mo.id = m.office_id
      where m.tenant_id = workspace.tenant_id and m.user_id = target.user_id and m.status <> 'ended'
        and (m.id = target.id or workspace.role = 'president_team_member' or m.user_id = p_user_id
             or (m.office_id is not null and mo.status = 'active' and (
                   (authz.decide(p_user_id, 'manage_members', workspace.tenant_id, m.office_id, m.user_id, workspace.id)->>'allowed')::boolean
                   or (authz.decide(p_user_id, 'view_managed_wallets', workspace.tenant_id, m.office_id, m.user_id, workspace.id)->>'allowed')::boolean)))
    ), '[]'::jsonb),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object('action', e.action, 'fromStatus', e.from_status, 'toStatus', e.to_status,
        'at', e.at, 'actor', org.person(e.actor_user_id)) order by e.at desc, e.id desc)
      from (select * from org.membership_events where membership_id = target.id order by at desc, id desc limit 20) e
    ), '[]'::jsonb),
    'actions', jsonb_build_object(
      'suspend', target.status <> 'ended' and target.user_id <> p_user_id and (
        case when target.office_id is null then workspace.role = 'president_team_member'
        else office.status = 'active' and (authz.decide(p_user_id, 'suspend_membership', workspace.tenant_id, office.id,
               target.user_id, workspace.id)->>'allowed')::boolean end),
      'move', target.status = 'active' and target.office_id is not null and office.status = 'active'
        and (authz.decide(p_user_id, 'move_membership', workspace.tenant_id, office.id, target.user_id, workspace.id)->>'allowed')::boolean,
      'end', target.status <> 'ended' and target.user_id <> p_user_id and (
        case when target.office_id is null then workspace.role = 'president_team_member'
        else office.status = 'active' and (authz.decide(p_user_id, 'end_membership', workspace.tenant_id, office.id,
               target.user_id, workspace.id)->>'allowed')::boolean end),
      'changeRole', target.status = 'active' and target.office_id is not null and office.status = 'active'
        and (authz.decide(p_user_id, 'manage_members', workspace.tenant_id, office.id, target.user_id, workspace.id)->>'allowed')::boolean
        and (workspace.office_id is null or exists (
          select 1 from org.office_closure c
          where c.ancestor_id = workspace.office_id and c.descendant_id = office.id and c.depth > 0))
    )
  );
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
      and p.proname in ('close_office', 'change_membership_role', 'list_offices', 'office_detail',
                        'list_members', 'member_detail')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end;
$$;
