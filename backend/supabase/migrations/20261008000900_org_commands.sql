-- Blueprint 02 — B4: commands and reads called by the `org` Edge Function.
-- Order in every command: session gate (step-up where required) → workspace →
-- authorization → idempotent replay → state checks → effects. Replays therefore
-- always re-check current authority (A-01).

-- ── Small helpers ─────────────────────────────────────────────────────────

create function org.require_text(p_value text, p_field text, p_min int, p_max int)
returns text
language plpgsql
set search_path = ''
as $$
begin
  if p_value is null or length(btrim(p_value)) not between p_min and p_max then
    perform identity.fail('validation_error', jsonb_build_object('field', p_field));
  end if;
  return btrim(p_value);
end;
$$;

create function org.page_limit(p_limit int)
returns int
language plpgsql
set search_path = ''
as $$
begin
  if p_limit is not null and p_limit not between 1 and 100 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'limit'));
  end if;
  return coalesce(p_limit, 50);
end;
$$;

create function org.encode_cursor(p_value jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select translate(encode(convert_to(p_value::text, 'UTF8'), 'base64'), E'\n', '');
$$;

create function org.decode_cursor(p_cursor text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  decoded jsonb;
begin
  if p_cursor is null then
    return null;
  end if;
  begin
    decoded := convert_from(decode(p_cursor, 'base64'), 'UTF8')::jsonb;
  exception when others then
    perform identity.fail('validation_error', jsonb_build_object('field', 'cursor'));
  end;
  if jsonb_typeof(decoded) <> 'object' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'cursor'));
  end if;
  return decoded;
end;
$$;

create function org.person(p_user_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'uid', a.uid,
    'name', coalesce(nullif(btrim(p.display_name), ''), nullif(btrim(concat_ws(' ', p.first_name, p.last_name)), ''))
  )
  from identity.accounts a
  left join identity.profiles p on p.user_id = a.user_id
  where a.user_id = p_user_id;
$$;

create function org.office_in_tenant(p_tenant_id uuid, p_office_id uuid)
returns org.offices
language plpgsql
set search_path = ''
as $$
declare
  office org.offices;
begin
  select * into office from org.offices where id = p_office_id and tenant_id = p_tenant_id;
  if office.id is null then
    perform identity.fail('not_found');
  end if;
  return office;
end;
$$;

create function org.membership_in_tenant(p_tenant_id uuid, p_membership_id uuid)
returns org.memberships
language plpgsql
set search_path = ''
as $$
declare
  membership org.memberships;
begin
  select * into membership from org.memberships where id = p_membership_id and tenant_id = p_tenant_id;
  if membership.id is null then
    perform identity.fail('not_found');
  end if;
  return membership;
end;
$$;

-- Workspace for an organizational change: actor's active membership in an
-- active network.
create function org.change_workspace(p_user_id uuid, p_membership_id uuid)
returns org.memberships
language plpgsql
set search_path = ''
as $$
declare
  workspace org.memberships;
begin
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform org.require_active_tenant(workspace.tenant_id);
  return workspace;
end;
$$;

-- Session gate for organizational writes: restricted accounts may read but not
-- change anything (Blueprint 02 B3).
create function org.require_writer(p_user_id uuid, p_session_id uuid, p_step_up boolean default false)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if identity.require_session(p_user_id, p_session_id, p_step_up => p_step_up) <> 'active' then
    perform identity.fail('authorization_denied', jsonb_build_object('reason', 'account_not_active'));
  end if;
end;
$$;

-- ── Networks ──────────────────────────────────────────────────────────────

create function api.start_network(
  p_user_id uuid,
  p_session_id uuid,
  p_name text,
  p_short_name text,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  account_status identity.account_status;
  clean_name text;
  clean_short text;
  request jsonb;
  replayed jsonb;
  tenant_id uuid;
  president org.memberships;
begin
  account_status := identity.require_session(p_user_id, p_session_id);
  if account_status <> 'active' then
    perform identity.fail('authorization_denied', jsonb_build_object('reason', 'account_not_active'));
  end if;
  clean_name := org.require_text(p_name, 'name', 2, 100);
  clean_short := org.require_text(p_short_name, 'shortName', 1, 30);

  request := jsonb_build_object('name', clean_name, 'shortName', clean_short);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'start_network', request);
  if replayed is not null then
    return replayed;
  end if;

  begin
    insert into org.tenants (name, short_name, created_by)
    values (clean_name, clean_short, p_user_id)
    returning id into tenant_id;
  exception when unique_violation then
    perform identity.fail('conflict', jsonb_build_object('reason', 'pending_network_exists'));
  end;

  perform authz.seed_role_permissions(tenant_id);
  president := org.create_membership(tenant_id, null, p_user_id, 'president_team_member', p_user_id);
  perform audit.record_tenant(tenant_id, p_user_id, 'tenant.created', 'tenant', tenant_id::text,
    p_safe_after => jsonb_build_object('status', 'pending_payment', 'name', clean_name), p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'start_network', request,
    jsonb_build_object('tenantId', tenant_id, 'status', 'pending_payment', 'membershipId', president.id));
