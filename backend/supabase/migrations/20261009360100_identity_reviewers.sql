-- Blueprint 36 — identity (NIN) review becomes a permission the President Team
-- can hand out (owner decision 2026-10-12). New A-03 row `review_identity`:
-- office-scoped and grantable, so it is switched per role in Role permissions
-- and given to one person through a Cross-access rule. Defaults keep Blueprint
-- 06 Q4: President Team (locked on) and World Team (on, switchable). A lower
-- role that gets it reviews people in its office and the offices below.

-- ── Permission (A-03 catalogue: 34 → 35 rows) ─────────────────────────────

do $$
begin
  alter table authz.permission_catalog disable trigger permission_catalog_immutable;
  alter table authz.default_role_permissions disable trigger default_role_permissions_immutable;
  insert into authz.permission_catalog (key, protected, grantable, scope, wallet_holder_baseline, can_target_own_wallet)
  values ('review_identity', false, true, 'office', false, false)
  on conflict (key) do nothing;
  insert into authz.default_role_permissions (role, permission_key, allowed)
  select r, 'review_identity', r in ('world_team_member', 'president_team_member')
  from unnest(enum_range(null::org.role)) r
  on conflict do nothing;
  alter table authz.permission_catalog enable trigger permission_catalog_immutable;
  alter table authz.default_role_permissions enable trigger default_role_permissions_immutable;
end;
$$;

insert into authz.role_permissions (tenant_id, role, permission_key, allowed)
select t.id, d.role, d.permission_key, d.allowed
from org.tenants t
cross join authz.default_role_permissions d
where d.permission_key = 'review_identity'
on conflict (tenant_id, role, permission_key) do nothing;

-- The President Team's cell stays on: one locked cell in an editable row.
create function authz.locked_cell(p_role org.role, p_permission_key text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_role = 'president_team_member' and p_permission_key = 'review_identity';
$$;

-- ── Review authority ──────────────────────────────────────────────────────

-- May this workspace decide this review? The resolver decides
-- `review_identity` against the requester's office and account (role policy
-- for the workspace, explicit rules for the person). Never one's own review.
create or replace function identity.can_review(p_workspace org.memberships, p_review identity.nin_reviews)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_review.user_id <> p_workspace.user_id
    and p_workspace.tenant_id = p_review.tenant_id
    and p_workspace.status = 'active'
    and coalesce((authz.decide(
      p_workspace.user_id, 'review_identity', p_review.tenant_id,
      (select m.office_id from org.memberships m where m.id = p_review.membership_id),
      p_review.user_id, p_workspace.id
    )->>'allowed')::boolean, false);
$$;

-- Does this workspace review identities at all (its role holds the permission,
-- or the person has a current Cross-access grant for it)? Gates the list.
create function identity.reviews_identities(p_workspace org.memberships)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
      select 1 from authz.role_permissions rp
      where rp.tenant_id = p_workspace.tenant_id and rp.role = p_workspace.role
        and rp.permission_key = 'review_identity' and rp.allowed
    )
    or exists (
      select 1 from authz.access_rules r
      join authz.access_assignments a on a.id = r.assignment_id
      where r.tenant_id = p_workspace.tenant_id and r.subject_user_id = p_workspace.user_id
        and r.permission_key = 'review_identity' and r.effect = 'allow'
        and r.revoked_at is null and a.revoked_at is null
        and r.starts_at <= now() and (r.expires_at is null or r.expires_at > now())
    );
$$;

create or replace function api.nin_reviews(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
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
  if not identity.reviews_identities(workspace) then
    perform identity.fail('authorization_denied');
  end if;
  return coalesce((
    select jsonb_agg(identity.review_row(r) order by r.requested_at, r.id)
    from identity.nin_reviews r
    where r.tenant_id = workspace.tenant_id and r.status = 'pending' and identity.can_review(workspace, r)
  ), '[]'::jsonb);
end;
$$;

-- ── Role permissions: the locked cell ─────────────────────────────────────

create or replace function api.list_role_permissions(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
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
      'editable', not c.protected and c.scope <> 'assignment' and not authz.locked_cell(rp.role, c.key)
    ) order by c.key, rp.role)
    from authz.role_permissions rp
    join authz.permission_catalog c on c.key = rp.permission_key
    where rp.tenant_id = workspace.tenant_id
  ), '[]'::jsonb);
end;
$$;

create or replace function api.set_role_permission(
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
  if permission.protected or permission.scope = 'assignment' or authz.locked_cell(p_role::org.role, permission.key) then
    perform identity.fail('permission_not_grantable',
      jsonb_build_object('reason', case when permission.scope = 'assignment' then 'assignment_only' else 'protected' end));
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

-- ── Cross-access: identity review comes from the President Team ──────────

-- As in Blueprint 16, plus the President-only check for `review_identity`
-- (Directors and the World Team hold manage_access_rules for their offices).
create or replace function api.create_access_assignment(
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
  perform org.require_active_tenant(workspace.tenant_id);
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
    -- Blueprint 36: only the President Team hands out identity review.
    if permission.key = 'review_identity' and workspace.role <> 'president_team_member' then
      perform identity.fail('permission_not_grantable',
        jsonb_build_object('permission', permission.key, 'reason', 'president_only'));
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

revoke all on function authz.locked_cell(org.role, text) from public, anon, authenticated;
revoke all on function identity.reviews_identities(org.memberships) from public, anon, authenticated;
