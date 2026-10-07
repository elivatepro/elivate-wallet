begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(53);

insert into auth.users (
  id,
  aud,
  role,
  email,
  raw_app_meta_data,
  raw_user_meta_data
)
values
  ('00000000-0000-0000-0000-000000000901', 'authenticated', 'authenticated', 'organization-president@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000902', 'authenticated', 'authenticated', 'organization-team-leader@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000903', 'authenticated', 'authenticated', 'organization-invited@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000904', 'authenticated', 'authenticated', 'organization-created@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000905', 'authenticated', 'authenticated', 'organization-out-of-scope@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000906', 'authenticated', 'authenticated', 'organization-lifecycle@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000907', 'authenticated', 'authenticated', 'organization-move@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000908', 'authenticated', 'authenticated', 'organization-billing-owner@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000909', 'authenticated', 'authenticated', 'organization-closed-office@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-00000000090a', 'authenticated', 'authenticated', 'organization-expired@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-00000000090b', 'authenticated', 'authenticated', 'organization-primary-replacement@example.test', '{}'::jsonb, '{}'::jsonb)
on conflict (id) do nothing;

insert into public.user_accounts (user_id, status)
values
  ('00000000-0000-0000-0000-000000000901', 'active'),
  ('00000000-0000-0000-0000-000000000902', 'active'),
  ('00000000-0000-0000-0000-000000000903', 'active'),
  ('00000000-0000-0000-0000-000000000904', 'active'),
  ('00000000-0000-0000-0000-000000000905', 'active'),
  ('00000000-0000-0000-0000-000000000906', 'active'),
  ('00000000-0000-0000-0000-000000000907', 'active'),
  ('00000000-0000-0000-0000-000000000908', 'active'),
  ('00000000-0000-0000-0000-000000000909', 'active'),
  ('00000000-0000-0000-0000-00000000090a', 'active'),
  ('00000000-0000-0000-0000-00000000090b', 'active');

insert into public.tenants (id, name)
values (
  '10000000-0000-0000-0000-000000000901',
  'Organization Lifecycle Test Tenant'
);

insert into public.offices (id, tenant_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000901',
  '10000000-0000-0000-0000-000000000901',
  'world_team',
  'Organization World Team'
);

insert into public.offices (
  id,
  tenant_id,
  parent_office_id,
  office_type,
  name
)
values
  (
    '20000000-0000-0000-0000-000000000902',
    '10000000-0000-0000-0000-000000000901',
    '20000000-0000-0000-0000-000000000901',
    'director',
    'Organization Director A'
  ),
  (
    '20000000-0000-0000-0000-000000000904',
    '10000000-0000-0000-0000-000000000901',
    '20000000-0000-0000-0000-000000000901',
    'director',
    'Organization Director B'
  );

insert into public.offices (
  id,
  tenant_id,
  parent_office_id,
  office_type,
  name
)
values
  (
    '20000000-0000-0000-0000-000000000903',
    '10000000-0000-0000-0000-000000000901',
    '20000000-0000-0000-0000-000000000902',
    'team_leader',
    'Organization Team A'
  ),
  (
    '20000000-0000-0000-0000-000000000905',
    '10000000-0000-0000-0000-000000000901',
    '20000000-0000-0000-0000-000000000904',
    'team_leader',
    'Organization Team B'
  );

insert into public.memberships (
  id,
  tenant_id,
  user_id,
  office_id,
  role_key,
  status,
  is_primary
)
values
  (
    '30000000-0000-0000-0000-000000000901',
    '10000000-0000-0000-0000-000000000901',
    '00000000-0000-0000-0000-000000000901',
    null,
    'president_team_member',
    'active',
    true
  ),
  (
    '30000000-0000-0000-0000-000000000902',
    '10000000-0000-0000-0000-000000000901',
    '00000000-0000-0000-0000-000000000902',
    '20000000-0000-0000-0000-000000000903',
    'team_leader',
    'active',
    true
  ),
  (
    '30000000-0000-0000-0000-000000000906',
    '10000000-0000-0000-0000-000000000901',
    '00000000-0000-0000-0000-000000000906',
    '20000000-0000-0000-0000-000000000903',
    'member',
    'active',
    true
  ),
  (
    '30000000-0000-0000-0000-000000000907',
    '10000000-0000-0000-0000-000000000901',
    '00000000-0000-0000-0000-000000000907',
    '20000000-0000-0000-0000-000000000903',
    'member',
    'active',
    true
  ),
  (
    '30000000-0000-0000-0000-000000000908',
    '10000000-0000-0000-0000-000000000901',
    '00000000-0000-0000-0000-000000000908',
    '20000000-0000-0000-0000-000000000903',
    'member',
    'active',
    true
  ),
  (
    '30000000-0000-0000-0000-00000000090b',
    '10000000-0000-0000-0000-000000000901',
    '00000000-0000-0000-0000-00000000090b',
    '20000000-0000-0000-0000-000000000903',
    'member',
    'active',
    true
  ),
  (
    '30000000-0000-0000-0000-00000000091b',
    '10000000-0000-0000-0000-000000000901',
    '00000000-0000-0000-0000-00000000090b',
    '20000000-0000-0000-0000-000000000905',
    'member',
    'active',
    false
  );

