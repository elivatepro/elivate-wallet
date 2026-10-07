begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select no_plan();

insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
values
  ('00000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'president@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'director@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000003', 'authenticated', 'authenticated', 'member@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000004', 'authenticated', 'authenticated', 'other@example.test', '{}'::jsonb, '{}'::jsonb)
on conflict (id) do nothing;

insert into public.user_accounts (user_id)
values
  ('00000000-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-000000000002'),
  ('00000000-0000-0000-0000-000000000003'),
  ('00000000-0000-0000-0000-000000000004');

insert into public.tenants (id, name)
values
  ('10000000-0000-0000-0000-000000000001', 'Tenant One'),
  ('10000000-0000-0000-0000-000000000002', 'Tenant Two');

insert into public.offices (id, tenant_id, office_type, name)
values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'world_team', 'World Team One'),
  ('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000002', 'world_team', 'World Team Two')
;

insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'director', 'Director Office One');

insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values
  ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', 'team_leader', 'Team Leader Office One');

insert into public.memberships (id, tenant_id, user_id, office_id, role_key, is_primary)
values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', null, 'president_team_member', true),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', 'director', true),
  ('30000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000003', 'member', true),
  ('30000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000004', 'world_team_member', true);

select authz.seed_tenant_role_permissions('10000000-0000-0000-0000-000000000001');
select authz.seed_tenant_role_permissions('10000000-0000-0000-0000-000000000002');

select ok(
  exists (
    select 1
      from authz.office_closure
     where tenant_id = '10000000-0000-0000-0000-000000000001'
       and ancestor_office_id = '20000000-0000-0000-0000-000000000002'
       and descendant_office_id = '20000000-0000-0000-0000-000000000003'
       and depth = 1
  ),
  'office closure contains descendant scope'
);

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000002', null, 'record_income',
    '10000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000003', null, null, null, null, null, null
  )).decision,
  'ALLOW'::authz.authorization_decision_state,
  'director role permission covers descendant office'
);

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000003', null, 'approve_withdrawal',
    '10000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000003', null, null, null, null, null, null
  )).decision,
  'DENY'::authz.authorization_decision_state,
  'member does not inherit leadership permissions by role rank'
);

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000002', null, 'record_income',
    '10000000-0000-0000-0000-000000000002',
    '20000000-0000-0000-0000-000000000004', null, null, null, null, null, null
  )).reason_code,
  'no_matching_allow',
  'cross-tenant access requires an active membership in the target tenant'
);

insert into authz.access_assignments (id, tenant_id, subject_user_id, created_by_user_id, reason)
values (
  '40000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000001',
  'Test deny'
);

insert into authz.access_rules (
  tenant_id, assignment_id, permission_key, effect, scope_type
)
values (
  '10000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  'record_income', 'deny', 'tenant'
);

insert into authz.access_rules (
  tenant_id, assignment_id, permission_key, effect, scope_type
)
values (
  '10000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  'record_income', 'allow', 'tenant'
);

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000002', null, 'record_income',
    '10000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000003', null, null, null, null, null, null
  )).source,
  'explicit_deny'::authz.authorization_source,
  'explicit deny overrides role policy'
);

insert into authz.access_assignments (id, tenant_id, subject_user_id, created_by_user_id, reason)
values (
  '40000000-0000-0000-0000-000000000002',
  '10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000003',
  '00000000-0000-0000-0000-000000000001',
  'Expired grant'
);

insert into authz.access_rules (
  tenant_id, assignment_id, permission_key, effect, scope_type, starts_at, expires_at
)
values (
  '10000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000002',
  'approve_withdrawal', 'allow', 'tenant',
  clock_timestamp() - interval '2 hours',
  clock_timestamp() - interval '1 hour'
);

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000003', null, 'approve_withdrawal',
    '10000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000003', null, null, null, null, null, null
  )).decision,
  'DENY'::authz.authorization_decision_state,
  'expired explicit grant is ignored'
);

insert into authz.access_assignments (id, tenant_id, subject_user_id, created_by_user_id, reason)
values (
  '40000000-0000-0000-0000-000000000003',
  '10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000003',
  '00000000-0000-0000-0000-000000000002',
  'Out of scope manager test'
);

select throws_ok(
  $$insert into authz.access_rules (tenant_id, assignment_id, permission_key, effect, scope_type)
    values ('10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000003', 'record_income', 'allow', 'tenant')$$,
  '42501',
  null,
  'access manager cannot create a tenant-wide rule outside their office scope'
);

select throws_ok(
  $$insert into authz.access_rules (tenant_id, assignment_id, permission_key, effect, scope_type, expires_at)
    values ('10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 'record_income', 'deny', 'tenant', clock_timestamp() + interval '1 hour')$$,
  '23514',
  null,
  'explicit denies cannot expire'
);

select throws_ok(
  $$insert into authz.access_rules (tenant_id, assignment_id, permission_key, effect, scope_type, scope_office_id)
    values ('10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000003', 'manage_role_permissions', 'allow', 'office_subtree', '20000000-0000-0000-0000-000000000002')$$,
  '23514',
  null,
  'protected permissions cannot be granted by a non-president'
);

update public.memberships
   set status = 'suspended'
 where id = '30000000-0000-0000-0000-000000000002';

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000002', null, 'record_income',
    '10000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000003', null, null, null, null, null, null
  )).decision,
  'DENY'::authz.authorization_decision_state,
  'suspended membership contributes no authorization authority'
);