end;
$$;

create function api.activate_tenant(
  p_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
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
  clean_reason text;
  request jsonb;
  replayed jsonb;
  tenant org.tenants;
begin
  perform pg_advisory_xact_lock(hashtextextended('identity.platform_admins', 0));
  perform identity.require_session(p_user_id, p_session_id, p_step_up => true);
  perform identity.require_platform_admin(p_user_id);
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('tenantId', p_tenant_id, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'activate_tenant', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into tenant from org.tenants where id = p_tenant_id for update;
  if tenant.id is null then
    perform identity.fail('not_found');
  end if;
  if tenant.status <> 'pending_payment' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'not_pending'));
  end if;

  update org.tenants
  set status = 'active', activated_at = now(), activated_by = p_user_id, activation_source = 'admin'
  where id = p_tenant_id;
  perform audit.record_tenant(p_tenant_id, p_user_id, 'tenant.activated', 'tenant', p_tenant_id::text, clean_reason,
    jsonb_build_object('status', 'pending_payment'), jsonb_build_object('status', 'active', 'source', 'admin'), p_request_id);
  perform audit.record('tenant.activated', p_user_id, p_session_id, null, clean_reason,
    p_safe_after => jsonb_build_object('tenantId', p_tenant_id), p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'activate_tenant', request,
    jsonb_build_object('tenantId', p_tenant_id, 'status', 'active'));
end;
$$;

-- ── Workspaces and capabilities ───────────────────────────────────────────

create function api.my_workspaces(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  return coalesce((
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
end;
$$;

create function api.my_capabilities(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  tenant_status org.tenant_status;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  select status into tenant_status from org.tenants where id = workspace.tenant_id;

  return jsonb_build_object(
    'membershipId', workspace.id,
    'tenantStatus', tenant_status,
    'permissions', coalesce((
      select jsonb_agg(c.key order by c.key)
      from authz.permission_catalog c
      where (authz.decide(
          p_user_id, c.key, workspace.tenant_id,
          case when c.scope = 'office' then workspace.office_id end,
          case when c.scope = 'self' then p_user_id end,
          workspace.id
        )->>'allowed')::boolean
        -- Held only for specific targets: the server still checks each action.
        or (c.scope in ('office', 'tenant') and exists (
          select 1 from authz.access_rules r
          join authz.access_assignments a on a.id = r.assignment_id
          where r.tenant_id = workspace.tenant_id and r.subject_user_id = p_user_id
            and r.permission_key = c.key and r.effect = 'allow'
            and r.revoked_at is null and a.revoked_at is null
            and r.starts_at <= now() and (r.expires_at is null or r.expires_at > now())
        ))
        or (c.scope = 'assignment' and tenant_status = 'active' and exists (
          select 1 from authz.reviewer_assignments ra
          where ra.membership_id = workspace.id and ra.ended_at is null
        ))
    ), '[]'::jsonb)
  );
end;
$$;

-- ── Offices ───────────────────────────────────────────────────────────────

create function api.list_offices(
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
      'memberCount', (select count(*) from org.memberships l
                      where l.office_id = o.id and l.status = 'active')
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

create function api.create_office(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_type text,
  p_name text,
  p_parent_office_id uuid,
  p_leader_uids text[],
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
  clean_uids text[];
  request jsonb;
  replayed jsonb;
  office org.offices;
  leader org.memberships;
  leader_ids uuid[] := '{}'::uuid[];
  leader_uid text;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform authz.require_president(workspace);

  if p_type is null or p_type not in ('world_team', 'director', 'team_leader') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'type'));
  end if;
  clean_name := org.require_text(p_name, 'name', 2, 100);
  select array_agg(distinct upper(btrim(u)) order by upper(btrim(u))) into clean_uids from unnest(p_leader_uids) u;
  if clean_uids is null or cardinality(clean_uids) <> cardinality(p_leader_uids)
    or cardinality(clean_uids) not between 1 and 20 or array_position(clean_uids, null) is not null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'leaderUids'));
  end if;
  if p_parent_office_id is not null then
    perform org.office_in_tenant(workspace.tenant_id, p_parent_office_id);
  end if;

  request := jsonb_build_object('membershipId', workspace.id, 'type', p_type, 'name', clean_name,
    'parentOfficeId', p_parent_office_id, 'leaderUids', to_jsonb(clean_uids));
  replayed := identity.replay(p_user_id, p_idempotency_key, 'create_office', request);
  if replayed is not null then
    return replayed;
  end if;

  perform org.lock_tree(workspace.tenant_id);
  insert into org.offices (tenant_id, parent_office_id, office_type, name, created_by)
  values (workspace.tenant_id, p_parent_office_id, p_type::org.office_type, clean_name, p_user_id)
  returning * into office;

  foreach leader_uid in array clean_uids loop
    leader := org.create_membership(workspace.tenant_id, office.id, identity.account_by_uid(leader_uid),
      org.leader_role(office.office_type), p_user_id);
    leader_ids := leader_ids || leader.id;
  end loop;

  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'office.created', 'office', office.id::text,
    p_safe_after => jsonb_build_object('name', office.name, 'type', office.office_type,
      'parentOfficeId', office.parent_office_id, 'leaders', cardinality(leader_ids)),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'create_office', request,
    jsonb_build_object('officeId', office.id, 'leaderMembershipIds', to_jsonb(leader_ids)));
end;
$$;

create function api.rename_office(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_office_id uuid,
  p_name text,
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
  clean_name text;
  request jsonb;
  replayed jsonb;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  office := org.office_in_tenant(workspace.tenant_id, p_office_id);
  perform authz.require(p_user_id, 'manage_members', workspace.tenant_id, office.id, null, workspace.id);
  clean_name := org.require_text(p_name, 'name', 2, 100);

  request := jsonb_build_object('officeId', office.id, 'name', clean_name);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'rename_office', request);
  if replayed is not null then
    return replayed;
  end if;

  update org.offices set name = clean_name where id = office.id;
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'office.renamed', 'office', office.id::text,
    p_safe_before => jsonb_build_object('name', office.name), p_safe_after => jsonb_build_object('name', clean_name),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'rename_office', request,
    jsonb_build_object('officeId', office.id, 'name', clean_name));
