-- Blueprint 02 — B2/B3: permission catalog (A-03), tenant role policies, explicit
-- access rules, evidence reviewers, action confirmations and the resolver.

create table authz.permission_catalog (
  key text primary key check (key ~ '^[a-z_]+$'),
  protected boolean not null,
  grantable boolean not null,
  scope text not null check (scope in ('self', 'office', 'tenant', 'assignment')),
  wallet_holder_baseline boolean not null,
  can_target_own_wallet boolean not null
);

create table authz.default_role_permissions (
  role org.role not null,
  permission_key text not null references authz.permission_catalog (key) on delete restrict,
  allowed boolean not null,
  primary key (role, permission_key)
);

-- A-03, row by row. Columns M, TL, D, W, P.
with matrix (key, m, tl, d, w, p, protected, grantable, scope, baseline, own) as (
  values
    ('view_own_wallet',                           true,  true,  true,  true,  false, true,  false, 'self',       true,  true),
    ('view_own_financials',                       true,  true,  true,  true,  false, true,  false, 'self',       true,  true),
    ('export_own_statement',                      true,  true,  true,  true,  false, true,  false, 'self',       true,  true),
    ('initiate_own_withdrawal',                   true,  true,  true,  true,  false, true,  false, 'self',       true,  true),
    ('manage_own_payout_accounts',                true,  true,  true,  true,  false, true,  false, 'self',       true,  true),
    ('transfer_between_own_pockets',              true,  true,  true,  true,  false, false, false, 'self',       true,  true),
    ('view_managed_wallets',                      false, true,  true,  true,  true,  false, true,  'office',     false, false),
    ('record_income',                             false, true,  true,  true,  true,  false, true,  'office',     false, false),
    ('approve_withdrawal',                        false, true,  true,  true,  true,  false, true,  'office',     false, false),
    ('withdraw_on_behalf',                        false, false, false, true,  true,  false, true,  'office',     false, false),
    ('transfer_between_pockets_on_behalf',        false, true,  true,  true,  true,  false, true,  'office',     false, false),
    ('approve_pocket_transfer',                   false, true,  true,  true,  true,  false, true,  'office',     false, false),
    ('perform_currency_conversion',               false, true,  true,  true,  true,  false, true,  'office',     false, false),
    ('manual_credit_debit_adjustment',            false, false, false, true,  true,  false, true,  'office',     false, false),
    ('record_returned_funds',                     false, true,  true,  true,  true,  false, true,  'office',     false, false),
    ('view_scoped_financial_reports',             false, true,  true,  true,  true,  false, true,  'office',     false, false),
    ('export_scoped_reports',                     false, true,  true,  true,  true,  false, true,  'office',     false, false),
    ('invite_members',                            false, true,  true,  true,  true,  false, true,  'office',     false, false),
    ('manage_members',                            false, true,  true,  true,  true,  false, true,  'office',     false, false),
    ('move_membership',                           false, false, false, true,  true,  false, true,  'office',     false, false),
    ('suspend_membership',                        false, false, false, true,  true,  false, true,  'office',     false, false),
    ('end_membership',                            false, false, false, true,  true,  false, true,  'office',     false, false),
    ('manage_access_rules',                       false, false, true,  true,  true,  false, true,  'office',     false, false),
    ('manage_subscription',                       false, false, false, false, true,  false, true,  'tenant',     false, false),
    ('manage_role_permissions',                   false, false, false, false, true,  true,  false, 'tenant',     false, false),
    ('manage_security_settings',                  false, false, false, false, true,  true,  false, 'tenant',     false, false),
    ('configure_adjustment_evidence_requirement', false, false, false, false, true,  true,  false, 'tenant',     false, false),
    ('reverse_transaction',                       false, false, false, false, true,  true,  false, 'tenant',     false, false),
    ('transfer_presidency',                       false, false, false, false, true,  true,  false, 'tenant',     false, false),
    ('deactivate_tenant',                         false, false, false, false, true,  true,  false, 'tenant',     false, false),
    ('review_financial_evidence',                 false, false, false, false, true,  false, true,  'assignment', false, false)
),
catalog as (
  insert into authz.permission_catalog (key, protected, grantable, scope, wallet_holder_baseline, can_target_own_wallet)
  select key, protected, grantable, scope, baseline, own from matrix
  returning key
)
insert into authz.default_role_permissions (role, permission_key, allowed)
select r.role, x.key, r.allowed
from matrix x
cross join lateral (values
  ('member'::org.role, x.m), ('team_leader', x.tl), ('director', x.d),
  ('world_team_member', x.w), ('president_team_member', x.p)
) as r (role, allowed)
join catalog c on c.key = x.key;