select authz.seed_tenant_role_permissions(
  '10000000-0000-0000-0000-000000000901'
);

insert into commercial.plans (id, plan_key, display_name)
values (
  'c0000000-0000-4000-8000-000000000901',
  'organization_lifecycle_50',
  'Organization lifecycle capacity 50'
);

insert into commercial.plan_versions (
  id,
  plan_id,
  version_number,
  minimum_covered_users,
  maximum_covered_users,
  list_price_amount,
  currency_code,
  billing_cadence_code,
  effective_from
)
values (
  'c1000000-0000-4000-8000-000000000901',
  'c0000000-0000-4000-8000-000000000901',
  1,
  1,
  50,
  1.00,
  'NGN',
  null,
  current_date
);

insert into commercial.tenant_subscriptions (
  id,
  tenant_id,
  plan_version_id,
  status,
  starts_at,
  status_reason,
  status_changed_by_user_id,
  created_by_user_id
)
values (
  'c2000000-0000-4000-8000-000000000901',
  '10000000-0000-0000-0000-000000000901',
  'c1000000-0000-4000-8000-000000000901',
  'active',
  clock_timestamp() - interval '1 day',
  'organization_lifecycle_test',
  '00000000-0000-0000-0000-000000000901',
  '00000000-0000-0000-0000-000000000901'
);

set local role service_role;
select ok(
  command_api.create_invitation(
    '90000000-0000-0000-0000-000000000901',
    '00000000-0000-0000-0000-000000000902',
    null,
    '10000000-0000-0000-0000-000000000901',
    '20000000-0000-0000-0000-000000000903',
    'member',
    'ORGANIZATION-INVITED@EXAMPLE.TEST',
    extensions.digest('organization-valid-invitation', 'sha256'),
    '2099-01-01 00:00:00+00'
  ) is not null,
  'a trusted in-scope actor can create an invitation'
);
reset role;

select is(
  command_api.create_invitation(
    '90000000-0000-0000-0000-000000000901',
    '00000000-0000-0000-0000-000000000902',
    null,
    '10000000-0000-0000-0000-000000000901',
    '20000000-0000-0000-0000-000000000903',
    'member',
    'ORGANIZATION-INVITED@EXAMPLE.TEST',
    extensions.digest('organization-valid-invitation', 'sha256'),
    '2099-01-01 00:00:00+00'
  ),
  (
    select result_id
      from internal.organization_command_idempotency
     where idempotency_key = '90000000-0000-0000-0000-000000000901'
  ),
  'an identical invitation command replays its original result'
);

select throws_ok(
  $$select command_api.create_invitation(
      '90000000-0000-0000-0000-000000000901',
      '00000000-0000-0000-0000-000000000902',
      null,
      '10000000-0000-0000-0000-000000000901',
      '20000000-0000-0000-0000-000000000903',
      'member',
      'conflicting-organization-invite@example.test',
      extensions.digest('organization-valid-invitation', 'sha256'),
      '2099-01-01 00:00:00+00'
    )$$,
  '23505',
  'idempotency key already used with different organization command data',
  'an invitation idempotency key rejects conflicting command data'
);

select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000904',
  true
);

select throws_ok(
  $$select command_api.accept_invitation(
      '90000000-0000-0000-0000-000000000902',
      '00000000-0000-0000-0000-000000000903',
      extensions.digest('organization-valid-invitation', 'sha256')
    )$$,
  '42501',
  'invitation command actor does not match the authenticated user',
  'invitation acceptance rejects an actor that does not match auth.uid'
);