end;
$$;

-- Places an office, with its whole subtree, at the top or under a higher office (Q2).
create function api.place_office(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_office_id uuid,
  p_parent_office_id uuid,
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
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform authz.require_president(workspace);
  office := org.office_in_tenant(workspace.tenant_id, p_office_id);
  if p_parent_office_id is not null then
    perform org.office_in_tenant(workspace.tenant_id, p_parent_office_id);
  end if;
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('officeId', office.id, 'parentOfficeId', p_parent_office_id, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'place_office', request);
  if replayed is not null then
    return replayed;
  end if;

  perform org.lock_tree(workspace.tenant_id);
  select * into office from org.offices where id = office.id for update;
  if office.parent_office_id is not distinct from p_parent_office_id then
    return identity.store_result(p_user_id, p_idempotency_key, 'place_office', request,
      jsonb_build_object('officeId', office.id, 'parentOfficeId', p_parent_office_id, 'changed', false));
  end if;

  update org.offices set parent_office_id = p_parent_office_id where id = office.id;
  insert into org.office_moves (tenant_id, office_id, from_parent_id, to_parent_id, reason, actor_user_id)
  values (workspace.tenant_id, office.id, office.parent_office_id, p_parent_office_id, clean_reason, p_user_id);
  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'office.placed', 'office', office.id::text, clean_reason,
    jsonb_build_object('parentOfficeId', office.parent_office_id), jsonb_build_object('parentOfficeId', p_parent_office_id),
    p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'place_office', request,
    jsonb_build_object('officeId', office.id, 'parentOfficeId', p_parent_office_id, 'changed', true));
end;
$$;

-- ── Leaders ───────────────────────────────────────────────────────────────

create function api.add_office_leader(
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
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('officeId', office.id, 'leaderUid', upper(btrim(p_leader_uid)), 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'add_office_leader', request);
  if replayed is not null then
    return replayed;
  end if;

  perform 1 from org.offices where id = office.id for update;
  leader := org.create_membership(workspace.tenant_id, office.id, leader_user_id, org.leader_role(office.office_type), p_user_id);
  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'office.leader_added', 'membership', leader.id::text, clean_reason,
    p_safe_after => jsonb_build_object('officeId', office.id, 'role', leader.role), p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'add_office_leader', request,
    jsonb_build_object('membershipId', leader.id));
end;
$$;

