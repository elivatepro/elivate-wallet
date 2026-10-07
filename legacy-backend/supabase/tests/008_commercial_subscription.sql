begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
values
  ('00000000-0000-0000-0000-000000000801', 'authenticated', 'authenticated', 'commercial-president@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000802', 'authenticated', 'authenticated', 'commercial-covered@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000803', 'authenticated', 'authenticated', 'commercial-suspended-account@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000804', 'authenticated', 'authenticated', 'commercial-suspended-membership@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000805', 'authenticated', 'authenticated', 'commercial-ended@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000806', 'authenticated', 'authenticated', 'commercial-invited@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000807', 'authenticated', 'authenticated', 'commercial-candidate@example.test', '{}'::jsonb, '{}'::jsonb)
on conflict (id) do nothing;

insert into public.user_accounts (user_id, status)
values
  ('00000000-0000-0000-0000-000000000801', 'active'),
  ('00000000-0000-0000-0000-000000000802', 'active'),
  ('00000000-0000-0000-0000-000000000803', 'suspended'),
  ('00000000-0000-0000-0000-000000000804', 'active'),
  ('00000000-0000-0000-0000-000000000805', 'active'),
  ('00000000-0000-0000-0000-000000000806', 'active'),
  ('00000000-0000-0000-0000-000000000807', 'active');

insert into public.tenants (id, name)
values ('10000000-0000-0000-0000-000000000801', 'Commercial Test Tenant');

insert into public.offices (id, tenant_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000801',
  '10000000-0000-0000-0000-000000000801',
  'world_team',
  'Commercial World Team'
);

insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000802',
  '10000000-0000-0000-0000-000000000801',
  '20000000-0000-0000-0000-000000000801',
  'director',
  'Commercial Director'
);

insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000803',
  '10000000-0000-0000-0000-000000000801',
  '20000000-0000-0000-0000-000000000802',
  'team_leader',
  'Commercial Team'
);

insert into public.memberships (
  id, tenant_id, user_id, office_id, role_key, status, is_primary, ended_at
)
values
  ('30000000-0000-0000-0000-000000000801', '10000000-0000-0000-0000-000000000801', '00000000-0000-0000-0000-000000000801', null, 'president_team_member', 'active', true, null),
  ('30000000-0000-0000-0000-000000000802', '10000000-0000-0000-0000-000000000801', '00000000-0000-0000-0000-000000000802', '20000000-0000-0000-0000-000000000803', 'member', 'active', true, null),
  ('30000000-0000-0000-0000-000000000803', '10000000-0000-0000-0000-000000000801', '00000000-0000-0000-0000-000000000802', '20000000-0000-0000-0000-000000000803', 'team_leader', 'suspended', false, null),
  ('30000000-0000-0000-0000-000000000804', '10000000-0000-0000-0000-000000000801', '00000000-0000-0000-0000-000000000803', '20000000-0000-0000-0000-000000000803', 'member', 'active', true, null),
  ('30000000-0000-0000-0000-000000000805', '10000000-0000-0000-0000-000000000801', '00000000-0000-0000-0000-000000000804', '20000000-0000-0000-0000-000000000803', 'member', 'suspended', true, null),
  ('30000000-0000-0000-0000-000000000806', '10000000-0000-0000-0000-000000000801', '00000000-0000-0000-0000-000000000805', '20000000-0000-0000-0000-000000000803', 'member', 'ended', false, clock_timestamp());

insert into public.invitations (
  id, tenant_id, office_id, role_key, email, token_digest, expires_at
)
values (
  '40000000-0000-0000-0000-000000000801',
  '10000000-0000-0000-0000-000000000801',
  '20000000-0000-0000-0000-000000000803',
  'member',
  'commercial-invited@example.test',
  extensions.digest('commercial-invitation', 'sha256'),
  clock_timestamp() + interval '1 day'
);

select authz.seed_tenant_role_permissions('10000000-0000-0000-0000-000000000801');

insert into commercial.plans (id, plan_key, display_name)
values (
  'c0000000-0000-4000-8000-000000000801',
  'test_capacity_four',
  'Test capacity four'
);

