-- Blueprint 22 — B3: the "funds not managed" switch and what it changes.
--
--   * api.set_funds_managed: President Team only, reason + PIN step-up,
--     idempotent, inside the workspace's network. Setting it is refused while
--     the director's wallet holds money from this network or has an open
--     operation (conflict / wallet_not_empty).
--   * The wallet is kept (wallets are account-wide and immutable). The ledger
--     refuses every posting and hold on a segment of an exempted membership
--     (conflict / funds_not_managed), under a per-membership advisory lock the
--     switch takes exclusively, so a check and a posting never interleave.
--   * Money targets (income, adjustments, withdrawals, pocket moves) skip it,
--     and the own-wallet permissions never come from it (authz.decide).
--   * Reads: member_detail and the workspace list show the switch.

-- ── Money held in a network ───────────────────────────────────────────────

-- Any posted or reserved amount on the person's wallet segments from this
-- network, in any currency or pocket, or an open withdrawal, pocket move or
-- entry there. Never reads another network.
create function org.funds_held(p_tenant_id uuid, p_user_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
      select 1 from ledger.balances b
      where b.tenant_id = p_tenant_id and b.owner_user_id = p_user_id and (b.posted <> 0 or b.reserved <> 0))
    or exists (
      select 1 from finance.withdrawals w
      where w.tenant_id = p_tenant_id and w.owner_user_id = p_user_id and w.status in ('requested', 'approved'))
    or exists (
      select 1 from finance.pocket_transfers t
      where t.tenant_id = p_tenant_id and t.owner_user_id = p_user_id and t.status = 'requested')
    or exists (
      select 1 from finance.entries e
      where e.tenant_id = p_tenant_id and e.owner_user_id = p_user_id and e.status = 'needs_review');
$$;

create function org.funds_lock_key(p_membership_id uuid)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select hashtextextended('org.funds:' || p_membership_id::text, 0);
$$;

-- ── Ledger backstop ───────────────────────────────────────────────────────

-- Before a posting or a new hold on a member-value account: refused when the
-- segment's membership has its funds unmanaged.
create function ledger.refuse_unmanaged_funds()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_membership_id uuid;
begin
  select a.membership_id into v_membership_id
  from ledger.accounts a
  where a.id = new.account_id and a.class = 'member_value';
  if v_membership_id is not null then
    perform pg_advisory_xact_lock_shared(org.funds_lock_key(v_membership_id));
    if org.funds_not_managed(v_membership_id) then
      perform identity.fail('conflict', jsonb_build_object('reason', 'funds_not_managed'));
    end if;
  end if;
  return new;
end;
$$;

create trigger postings_funds_managed
before insert on ledger.postings
for each row execute function ledger.refuse_unmanaged_funds();

create trigger reservations_funds_managed
before insert on ledger.reservations
for each row execute function ledger.refuse_unmanaged_funds();

-- ── Money targets ─────────────────────────────────────────────────────────

-- Income, adjustments, withdrawals and pocket moves all ask this.
create or replace function finance.target_eligible(p_membership org.memberships)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_membership.status = 'active'
    and p_membership.role <> 'president_team_member'
    and not org.funds_not_managed(p_membership.id)
    and exists (select 1 from org.offices o where o.id = p_membership.office_id and o.status = 'active')
    and exists (select 1 from identity.accounts a
                where a.user_id = p_membership.user_id and a.status in ('active', 'restricted'));
$$;

-- ── Authorization ─────────────────────────────────────────────────────────

-- As in Blueprint 16, plus: the self-service (own-wallet) rows never come
-- from a membership whose funds are not managed.
create or replace function authz.decide(
  p_actor_user_id uuid,
  p_permission_key text,
  p_tenant_id uuid,
  p_target_office_id uuid default null,
  p_target_user_id uuid default null,
  p_workspace_membership_id uuid default null
)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  permission authz.permission_catalog;
  tenant_status org.tenant_status;
  explicit_effect text;