-- Replaces one leader with another (W-05): the incoming person's other open
-- memberships in this office end, the outgoing leadership ends.
create function api.replace_office_leader(
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
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('officeId', office.id, 'outgoingMembershipId', outgoing.id,
    'incomingUid', upper(btrim(p_incoming_uid)), 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'replace_office_leader', request);
  if replayed is not null then
    return replayed;
  end if;

  perform 1 from org.offices where id = office.id for update;
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

-- ── Memberships ───────────────────────────────────────────────────────────

create function api.add_membership(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_office_id uuid,
  p_member_uid text,
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
  member_user_id uuid;
  request jsonb;
  replayed jsonb;
  created org.memberships;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  office := org.office_in_tenant(workspace.tenant_id, p_office_id);
  member_user_id := identity.account_by_uid(p_member_uid);
  perform authz.require(p_user_id, 'manage_members', workspace.tenant_id, office.id, member_user_id, workspace.id);

  request := jsonb_build_object('officeId', office.id, 'memberUid', upper(btrim(p_member_uid)));
  replayed := identity.replay(p_user_id, p_idempotency_key, 'add_membership', request);
  if replayed is not null then
    return replayed;
  end if;

  created := org.create_membership(workspace.tenant_id, office.id, member_user_id, 'member', p_user_id);
  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'membership.added', 'membership', created.id::text,
    p_safe_after => jsonb_build_object('officeId', office.id, 'role', 'member'), p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'add_membership', request,
    jsonb_build_object('membershipId', created.id, 'isPrimary', created.is_primary));
end;
$$;

create function api.move_membership(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_target_membership_id uuid,
  p_to_office_id uuid,
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
  destination org.offices;
  clean_reason text;
  request jsonb;
  replayed jsonb;
  moved org.memberships;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  target := org.membership_in_tenant(workspace.tenant_id, p_target_membership_id);
  if target.office_id is null then
    perform identity.fail('conflict', jsonb_build_object('reason', 'president_membership'));
  end if;
  destination := org.office_in_tenant(workspace.tenant_id, p_to_office_id);
  perform authz.require(p_user_id, 'move_membership', workspace.tenant_id, target.office_id, target.user_id, workspace.id);
  perform authz.require(p_user_id, 'move_membership', workspace.tenant_id, destination.id, target.user_id, workspace.id);
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('targetMembershipId', target.id, 'toOfficeId', destination.id, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'move_membership', request);
  if replayed is not null then
    return replayed;
  end if;

  perform 1 from org.offices where id in (target.office_id, destination.id) order by id for update;
  select * into target from org.memberships where id = target.id for update;
  if target.status <> 'active' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'membership_not_active'));
  end if;
  if destination.id = target.office_id then
    perform identity.fail('validation_error', jsonb_build_object('field', 'toOfficeId'));
  end if;

  moved := org.create_membership(workspace.tenant_id, destination.id, target.user_id, target.role, p_user_id, false);
  perform org.end_membership(target.id, clean_reason, p_user_id, 'moved', moved.id);
  if target.is_primary then
    update org.memberships set is_primary = true where id = moved.id;
  end if;
  perform org.assert_leader_remains(target.office_id);
  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'membership.moved', 'membership', target.id::text, clean_reason,
    jsonb_build_object('officeId', target.office_id), jsonb_build_object('officeId', destination.id, 'membershipId', moved.id),
    p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'move_membership', request,
    jsonb_build_object('endedMembershipId', target.id, 'membershipId', moved.id));
end;
$$;

-- Who may suspend/end a membership: President Team memberships only by the
-- President Team (Q5, never oneself); others by the matching permission.
create function org.require_lifecycle_authority(
  p_user_id uuid,
  p_workspace org.memberships,
  p_target org.memberships,
  p_permission_key text
)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_target.role = 'president_team_member' then
    perform authz.require_president(p_workspace);
    if p_target.user_id = p_user_id then
      perform identity.fail('self_target_forbidden');
    end if;
  else
    perform authz.require(p_user_id, p_permission_key, p_workspace.tenant_id, p_target.office_id, p_target.user_id, p_workspace.id);
  end if;
end;
$$;

-- Locks what a membership change must keep consistent, then checks the
-- last-leader and last-President rules after the change.
create function org.lock_for_change(p_target org.memberships)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_target.office_id is null then
    perform 1 from org.tenants where id = p_target.tenant_id for update;
  else
    perform 1 from org.offices where id = p_target.office_id for update;
  end if;
end;
$$;

create function org.assert_after_change(p_target org.memberships)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_target.office_id is null then
    perform org.assert_president_remains(p_target.tenant_id);
  else
    perform org.assert_leader_remains(p_target.office_id);
  end if;
end;
$$;

create function api.set_membership_status(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_target_membership_id uuid,
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
  workspace org.memberships;
  target org.memberships;
  clean_reason text;
  request jsonb;
  replayed jsonb;
  updated org.memberships;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  target := org.membership_in_tenant(workspace.tenant_id, p_target_membership_id);
  perform org.require_lifecycle_authority(p_user_id, workspace, target, 'suspend_membership');
  if p_status is null or p_status not in ('active', 'suspended') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'status'));
  end if;
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('targetMembershipId', target.id, 'status', p_status, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'set_membership_status', request);
  if replayed is not null then
    return replayed;
  end if;

  perform org.lock_for_change(target);
  select * into target from org.memberships where id = target.id for update;
  if target.status = 'ended' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'membership_ended'));
  end if;
  if target.status::text = p_status then
    return identity.store_result(p_user_id, p_idempotency_key, 'set_membership_status', request,
      jsonb_build_object('membershipId', target.id, 'status', p_status, 'changed', false));
  end if;

  update org.memberships set status = p_status::org.membership_status where id = target.id returning * into updated;
  perform org.record_membership_event(updated,
    case when p_status = 'suspended' then 'suspended' else 'reactivated' end, target.status, clean_reason, p_user_id);
  perform org.assert_after_change(target);
  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'membership.' || updated.status::text, 'membership', target.id::text,
    clean_reason, jsonb_build_object('status', target.status), jsonb_build_object('status', updated.status), p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'set_membership_status', request,
    jsonb_build_object('membershipId', target.id, 'status', p_status, 'changed', true));
