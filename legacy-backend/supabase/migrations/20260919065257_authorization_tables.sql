create table authz.permission_catalog (
  permission_key text primary key check (permission_key ~ '^[a-z][a-z0-9_]*$'),
  area text not null check (length(btrim(area)) > 0),
  protected boolean not null,
  grantable boolean not null,
  wallet_holder_baseline boolean not null,
  can_target_own_wallet boolean not null,
  default_scope_mode text not null check (default_scope_mode in (
    'self', 'role_office', 'entire_tenant', 'explicit_grant', 'not_applicable'
  )),
  step_up_mode authz.required_auth_level not null default 'none'
);

create table authz.default_role_permissions (
  role_key public.role_key not null,
  permission_key text not null references authz.permission_catalog (permission_key),
  primary key (role_key, permission_key)
);

create table authz.tenant_role_permissions (
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  role_key public.role_key not null,
  permission_key text not null references authz.permission_catalog (permission_key),
  allowed boolean not null,
  updated_by uuid references public.user_accounts (user_id) on delete restrict,
  updated_at timestamptz not null default clock_timestamp(),
  primary key (tenant_id, role_key, permission_key)
);

create table authz.office_closure (
  tenant_id uuid not null,
  ancestor_office_id uuid not null,
  descendant_office_id uuid not null,
  depth integer not null check (depth >= 0),
  primary key (tenant_id, ancestor_office_id, descendant_office_id),
  foreign key (tenant_id, ancestor_office_id)
    references public.offices (tenant_id, id)
    on delete cascade,
  foreign key (tenant_id, descendant_office_id)
    references public.offices (tenant_id, id)
    on delete cascade
);

create index office_closure_descendant_ancestor
  on authz.office_closure (tenant_id, descendant_office_id, ancestor_office_id);

create table authz.access_assignments (
  id uuid primary key default extensions.gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  subject_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  created_by_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  reason text not null check (length(btrim(reason)) > 0),
  created_at timestamptz not null default clock_timestamp(),
  revoked_at timestamptz,
  revoked_by_user_id uuid references public.user_accounts (user_id) on delete restrict,
  unique (tenant_id, id),
  check ((revoked_at is null and revoked_by_user_id is null)
    or (revoked_at is not null and revoked_by_user_id is not null))
);

create index access_assignments_active_subject
  on authz.access_assignments (tenant_id, subject_user_id)
  where revoked_at is null;

