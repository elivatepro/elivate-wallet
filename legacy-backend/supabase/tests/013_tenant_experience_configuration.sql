begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, auth, extensions, pg_catalog;

select plan(14);

insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
values
  (
    '00000000-0000-0000-0000-000000000601', 'authenticated', 'authenticated',
    'team-admin@example.test', '{}'::jsonb, '{}'::jsonb
  ),
  (
    '00000000-0000-0000-0000-000000000602', 'authenticated', 'authenticated',
    'team-member@example.test', '{}'::jsonb, '{}'::jsonb
  );

insert into public.user_accounts (user_id)
values
  ('00000000-0000-0000-0000-000000000601'),
  ('00000000-0000-0000-0000-000000000602');

insert into public.tenants (id, name)
values ('10000000-0000-0000-0000-000000000601', 'Configuration Tenant');

insert into public.offices (id, tenant_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000601',
  '10000000-0000-0000-0000-000000000601',
  'world_team',
  'Configuration World Team'
);

insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000602',
  '10000000-0000-0000-0000-000000000601',
  '20000000-0000-0000-0000-000000000601',
  'director',
  'Configuration Director'
);

insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000603',
  '10000000-0000-0000-0000-000000000601',
  '20000000-0000-0000-0000-000000000602',
  'team_leader',
  'Configuration Team'
);

insert into public.memberships (
  id, tenant_id, user_id, office_id, role_key, is_primary
)
values
  (
    '30000000-0000-0000-0000-000000000601',
    '10000000-0000-0000-0000-000000000601',
    '00000000-0000-0000-0000-000000000601',
    null,
    'president_team_member', true
  ),
  (
    '30000000-0000-0000-0000-000000000602',
    '10000000-0000-0000-0000-000000000601',
    '00000000-0000-0000-0000-000000000602',
    '20000000-0000-0000-0000-000000000603',
    'member', true
  );

select authz.seed_default_role_policy('10000000-0000-0000-0000-000000000601');

insert into authz.elevated_sessions (
  session_id, user_id, verified_at, valid_until, factor_method
)
values (
  '70000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000601',
  clock_timestamp(), clock_timestamp() + interval '4 minutes', 'test_mfa'
);

-- A verified elevation is tied to a real Auth session.
insert into auth.sessions(id,user_id,aal,created_at,updated_at)
select session_id,user_id,'aal2',verified_at,verified_at from authz.elevated_sessions
on conflict (id) do nothing;

select is(
  (tenant_config.register_brand_asset(
    '91000000-0000-0000-0000-000000000601',
    '00000000-0000-0000-0000-000000000601',
    '70000000-0000-0000-0000-000000000601',
    '10000000-0000-0000-0000-000000000601',
    'primary_logo',
    '10000000-0000-0000-0000-000000000601/logo.png',
    'image/png', 128, repeat('a', 64), 320, 80
  )).asset_kind,
  'primary_logo'::text,
  'trusted asset registration creates private metadata'
);

select is(
  (tenant_config.update_team_configuration(
    '92000000-0000-0000-0000-000000000601',
    '00000000-0000-0000-0000-000000000601',
    '70000000-0000-0000-0000-000000000601',
    '10000000-0000-0000-0000-000000000601',
    'Configuration Team', 'Config Team', 'Support Desk',
    'support@example.test', '+2348000000000', 'en-NG', 'Africa/Lagos',
    (select id from tenant_config.brand_assets
      where tenant_id = '10000000-0000-0000-0000-000000000601'),
    null, null, null, 'calm_blue', 'A short team slogan',
    'https://support.example.test', 'initial configuration'
  )).revision_number,
  1,
  'trusted configuration update creates revision one'
);

select is(
  (select team_display_name from public.tenant_member_branding_read
    where tenant_id = '10000000-0000-0000-0000-000000000601'),
  'Configuration Team'::text,
  'member-safe read model exposes the approved team name'
);

select is(
  (select team_slogan from public.tenant_member_branding_read
    where tenant_id = '10000000-0000-0000-0000-000000000601'),
  'A short team slogan'::text,
  'member-safe read model exposes the short slogan'
);