select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000905',
  true
);

select throws_ok(
  $$select command_api.accept_invitation(
      '90000000-0000-0000-0000-000000000903',
      '00000000-0000-0000-0000-000000000905',
      extensions.digest('organization-valid-invitation', 'sha256')
    )$$,
  '42501',
  'authenticated user does not match the invitation',
  'invitation acceptance binds the authenticated account email'
);

select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000903',
  true
);

set local role service_role;
select ok(
  command_api.accept_invitation(
    '90000000-0000-0000-0000-000000000904',
    '00000000-0000-0000-0000-000000000903',
    extensions.digest('organization-valid-invitation', 'sha256')
  ) is not null,
  'the authenticated invited user can accept a valid invitation'
);
reset role;

select ok(
  exists (
    select 1
      from public.invitations invitation
     where invitation.token_digest = extensions.digest(
       'organization-valid-invitation',
       'sha256'
     )
       and invitation.status = 'accepted'
       and invitation.accepted_user_id =
         '00000000-0000-0000-0000-000000000903'
       and invitation.accepted_membership_id = (
         select result_id
           from internal.organization_command_idempotency
          where idempotency_key =
            '90000000-0000-0000-0000-000000000904'
       )
  ),
  'acceptance binds the invitation to the user and created membership'
);

select ok(
  exists (
    select 1
      from public.memberships membership
     where membership.id = (
       select result_id
         from internal.organization_command_idempotency
        where idempotency_key = '90000000-0000-0000-0000-000000000904'
     )
       and membership.user_id = '00000000-0000-0000-0000-000000000903'
       and membership.status = 'active'
       and membership.is_primary
  ),
  'acceptance creates an active primary membership for a new tenant member'
);

select is(
  (
    select count(*)
      from public.wallets wallet
     where wallet.owner_user_id = '00000000-0000-0000-0000-000000000903'
  ),
  1::bigint,
  'acceptance creates exactly one wallet for the eligible member'
);

select is(
  command_api.accept_invitation(
    '90000000-0000-0000-0000-000000000904',
    '00000000-0000-0000-0000-000000000903',
    extensions.digest('organization-valid-invitation', 'sha256')
  ),
  (
    select result_id
      from internal.organization_command_idempotency
     where idempotency_key = '90000000-0000-0000-0000-000000000904'
  ),
  'an identical invitation acceptance replays the original membership'
);

select set_config('request.jwt.claim.sub', '', true);

select ok(
  internal.create_membership(
    '90000000-0000-0000-0000-000000000905',
    '00000000-0000-0000-0000-000000000902',
    null,
    '10000000-0000-0000-0000-000000000901',
    '00000000-0000-0000-0000-000000000904',
    '20000000-0000-0000-0000-000000000903',
    'member'
  ) is not null,
  'a Team Leader can create a membership in their exact office scope'
);

select ok(
  exists (
    select 1
      from public.memberships membership
     where membership.id = (
       select result_id
         from internal.organization_command_idempotency
        where idempotency_key = '90000000-0000-0000-0000-000000000905'
     )
       and membership.status = 'active'
       and membership.is_primary
  ),
  'trusted membership creation makes the first current membership primary'
);

select is(
  (
    select count(*)
      from public.wallets wallet
     where wallet.owner_user_id = '00000000-0000-0000-0000-000000000904'
  ),
  1::bigint,
  'trusted membership creation ensures the eligible user wallet exists'
);

select throws_ok(
  $$select internal.create_membership(
      '90000000-0000-0000-0000-000000000906',
      '00000000-0000-0000-0000-000000000902',
      null,
      '10000000-0000-0000-0000-000000000901',
      '00000000-0000-0000-0000-000000000905',
      '20000000-0000-0000-0000-000000000905',
      'member'
    )$$,
  '42501',
  'membership creation is not authorized',
  'a Team Leader cannot create a membership in a sibling office branch'
);

insert into public.invitations (
  tenant_id,
  office_id,
  role_key,
  email,
  token_digest,
  expires_at
)
values (
  '10000000-0000-0000-0000-000000000901',
  '20000000-0000-0000-0000-000000000905',
  'member',
  'organization-closed-office@example.test',
  extensions.digest('organization-closed-office-invitation', 'sha256'),
  '2099-01-01 00:00:00+00'
);

update public.offices
   set status = 'closed'
 where id = '20000000-0000-0000-0000-000000000905';

