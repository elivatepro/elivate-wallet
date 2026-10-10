-- Blueprint 20 — B5: one read to open the app and one read for Home.
--   * api.app_bootstrap replaces the five sequential calls behind
--     /api/session (state → profile → workspaces → capabilities → brand).
--   * api.home_view replaces the four behind /api/home (workspaces → wallet →
--     activity + split): the tenant comes from the membership, server-side.
--   * api.my_wallet and api.my_activity take an optional membership instead
--     of a tenant id, so the money reads no longer refetch the workspace list
--     just to learn the tenant.
-- Both new reads are read-only, run require_session once, and check that the
-- membership is the caller's. The pieces they reuse are lifted out of the
-- existing api functions unchanged (org.workspaces_json,
-- org.capabilities_json), so the separate reads and these stay equal
-- (pgTAP 203 and 204).

-- ── Shared pieces ─────────────────────────────────────────────────────────

-- The caller's workspaces: every membership that has not ended (W-02).
create function org.workspaces_json(p_user_id uuid)
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
      'isPrimary', m.is_primary
    ) order by t.name, t.id, m.is_primary desc, m.started_at, m.id)
    from org.memberships m
    join org.tenants t on t.id = m.tenant_id
    left join org.offices o on o.id = m.office_id
    where m.user_id = p_user_id and m.status <> 'ended'
  ), '[]'::jsonb);
$$;

-- One of the caller's workspaces (the same set as org.workspaces_json), or
-- workspace_invalid. Reads of the caller's own money use it to learn the
-- tenant; authorization still happens where it always did.
create function org.own_membership(p_user_id uuid, p_membership_id uuid)
returns org.memberships
language plpgsql
stable
set search_path = ''
as $$
declare
  membership org.memberships;
begin
  select m.* into membership from org.memberships m
  where m.id = p_membership_id and m.user_id = p_user_id and m.status <> 'ended';
  if membership.id is null then
    perform identity.fail('workspace_invalid');
  end if;
  return membership;
end;
$$;

-- The capabilities of an (already required) workspace: what the nav shows.
create function org.capabilities_json(p_user_id uuid, p_workspace org.memberships)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  tenant_status org.tenant_status;
begin
  select status into tenant_status from org.tenants where id = p_workspace.tenant_id;

  return jsonb_build_object(
    'membershipId', p_workspace.id,
    'tenantStatus', tenant_status,
    'billingOwner', exists (select 1 from billing.owners o
                            where o.tenant_id = p_workspace.tenant_id and o.user_id = p_user_id and o.ended_at is null),
    'permissions', coalesce((
      select jsonb_agg(c.key order by c.key)
      from authz.permission_catalog c
      where (authz.decide(
          p_user_id, c.key, p_workspace.tenant_id,
          case when c.scope = 'office' then p_workspace.office_id end,
          case when c.scope = 'self' then p_user_id end,
          p_workspace.id
        )->>'allowed')::boolean
        -- Held only for specific targets: the server still checks each action.
        or (c.scope in ('office', 'tenant') and exists (
          select 1 from authz.access_rules r
          join authz.access_assignments a on a.id = r.assignment_id
          where r.tenant_id = p_workspace.tenant_id and r.subject_user_id = p_user_id
            and r.permission_key = c.key and r.effect = 'allow'
            and r.revoked_at is null and a.revoked_at is null
            and r.starts_at <= now() and (r.expires_at is null or r.expires_at > now())
        ))
        or (c.scope = 'assignment' and tenant_status in ('active', 'suspended') and exists (
          select 1 from authz.reviewer_assignments ra
          where ra.membership_id = p_workspace.id and ra.ended_at is null
        ))
    ), '[]'::jsonb)
  );
end;
$$;

