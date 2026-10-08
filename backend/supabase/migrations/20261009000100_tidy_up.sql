-- Tidy-up (owner decisions 1, 53 and 54 of 2026-10-08).
--
-- 1. Leader roles are given only in offices strictly below the actor's own
--    office; the President Team may lead-assign in any office. Applies to
--    api.add_office_leader and api.replace_office_leader (previously a Team
--    Leader with manage_members could add or replace a co-leader in their own
--    office). Blueprint 03 invitations reuse org.require_below_own_office.
-- 2. api.list_offices memberCount rolls up over the office's subtree
--    (distinct people with an active membership anywhere in it). leaderCount
--    stays the office's own active leaders.
-- 3. One self-target code: api.set_account_status now fails with
--    self_target_forbidden, as org commands already do.
-- 4. api.cancel_pin_reset withdraws a reset request whose email could not be
--    sent, so the 60-second cooldown does not block an immediate retry.

-- ── 1. Strictly below the actor's own office ──────────────────────────────

create function org.require_below_own_office(p_workspace org.memberships, p_office_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_workspace.role = 'president_team_member' then
    return;
  end if;
  if p_workspace.office_id is null or not exists (
    select 1 from org.office_closure c
    where c.ancestor_id = p_workspace.office_id and c.descendant_id = p_office_id and c.depth > 0
  ) then
    perform identity.fail('authorization_denied', jsonb_build_object('reason', 'office_not_below_own'));
  end if;
end;
$$;

create or replace function api.add_office_leader(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_office_id uuid,
  p_leader_uid text,
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
  leader_user_id uuid;
  clean_reason text;
  request jsonb;
  replayed jsonb;
  leader org.memberships;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  office := org.office_in_tenant(workspace.tenant_id, p_office_id);
  leader_user_id := identity.account_by_uid(p_leader_uid);
  perform authz.require(p_user_id, 'manage_members', workspace.tenant_id, office.id, leader_user_id, workspace.id);
  perform org.require_below_own_office(workspace, office.id);
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('officeId', office.id, 'leaderUid', upper(btrim(p_leader_uid)), 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'add_office_leader', request);
  if replayed is not null then
    return replayed;
  end if;

  perform org.lock_people(workspace.tenant_id, array[leader_user_id]);
  perform 1 from org.offices where id = office.id for no key update;
  leader := org.create_membership(workspace.tenant_id, office.id, leader_user_id, org.leader_role(office.office_type), p_user_id);
  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'office.leader_added', 'membership', leader.id::text, clean_reason,
    p_safe_after => jsonb_build_object('officeId', office.id, 'role', leader.role), p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'add_office_leader', request,
    jsonb_build_object('membershipId', leader.id));
end;
$$;

create or replace function api.replace_office_leader(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_office_id uuid,
  p_outgoing_membership_id uuid,
  p_incoming_uid text,
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
  outgoing org.memberships;
  incoming_user_id uuid;
  clean_reason text;
  request jsonb;
  replayed jsonb;
  existing record;
  incoming org.memberships;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  office := org.office_in_tenant(workspace.tenant_id, p_office_id);
  outgoing := org.membership_in_tenant(workspace.tenant_id, p_outgoing_membership_id);
  if outgoing.office_id is distinct from office.id then
    perform identity.fail('not_found');
  end if;
  incoming_user_id := identity.account_by_uid(p_incoming_uid);
  if incoming_user_id = outgoing.user_id then
    perform identity.fail('validation_error', jsonb_build_object('field', 'incomingUid'));
  end if;
  perform authz.require(p_user_id, 'manage_members', workspace.tenant_id, office.id, outgoing.user_id, workspace.id);
  perform authz.require(p_user_id, 'manage_members', workspace.tenant_id, office.id, incoming_user_id, workspace.id);
  perform org.require_below_own_office(workspace, office.id);
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('officeId', office.id, 'outgoingMembershipId', outgoing.id,
    'incomingUid', upper(btrim(p_incoming_uid)), 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'replace_office_leader', request);
  if replayed is not null then
    return replayed;
  end if;

  perform org.lock_people(workspace.tenant_id, array[outgoing.user_id, incoming_user_id]);
  perform 1 from org.offices where id = office.id for no key update;
  select * into outgoing from org.memberships where id = outgoing.id for update;
  if outgoing.status = 'ended' or outgoing.role <> org.leader_role(office.office_type) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'not_a_current_leader'));
  end if;

  for existing in
    select id from org.memberships
    where office_id = office.id and user_id = incoming_user_id and status <> 'ended'
  loop
    perform org.end_membership(existing.id, clean_reason, p_user_id);
  end loop;

  incoming := org.create_membership(workspace.tenant_id, office.id, incoming_user_id, outgoing.role, p_user_id);
  perform org.end_membership(outgoing.id, clean_reason, p_user_id, 'replaced', incoming.id);
  perform org.ensure_primary(workspace.tenant_id, outgoing.user_id);
  perform org.ensure_primary(workspace.tenant_id, incoming_user_id);
  perform org.assert_leader_remains(office.id);
  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'office.leader_replaced', 'office', office.id::text, clean_reason,
    jsonb_build_object('membershipId', outgoing.id), jsonb_build_object('membershipId', incoming.id), p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'replace_office_leader', request,
    jsonb_build_object('endedMembershipId', outgoing.id, 'membershipId', incoming.id));