end;
$$;

create function api.end_membership(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_target_membership_id uuid,
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
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  target := org.membership_in_tenant(workspace.tenant_id, p_target_membership_id);
  perform org.require_lifecycle_authority(p_user_id, workspace, target, 'end_membership');
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('targetMembershipId', target.id, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'end_membership', request);
  if replayed is not null then
    return replayed;
  end if;

  perform org.lock_for_change(target);
  select * into target from org.memberships where id = target.id for update;
  if target.status = 'ended' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'membership_ended'));
  end if;

  perform org.end_membership(target.id, clean_reason, p_user_id);
  perform org.ensure_primary(target.tenant_id, target.user_id);
  perform org.assert_after_change(target);
  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'membership.ended', 'membership', target.id::text, clean_reason,
    jsonb_build_object('status', target.status), jsonb_build_object('status', 'ended'), p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'end_membership', request,
    jsonb_build_object('membershipId', target.id, 'status', 'ended'));
end;
$$;

-- ── President Team (Q5) ───────────────────────────────────────────────────

create function api.add_president(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_member_uid text,
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
  president_user_id uuid;
  clean_reason text;
  request jsonb;
  replayed jsonb;
  created org.memberships;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform authz.require_president(workspace);
  president_user_id := identity.account_by_uid(p_member_uid);
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('tenantId', workspace.tenant_id, 'memberUid', upper(btrim(p_member_uid)), 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'add_president', request);
  if replayed is not null then
    return replayed;
  end if;

  perform 1 from org.tenants where id = workspace.tenant_id for update;
  created := org.create_membership(workspace.tenant_id, null, president_user_id, 'president_team_member', p_user_id);
  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'president.added', 'membership', created.id::text, clean_reason,
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'add_president', request,
    jsonb_build_object('membershipId', created.id));
end;
$$;

create function api.remove_president(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_target_membership_id uuid,
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
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform authz.require_president(workspace);
  target := org.membership_in_tenant(workspace.tenant_id, p_target_membership_id);
  if target.role <> 'president_team_member' then
    perform identity.fail('not_found');
  end if;
  return api.end_membership(p_user_id, p_session_id, p_membership_id, p_target_membership_id,
    p_reason, p_idempotency_key, p_request_id);
end;
$$;

-- ── Members ───────────────────────────────────────────────────────────────

create function api.list_members(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_office_id uuid default null,
  p_role text default null,
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
  page_size := org.page_limit(p_limit);
  after := org.decode_cursor(p_cursor);

  select coalesce(jsonb_agg(item order by item->>'startedAt', item->>'membershipId'), '[]'::jsonb) into rows
  from (
    select jsonb_build_object(
      'membershipId', m.id,
      'person', org.person(m.user_id),
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
    where m.tenant_id = workspace.tenant_id
      and (
        (scope_office_id is null)
        or exists (select 1 from org.office_closure c where c.ancestor_id = scope_office_id and c.descendant_id = m.office_id)
      )
      and (p_role is null or m.role = p_role::org.role)
      and (case when p_status is null then m.status <> 'ended' else m.status = p_status::org.membership_status end)
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

-- ── Role permissions ──────────────────────────────────────────────────────

create function api.list_role_permissions(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform authz.require_president(workspace);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'permission', c.key,
      'role', rp.role,
      'allowed', rp.allowed,
      'editable', not c.protected and c.scope <> 'assignment'
    ) order by c.key, rp.role)
    from authz.role_permissions rp
    join authz.permission_catalog c on c.key = rp.permission_key
    where rp.tenant_id = workspace.tenant_id
  ), '[]'::jsonb);
end;
$$;

create function api.set_role_permission(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_role text,
  p_permission_key text,
  p_allowed boolean,
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
  permission authz.permission_catalog;
  clean_reason text;
  request jsonb;
  replayed jsonb;
  previous boolean;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  perform authz.require(p_user_id, 'manage_role_permissions', workspace.tenant_id, null, null, workspace.id);
  if p_role is null or p_role not in ('member', 'team_leader', 'director', 'world_team_member', 'president_team_member') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'role'));
  end if;
  if p_allowed is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'allowed'));
  end if;
  select * into permission from authz.permission_catalog where key = p_permission_key;
  if permission.key is null then
    perform identity.fail('not_found');
  end if;
  if permission.protected or permission.scope = 'assignment' then
    perform identity.fail('permission_not_grantable',
      jsonb_build_object('reason', case when permission.protected then 'protected' else 'assignment_only' end));
  end if;
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('tenantId', workspace.tenant_id, 'role', p_role, 'permission', p_permission_key,
    'allowed', p_allowed, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'set_role_permission', request);
  if replayed is not null then
    return replayed;
  end if;

  select allowed into previous from authz.role_permissions
  where tenant_id = workspace.tenant_id and role = p_role::org.role and permission_key = p_permission_key
  for update;
  update authz.role_permissions
  set allowed = p_allowed, updated_by = p_user_id, updated_at = now()
  where tenant_id = workspace.tenant_id and role = p_role::org.role and permission_key = p_permission_key;
  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'role_permission.changed', 'role_permission',
    p_role || ':' || p_permission_key, clean_reason,
    jsonb_build_object('allowed', previous), jsonb_build_object('allowed', p_allowed), p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'set_role_permission', request,
    jsonb_build_object('role', p_role, 'permission', p_permission_key, 'allowed', p_allowed, 'changed', previous <> p_allowed));