select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000909',
  true
);

select throws_ok(
  $$select command_api.accept_invitation(
      '90000000-0000-0000-0000-000000000916',
      '00000000-0000-0000-0000-000000000909',
      extensions.digest('organization-closed-office-invitation', 'sha256')
    )$$,
  '23514',
  'membership office must be active',
  'invitation acceptance rejects an office that closed after issuance'
);

update public.offices
   set status = 'active'
 where id = '20000000-0000-0000-0000-000000000905';

select set_config('request.jwt.claim.sub', '', true);

create temporary table organization_version_snapshot (
  tenant_version bigint not null,
  account_version bigint not null
) on commit drop;

insert into organization_version_snapshot (tenant_version, account_version)
select tenant.authz_version, account.authz_version
  from public.tenants tenant
  join public.user_accounts account
    on account.user_id = '00000000-0000-0000-0000-000000000906'
 where tenant.id = '10000000-0000-0000-0000-000000000901';

select is(
  internal.suspend_membership(
    '90000000-0000-0000-0000-000000000907',
    '00000000-0000-0000-0000-000000000901',
    null,
    '30000000-0000-0000-0000-000000000906'
  ),
  '30000000-0000-0000-0000-000000000906'::uuid,
  'an authorized President can suspend a member'
);

select is(
  (
    select status::text
      from public.memberships
     where id = '30000000-0000-0000-0000-000000000906'
  ),
  'suspended',
  'suspension changes the membership lifecycle state'
);

select ok(
  (
    select tenant.authz_version = snapshot.tenant_version + 1
       and account.authz_version = snapshot.account_version + 1
      from organization_version_snapshot snapshot
      join public.tenants tenant
        on tenant.id = '10000000-0000-0000-0000-000000000901'
      join public.user_accounts account
        on account.user_id = '00000000-0000-0000-0000-000000000906'
  ),
  'suspension bumps tenant and member authorization versions'
);

select throws_ok(
  $$select internal.activate_membership(
      '90000000-0000-0000-0000-000000000917',
      '00000000-0000-0000-0000-000000000902',
      null,
      '30000000-0000-0000-0000-000000000906'
    )$$,
  '42501',
  'membership activation is not authorized',
  'a lower-scope manager cannot undo a higher-authority suspension'
);

select is(
  internal.activate_membership(
    '90000000-0000-0000-0000-000000000908',
    '00000000-0000-0000-0000-000000000901',
    null,
    '30000000-0000-0000-0000-000000000906'
  ),
  '30000000-0000-0000-0000-000000000906'::uuid,
  'an authorized President can reactivate a suspended member'
);

select is(
  (
    select status::text
      from public.memberships
     where id = '30000000-0000-0000-0000-000000000906'
  ),
  'active',
  'activation restores the active membership lifecycle state'
);

select ok(
  (
    select tenant.authz_version = snapshot.tenant_version + 2
       and account.authz_version = snapshot.account_version + 2
      from organization_version_snapshot snapshot
      join public.tenants tenant
        on tenant.id = '10000000-0000-0000-0000-000000000901'
      join public.user_accounts account
        on account.user_id = '00000000-0000-0000-0000-000000000906'
  ),
  'activation bumps tenant and member authorization versions again'
);

select throws_ok(
  $$select internal.end_membership(
      '90000000-0000-0000-0000-000000000909',
      '00000000-0000-0000-0000-000000000901',
      null,
      '30000000-0000-0000-0000-00000000090b',
      null
    )$$,
  '23514',
  'ending a primary membership requires a current replacement',
  'ending a primary membership fails closed without a replacement'
);

select is(
  internal.end_membership(
    '90000000-0000-0000-0000-00000000090a',
    '00000000-0000-0000-0000-000000000901',
    null,
    '30000000-0000-0000-0000-00000000090b',
    '30000000-0000-0000-0000-00000000091b'
  ),
  '30000000-0000-0000-0000-00000000090b'::uuid,
  'ending a primary membership accepts a valid current replacement'
);

select ok(
  exists (
    select 1
      from public.memberships membership
     where membership.id = '30000000-0000-0000-0000-00000000090b'
       and membership.status = 'ended'
       and not membership.is_primary
       and membership.ended_at is not null
  ),
  'ending preserves the source membership as non-primary history'
);