begin
  select * into permission from authz.permission_catalog where key = p_permission_key;
  if permission.key is null then
    return jsonb_build_object('allowed', false, 'reason', 'unknown_permission');
  end if;

  select status into tenant_status from org.tenants where id = p_tenant_id;
  if tenant_status is null then
    return jsonb_build_object('allowed', false, 'reason', 'not_found');
  end if;
  -- Blueprint 16: a paused (suspended) network keeps its reads; writes are
  -- refused in authz.require. A network awaiting payment lets only
  -- manage_subscription through, so it can be paid for.
  if tenant_status = 'deactivated'
     or (tenant_status = 'pending_payment' and permission.key <> 'manage_subscription') then
    return jsonb_build_object('allowed', false, 'reason', 'network_not_active');
  end if;

  if p_target_office_id is not null and not exists (
    select 1 from org.offices where id = p_target_office_id and tenant_id = p_tenant_id and status = 'active'
  ) then
    return jsonb_build_object('allowed', false, 'reason', 'not_found');
  end if;

  -- The actor must belong to the network.
  if not exists (
    select 1 from org.memberships
    where tenant_id = p_tenant_id and user_id = p_actor_user_id and status = 'active'
  ) then
    return jsonb_build_object('allowed', false, 'reason', 'no_membership');
  end if;

  -- Self-service rows: the owner only.
  if permission.scope = 'self' then
    if p_target_user_id is distinct from p_actor_user_id then
      return jsonb_build_object('allowed', false, 'reason', 'self_only');
    end if;
    if exists (
      select 1 from org.memberships m
      join authz.role_permissions rp
        on rp.tenant_id = m.tenant_id and rp.role = m.role and rp.permission_key = permission.key
      where m.tenant_id = p_tenant_id and m.user_id = p_actor_user_id and m.status = 'active' and rp.allowed
        and (p_workspace_membership_id is null or m.id = p_workspace_membership_id)
        -- Blueprint 22: a membership whose funds are not managed holds no money.
        and not org.funds_not_managed(m.id)
    ) then
      return jsonb_build_object('allowed', true, 'reason', 'ok', 'source', 'role_policy');
    end if;
    return jsonb_build_object('allowed', false, 'reason', 'default_deny');
  end if;

  -- Leadership permissions never target the actor (A-04 self-target guard).
  if p_target_user_id = p_actor_user_id and not permission.can_target_own_wallet then
    return jsonb_build_object('allowed', false, 'reason', 'self_target');
  end if;

  -- Evidence review comes only from a current reviewer assignment.
  if permission.scope = 'assignment' then
    if exists (
      select 1 from authz.reviewer_assignments ra
      join org.memberships m on m.id = ra.membership_id
      where ra.tenant_id = p_tenant_id and ra.ended_at is null
        and m.user_id = p_actor_user_id and m.status = 'active'
        and (p_workspace_membership_id is null or m.id = p_workspace_membership_id)
        -- Within the reviewer's own scope; President Team reviewers cover the network.
        and (m.office_id is null
             or authz.office_covers(m.office_id, p_tenant_id, p_target_office_id, p_target_user_id))
    ) then
      return jsonb_build_object('allowed', true, 'reason', 'ok', 'source', 'reviewer_assignment');
    end if;
    return jsonb_build_object('allowed', false, 'reason', 'default_deny');
  end if;

  -- Explicit rules: deny beats grant.
  select case when bool_or(r.effect = 'deny') then 'deny' when bool_or(r.effect = 'allow') then 'allow' end
  into explicit_effect
  from authz.access_rules r
  join authz.access_assignments a on a.id = r.assignment_id
  where r.tenant_id = p_tenant_id
    and r.subject_user_id = p_actor_user_id
    and r.permission_key = permission.key
    and r.revoked_at is null and a.revoked_at is null
    and r.starts_at <= now()
    and (r.expires_at is null or r.expires_at > now())
    and authz.rule_covers(r, p_target_office_id, p_target_user_id);

  if explicit_effect = 'deny' then
    return jsonb_build_object('allowed', false, 'reason', 'explicit_deny', 'source', 'explicit_deny');
  end if;
  if explicit_effect = 'allow' then
    return jsonb_build_object('allowed', true, 'reason', 'ok', 'source', 'explicit_grant');
  end if;

  -- Exact-role policy over the memberships that cover the target.
  if exists (
    select 1 from org.memberships m
    join authz.role_permissions rp
      on rp.tenant_id = m.tenant_id and rp.role = m.role and rp.permission_key = permission.key
    left join org.offices o on o.id = m.office_id
    where m.tenant_id = p_tenant_id and m.user_id = p_actor_user_id and m.status = 'active'
      and rp.allowed
      and (p_workspace_membership_id is null or m.id = p_workspace_membership_id)
      and (m.office_id is null or o.status = 'active')
      and (
        m.office_id is null                    -- President Team: the whole tenant
        or (permission.scope = 'office'
            and authz.office_covers(m.office_id, p_tenant_id, p_target_office_id, p_target_user_id))
        or (permission.scope = 'tenant')       -- tenant-scoped rows enabled for another role
      )
  ) then
    return jsonb_build_object('allowed', true, 'reason', 'ok', 'source', 'role_policy');
  end if;

  return jsonb_build_object('allowed', false, 'reason', 'default_deny');
end;
$$;

-- ── The switch ────────────────────────────────────────────────────────────