create function authz.reject_catalog_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform identity.fail('invariant_violation', jsonb_build_object('table', tg_table_schema || '.' || tg_table_name));
  return null;
end;
$$;

create trigger permission_catalog_immutable
before insert or update or delete on authz.permission_catalog
for each statement execute function authz.reject_catalog_change();
create trigger default_role_permissions_immutable
before insert or update or delete on authz.default_role_permissions
for each statement execute function authz.reject_catalog_change();

create table authz.role_permissions (
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  role org.role not null,
  permission_key text not null references authz.permission_catalog (key) on delete restrict,
  allowed boolean not null,
  updated_by uuid references identity.accounts (user_id) on delete restrict,
  updated_at timestamptz not null default now(),
  primary key (tenant_id, role, permission_key)
);

create function authz.seed_role_permissions(p_tenant_id uuid)
returns void
language sql
set search_path = ''
as $$
  insert into authz.role_permissions (tenant_id, role, permission_key, allowed)
  select p_tenant_id, role, permission_key, allowed from authz.default_role_permissions;
$$;

-- ── Explicit access rules (A-02, W-06) ────────────────────────────────────

create table authz.access_assignments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  subject_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  created_by uuid not null references identity.accounts (user_id) on delete restrict,
  reason text not null,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by uuid references identity.accounts (user_id) on delete restrict,
  revoke_reason text,
  check ((revoked_at is null) = (revoked_by is null)),
  check ((revoked_at is null) = (revoke_reason is null))
);

create index access_assignments_tenant_idx on authz.access_assignments (tenant_id, created_at desc, id);

create table authz.access_rules (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references authz.access_assignments (id) on delete restrict,
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  subject_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  permission_key text not null references authz.permission_catalog (key) on delete restrict,
  effect text not null check (effect in ('allow', 'deny')),
  scope_type text not null check (scope_type in ('tenant', 'office_subtree', 'member')),
  scope_office_id uuid,
  scope_user_id uuid references identity.accounts (user_id) on delete restrict,
  starts_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  foreign key (tenant_id, scope_office_id) references org.offices (tenant_id, id) on delete restrict,
  check (effect = 'allow' or expires_at is null),
  check (expires_at is null or expires_at > starts_at),
  check (
    (scope_type = 'tenant' and scope_office_id is null and scope_user_id is null)
    or (scope_type = 'office_subtree' and scope_office_id is not null and scope_user_id is null)
    or (scope_type = 'member' and scope_office_id is null and scope_user_id is not null)
  )
);

create index access_rules_lookup_idx
  on authz.access_rules (tenant_id, subject_user_id, permission_key) where revoked_at is null;
create index access_rules_assignment_idx on authz.access_rules (assignment_id);

-- ── Evidence reviewers (A-04) ─────────────────────────────────────────────

create table authz.reviewer_assignments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  membership_id uuid not null references org.memberships (id) on delete restrict,
  assigned_by uuid not null references identity.accounts (user_id) on delete restrict,
  reason text not null,
  assigned_at timestamptz not null default now(),
  ended_at timestamptz,
  ended_by uuid references identity.accounts (user_id) on delete restrict,
  end_reason text,
  check ((ended_at is null) = (ended_by is null)),
  check ((ended_at is null) = (end_reason is null))
);

create unique index reviewer_assignments_one_active
  on authz.reviewer_assignments (membership_id) where ended_at is null;

-- Per-action confirmations for presidency transfer and tenant deactivation
-- (A-05). Bound to action, target type, target and session; consumed once.
create table authz.action_confirmations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references identity.accounts (user_id) on delete restrict,
  session_id uuid not null,
  action text not null check (action in ('transfer_presidency', 'deactivate_tenant')),
  target_type text not null check (target_type in ('tenant', 'membership')),
  target_id uuid not null,
  created_at timestamptz not null default now(),
  consumed_at timestamptz
);