end;
$$;

-- ── Access rules (W-06) ───────────────────────────────────────────────────

create function org.assignment_json(p_assignment authz.access_assignments)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_assignment.id,
    'subject', org.person(p_assignment.subject_user_id),
    'createdBy', org.person(p_assignment.created_by),
    'reason', p_assignment.reason,
    'createdAt', p_assignment.created_at,
    'revokedAt', p_assignment.revoked_at,
    'revokeReason', p_assignment.revoke_reason,
    'rules', coalesce((
      select jsonb_agg(jsonb_build_object(
        'permission', r.permission_key,
        'effect', r.effect,
        'scopeType', r.scope_type,
        'scopeOfficeId', r.scope_office_id,
        'scopeOfficeName', o.name,
        'scopePerson', case when r.scope_user_id is not null then org.person(r.scope_user_id) end,
        'startsAt', r.starts_at,
        'expiresAt', r.expires_at
      ) order by r.permission_key, r.id)
      from authz.access_rules r
      left join org.offices o on o.id = r.scope_office_id
      where r.assignment_id = p_assignment.id
    ), '[]'::jsonb)
  );
$$;

-- Can the actor manage every rule in the assignment?
create function authz.covers_assignment(p_actor_user_id uuid, p_assignment_id uuid, p_workspace_membership_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select not exists (
    select 1 from authz.access_rules r
    where r.assignment_id = p_assignment_id
      and not authz.covers_scope(p_actor_user_id, r.tenant_id, r.scope_type, r.scope_office_id, r.scope_user_id,
        p_workspace_membership_id)
  );
$$;

create function api.list_access_assignments(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
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
  workspace := org.change_workspace(p_user_id, p_membership_id);
  page_size := org.page_limit(p_limit);
  after := org.decode_cursor(p_cursor);

  select coalesce(jsonb_agg(org.assignment_json(a) order by a.created_at desc, a.id desc), '[]'::jsonb) into rows
  from (
    select a.* from authz.access_assignments a
    where a.tenant_id = workspace.tenant_id
      and authz.covers_assignment(p_user_id, a.id, workspace.id)
      and (after is null or (to_char(a.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'), a.id::text)
                            < (after->>'c', after->>'id'))
    order by a.created_at desc, a.id desc
    limit page_size + 1
  ) a;

  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(e) from jsonb_array_elements(rows) with ordinality as x (e, n) where n <= page_size), '[]'::jsonb),
    'nextCursor', case when jsonb_array_length(rows) > page_size then (
      select org.encode_cursor(jsonb_build_object(
        'c', to_char(a.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'), 'id', a.id))
      from authz.access_assignments a where a.id = (rows->(page_size - 1)->>'id')::uuid
    ) end
  );
end;
$$;

create function api.create_access_assignment(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_subject_uid text,
  p_rules jsonb,
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
  subject_user_id uuid;
  clean_reason text;
  request jsonb;
  replayed jsonb;
  rule jsonb;
  permission authz.permission_catalog;
  scope_type text;
  scope_office_id uuid;
  scope_user_id uuid;
  starts timestamptz;
  expires timestamptz;
  parsed jsonb := '[]'::jsonb;
  assignment_id uuid;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  subject_user_id := identity.account_by_uid(p_subject_uid);
  if subject_user_id = p_user_id then
    perform identity.fail('self_target_forbidden');
  end if;
  if not exists (
    select 1 from org.memberships
    where tenant_id = workspace.tenant_id and user_id = subject_user_id and status = 'active'
  ) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'subject_not_member'));
  end if;
  clean_reason := identity.require_reason(p_reason);
  if p_rules is null or jsonb_typeof(p_rules) <> 'array' or jsonb_array_length(p_rules) not between 1 and 50 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'rules'));
  end if;

  for rule in select value from jsonb_array_elements(p_rules) loop
    if jsonb_typeof(rule) <> 'object' then
      perform identity.fail('validation_error', jsonb_build_object('field', 'rules'));
    end if;
    select * into permission from authz.permission_catalog where key = rule->>'permission';
    if permission.key is null then
      perform identity.fail('validation_error', jsonb_build_object('field', 'rules.permission'));
    end if;
    if permission.protected or not permission.grantable or permission.scope = 'assignment' then
      perform identity.fail('permission_not_grantable', jsonb_build_object('permission', permission.key));
    end if;
    if rule->>'effect' is null or rule->>'effect' not in ('allow', 'deny') then
      perform identity.fail('validation_error', jsonb_build_object('field', 'rules.effect'));
    end if;

    scope_type := rule->>'scopeType';
    scope_office_id := null;
    scope_user_id := null;
    if scope_type = 'office_subtree' then
      begin
        scope_office_id := (rule->>'scopeOfficeId')::uuid;
      exception when others then
        perform identity.fail('validation_error', jsonb_build_object('field', 'rules.scopeOfficeId'));
      end;
      perform org.office_in_tenant(workspace.tenant_id, scope_office_id);
    elsif scope_type = 'member' then
      scope_user_id := identity.account_by_uid(rule->>'scopeUid');
      if not exists (
        select 1 from org.memberships
        where tenant_id = workspace.tenant_id and user_id = scope_user_id and status <> 'ended'
      ) then
        perform identity.fail('not_found');
      end if;
    elsif scope_type is distinct from 'tenant' then
      perform identity.fail('validation_error', jsonb_build_object('field', 'rules.scopeType'));
    end if;

    begin
      starts := coalesce((rule->>'startsAt')::timestamptz, now());
      expires := (rule->>'expiresAt')::timestamptz;
    exception when others then
      perform identity.fail('validation_error', jsonb_build_object('field', 'rules.expiresAt'));
    end;
    if expires is not null and (rule->>'effect' = 'deny' or expires <= greatest(starts, now())) then
      perform identity.fail('validation_error', jsonb_build_object('field', 'rules.expiresAt'));
    end if;

    if not authz.covers_scope(p_user_id, workspace.tenant_id, scope_type, scope_office_id, scope_user_id, workspace.id) then
      perform identity.fail('scope_exceeds_authority', jsonb_build_object('permission', permission.key));
    end if;

    parsed := parsed || jsonb_build_object(
      'permission', permission.key, 'effect', rule->>'effect', 'scopeType', scope_type,
      'scopeOfficeId', scope_office_id, 'scopeUserId', scope_user_id,
      'startsAt', rule->>'startsAt', 'expiresAt', rule->>'expiresAt');
  end loop;

  request := jsonb_build_object('tenantId', workspace.tenant_id, 'subjectUid', upper(btrim(p_subject_uid)),
    'rules', parsed, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'create_access_assignment', request);
  if replayed is not null then
    return replayed;
  end if;

  insert into authz.access_assignments (tenant_id, subject_user_id, created_by, reason)
  values (workspace.tenant_id, subject_user_id, p_user_id, clean_reason)
  returning id into assignment_id;

  insert into authz.access_rules (
    assignment_id, tenant_id, subject_user_id, permission_key, effect, scope_type,
    scope_office_id, scope_user_id, starts_at, expires_at
  )
  select assignment_id, workspace.tenant_id, subject_user_id, r->>'permission', r->>'effect', r->>'scopeType',
    (r->>'scopeOfficeId')::uuid, (r->>'scopeUserId')::uuid,
    coalesce((r->>'startsAt')::timestamptz, now()), (r->>'expiresAt')::timestamptz
  from jsonb_array_elements(parsed) r;

  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'access.assigned', 'access_assignment', assignment_id::text,
    clean_reason, p_safe_after => jsonb_build_object('rules', jsonb_array_length(parsed)), p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'create_access_assignment', request,
    jsonb_build_object('assignmentId', assignment_id));