end;
$$;

-- ── 2. Rolled-up office member counts ─────────────────────────────────────

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
                      where c.ancestor_id = o.id and l.status = 'active')
    ) as item
    from org.offices o
    where o.tenant_id = workspace.tenant_id
      and (workspace.office_id is null or exists (
        select 1 from org.office_closure c where c.ancestor_id = workspace.office_id and c.descendant_id = o.id
      ))
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

-- ── 3. One self-target code ───────────────────────────────────────────────

create or replace function api.set_account_status(
  p_user_id uuid,
  p_session_id uuid,
  p_target_uid text,
  p_status text,
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
  request jsonb;
  replayed jsonb;
  clean_reason text;
  target_user_id uuid;
  previous identity.account_status;
  next_status identity.account_status;
begin
  perform pg_advisory_xact_lock(hashtextextended('identity.platform_admins', 0));
  perform identity.require_session(p_user_id, p_session_id, p_step_up => true);
  perform identity.require_platform_admin(p_user_id);

  clean_reason := identity.require_reason(p_reason);
  if p_status is null or p_status not in ('active', 'restricted', 'suspended', 'deactivated') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'status'));
  end if;
  next_status := p_status::identity.account_status;

  request := jsonb_build_object('targetUid', upper(btrim(p_target_uid)), 'status', p_status, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'set_account_status', request);
  if replayed is not null then
    return replayed;
  end if;

  target_user_id := identity.account_by_uid(p_target_uid);
  if target_user_id = p_user_id then
    perform identity.fail('self_target_forbidden');
  end if;

  select status into previous from identity.accounts where user_id = target_user_id for update;

  if previous <> next_status then
    update identity.accounts set status = next_status where user_id = target_user_id;
    insert into identity.account_status_changes (user_id, from_status, to_status, reason, actor_user_id)
    values (target_user_id, previous, next_status, clean_reason, p_user_id);
    if next_status in ('suspended', 'deactivated') then
      delete from identity.session_pin_proofs where user_id = target_user_id;
    end if;
    perform audit.record('account.status_changed', p_user_id, p_session_id, target_user_id, clean_reason,
      jsonb_build_object('status', previous), jsonb_build_object('status', next_status), p_request_id);
  end if;

  return identity.store_result(p_user_id, p_idempotency_key, 'set_account_status', request,
    jsonb_build_object('targetUid', upper(btrim(p_target_uid)), 'previousStatus', previous,
      'status', next_status, 'changed', previous <> next_status));
end;
$$;

-- ── 4. Withdraw a PIN-reset request whose email was not sent ──────────────

create function api.cancel_pin_reset(
  p_user_id uuid,
  p_session_id uuid,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  removed int;
begin
  perform identity.require_live_session(p_user_id, p_session_id);
  perform pg_advisory_xact_lock(hashtextextended('identity.pin_reset:' || p_user_id::text, 0));

  delete from identity.pin_reset_requests
  where user_id = p_user_id and consumed_at is null
    and requested_at > now() - identity.pin_reset_cooldown();
  get diagnostics removed = row_count;

  if removed > 0 then
    perform audit.record('pin.reset_email_failed', p_user_id, p_session_id, p_user_id, p_request_id => p_request_id);
  end if;
  return jsonb_build_object('cancelled', removed > 0);
end;
$$;

revoke all on function api.cancel_pin_reset(uuid, uuid, text) from public, anon, authenticated;
grant execute on function api.cancel_pin_reset(uuid, uuid, text) to service_role;