create function authz.consume_confirmation(
  p_user_id uuid,
  p_session_id uuid,
  p_action text,
  p_target_type text,
  p_target_id uuid
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  confirmation_id uuid;
begin
  select id into confirmation_id from authz.action_confirmations
  where user_id = p_user_id and session_id = p_session_id and action = p_action
    and target_type = p_target_type and target_id = p_target_id
    and consumed_at is null and created_at > now() - interval '5 minutes'
  order by created_at desc
  limit 1
  for update;
  if confirmation_id is null then
    perform identity.fail('step_up_required', jsonb_build_object('reason', 'confirmation_required'));
  end if;
  update authz.action_confirmations set consumed_at = now() where id = confirmation_id;
end;
$$;

alter table authz.permission_catalog enable row level security;
alter table authz.default_role_permissions enable row level security;
alter table authz.role_permissions enable row level security;
alter table authz.access_assignments enable row level security;
alter table authz.access_rules enable row level security;
alter table authz.reviewer_assignments enable row level security;
alter table authz.action_confirmations enable row level security;

-- ── Resolver (B3) ─────────────────────────────────────────────────────────

-- Does an office cover a target? A target is an office, a user in the tenant
-- (any of their open memberships), or the tenant itself (only tenant-wide
-- authority covers it).
create function authz.office_covers(
  p_office_id uuid,
  p_tenant_id uuid,
  p_target_office_id uuid,
  p_target_user_id uuid
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select case
    when p_target_office_id is not null then exists (
      select 1 from org.office_closure
      where ancestor_id = p_office_id and descendant_id = p_target_office_id
    )
    when p_target_user_id is not null then exists (
      select 1 from org.memberships tm
      join org.office_closure c on c.descendant_id = tm.office_id
      where tm.tenant_id = p_tenant_id and tm.user_id = p_target_user_id
        and tm.status <> 'ended' and c.ancestor_id = p_office_id
    )
    else false
  end;
$$;

-- Does an explicit rule's scope cover the target?
create function authz.rule_covers(
  p_rule authz.access_rules,
  p_target_office_id uuid,
  p_target_user_id uuid
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select case p_rule.scope_type
    when 'tenant' then true
    when 'office_subtree' then authz.office_covers(p_rule.scope_office_id, p_rule.tenant_id, p_target_office_id, p_target_user_id)
    -- Member scope matches the target person however the target was given.
    else p_target_user_id = p_rule.scope_user_id
  end;
$$;

-- A-01 resolver. Session gate and step-up are checked by each command before
-- calling this. Returns { allowed, reason, source }.
--   p_target_office_id / p_target_user_id: the resolved target (both null =
--   the tenant itself). Callers resolve memberships to office + user first.
--   p_workspace_membership_id: the selected workspace; when given, role policy
--   only counts that membership, while explicit grants still apply (A-02).
create function authz.decide(
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
  if tenant_status <> 'active' then
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

-- Raises the matching contract error when the resolver denies.
create function authz.require(
  p_actor_user_id uuid,
  p_permission_key text,
  p_tenant_id uuid,
  p_target_office_id uuid default null,
  p_target_user_id uuid default null,
  p_workspace_membership_id uuid default null
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  decision jsonb;
begin
  decision := authz.decide(p_actor_user_id, p_permission_key, p_tenant_id,
    p_target_office_id, p_target_user_id, p_workspace_membership_id);
  if (decision->>'allowed')::boolean then
    return;
  end if;
  case decision->>'reason'
    when 'network_not_active' then perform identity.fail('network_not_active');
    when 'not_found' then perform identity.fail('not_found');
    when 'self_target' then perform identity.fail('self_target_forbidden');
    else perform identity.fail('authorization_denied');
  end case;
end;
$$;

-- Validates the selected workspace (A-02): the actor's own active membership.
-- Returns it; the network may still be awaiting payment.
create function authz.require_workspace(p_actor_user_id uuid, p_membership_id uuid)
returns org.memberships
language plpgsql
set search_path = ''
as $$
declare
  workspace org.memberships;
begin
  select m.* into workspace from org.memberships m
  left join org.offices o on o.id = m.office_id
  where m.id = p_membership_id and m.user_id = p_actor_user_id and m.status = 'active'
    and (m.office_id is null or o.status = 'active');
  if workspace.id is null then
    perform identity.fail('workspace_invalid');
  end if;
  return workspace;
end;
$$;

-- The network must be active for organizational changes.
create function org.require_active_tenant(p_tenant_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if (select status from org.tenants where id = p_tenant_id) is distinct from 'active' then
    perform identity.fail('network_not_active');
  end if;
end;
$$;

-- President Team actions: the actor's workspace must be an active President
-- Team membership of an active network.
create function authz.require_president(p_workspace org.memberships)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_workspace.role <> 'president_team_member' then
    perform identity.fail('authorization_denied');
  end if;
  perform org.require_active_tenant(p_workspace.tenant_id);
end;
$$;

-- Is a proposed rule scope inside the actor's own manage_access_rules scope?
create function authz.covers_scope(
  p_actor_user_id uuid,
  p_tenant_id uuid,
  p_scope_type text,
  p_scope_office_id uuid,
  p_scope_user_id uuid
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select (authz.decide(
    p_actor_user_id, 'manage_access_rules', p_tenant_id,
    case when p_scope_type = 'office_subtree' then p_scope_office_id end,
    case when p_scope_type = 'member' then p_scope_user_id end
  )->>'allowed')::boolean;
$$;