create function api.set_funds_managed(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_target_membership_id uuid,
  p_not_managed boolean,
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
  clean_reason text;
  request jsonb;
  replayed jsonb;
  currently boolean;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform authz.require_president(workspace);
  if p_not_managed is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'notManaged'));
  end if;
  target := org.membership_in_tenant(workspace.tenant_id, p_target_membership_id);
  if target.user_id = p_user_id then
    perform identity.fail('self_target_forbidden');
  end if;
  if target.role <> 'director' or target.status = 'ended' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'not_a_director'));
  end if;
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('tenantId', workspace.tenant_id, 'targetMembershipId', target.id,
    'notManaged', p_not_managed, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'set_funds_managed', request);
  if replayed is not null then
    return replayed;
  end if;

  -- Postings and holds on this membership take the same key shared.
  perform pg_advisory_xact_lock(org.funds_lock_key(target.id));
  currently := org.funds_not_managed(target.id);
  if currently = p_not_managed then
    return identity.store_result(p_user_id, p_idempotency_key, 'set_funds_managed', request,
      jsonb_build_object('membershipId', target.id, 'fundsNotManaged', currently, 'changed', false));
  end if;

  if p_not_managed then
    if org.funds_held(workspace.tenant_id, target.user_id) then
      perform identity.fail('conflict', jsonb_build_object('reason', 'wallet_not_empty'));
    end if;
    insert into org.funds_exemptions (tenant_id, membership_id, user_id, set_by, set_reason)
    values (workspace.tenant_id, target.id, target.user_id, p_user_id, clean_reason);
  else
    update org.funds_exemptions
    set cleared_by = p_user_id, cleared_reason = clean_reason, cleared_at = now()
    where membership_id = target.id and cleared_at is null;
  end if;

  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id,
    case when p_not_managed then 'membership.funds_not_managed' else 'membership.funds_managed' end,
    'membership', target.id::text, clean_reason,
    jsonb_build_object('fundsNotManaged', currently), jsonb_build_object('fundsNotManaged', p_not_managed),
    p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'set_funds_managed', request,
    jsonb_build_object('membershipId', target.id, 'fundsNotManaged', p_not_managed, 'changed', true));
end;
$$;

-- ── Reads ─────────────────────────────────────────────────────────────────

-- The workspace list (Blueprint 20) gains fundsNotManaged.
create or replace function org.workspaces_json(p_user_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select jsonb_agg(jsonb_build_object(
      'membershipId', m.id,
      'tenantId', t.id,
      'tenantName', t.name,
      'tenantShortName', t.short_name,
      'tenantStatus', t.status,
      'officeId', o.id,
      'officeName', o.name,
      'officeType', o.office_type,
      'role', m.role,
      'status', m.status,
      'isPrimary', m.is_primary,
      'fundsNotManaged', org.funds_not_managed(m.id)
    ) order by t.name, t.id, m.is_primary desc, m.started_at, m.id)
    from org.memberships m
    join org.tenants t on t.id = m.tenant_id
    left join org.offices o on o.id = m.office_id
    where m.user_id = p_user_id and m.status <> 'ended'
  ), '[]'::jsonb);
$$;

-- member_detail (Blueprint 07) gains fundsNotManaged, fundsBlocked and
-- actions.funds.
create or replace function api.member_detail(p_user_id uuid, p_session_id uuid, p_membership_id uuid, p_target_membership_id uuid)
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
    -- Blueprint 22: the funds switch (President Team, directors only).
    'fundsNotManaged', org.funds_not_managed(target.id),
    'fundsBlocked', case
      when workspace.role = 'president_team_member' and target.role = 'director' and target.status <> 'ended'
        and not org.funds_not_managed(target.id) and org.funds_held(workspace.tenant_id, target.user_id)
        then 'wallet_not_empty' end,
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
      'funds', target.role = 'director' and target.status <> 'ended' and target.user_id <> p_user_id
        and workspace.role = 'president_team_member'
        and exists (select 1 from org.tenants t where t.id = workspace.tenant_id and t.status = 'active'),
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

revoke all on function org.funds_held(uuid, uuid) from public, anon, authenticated;
revoke all on function org.funds_lock_key(uuid) from public, anon, authenticated;
revoke all on function ledger.refuse_unmanaged_funds() from public, anon, authenticated;
revoke all on function finance.target_eligible(org.memberships) from public, anon, authenticated;
revoke all on function authz.decide(uuid, text, uuid, uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function org.workspaces_json(uuid) from public, anon, authenticated;
do $$
declare
  f text;
begin
  foreach f in array array[
    'api.set_funds_managed(uuid, uuid, uuid, uuid, boolean, text, text, text)',
    'api.member_detail(uuid, uuid, uuid, uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