select ok(
  (
    select membership.is_primary
      from public.memberships membership
     where membership.id = '30000000-0000-0000-0000-00000000091b'
  ),
  'ending transfers primary status to the validated replacement'
);

select ok(
  internal.move_membership(
    '90000000-0000-0000-0000-00000000090b',
    '00000000-0000-0000-0000-000000000901',
    null,
    '30000000-0000-0000-0000-000000000907',
    '20000000-0000-0000-0000-000000000905',
    'member'
  ) is not null,
  'an authorized President can move a membership across office branches'
);

select ok(
  exists (
    select 1
      from public.memberships membership
     where membership.id = '30000000-0000-0000-0000-000000000907'
       and membership.status = 'ended'
       and not membership.is_primary
       and membership.ended_at is not null
  ),
  'a move preserves the source membership as ended history'
);

select ok(
  exists (
    select 1
      from public.memberships membership
     where membership.id = (
       select result_id
         from internal.organization_command_idempotency
        where idempotency_key = '90000000-0000-0000-0000-00000000090b'
     )
       and membership.office_id = '20000000-0000-0000-0000-000000000905'
       and membership.role_key = 'member'
       and membership.status = 'active'
       and membership.is_primary
  ),
  'a move creates an active destination membership and carries primary state'
);

select is(
  internal.move_membership(
    '90000000-0000-0000-0000-00000000090b',
    '00000000-0000-0000-0000-000000000901',
    null,
    '30000000-0000-0000-0000-000000000907',
    '20000000-0000-0000-0000-000000000905',
    'member'
  ),
  (
    select result_id
      from internal.organization_command_idempotency
     where idempotency_key = '90000000-0000-0000-0000-00000000090b'
  ),
  'an identical membership move replays the destination membership'
);

select throws_ok(
  $$select command_api.create_invitation(
      '90000000-0000-0000-0000-00000000090c',
      '00000000-0000-0000-0000-000000000901',
      null,
      '10000000-0000-0000-0000-000000000901',
      '20000000-0000-0000-0000-000000000901',
      'president_team_member',
      'organization-president-invite@example.test',
      extensions.digest('organization-president-invitation', 'sha256'),
      '2099-01-01 00:00:00+00'
    )$$,
  '23514',
  'President authority requires the protected presidency transfer command',
  'generic invitation creation rejects President authority'
);

select throws_ok(
  $$select internal.create_membership(
      '90000000-0000-0000-0000-00000000090d',
      '00000000-0000-0000-0000-000000000901',
      null,
      '10000000-0000-0000-0000-000000000901',
      '00000000-0000-0000-0000-000000000905',
      '20000000-0000-0000-0000-000000000901',
      'president_team_member'
    )$$,
  '23514',
  'President authority requires the protected presidency transfer command',
  'generic membership creation rejects President authority'
);

select throws_ok(
  $$select internal.suspend_membership(
      '90000000-0000-0000-0000-00000000090e',
      '00000000-0000-0000-0000-000000000901',
      null,
      '30000000-0000-0000-0000-000000000901'
    )$$,
  '23514',
  'President authority requires the protected presidency transfer command',
  'generic suspension rejects a President membership'
);

select throws_ok(
  $$select internal.end_membership(
      '90000000-0000-0000-0000-00000000090f',
      '00000000-0000-0000-0000-000000000901',
      null,
      '30000000-0000-0000-0000-000000000901',
      null
    )$$,
  '23514',
  'President authority requires the protected presidency transfer command',
  'generic ending rejects a President membership'
);

select throws_ok(
  $$select internal.move_membership(
      '90000000-0000-0000-0000-000000000910',
      '00000000-0000-0000-0000-000000000901',
      null,
      '30000000-0000-0000-0000-000000000901',
      '20000000-0000-0000-0000-000000000905',
      'member'
    )$$,
  '23514',
  'President authority requires the protected presidency transfer command',
  'generic move rejects a President membership'
);

insert into commercial.billing_owner_assignments (
  id,
  tenant_id,
  membership_id,
  owner_user_id,
  assigned_by_user_id,
  assignment_reason
)
values (
  'c3000000-0000-4000-8000-000000000901',
  '10000000-0000-0000-0000-000000000901',
  '30000000-0000-0000-0000-000000000908',
  '00000000-0000-0000-0000-000000000908',
  '00000000-0000-0000-0000-000000000901',
  'organization lifecycle billing owner guard'
);