end;
$$;

create function api.revoke_access_assignment(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_assignment_id uuid,
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
  assignment authz.access_assignments;
  clean_reason text;
  request jsonb;
  replayed jsonb;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  select * into assignment from authz.access_assignments where id = p_assignment_id and tenant_id = workspace.tenant_id;
  if assignment.id is null then
    perform identity.fail('not_found');
  end if;
  if assignment.subject_user_id = p_user_id then
    perform identity.fail('self_target_forbidden');
  end if;
  -- Checked against the person revoking, not the original creator.
  if not authz.covers_assignment(p_user_id, assignment.id, workspace.id) then
    perform identity.fail('scope_exceeds_authority');
  end if;
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('assignmentId', assignment.id, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'revoke_access_assignment', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into assignment from authz.access_assignments where id = assignment.id for update;
  if assignment.revoked_at is not null then
    return identity.store_result(p_user_id, p_idempotency_key, 'revoke_access_assignment', request,
      jsonb_build_object('assignmentId', assignment.id, 'changed', false));
  end if;

  update authz.access_assignments
  set revoked_at = now(), revoked_by = p_user_id, revoke_reason = clean_reason
  where id = assignment.id;
  update authz.access_rules set revoked_at = now() where assignment_id = assignment.id and revoked_at is null;
  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'access.revoked', 'access_assignment', assignment.id::text,
    clean_reason, p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'revoke_access_assignment', request,
    jsonb_build_object('assignmentId', assignment.id, 'changed', true));
end;
$$;

-- ── Evidence reviewers (A-04) ─────────────────────────────────────────────

create function api.list_reviewers(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform authz.require_president(workspace);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'assignmentId', ra.id,
      'membershipId', m.id,
      'person', org.person(m.user_id),
      'role', m.role,
      'officeName', o.name,
      'reason', ra.reason,
      'assignedAt', ra.assigned_at,
      'assignedBy', org.person(ra.assigned_by)
    ) order by ra.assigned_at, ra.id)
    from authz.reviewer_assignments ra
    join org.memberships m on m.id = ra.membership_id
    left join org.offices o on o.id = m.office_id
    where ra.tenant_id = workspace.tenant_id and ra.ended_at is null
  ), '[]'::jsonb);