select is(
  (tenant_config.update_team_configuration(
    '92000000-0000-0000-0000-000000000601',
    '00000000-0000-0000-0000-000000000601',
    '70000000-0000-0000-0000-000000000601',
    '10000000-0000-0000-0000-000000000601',
    'Configuration Team', 'Config Team', 'Support Desk',
    'support@example.test', '+2348000000000', 'en-NG', 'Africa/Lagos',
    (select id from tenant_config.brand_assets
      where tenant_id = '10000000-0000-0000-0000-000000000601'),
    null, null, null, 'calm_blue', 'A short team slogan',
    'https://support.example.test', 'initial configuration'
  )).id,
  (select id from tenant_config.configuration_revisions
    where tenant_id = '10000000-0000-0000-0000-000000000601'),
  'same idempotency key reuses the original configuration revision'
);

select is(
  (select count(*)::integer from tenant_config.configuration_revisions
    where tenant_id = '10000000-0000-0000-0000-000000000601'),
  1,
  'idempotent configuration update does not create a duplicate revision'
);

select throws_ok(
  $$select tenant_config.update_team_configuration(
    '92000000-0000-0000-0000-000000000601',
    '00000000-0000-0000-0000-000000000601',
    '70000000-0000-0000-0000-000000000601',
    '10000000-0000-0000-0000-000000000601',
    'Different Team', 'Config Team', 'Support Desk',
    'support@example.test', '+2348000000000', 'en-NG', 'Africa/Lagos',
    null, null, null, null, 'calm_blue', 'A short team slogan',
    'https://support.example.test', 'conflicting replay'
  )$$,
  '23505',
  'idempotency key already used with different team configuration data',
  'conflicting configuration replay is rejected'
);

select throws_ok(
  $$select tenant_config.update_team_configuration(
    '92000000-0000-0000-0000-000000000602',
    '00000000-0000-0000-0000-000000000602',
    '70000000-0000-0000-0000-000000000601',
    '10000000-0000-0000-0000-000000000601',
    'Unauthorized Team', null, null, null, null, 'en-NG', 'Africa/Lagos',
    null, null, null, null, null, null, null, 'unauthorized'
  )$$,
  '42501',
  null,
  'ordinary members cannot update team configuration'
);

insert into commercial.tenant_extra_entitlements (
  tenant_id, extra_key, starts_at, granted_by_user_id, grant_reason
)
values (
  '10000000-0000-0000-0000-000000000601', 'white_label_domain',
  clock_timestamp(), '00000000-0000-0000-0000-000000000601',
  'approved optional add-on'
);

select ok(
  commercial.has_active_extra(
    '10000000-0000-0000-0000-000000000601', 'white_label_domain'
  ),
  'optional white-label domain entitlement is represented separately'
);

select throws_ok(
  $$update tenant_config.configuration_revisions
       set team_display_name = 'Mutated'
     where tenant_id = '10000000-0000-0000-0000-000000000601'$$,
  '55000',
  'configuration revisions are immutable',
  'configuration history cannot be edited in place'
);

select is(
  (select count(*)::integer from authz.security_audit_events
    where tenant_id = '10000000-0000-0000-0000-000000000601'
      and event_type = 'team_configuration_updated'),
  1,
  'successful configuration changes are internally audited'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000602',
  true
);

select throws_ok(
  $$select tenant_config.update_team_configuration(
    '92000000-0000-0000-0000-000000000603',
    '00000000-0000-0000-0000-000000000601',
    '70000000-0000-0000-0000-000000000601',
    '10000000-0000-0000-0000-000000000601',
    'Team', null, null, null, null, 'en-NG', 'Africa/Lagos',
    null, null, null, null, null, null, null, 'cross-context'
  )$$,
  '42501',
  null,
  'actor identity cannot be substituted by the caller'
);

select is(
  (select count(*)::integer from public.tenant_member_branding_read),
  1,
  'active members can read only the safe branding model'
);

select throws_ok(
  $$select * from tenant_config.brand_assets$$,
  '42501',
  null,
  'members cannot read private asset metadata directly'
);

select * from finish();
rollback;
