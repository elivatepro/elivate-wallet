begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

insert into auth.users (
  id, aud, role, email, raw_app_meta_data, raw_user_meta_data
)
values
  ('00000000-0000-0000-0000-000000000a01', 'authenticated', 'authenticated', 'dev-president@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000a02', 'authenticated', 'authenticated', 'dev-leader@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000a03', 'authenticated', 'authenticated', 'dev-member@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000a04', 'authenticated', 'authenticated', 'dev-fourth@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000a05', 'authenticated', 'authenticated', 'dev-unverified@example.test', '{}'::jsonb, '{}'::jsonb);

insert into public.user_accounts (user_id)
values
  ('00000000-0000-0000-0000-000000000a01'),
  ('00000000-0000-0000-0000-000000000a02'),
  ('00000000-0000-0000-0000-000000000a03'),
  ('00000000-0000-0000-0000-000000000a04'),
  ('00000000-0000-0000-0000-000000000a05');

update auth.users
   set email_confirmed_at = clock_timestamp()
 where id <> '00000000-0000-0000-0000-000000000a05'
   and id in (
     '00000000-0000-0000-0000-000000000a01',
     '00000000-0000-0000-0000-000000000a02',
     '00000000-0000-0000-0000-000000000a03',
     '00000000-0000-0000-0000-000000000a04'
   );

select throws_ok(
  $$select command_api.bootstrap_development_network(
    '00000000-0000-0000-0000-000000000a05',
    decode(repeat('ff', 32), 'hex'), 'Unverified Network'
  )$$,
  '42501',
  'a verified active account is required for network setup',
  'unverified users cannot create development networks'
);

select ok(not has_function_privilege('anon',
  'command_api.bootstrap_development_network(uuid,bytea,text)', 'EXECUTE'),
  'anonymous clients cannot call the setup transport');
select ok(not has_function_privilege('authenticated',
  'command_api.bootstrap_development_network(uuid,bytea,text)', 'EXECUTE'),
  'authenticated clients cannot call the setup transport');
select ok(has_function_privilege('service_role',
  'command_api.bootstrap_development_network(uuid,bytea,text)', 'EXECUTE'),
  'trusted service can call the setup transport');
select ok((select prosecdef from pg_proc
  where oid = 'command_api.bootstrap_development_network(uuid,bytea,text)'::regprocedure),
  'the narrow transport delegates with pinned definer privileges');

select ok(not has_schema_privilege('anon', 'command_api', 'USAGE'),
  'anonymous callers cannot access command schema');
select ok(not has_schema_privilege('authenticated', 'command_api', 'USAGE'),
  'authenticated callers cannot access command schema');
select ok(not has_schema_privilege('service_role', 'internal', 'USAGE'),
  'internal remains unavailable to the service runtime');
select ok(not has_function_privilege('service_role',
  'internal.bootstrap_development_network(uuid,bytea,text)', 'EXECUTE'),
  'service runtime calls only the narrow wrapper');

create temporary table test_development_network (tenant_id uuid);
grant insert on test_development_network to service_role;
set local role service_role;
insert into test_development_network
select command_api.bootstrap_development_network(
  '00000000-0000-0000-0000-000000000a01',
  decode(repeat('ab', 32), 'hex'), 'Test Network'
);
reset role;

select is(
  (select count(*)::integer from test_development_network), 1,
  'a verified President creates one development network'
);
select is(
  (select count(*)::integer
     from public.memberships membership
     join test_development_network network on network.tenant_id = membership.tenant_id
    where membership.user_id = '00000000-0000-0000-0000-000000000a01'
      and membership.role_key = 'president_team_member'
      and membership.status = 'active'), 1,
  'the creator receives only President Team Member membership'
);
select is(
  (select count(*)::integer
     from public.offices office
     join test_development_network network on network.tenant_id = office.tenant_id), 3,
  'network setup creates the required office hierarchy'
);
select is(
  (select subscription.status::text
     from commercial.tenant_subscriptions subscription
     join test_development_network network on network.tenant_id = subscription.tenant_id),
  'suspended',
  'development network has a suspended commercial subscription'
);
select ok(
  commercial.is_tenant_commercially_restricted(
    (select tenant_id from test_development_network)
  ),
  'financial operations remain commercially restricted'
);
select ok(
  (commercial.evaluate_seat_capacity(
    (select tenant_id from test_development_network),
    '00000000-0000-0000-0000-000000000a02'
  )).allowed,
  'the second test account has a development seat'
);
select throws_ok(
  $$select internal.bootstrap_development_network(
    '00000000-0000-0000-0000-000000000a04',
    decode(repeat('ab', 32), 'hex'), 'Another Network'
  )$$,
  '23505',
  'development setup token has already been used',
  'a setup token cannot create another network'
);