end;
$$;

create function api.assign_reviewer(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_target_membership_id uuid,
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
  assignment_id uuid;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform authz.require_president(workspace);
  target := org.membership_in_tenant(workspace.tenant_id, p_target_membership_id);
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('targetMembershipId', target.id, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'assign_reviewer', request);
  if replayed is not null then
    return replayed;
  end if;

  if target.status <> 'active' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'membership_not_active'));
  end if;
  begin
    insert into authz.reviewer_assignments (tenant_id, membership_id, assigned_by, reason)
    values (workspace.tenant_id, target.id, p_user_id, clean_reason)
    returning id into assignment_id;
  exception when unique_violation then
    perform identity.fail('conflict', jsonb_build_object('reason', 'already_reviewer'));
  end;
  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'reviewer.assigned', 'reviewer_assignment', assignment_id::text,
    clean_reason, p_safe_after => jsonb_build_object('membershipId', target.id), p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'assign_reviewer', request,
    jsonb_build_object('assignmentId', assignment_id));
end;
$$;

create function api.end_reviewer(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_assignment_id uuid,
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
  assignment authz.reviewer_assignments;
  clean_reason text;
  request jsonb;
  replayed jsonb;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform authz.require_president(workspace);
  select * into assignment from authz.reviewer_assignments where id = p_assignment_id and tenant_id = workspace.tenant_id;
  if assignment.id is null then
    perform identity.fail('not_found');
  end if;
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('assignmentId', assignment.id, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'end_reviewer', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into assignment from authz.reviewer_assignments where id = assignment.id for update;
  if assignment.ended_at is null then
    update authz.reviewer_assignments
    set ended_at = now(), ended_by = p_user_id, end_reason = clean_reason
    where id = assignment.id;
    perform org.bump_authz_version(workspace.tenant_id);
    perform audit.record_tenant(workspace.tenant_id, p_user_id, 'reviewer.ended', 'reviewer_assignment', assignment.id::text,
      clean_reason, p_request_id => p_request_id);
  end if;

  return identity.store_result(p_user_id, p_idempotency_key, 'end_reviewer', request,
    jsonb_build_object('assignmentId', assignment.id, 'changed', assignment.ended_at is null));
end;
$$;

-- ── Tenant audit log (D-11) ───────────────────────────────────────────────

create function api.tenant_audit_log(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
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
  perform authz.require_president(workspace);
  page_size := org.page_limit(p_limit);
  after := org.decode_cursor(p_cursor);

  select coalesce(jsonb_agg(item order by (item->>'id')::bigint desc), '[]'::jsonb) into rows
  from (
    select jsonb_build_object(
      'id', e.id,
      'at', e.at,
      'actor', org.person(e.actor_user_id),
      'action', e.action,
      'targetType', e.target_type,
      'targetId', e.target_id,
      'reason', e.reason,
      'before', e.safe_before,
      'after', e.safe_after
    ) as item
    from audit.tenant_events e
    where e.tenant_id = workspace.tenant_id
      and (after is null or e.id < (after->>'id')::bigint)
    order by e.id desc
    limit page_size + 1
  ) page;

  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(e) from jsonb_array_elements(rows) with ordinality as x (e, n) where n <= page_size), '[]'::jsonb),
    'nextCursor', case when jsonb_array_length(rows) > page_size
      then org.encode_cursor(jsonb_build_object('id', rows->(page_size - 1)->>'id')) end
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
  loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end;
$$;