update public.user_accounts
   set status = 'suspended'
 where user_id = '00000000-0000-0000-0000-000000000001';

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000001', null, 'manage_role_permissions',
    '10000000-0000-0000-0000-000000000001',
    null, null, null, null, null, null, null
  )).reason_code,
  'account_not_active',
  'globally suspended account is denied before tenant policy'
);

update public.user_accounts
   set status = 'active'
 where user_id = '00000000-0000-0000-0000-000000000001';

update public.memberships
   set status = 'active'
 where id = '30000000-0000-0000-0000-000000000002';

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000001', null, 'manage_role_permissions',
    '10000000-0000-0000-0000-000000000001',
    null, null, null, null, null, null, null
  )).decision,
  'STEP_UP_REQUIRED'::authz.authorization_decision_state,
  'sensitive tenant policy change requires step-up'
);

insert into authz.elevated_sessions (session_id, user_id, verified_at, valid_until, factor_method)
values (
  '50000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000001',
  clock_timestamp() - interval '4 minutes',
  clock_timestamp() - interval '1 minute',
  'expired-test'
);

-- A verified elevation is tied to a real Auth session.
insert into auth.sessions(id,user_id,aal,created_at,updated_at)
select session_id,user_id,'aal2',verified_at,verified_at from authz.elevated_sessions
on conflict (id) do nothing;

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000001',
    '50000000-0000-0000-0000-000000000002',
    'manage_role_permissions',
    '10000000-0000-0000-0000-000000000001',
    null, null, null, null, null, null, null
  )).reason_code,
  'step_up_required',
  'expired elevated session requires a fresh step-up'
);

insert into authz.elevated_sessions (session_id, user_id, verified_at, valid_until, factor_method)
values (
  '50000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  clock_timestamp(),
  clock_timestamp() + interval '4 minutes',
  'test'
);

-- A verified elevation is tied to a real Auth session.
insert into auth.sessions(id,user_id,aal,created_at,updated_at)
select session_id,user_id,'aal2',verified_at,verified_at from authz.elevated_sessions
on conflict (id) do nothing;

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000001',
    '50000000-0000-0000-0000-000000000001',
    'manage_role_permissions',
    '10000000-0000-0000-0000-000000000001',
    null, null, null, null, null, null, null
  )).decision,
  'ALLOW'::authz.authorization_decision_state,
  'valid elevated session allows eligible sensitive action'
);

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000001',
    '50000000-0000-0000-0000-000000000001',
    'transfer_presidency',
    '10000000-0000-0000-0000-000000000001',
    null, null, null, null, null, 'transfer_presidency', null
  )).reason_code,
  'action_confirmation_required',
  'destructive action requires one-time confirmation'
);

insert into authz.action_confirmations (
  session_id, user_id, action_key, target_type, target_id, expires_at
)
values (
  '50000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  'transfer_presidency', 'tenant', '10000000-0000-0000-0000-000000000001',
  clock_timestamp() + interval '4 minutes'
);

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000001',
    '50000000-0000-0000-0000-000000000001',
    'transfer_presidency',
    '10000000-0000-0000-0000-000000000001',
    null, null, null, null, null, 'transfer_presidency', null
  )).decision,
  'ALLOW'::authz.authorization_decision_state,
  'one-time confirmation completes destructive authorization'
);

select ok(
  authz.consume_action_confirmation(
    '50000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001',
    'transfer_presidency', 'tenant', '10000000-0000-0000-0000-000000000001'
  ),
  'action confirmation is consumed atomically'
);

select ok(
  not authz.consume_action_confirmation(
    '50000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001',
    'transfer_presidency', 'tenant', '10000000-0000-0000-0000-000000000001'
  ),
  'consumed action confirmation cannot be replayed'
);

select ok(
  not has_table_privilege('authenticated', 'authz.permission_catalog', 'select'),
  'authenticated role cannot directly read private authorization tables'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);

select is(
  (select count(*) from public.tenants),
  1::bigint,
  'authenticated member sees only tenants where they have active membership'
);

select is(
  (select count(*) from public.memberships),
  1::bigint,
  'member sees only their own membership inside the tenant'
);

select is(
  (select count(*) from public.user_accounts),
  1::bigint,
  'account read is self-scoped'
);

select throws_ok(
  $$update public.user_accounts set status = 'disabled' where user_id = '00000000-0000-0000-0000-000000000003'$$,
  '42501',
  null,
  'authenticated client cannot mutate account security state'
);

select throws_ok(
  $$select permission_key from authz.permission_catalog limit 1$$,
  '42501',
  null,
  'authenticated client cannot read private authorization catalog'
);

set local role service_role;

select finish();
rollback;