-- Regression: newly created PTM membership needs tenant defaults before it
-- can create invitations through the resolver-backed command boundary.
select is(
  (select count(*)::integer from authz.tenant_role_permissions policy
    join test_development_network network on network.tenant_id=policy.tenant_id),
  (select count(*)::integer from authz.default_role_permissions),
  'bootstrap initializes the complete approved exact-role default policy'
);
select is(
  (authz.authorize('00000000-0000-0000-0000-000000000a01',null,'invite_members',
    (select tenant_id from test_development_network),
    (select office.id from public.offices office join test_development_network network
      on network.tenant_id=office.tenant_id where office.office_type='team_leader'),
    null,null,null,null,null,null)).decision,
  'ALLOW'::authz.authorization_decision_state,
  'fresh development President can invite into the stored Team office'
);
select is(
  (authz.authorize('00000000-0000-0000-0000-000000000a01',null,'record_income',
    (select tenant_id from test_development_network),null,null,null,null,null,null,null)).reason_code,
  'commercial_money_movement_restricted',
  'seeding role defaults does not bypass development financial suspension'
);
select ok(command_api.create_invitation(
  '91000000-0000-0000-0000-000000000a02','00000000-0000-0000-0000-000000000a01',null,
  (select tenant_id from test_development_network),
  (select office.id from public.offices office join test_development_network network
    on network.tenant_id=office.tenant_id where office.office_type='team_leader'),
  'team_leader','dev-leader@example.test',extensions.digest('development-team-leader','sha256'),
  '2099-01-01 00:00:00+00') is not null,
  'fresh development President creates a Team Leader invitation');
select ok(command_api.accept_invitation(
  '92000000-0000-0000-0000-000000000a02','00000000-0000-0000-0000-000000000a02',
  extensions.digest('development-team-leader','sha256')) is not null,
  'invited Team Leader joins the suspended development network');

select ok(
  (commercial.evaluate_seat_capacity(
    (select tenant_id from test_development_network),
    '00000000-0000-0000-0000-000000000a03'
  )).allowed,
  'the third test account has a development seat'
);

select ok(command_api.create_invitation(
  '91000000-0000-0000-0000-000000000a03','00000000-0000-0000-0000-000000000a01',null,
  (select tenant_id from test_development_network),
  (select office.id from public.offices office join test_development_network network
    on network.tenant_id=office.tenant_id where office.office_type='team_leader'),
  'member','dev-member@example.test',extensions.digest('development-member','sha256'),
  '2099-01-01 00:00:00+00') is not null,
  'fresh development President creates a Member invitation');
select ok(command_api.accept_invitation(
  '92000000-0000-0000-0000-000000000a03','00000000-0000-0000-0000-000000000a03',
  extensions.digest('development-member','sha256')) is not null,
  'invited Member joins the third development seat');

select ok(
  not (commercial.evaluate_seat_capacity(
    (select tenant_id from test_development_network),
    '00000000-0000-0000-0000-000000000a04'
  )).allowed,
  'a fourth test account cannot join the three-seat development network'
);

select ok(command_api.create_invitation(
  '91000000-0000-0000-0000-000000000a04','00000000-0000-0000-0000-000000000a01',null,
  (select tenant_id from test_development_network),
  (select office.id from public.offices office join test_development_network network
    on network.tenant_id=office.tenant_id where office.office_type='team_leader'),
  'member','dev-fourth@example.test',extensions.digest('development-fourth','sha256'),
  '2099-01-01 00:00:00+00') is not null,
  'invitation creation does not itself consume the fourth seat');
select throws_ok($$select command_api.accept_invitation(
  '92000000-0000-0000-0000-000000000a04','00000000-0000-0000-0000-000000000a04',
  extensions.digest('development-fourth','sha256'))$$,'23514',null,
  'acceptance still enforces the three-seat development capacity');

select * from finish();
rollback;
