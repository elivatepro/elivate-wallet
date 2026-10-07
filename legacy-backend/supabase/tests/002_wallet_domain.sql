begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select no_plan();

insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
values
  ('00000000-0000-0000-0000-000000000101', 'authenticated', 'authenticated', 'wallet-president@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000102', 'authenticated', 'authenticated', 'wallet-leader@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000103', 'authenticated', 'authenticated', 'wallet-member@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000104', 'authenticated', 'authenticated', 'wallet-outsider@example.test', '{}'::jsonb, '{}'::jsonb)
on conflict (id) do nothing;

insert into public.user_accounts (user_id)
values
  ('00000000-0000-0000-0000-000000000101'),
  ('00000000-0000-0000-0000-000000000102'),
  ('00000000-0000-0000-0000-000000000103'),
  ('00000000-0000-0000-0000-000000000104');

insert into public.tenants (id, name)
values
  ('10000000-0000-0000-0000-000000000101', 'Wallet Tenant One'),
  ('10000000-0000-0000-0000-000000000102', 'Wallet Tenant Two');

insert into public.offices (id, tenant_id, office_type, name)
values
  ('20000000-0000-0000-0000-000000000101', '10000000-0000-0000-0000-000000000101', 'world_team', 'Wallet World Team One'),
  ('20000000-0000-0000-0000-000000000104', '10000000-0000-0000-0000-000000000102', 'world_team', 'Wallet World Team Two');

insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000102',
  '10000000-0000-0000-0000-000000000101',
  '20000000-0000-0000-0000-000000000101',
  'director',
  'Wallet Director Office'
);

insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000103',
  '10000000-0000-0000-0000-000000000101',
  '20000000-0000-0000-0000-000000000102',
  'team_leader',
  'Wallet Team Leader Office'
);

insert into public.memberships (
  id, tenant_id, user_id, office_id, role_key, is_primary
)
values
  ('30000000-0000-0000-0000-000000000101', '10000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000101', null, 'president_team_member', true),
  ('30000000-0000-0000-0000-000000000102', '10000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000102', '20000000-0000-0000-0000-000000000103', 'team_leader', true),
  ('30000000-0000-0000-0000-000000000103', '10000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000103', '20000000-0000-0000-0000-000000000103', 'member', true),
  ('30000000-0000-0000-0000-000000000104', '10000000-0000-0000-0000-000000000102', '00000000-0000-0000-0000-000000000104', '20000000-0000-0000-0000-000000000104', 'world_team_member', true);

select authz.seed_tenant_role_permissions('10000000-0000-0000-0000-000000000101');
select authz.seed_tenant_role_permissions('10000000-0000-0000-0000-000000000102');

insert into public.wallets (id, owner_user_id)
values
  ('60000000-0000-0000-0000-000000000102', '00000000-0000-0000-0000-000000000102'),
  ('60000000-0000-0000-0000-000000000103', '00000000-0000-0000-0000-000000000103'),
  ('60000000-0000-0000-0000-000000000104', '00000000-0000-0000-0000-000000000104');

select throws_ok(
  $$insert into public.wallets (owner_user_id)
    values ('00000000-0000-0000-0000-000000000101')$$,
  '23514',
  'wallet owner must have an active wallet-eligible membership',
  'president-only account cannot receive a wallet'
);

select throws_ok(
  $$insert into public.wallets (owner_user_id)
    values ('00000000-0000-0000-0000-000000000103')$$,
  '23505',
  null,
  'one global wallet is enforced per user'
);

select ok(
  exists (
    select 1
      from public.pocket_definitions
     where pocket_key = 'debt'
       and allows_negative
       and transfer_in_allowed
       and not transfer_out_allowed
  ),
  'Debt is the only seeded pocket and preserves its frozen direction rules'
);

select throws_ok(
  $$insert into public.pocket_definitions (
      pocket_key, display_name, allows_negative, sort_order
    ) values ('invalid_negative', 'Invalid Negative', true, 901)$$,
  '23514',
  null,
  'non-Debt pocket definitions cannot allow negative balances'
);

insert into public.pocket_definitions (
  pocket_key, display_name, sort_order
)
values
  ('test_primary', 'Test Primary', 100),
  ('test_secondary', 'Test Secondary', 200);

insert into public.allocation_policy_versions (
  id, tenant_id, version_number, created_by_user_id
)
values (
  '70000000-0000-0000-0000-000000000101',
  '10000000-0000-0000-0000-000000000101',
  1,
  '00000000-0000-0000-0000-000000000101'
);

insert into public.allocation_policy_rules (
  tenant_id, policy_version_id, pocket_key,
  allocation_basis_points, remainder_rank
)
values
  ('10000000-0000-0000-0000-000000000101', '70000000-0000-0000-0000-000000000101', 'test_primary', 4000, 1),
  ('10000000-0000-0000-0000-000000000101', '70000000-0000-0000-0000-000000000101', 'test_secondary', 5000, 2);

select throws_ok(
  $$update public.allocation_policy_versions
       set activated_at = clock_timestamp()
     where id = '70000000-0000-0000-0000-000000000101'$$,
  '23514',
  'active allocation policy percentages must total exactly 100 percent',
  'allocation policy cannot activate below exactly 100 percent'
);

update public.allocation_policy_rules
   set allocation_basis_points = 6000
 where policy_version_id = '70000000-0000-0000-0000-000000000101'
   and pocket_key = 'test_secondary';

update public.allocation_policy_versions
   set activated_at = clock_timestamp()
 where id = '70000000-0000-0000-0000-000000000101';