create table authz.access_rules (
  id uuid primary key default extensions.gen_random_uuid(),
  tenant_id uuid not null,
  assignment_id uuid not null,
  permission_key text not null references authz.permission_catalog (permission_key),
  effect authz.access_effect not null,
  scope_type authz.access_scope_type not null,
  scope_office_id uuid,
  scope_membership_id uuid,
  starts_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz,
  revoked_at timestamptz,
  revoked_by_user_id uuid references public.user_accounts (user_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  foreign key (tenant_id, assignment_id)
    references authz.access_assignments (tenant_id, id)
    on delete restrict,
  foreign key (tenant_id, scope_office_id)
    references public.offices (tenant_id, id)
    on delete restrict,
  foreign key (tenant_id, scope_membership_id)
    references public.memberships (tenant_id, id)
    on delete restrict,
  check ((scope_type = 'tenant' and scope_office_id is null and scope_membership_id is null)
    or (scope_type = 'office_subtree' and scope_office_id is not null and scope_membership_id is null)
    or (scope_type = 'member' and scope_office_id is null and scope_membership_id is not null)),
  check ((effect = 'deny' and expires_at is null)
    or effect = 'allow'),
  check (expires_at is null or expires_at > starts_at),
  check (revoked_at is null or revoked_at >= starts_at)
);

create index access_rules_active_permission
  on authz.access_rules (assignment_id, permission_key)
  where revoked_at is null;

create index access_rules_active_office_scope
  on authz.access_rules (tenant_id, scope_office_id)
  where scope_office_id is not null and revoked_at is null;

create index access_rules_active_membership_scope
  on authz.access_rules (tenant_id, scope_membership_id)
  where scope_membership_id is not null and revoked_at is null;

create index access_rules_active_expiry
  on authz.access_rules (expires_at)
  where expires_at is not null and revoked_at is null;

create table authz.elevated_sessions (
  session_id uuid primary key,
  user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  verified_at timestamptz not null,
  valid_until timestamptz not null,
  factor_method text not null check (length(btrim(factor_method)) > 0),
  revoked_at timestamptz,
  check (valid_until > verified_at),
  check (valid_until <= verified_at + interval '5 minutes')
);

create index elevated_sessions_user_valid_until
  on authz.elevated_sessions (user_id, valid_until);

create table authz.action_confirmations (
  id uuid primary key default extensions.gen_random_uuid(),
  session_id uuid not null,
  user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  action_key text not null,
  target_type text not null,
  target_id uuid,
  confirmed_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  foreign key (session_id) references authz.elevated_sessions (session_id) on delete restrict,
  check (expires_at > confirmed_at),
  check (expires_at <= confirmed_at + interval '5 minutes')
);

create index action_confirmations_available
  on authz.action_confirmations (session_id, user_id, action_key, target_type, target_id)
  where consumed_at is null;

create table authz.security_audit_events (
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default clock_timestamp(),
  actor_user_id uuid references public.user_accounts (user_id) on delete restrict,
  session_id uuid,
  tenant_id uuid references public.tenants (id) on delete restrict,
  event_type text not null,
  permission_key text references authz.permission_catalog (permission_key),
  target_type text,
  target_id uuid,
  allowed boolean,
  source authz.authorization_source,
  source_id uuid,
  reason_code text,
  metadata jsonb not null default '{}'::jsonb
);

create index security_audit_events_tenant_occurred
  on authz.security_audit_events (tenant_id, occurred_at desc);

create index security_audit_events_actor_occurred
  on authz.security_audit_events (actor_user_id, occurred_at desc);

create type authz.authorization_decision as (
  decision authz.authorization_decision_state,
  permission_key text,
  actor_user_id uuid,
  target_tenant_id uuid,
  target_office_id uuid,
  target_membership_id uuid,
  target_user_id uuid,
  target_wallet_id uuid,
  source authz.authorization_source,
  source_id uuid,
  reason_code text,
  required_auth_level authz.required_auth_level,
  max_auth_age_seconds integer
);

-- Keep private authorization relations inaccessible even if a future privilege
-- grant is accidentally broader than intended. SECURITY DEFINER helpers and
-- service_role remain able to operate on these tables.
alter table authz.permission_catalog enable row level security;
alter table authz.default_role_permissions enable row level security;
alter table authz.tenant_role_permissions enable row level security;
alter table authz.office_closure enable row level security;
alter table authz.access_assignments enable row level security;
alter table authz.access_rules enable row level security;
alter table authz.elevated_sessions enable row level security;
alter table authz.action_confirmations enable row level security;
alter table authz.security_audit_events enable row level security;

insert into authz.permission_catalog (
  permission_key,
  area,
  protected,
  grantable,
  wallet_holder_baseline,
  can_target_own_wallet,
  default_scope_mode,
  step_up_mode
)
values
  ('manage_access_rules', 'Access Control', false, true, false, false, 'role_office', 'none'),
  ('manage_role_permissions', 'Access Control', true, false, false, false, 'entire_tenant', 'elevated'),
  ('manage_subscription', 'Billing', false, true, false, false, 'entire_tenant', 'none'),
  ('record_income', 'Income', false, true, false, false, 'role_office', 'none'),
  ('end_membership', 'Membership', false, true, false, false, 'role_office', 'none'),
  ('invite_members', 'Membership', false, true, false, false, 'role_office', 'none'),
  ('manage_members', 'Membership', false, true, false, false, 'role_office', 'none'),
  ('move_membership', 'Membership', false, true, false, false, 'role_office', 'none'),
  ('suspend_membership', 'Membership', false, true, false, false, 'role_office', 'none'),
  ('approve_pocket_transfer', 'Pocket Transfers', false, true, false, false, 'role_office', 'none'),
  ('transfer_between_own_pockets', 'Pocket Transfers', false, false, true, true, 'self', 'none'),
  ('transfer_between_pockets_on_behalf', 'Pocket Transfers', false, true, false, false, 'role_office', 'none'),
  ('export_own_statement', 'Reporting', true, false, true, true, 'self', 'none'),
  ('export_scoped_reports', 'Reporting', false, true, false, false, 'role_office', 'none'),
  ('view_own_financials', 'Reporting', true, false, true, true, 'self', 'none'),
  ('view_scoped_financial_reports', 'Reporting', false, true, false, false, 'role_office', 'none'),
  ('manage_security_settings', 'Security', true, false, false, false, 'entire_tenant', 'elevated'),
  ('reverse_transaction', 'Security', true, false, false, false, 'entire_tenant', 'elevated'),
  ('configure_adjustment_evidence_requirement', 'Tenant Admin', true, false, false, false, 'entire_tenant', 'elevated'),
  ('deactivate_tenant', 'Tenant Admin', true, false, false, false, 'entire_tenant', 'elevated_and_confirmed'),
  ('transfer_presidency', 'Tenant Admin', true, false, false, false, 'entire_tenant', 'elevated_and_confirmed'),
  ('manage_own_payout_accounts', 'Wallet', true, false, true, true, 'self', 'elevated'),
  ('manual_credit_debit_adjustment', 'Wallet', false, true, false, false, 'role_office', 'none'),
  ('perform_currency_conversion', 'Wallet', false, true, false, false, 'role_office', 'none'),
  ('review_financial_evidence', 'Wallet', false, true, false, false, 'explicit_grant', 'none'),
  ('view_managed_wallets', 'Wallet', false, true, false, false, 'role_office', 'none'),
  ('view_own_wallet', 'Wallet', true, false, true, true, 'self', 'none'),
  ('approve_withdrawal', 'Withdrawals', false, true, false, false, 'role_office', 'none'),
  ('initiate_own_withdrawal', 'Withdrawals', true, false, true, true, 'self', 'none'),
  ('record_returned_funds', 'Withdrawals', false, true, false, false, 'role_office', 'none'),
  ('withdraw_on_behalf', 'Withdrawals', false, true, false, false, 'role_office', 'none');

insert into authz.default_role_permissions (role_key, permission_key)
values
  ('director', 'manage_access_rules'),
  ('world_team_member', 'manage_access_rules'),
  ('president_team_member', 'manage_access_rules'),
  ('president_team_member', 'manage_role_permissions'),
  ('president_team_member', 'manage_subscription'),
  ('team_leader', 'record_income'),
  ('director', 'record_income'),
  ('world_team_member', 'record_income'),
  ('president_team_member', 'record_income'),
  ('world_team_member', 'end_membership'),
  ('president_team_member', 'end_membership'),
  ('team_leader', 'invite_members'),
  ('director', 'invite_members'),
  ('world_team_member', 'invite_members'),
  ('president_team_member', 'invite_members'),
  ('team_leader', 'manage_members'),
  ('director', 'manage_members'),
  ('world_team_member', 'manage_members'),
  ('president_team_member', 'manage_members'),
  ('world_team_member', 'move_membership'),
  ('president_team_member', 'move_membership'),
  ('world_team_member', 'suspend_membership'),
  ('president_team_member', 'suspend_membership'),
  ('team_leader', 'approve_pocket_transfer'),
  ('director', 'approve_pocket_transfer'),
  ('world_team_member', 'approve_pocket_transfer'),
  ('president_team_member', 'approve_pocket_transfer'),
  ('team_leader', 'transfer_between_pockets_on_behalf'),
  ('director', 'transfer_between_pockets_on_behalf'),
  ('world_team_member', 'transfer_between_pockets_on_behalf'),
  ('president_team_member', 'transfer_between_pockets_on_behalf'),
  ('team_leader', 'export_scoped_reports'),
  ('director', 'export_scoped_reports'),
  ('world_team_member', 'export_scoped_reports'),
  ('president_team_member', 'export_scoped_reports'),
  ('team_leader', 'view_scoped_financial_reports'),
  ('director', 'view_scoped_financial_reports'),
  ('world_team_member', 'view_scoped_financial_reports'),
  ('president_team_member', 'view_scoped_financial_reports'),
  ('president_team_member', 'manage_security_settings'),
  ('president_team_member', 'reverse_transaction'),
  ('president_team_member', 'configure_adjustment_evidence_requirement'),
  ('president_team_member', 'deactivate_tenant'),
  ('president_team_member', 'transfer_presidency'),
  ('world_team_member', 'manual_credit_debit_adjustment'),
  ('president_team_member', 'manual_credit_debit_adjustment'),
  ('team_leader', 'perform_currency_conversion'),
  ('director', 'perform_currency_conversion'),
  ('world_team_member', 'perform_currency_conversion'),
  ('president_team_member', 'perform_currency_conversion'),
  ('team_leader', 'view_managed_wallets'),
  ('director', 'view_managed_wallets'),
  ('world_team_member', 'view_managed_wallets'),
  ('president_team_member', 'view_managed_wallets'),
  ('team_leader', 'approve_withdrawal'),
  ('director', 'approve_withdrawal'),
  ('world_team_member', 'approve_withdrawal'),
  ('president_team_member', 'approve_withdrawal'),
  ('team_leader', 'record_returned_funds'),
  ('director', 'record_returned_funds'),
  ('world_team_member', 'record_returned_funds'),
  ('president_team_member', 'record_returned_funds'),
  ('world_team_member', 'withdraw_on_behalf'),
  ('president_team_member', 'withdraw_on_behalf');

create or replace function authz.seed_tenant_role_permissions(p_tenant_id uuid)
returns void
language sql
set search_path = pg_catalog, public, authz
as $$
  insert into authz.tenant_role_permissions (tenant_id, role_key, permission_key, allowed)
  select p_tenant_id, role_key, permission_key, true
    from authz.default_role_permissions
  on conflict (tenant_id, role_key, permission_key) do nothing;
$$;

revoke all on all tables in schema authz from public, anon, authenticated;
revoke all on all sequences in schema authz from public, anon, authenticated;
revoke all on function authz.seed_tenant_role_permissions(uuid) from public, anon, authenticated;