-- The profile as GET /identity/profile shows it: the photo's storage key
-- becomes a flag.
create function identity.public_profile(p_user_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select (v - 'photoKey') || jsonb_build_object('hasPhoto', coalesce(jsonb_typeof(v->'photoKey') = 'string', false))
  from (select identity.profile_view(p_user_id) as v) p;
$$;

-- ── The separate reads, now on the shared pieces (same output) ────────────

create or replace function api.my_workspaces(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  return org.workspaces_json(p_user_id);
end;
$$;

create or replace function api.my_capabilities(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  return org.capabilities_json(p_user_id, authz.require_workspace(p_user_id, p_membership_id));
end;
$$;

-- ── Opening the app ───────────────────────────────────────────────────────

-- { state, profile, workspace, capabilities, brand }. Before the PIN gate is
-- ready only the state is filled (no activity is recorded). The profile and
-- the brand are niceties: any failure leaves them null. A membership that is
-- not one of the caller's workspaces leaves the workspace null; one that is
-- listed but not usable fails with workspace_invalid, exactly like the
-- capabilities read.
create function api.app_bootstrap(p_user_id uuid, p_session_id uuid, p_membership_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  state jsonb;
  profile jsonb;
  workspace jsonb;
  capabilities jsonb;
  brand jsonb;
  membership org.memberships;
begin
  perform identity.require_live_session(p_user_id, p_session_id);
  state := identity.security_state(p_user_id, p_session_id);
  if state->>'gate' is distinct from 'ready' then
    return jsonb_build_object('state', state, 'profile', null, 'workspace', null, 'capabilities', null,
      'brand', null);
  end if;
  perform identity.require_session(p_user_id, p_session_id);

  begin
    profile := identity.public_profile(p_user_id);
  exception when others then
    profile := null;
  end;

  if p_membership_id is not null then
    select w.value into workspace
    from jsonb_array_elements(org.workspaces_json(p_user_id)) w
    where w.value->>'membershipId' = p_membership_id::text;
  end if;

  if workspace is not null then
    membership := authz.require_workspace(p_user_id, p_membership_id);
    capabilities := org.capabilities_json(p_user_id, membership);
    begin
      perform org.require_readable_tenant(membership.tenant_id);
      brand := org.brand_json(membership.tenant_id);
    exception when others then
      brand := null;
    end;
  end if;

  return jsonb_build_object('state', state, 'profile', profile, 'workspace', workspace,
    'capabilities', capabilities, 'brand', brand);
end;
$$;

-- ── Home (W-07) ───────────────────────────────────────────────────────────

-- { network, activity, split }: the selected network's slice of the caller's
-- own wallet, its five latest movements (no month summaries) and the split
-- percentages. network is null (and activity empty) when the caller has no
-- wallet in this network; split is null when it is unavailable.
create function api.home_view(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  membership org.memberships;
  v_wallet_id uuid;
  network jsonb;
  activity jsonb;
  allocation jsonb;
  split jsonb;
  empty constant jsonb := jsonb_build_object('network', null, 'activity', '[]'::jsonb, 'split', null);
begin
  perform identity.require_session(p_user_id, p_session_id);
  membership := org.own_membership(p_user_id, p_membership_id);
  v_wallet_id := ledger.wallet_for(p_user_id);
  if v_wallet_id is null then
    return empty;
  end if;
  network := ledger.wallet_networks(v_wallet_id, membership.tenant_id)->0;
  if network is null then
    return empty;
  end if;

  activity := ledger.activity(v_wallet_id, membership.tenant_id, null, null, null, null, null, null, null, null, 5,
    p_months => false)->'items';

  -- Percentages are a label; their absence never hides balances.
  begin
    allocation := ledger.allocation_json((authz.require_workspace(p_user_id, p_membership_id)).tenant_id);
    if allocation is not null then
      split := coalesce((
        select jsonb_agg(jsonb_build_object('pocketId', p.value->'pocketId', 'percent', p.value->'percent')
          order by p.ordinality)
        from jsonb_array_elements(allocation->'pockets') with ordinality p
      ), '[]'::jsonb);
    end if;
  exception when others then
    split := null;
  end;

  return jsonb_build_object('network', network, 'activity', activity, 'split', split);
end;
$$;

-- ── Own money reads by membership ─────────────────────────────────────────

-- p_membership_id (optional): only that workspace's network.
drop function api.my_wallet(uuid, uuid);
create function api.my_wallet(p_user_id uuid, p_session_id uuid, p_membership_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet_id uuid;
  v_tenant_id uuid;
begin
  perform identity.require_session(p_user_id, p_session_id);
  if p_membership_id is not null then
    v_tenant_id := (org.own_membership(p_user_id, p_membership_id)).tenant_id;
  end if;
  v_wallet_id := ledger.require_wallet(p_user_id);
  return jsonb_build_object('walletId', v_wallet_id, 'networks', ledger.wallet_networks(v_wallet_id, v_tenant_id));
end;
$$;

-- p_membership_id (optional, instead of p_tenant_id): that workspace's network.
drop function api.my_activity(uuid, uuid, uuid, text, uuid, text, text, text, text, text, int, text, text, text);
create function api.my_activity(
  p_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid default null,
  p_currency text default null,
  p_pocket_id uuid default null,
  p_direction text default null,
  p_type text default null,
  p_from text default null,
  p_to text default null,
  p_cursor text default null,
  p_limit int default null,
  p_query text default null,
  p_status text default null,
  p_tz text default null,
  p_membership_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet_id uuid;
  v_tenant_id uuid := p_tenant_id;
begin
  perform identity.require_session(p_user_id, p_session_id);
  if p_membership_id is not null then
    if p_tenant_id is not null then
      perform identity.fail('validation_error', jsonb_build_object('field', 'tenantId'));
    end if;
    v_tenant_id := (org.own_membership(p_user_id, p_membership_id)).tenant_id;
  end if;
  v_wallet_id := ledger.require_wallet(p_user_id);
  return ledger.activity(v_wallet_id, v_tenant_id, null, p_currency, p_pocket_id, p_direction, p_type,
    p_from, p_to, p_cursor, p_limit, p_query, p_status, p_tz);
end;
$$;

-- ── Privileges ────────────────────────────────────────────────────────────

revoke all on function org.workspaces_json(uuid) from public, anon, authenticated;
revoke all on function org.own_membership(uuid, uuid) from public, anon, authenticated;
revoke all on function org.capabilities_json(uuid, org.memberships) from public, anon, authenticated;
revoke all on function identity.public_profile(uuid) from public, anon, authenticated;
do $$
declare
  f text;
begin
  foreach f in array array[
    'api.my_workspaces(uuid, uuid)',
    'api.my_capabilities(uuid, uuid, uuid)',
    'api.app_bootstrap(uuid, uuid, uuid)',
    'api.home_view(uuid, uuid, uuid)',
    'api.my_wallet(uuid, uuid, uuid)',
    'api.my_activity(uuid, uuid, uuid, text, uuid, text, text, text, text, text, int, text, text, text, uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