insert into public.tenant_active_allocation_policies (
  tenant_id, policy_version_id, activated_by_user_id
)
values (
  '10000000-0000-0000-0000-000000000101',
  '70000000-0000-0000-0000-000000000101',
  '00000000-0000-0000-0000-000000000101'
);

select throws_ok(
  $$update public.allocation_policy_rules
       set allocation_basis_points = 5000
     where policy_version_id = '70000000-0000-0000-0000-000000000101'
       and pocket_key = 'test_primary'$$,
  '55000',
  'rules for an activated allocation policy are immutable',
  'activated allocation policy rules cannot be rewritten'
);

select is(
  (
    select sum(allocation_basis_points)
      from public.allocation_policy_rules
     where policy_version_id = '70000000-0000-0000-0000-000000000101'
  ),
  10000::bigint,
  'active allocation policy stores exact integer percentages totaling 100 percent'
);

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000103', null, 'view_own_wallet',
    '10000000-0000-0000-0000-000000000101',
    '20000000-0000-0000-0000-000000000103',
    '30000000-0000-0000-0000-000000000103',
    '00000000-0000-0000-0000-000000000103',
    '60000000-0000-0000-0000-000000000103',
    '00000000-0000-0000-0000-000000000103', null, null
  )).source,
  'protected_baseline'::authz.authorization_source,
  'wallet holder self-read resolves through the protected baseline'
);

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000103', null, 'manage_own_payout_accounts',
    '10000000-0000-0000-0000-000000000101',
    '20000000-0000-0000-0000-000000000103',
    '30000000-0000-0000-0000-000000000103',
    '00000000-0000-0000-0000-000000000103',
    '60000000-0000-0000-0000-000000000103',
    '00000000-0000-0000-0000-000000000103', null, null
  )).decision,
  'STEP_UP_REQUIRED'::authz.authorization_decision_state,
  'sensitive Wallet self-service still requires fresh step-up'
);

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000103', null, 'view_own_wallet',
    '10000000-0000-0000-0000-000000000101',
    '20000000-0000-0000-0000-000000000103',
    '30000000-0000-0000-0000-000000000103',
    '00000000-0000-0000-0000-000000000103',
    '60000000-0000-0000-0000-000000000102',
    null, null, null
  )).reason_code,
  'wallet_owner_mismatch',
  'wallet target user is derived from the authoritative wallet row'
);

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000102', null, 'view_managed_wallets',
    '10000000-0000-0000-0000-000000000101',
    '20000000-0000-0000-0000-000000000103',
    '30000000-0000-0000-0000-000000000103',
    '00000000-0000-0000-0000-000000000103',
    '60000000-0000-0000-0000-000000000103',
    '00000000-0000-0000-0000-000000000103', null, null
  )).decision,
  'ALLOW'::authz.authorization_decision_state,
  'leadership wallet access requires an authoritative target membership context'
);

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000102', null, 'view_managed_wallets',
    '10000000-0000-0000-0000-000000000101',
    '20000000-0000-0000-0000-000000000103',
    '30000000-0000-0000-0000-000000000102',
    '00000000-0000-0000-0000-000000000102',
    '60000000-0000-0000-0000-000000000102',
    '00000000-0000-0000-0000-000000000102', null, null
  )).reason_code,
  'leadership_self_wallet_forbidden',
  'leadership wallet permission cannot target the actor wallet'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000103', true);

select is(
  (select count(*) from public.wallets),
  1::bigint,
  'authenticated wallet holder reads only their own wallet'
);

select is(
  (select count(*) from public.allocation_policy_versions),
  1::bigint,
  'active tenant member can read allocation policy history for their tenant'
);

select ok(
  exists (select 1 from public.pocket_definitions where pocket_key = 'debt'),
  'active authenticated account can read the protected pocket catalogue'
);

select throws_ok(
  $$update public.wallets
       set owner_user_id = '00000000-0000-0000-0000-000000000102'
     where id = '60000000-0000-0000-0000-000000000103'$$,
  '42501',
  null,
  'authenticated client cannot mutate wallet ownership'
);

select throws_ok(
  $$select authz.can_read_wallet('60000000-0000-0000-0000-000000000103')$$,
  '42501',
  null,
  'private wallet authorization helper is not directly client-accessible'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000104', true);

select is(
  (
    select count(*)
      from public.allocation_policy_versions
     where tenant_id = '10000000-0000-0000-0000-000000000101'
  ),
  0::bigint,
  'allocation policy history is isolated by tenant'
);

reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000103', true);

update public.memberships
   set status = 'ended',
       is_primary = false,
       ended_at = clock_timestamp()
 where id = '30000000-0000-0000-0000-000000000103';

select ok(
  exists (
    select 1 from public.wallets
     where id = '60000000-0000-0000-0000-000000000103'
  ),
  'ending a membership does not delete the global wallet'
);

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000103', null, 'view_own_wallet',
    '10000000-0000-0000-0000-000000000101',
    '20000000-0000-0000-0000-000000000103',
    '30000000-0000-0000-0000-000000000103',
    '00000000-0000-0000-0000-000000000103',
    '60000000-0000-0000-0000-000000000103',
    '00000000-0000-0000-0000-000000000103', null, null
  )).reason_code,
  'no_active_wallet_membership',
  'ended membership contributes no protected Wallet authority'
);

select throws_ok(
  $$delete from public.wallets
     where id = '60000000-0000-0000-0000-000000000103'$$,
  '55000',
  'wallets preserve stable financial identity and cannot be deleted',
  'wallet identity cannot be destructively deleted'
);

select finish();
rollback;