insert into commercial.plan_versions (
  id, plan_id, version_number, minimum_covered_users,
  maximum_covered_users, list_price_amount, currency_code,
  billing_cadence_code, effective_from
)
values (
  'c1000000-0000-4000-8000-000000000801',
  'c0000000-0000-4000-8000-000000000801',
  1, 1, 4, 1.00, 'NGN', null, current_date
);

insert into commercial.tenant_subscriptions (
  id, tenant_id, plan_version_id, status, starts_at,
  status_reason, status_changed_by_user_id, created_by_user_id
)
values (
  'c2000000-0000-4000-8000-000000000801',
  '10000000-0000-0000-0000-000000000801',
  'c1000000-0000-4000-8000-000000000801',
  'active',
  clock_timestamp() - interval '1 day',
  'test_subscription_started',
  '00000000-0000-0000-0000-000000000801',
  '00000000-0000-0000-0000-000000000801'
);

select is(
  (select list_price_amount from commercial.plan_versions
    where id = 'c1000000-0000-4000-8000-000000000001'),
  700000.00::numeric,
  'the launch 400-user plan preserves the confirmed NGN price'
);
select is(
  (select list_price_amount from commercial.plan_versions
    where id = 'c1000000-0000-4000-8000-000000000002'),
  1000000.00::numeric,
  'the launch 1,000-user plan preserves the confirmed NGN price'
);
select is(
  (select list_price_amount from commercial.plan_versions
    where id = 'c1000000-0000-4000-8000-000000000003'),
  1500000.00::numeric,
  'the launch 1,001-plus plan preserves the confirmed NGN price'
);
select is(
  (select count(*) from commercial.plan_versions
    where billing_cadence_code is null),
  4::bigint,
  'billing cadence remains explicitly unresolved'
);
select is(
  (select count(*) from commercial.extra_catalog),
  5::bigint,
  'the approved optional extras are catalogued without activation semantics'
);

select throws_ok(
  $$insert into commercial.tenant_subscriptions (
       tenant_id, plan_version_id, status, starts_at, status_reason
     ) values (
       '10000000-0000-0000-0000-000000000801',
       'c1000000-0000-4000-8000-000000000801',
       'active', clock_timestamp(), 'duplicate_current'
     )$$,
  '23505',
  null,
  'a tenant cannot have two current subscription records'
);

select is(
  commercial.count_billable_users('10000000-0000-0000-0000-000000000801'),
  4,
  'distinct covered users count active and suspended states once, including President'
);
select ok(
  (commercial.evaluate_seat_capacity(
    '10000000-0000-0000-0000-000000000801',
    '00000000-0000-0000-0000-000000000802'
  )).allowed,
  'an already-covered user can receive another membership at capacity'
);
select is(
  (commercial.evaluate_seat_capacity(
    '10000000-0000-0000-0000-000000000801',
    '00000000-0000-0000-0000-000000000802'
  )).projected_billable_users,
  4,
  'multiple memberships for one user do not consume another seat'
);
select ok(
  not (commercial.evaluate_seat_capacity(
    '10000000-0000-0000-0000-000000000801',
    '00000000-0000-0000-0000-000000000807'
  )).allowed,
  'a new distinct covered user is blocked at plan capacity'
);
select is(
  (commercial.evaluate_seat_capacity(
    '10000000-0000-0000-0000-000000000801',
    '00000000-0000-0000-0000-000000000807'
  )).reason_code,
  'seat_capacity_reached',
  'capacity denial returns a stable reason code'
);
select throws_ok(
  $$select commercial.assert_seat_capacity(
    '10000000-0000-0000-0000-000000000801',
    '00000000-0000-0000-0000-000000000807'
  )$$,
  '23514',
  'tenant cannot add or activate this covered user',
  'the transaction-locking capacity assertion fails closed'
);

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000801', null, 'record_income',
    '10000000-0000-0000-0000-000000000801',
    '20000000-0000-0000-0000-000000000803',
    '30000000-0000-0000-0000-000000000802',
    '00000000-0000-0000-0000-000000000802'
  )).decision,
  'ALLOW'::authz.authorization_decision_state,
  'an active subscription permits authorized money movement'
);