select throws_ok(
  $$select internal.suspend_membership(
      '90000000-0000-0000-0000-000000000911',
      '00000000-0000-0000-0000-000000000901',
      null,
      '30000000-0000-0000-0000-000000000908'
    )$$,
  '23514',
  'current billing owner must be reassigned before membership authority changes',
  'the current billing owner cannot be suspended'
);

select throws_ok(
  $$select internal.end_membership(
      '90000000-0000-0000-0000-000000000912',
      '00000000-0000-0000-0000-000000000901',
      null,
      '30000000-0000-0000-0000-000000000908',
      null
    )$$,
  '23514',
  'current billing owner must be reassigned before membership authority changes',
  'the current billing owner cannot be ended'
);

select throws_ok(
  $$select internal.move_membership(
      '90000000-0000-0000-0000-000000000913',
      '00000000-0000-0000-0000-000000000901',
      null,
      '30000000-0000-0000-0000-000000000908',
      '20000000-0000-0000-0000-000000000905',
      'member'
    )$$,
  '23514',
  'current billing owner must be reassigned before membership authority changes',
  'the current billing owner cannot be moved'
);

insert into public.invitations (
  id,
  tenant_id,
  office_id,
  role_key,
  email,
  token_digest,
  expires_at
)
values (
  '40000000-0000-0000-0000-000000000901',
  '10000000-0000-0000-0000-000000000901',
  '20000000-0000-0000-0000-000000000903',
  'member',
  'organization-expired@example.test',
  extensions.digest('organization-expired-invitation', 'sha256'),
  '2020-01-01 00:00:00+00'
);

select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-00000000090a',
  true
);

select throws_ok(
  $$select command_api.accept_invitation(
      '90000000-0000-0000-0000-000000000914',
      '00000000-0000-0000-0000-00000000090a',
      extensions.digest('organization-expired-invitation', 'sha256')
    )$$,
  '23514',
  'invitation has expired',
  'acceptance rejects an expired pending invitation'
);

select set_config('request.jwt.claim.sub', '', true);

select is(
  internal.expire_invitations('2099-01-02 00:00:00+00'),
  2::bigint,
  'explicit invitation expiration transitions every due pending invitation'
);

select is(
  (
    select status::text
      from public.invitations
     where id = '40000000-0000-0000-0000-000000000901'
  ),
  'expired',
  'explicit expiration persists the expired invitation state'
);

select ok(
  not exists (
    select 1
      from (
        values
          ('internal.create_invitation(uuid,uuid,uuid,uuid,uuid,public.role_key,text,bytea,timestamptz)'),
          ('internal.revoke_invitation(uuid,uuid,uuid,uuid)'),
          ('internal.expire_invitations(timestamptz)'),
          ('internal.accept_invitation(uuid,uuid,bytea)'),
          ('internal.create_membership(uuid,uuid,uuid,uuid,uuid,uuid,public.role_key)'),
          ('internal.activate_membership(uuid,uuid,uuid,uuid)'),
          ('internal.suspend_membership(uuid,uuid,uuid,uuid)'),
          ('internal.end_membership(uuid,uuid,uuid,uuid,uuid)'),
          ('internal.move_membership(uuid,uuid,uuid,uuid,uuid,public.role_key)')
      ) as command(signature)
     where has_function_privilege('anon', command.signature, 'execute')
  ),
  'anon has no direct execution privilege on organization commands'
);

select ok(
  not exists (
    select 1
      from (
        values
          ('internal.create_invitation(uuid,uuid,uuid,uuid,uuid,public.role_key,text,bytea,timestamptz)'),
          ('internal.revoke_invitation(uuid,uuid,uuid,uuid)'),
          ('internal.expire_invitations(timestamptz)'),
          ('internal.accept_invitation(uuid,uuid,bytea)'),
          ('internal.create_membership(uuid,uuid,uuid,uuid,uuid,uuid,public.role_key)'),
          ('internal.activate_membership(uuid,uuid,uuid,uuid)'),
          ('internal.suspend_membership(uuid,uuid,uuid,uuid)'),
          ('internal.end_membership(uuid,uuid,uuid,uuid,uuid)'),
          ('internal.move_membership(uuid,uuid,uuid,uuid,uuid,public.role_key)')
      ) as command(signature)
     where has_function_privilege(
       'authenticated',
       command.signature,
       'execute'
     )
  ),
  'authenticated has no direct execution privilege on organization commands'
);

select ok(
  not exists (
    select 1
      from (
        values
          ('internal.create_invitation(uuid,uuid,uuid,uuid,uuid,public.role_key,text,bytea,timestamptz)'),
          ('internal.revoke_invitation(uuid,uuid,uuid,uuid)'),
          ('internal.expire_invitations(timestamptz)'),
          ('internal.accept_invitation(uuid,uuid,bytea)'),
          ('internal.create_membership(uuid,uuid,uuid,uuid,uuid,uuid,public.role_key)'),
          ('internal.activate_membership(uuid,uuid,uuid,uuid)'),
          ('internal.suspend_membership(uuid,uuid,uuid,uuid)'),
          ('internal.end_membership(uuid,uuid,uuid,uuid,uuid)'),
          ('internal.move_membership(uuid,uuid,uuid,uuid,uuid,public.role_key)')
      ) as command(signature)
     where has_function_privilege(
       'service_role',
       command.signature,
       'execute'
     )
  ),
  'service_role has no direct execution privilege on organization commands'
);

select is(
  (
    select count(*)
      from pg_class relation
      join pg_namespace namespace on namespace.oid = relation.relnamespace
     where namespace.nspname = 'internal'
       and relation.relname = 'organization_command_idempotency'
       and relation.relrowsecurity
       and relation.relforcerowsecurity
  ),
  1::bigint,
  'the organization idempotency table has RLS enabled and forced'
);

select is(
  (
    select count(*)
      from pg_policy policy
      join pg_class relation on relation.oid = policy.polrelid
      join pg_namespace namespace on namespace.oid = relation.relnamespace
     where namespace.nspname = 'internal'
       and relation.relname = 'organization_command_idempotency'
       and not policy.polpermissive
       and pg_get_expr(policy.polqual, policy.polrelid) = 'false'
       and pg_get_expr(policy.polwithcheck, policy.polrelid) = 'false'
  ),
  1::bigint,
  'the organization idempotency table has an explicit restrictive deny policy'
);

select ok(
  not exists (
    select 1
      from unnest(array['anon', 'authenticated', 'service_role']) as role_name
     where has_table_privilege(
       role_name,
       'internal.organization_command_idempotency',
       'select'
     )
        or has_table_privilege(
          role_name,
          'internal.organization_command_idempotency',
          'insert'
        )
        or has_table_privilege(
          role_name,
          'internal.organization_command_idempotency',
          'update'
        )
        or has_table_privilege(
          role_name,
          'internal.organization_command_idempotency',
          'delete'
        )
  ),
  'anon, authenticated, and service_role have no direct idempotency-table privileges'
);

set local role anon;
select throws_ok(
  $$select internal.expire_invitations('2099-01-02 00:00:00+00')$$,
  '42501',
  null,
  'anon cannot directly execute an organization command'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000903',
  true
);
select throws_ok(
  $$select internal.accept_invitation(
      '90000000-0000-0000-0000-000000000915',
      '00000000-0000-0000-0000-000000000903',
      extensions.digest('organization-valid-invitation', 'sha256')
    )$$,
  '42501',
  null,
  'authenticated cannot directly execute an organization command'
);
reset role;

set local role service_role;
select throws_ok(
  $$select internal.expire_invitations('2099-01-02 00:00:00+00')$$,
  '42501',
  null,
  'service_role cannot directly execute an organization command'
);
reset role;

select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
select ok(command_api.move_membership('90000000-0000-0000-0000-00000000090b','00000000-0000-0000-0000-000000000901',null,'30000000-0000-0000-0000-000000000907','20000000-0000-0000-0000-000000000905','member') is not null,'currently authorized move replay resolves original ended source context');
reset role;
update public.user_accounts set status='suspended' where user_id='00000000-0000-0000-0000-000000000901';
set local role service_role;
select throws_ok($$select command_api.move_membership('90000000-0000-0000-0000-00000000090b','00000000-0000-0000-0000-000000000901',null,'30000000-0000-0000-0000-000000000907','20000000-0000-0000-0000-000000000905','member')$$,'42501',null,'suspended President cannot replay membership move');
select throws_ok($$select command_api.activate_membership('90000000-0000-0000-0000-000000000908','00000000-0000-0000-0000-000000000901',null,'30000000-0000-0000-0000-000000000906')$$,'42501',null,'suspended President cannot replay membership activation');
reset role;

select * from finish();
rollback;