update commercial.tenant_subscriptions
   set status = 'suspended',
       status_reason = 'test_payment_suspension',
       status_changed_by_user_id = '00000000-0000-0000-0000-000000000801'
 where id = 'c2000000-0000-4000-8000-000000000801';

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000801', null, 'record_income',
    '10000000-0000-0000-0000-000000000801',
    '20000000-0000-0000-0000-000000000803',
    '30000000-0000-0000-0000-000000000802',
    '00000000-0000-0000-0000-000000000802'
  )).reason_code,
  'commercial_money_movement_restricted',
  'commercial suspension globally blocks a money-moving permission'
);
select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000801', null,
    'view_scoped_financial_reports',
    '10000000-0000-0000-0000-000000000801',
    '20000000-0000-0000-0000-000000000803'
  )).decision,
  'ALLOW'::authz.authorization_decision_state,
  'commercial suspension preserves authorized historical read access'
);
select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000801', null,
    'manage_subscription',
    '10000000-0000-0000-0000-000000000801',
    null, '30000000-0000-0000-0000-000000000802'
  )).decision,
  'ALLOW'::authz.authorization_decision_state,
  'commercial suspension preserves subscription-management authority'
);
select ok(
  (commercial.evaluate_seat_capacity(
    '10000000-0000-0000-0000-000000000801',
    '00000000-0000-0000-0000-000000000802'
  )).allowed,
  'commercial suspension does not turn an existing covered user into a new seat'
);
select is(
  (commercial.evaluate_seat_capacity(
    '10000000-0000-0000-0000-000000000801',
    '00000000-0000-0000-0000-000000000807'
  )).reason_code,
  'subscription_restricted',
  'commercial suspension blocks a user from becoming newly billable'
);

update commercial.tenant_subscriptions
   set status = 'payment_due',
       status_reason = 'test_payment_due',
       status_changed_by_user_id = '00000000-0000-0000-0000-000000000801'
 where id = 'c2000000-0000-4000-8000-000000000801';

select is(
  (authz.authorize(
    '00000000-0000-0000-0000-000000000801', null, 'record_income',
    '10000000-0000-0000-0000-000000000801',
    '20000000-0000-0000-0000-000000000803',
    '30000000-0000-0000-0000-000000000802',
    '00000000-0000-0000-0000-000000000802'
  )).decision,
  'ALLOW'::authz.authorization_decision_state,
  'payment_due does not suspend money movement'
);

update commercial.tenant_subscriptions
   set status = 'grace_period',
       status_reason = 'test_grace_period'
 where id = 'c2000000-0000-4000-8000-000000000801';
select ok(
  not commercial.is_tenant_commercially_restricted(
    '10000000-0000-0000-0000-000000000801'
  ),
  'grace period is not an effective suspension'
);

update commercial.tenant_subscriptions
   set status = 'past_due',
       status_reason = 'test_past_due'
 where id = 'c2000000-0000-4000-8000-000000000801';
select ok(
  not commercial.is_tenant_commercially_restricted(
    '10000000-0000-0000-0000-000000000801'
  ),
  'past due is distinct from suspension'
);

update commercial.tenant_subscriptions
   set status = 'cancelled',
       service_ends_at = clock_timestamp() + interval '1 day',
       status_reason = 'test_scheduled_cancellation'
 where id = 'c2000000-0000-4000-8000-000000000801';
select ok(
  not commercial.is_tenant_commercially_restricted(
    '10000000-0000-0000-0000-000000000801'
  ),
  'scheduled cancellation preserves service before its effective end'
);

update commercial.tenant_subscriptions
   set service_ends_at = clock_timestamp() - interval '1 minute'
 where id = 'c2000000-0000-4000-8000-000000000801';
select ok(
  commercial.is_tenant_commercially_restricted(
    '10000000-0000-0000-0000-000000000801'
  ),
  'effective cancellation restricts new money movement'
);

update commercial.tenant_subscriptions
   set status = 'active',
       service_ends_at = null,
       status_reason = 'test_reactivation'
 where id = 'c2000000-0000-4000-8000-000000000801';

insert into authz.elevated_sessions (
  session_id, user_id, verified_at, valid_until, factor_method
)
values (
  'a0000000-0000-4000-8000-000000000801',
  '00000000-0000-0000-0000-000000000801',
  clock_timestamp(),
  clock_timestamp() + interval '4 minutes',
  'test_totp'
);

-- A verified elevation is tied to a real Auth session.
insert into auth.sessions(id,user_id,aal,created_at,updated_at)
select session_id,user_id,'aal2',verified_at,verified_at from authz.elevated_sessions
on conflict (id) do nothing;

select throws_ok(
  $$select commercial.set_billing_owner(
    '00000000-0000-0000-0000-000000000801', null,
    '10000000-0000-0000-0000-000000000801',
    '30000000-0000-0000-0000-000000000802',
    'test_initial_assignment'
  )$$,
  '42501',
  'billing owner change requires fresh step-up authentication',
  'Billing Owner changes require a fresh elevated session'
);
select throws_ok(
  $$select commercial.set_billing_owner(
    '00000000-0000-0000-0000-000000000801',
    'a0000000-0000-4000-8000-000000000801',
    '10000000-0000-0000-0000-000000000801',
    '30000000-0000-0000-0000-000000000805',
    'test_invalid_target'
  )$$,
  '23514',
  'billing owner must have an active tenant membership and account',
  'Billing Owner must be an active member with an active account'
);

select isnt(
  commercial.set_billing_owner(
    '00000000-0000-0000-0000-000000000801',
    'a0000000-0000-4000-8000-000000000801',
    '10000000-0000-0000-0000-000000000801',
    '30000000-0000-0000-0000-000000000802',
    'test_initial_assignment'
  ),
  null::uuid,
  'an authorized stepped-up actor can assign a Billing Owner'
);
select isnt(
  commercial.set_billing_owner(
    '00000000-0000-0000-0000-000000000801',
    'a0000000-0000-4000-8000-000000000801',
    '10000000-0000-0000-0000-000000000801',
    '30000000-0000-0000-0000-000000000801',
    'test_owner_change'
  ),
  null::uuid,
  'Billing Owner can be changed independently of organizational role'
);
select is(
  (select count(*) from commercial.billing_owner_assignments
    where tenant_id = '10000000-0000-0000-0000-000000000801'
      and ended_at is null),
  1::bigint,
  'only one current Billing Owner exists per tenant'
);
select is(
  (select count(*) from commercial.billing_owner_assignments
    where tenant_id = '10000000-0000-0000-0000-000000000801'),
  2::bigint,
  'Billing Owner history is preserved'
);
select is(
  (select count(*) from authz.security_audit_events
    where tenant_id = '10000000-0000-0000-0000-000000000801'
      and event_type = 'billing_owner_changed'),
  2::bigint,
  'every effective Billing Owner change is security-audited'
);

select throws_ok(
  $$update commercial.plans
       set display_name = 'Rewritten'
     where id = 'c0000000-0000-4000-8000-000000000001'$$,
  '55000',
  'commercial.plans is immutable',
  'versioned plan identities cannot be rewritten'
);
select throws_ok(
  $$delete from commercial.subscription_status_events
     where subscription_id = 'c2000000-0000-4000-8000-000000000801'$$,
  '55000',
  'commercial.subscription_status_events is immutable',
  'subscription status history is append-only'
);
select throws_ok(
  $$update commercial.tenant_subscriptions
       set plan_version_id = 'c1000000-0000-4000-8000-000000000001'
     where id = 'c2000000-0000-4000-8000-000000000801'$$,
  '55000',
  'tenant subscription identity and plan history are immutable',
  'plan changes require a new subscription history record'
);

select ok(
  not has_schema_privilege('authenticated', 'commercial', 'usage')
  and not has_table_privilege(
    'authenticated', 'commercial.tenant_subscriptions', 'select'
  )
  and not has_table_privilege(
    'service_role', 'commercial.billing_owner_assignments', 'insert'
  ),
  'clients and service role have no direct commercial-table access'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'commercial.set_billing_owner(uuid,uuid,uuid,uuid,text)',
    'execute'
  )
  and not has_function_privilege(
    'service_role',
    'commercial.assert_seat_capacity(uuid,uuid,timestamptz)',
    'execute'
  )
  and not has_function_privilege(
    'service_role',
    'authz.authorize_without_commercial_restriction(uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,uuid,text,numeric)',
    'execute'
  ),
  'commercial commands and resolver core are not direct client or service-role endpoints'
);
select is(
  (
    select count(*)
      from pg_class relation
      join pg_namespace namespace on namespace.oid = relation.relnamespace
     where namespace.nspname = 'commercial'
       and relation.relname in (
         'plans', 'plan_versions', 'extra_catalog', 'tenant_subscriptions',
         'subscription_status_events', 'billing_owner_assignments',
         'tenant_extra_entitlements'
       )
       and relation.relrowsecurity
       and relation.relforcerowsecurity
  ),
  7::bigint,
  'every commercial table has RLS enabled and forced'
);
select is(
  (
    select count(*)
      from pg_policy policy
      join pg_class relation on relation.oid = policy.polrelid
      join pg_namespace namespace on namespace.oid = relation.relnamespace
     where namespace.nspname = 'commercial'
       and relation.relname in (
         'plans', 'plan_versions', 'extra_catalog', 'tenant_subscriptions',
         'subscription_status_events', 'billing_owner_assignments',
         'tenant_extra_entitlements'
       )
       and not policy.polpermissive
       and pg_get_expr(policy.polqual, policy.polrelid) = 'false'
       and pg_get_expr(policy.polwithcheck, policy.polrelid) = 'false'
  ),
  7::bigint,
  'every commercial table has a restrictive deny policy'
);
select ok(
  pg_get_functiondef(
    'commercial.assert_seat_capacity(uuid,uuid,timestamptz)'::regprocedure
  ) ilike '%pg_advisory_xact_lock%',
  'seat-capacity enforcement serializes changes per tenant'
);
select is(
  (
    select count(*)
      from pg_index index_definition
      join pg_class index_relation
        on index_relation.oid = index_definition.indexrelid
      join pg_namespace namespace
        on namespace.oid = index_relation.relnamespace
     where namespace.nspname = 'commercial'
       and index_relation.relname in (
         'tenant_subscriptions_plan_version_id',
         'tenant_subscriptions_status_changed_by_user_id',
         'tenant_subscriptions_created_by_user_id',
         'subscription_status_events_tenant_subscription',
         'subscription_status_events_actor_user_id',
         'billing_owner_assignments_tenant_membership',
         'billing_owner_assignments_owner_user_id',
         'billing_owner_assignments_assigned_by_user_id',
         'billing_owner_assignments_ended_by_user_id'
       )
  ),
  9::bigint,
  'commercial foreign keys have covering indexes'
);

do $$
begin
  if commercial.count_billable_users(
       '10000000-0000-0000-0000-000000000801'
     ) <> 4
     or (select count(*) from commercial.billing_owner_assignments
          where tenant_id = '10000000-0000-0000-0000-000000000801'
            and ended_at is null) <> 1
     or (select count(*) from authz.security_audit_events
          where tenant_id = '10000000-0000-0000-0000-000000000801'
            and event_type = 'billing_owner_changed') <> 2
     or commercial.is_tenant_commercially_restricted(
          '10000000-0000-0000-0000-000000000801'
        )
     or has_table_privilege(
       'authenticated', 'commercial.tenant_subscriptions', 'select'
     )
     or has_function_privilege(
       'service_role',
       'commercial.assert_seat_capacity(uuid,uuid,timestamptz)',
       'execute'
     ) then
    raise exception using
      errcode = 'P0001',
      message = 'commercial subscription aggregate acceptance guard failed';
  end if;
end;
$$;

select * from finish();
rollback;
