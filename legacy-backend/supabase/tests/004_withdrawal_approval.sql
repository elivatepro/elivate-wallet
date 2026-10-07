begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select no_plan();

insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
values
  ('00000000-0000-0000-0000-000000000301', 'authenticated', 'authenticated', 'withdrawal-approver@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000302', 'authenticated', 'authenticated', 'withdrawal-owner@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000303', 'authenticated', 'authenticated', 'withdrawal-world@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000304', 'authenticated', 'authenticated', 'withdrawal-outscope@example.test', '{}'::jsonb, '{}'::jsonb)
on conflict (id) do nothing;

insert into public.user_accounts (user_id)
values
  ('00000000-0000-0000-0000-000000000301'),
  ('00000000-0000-0000-0000-000000000302'),
  ('00000000-0000-0000-0000-000000000303'),
  ('00000000-0000-0000-0000-000000000304');

insert into public.tenants (id, name)
values ('10000000-0000-0000-0000-000000000301', 'Withdrawal Tenant');

insert into public.offices (id, tenant_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000301',
  '10000000-0000-0000-0000-000000000301',
  'world_team',
  'Withdrawal World Team'
);

insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values
  (
    '20000000-0000-0000-0000-000000000302',
    '10000000-0000-0000-0000-000000000301',
    '20000000-0000-0000-0000-000000000301',
    'director',
    'Withdrawal Director One'
  ),
  (
    '20000000-0000-0000-0000-000000000304',
    '10000000-0000-0000-0000-000000000301',
    '20000000-0000-0000-0000-000000000301',
    'director',
    'Withdrawal Director Two'
  );

insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values
  (
    '20000000-0000-0000-0000-000000000303',
    '10000000-0000-0000-0000-000000000301',
    '20000000-0000-0000-0000-000000000302',
    'team_leader',
    'Withdrawal Team One'
  ),
  (
    '20000000-0000-0000-0000-000000000305',
    '10000000-0000-0000-0000-000000000301',
    '20000000-0000-0000-0000-000000000304',
    'team_leader',
    'Withdrawal Team Two'
  );

insert into public.memberships (
  id, tenant_id, user_id, office_id, role_key, is_primary
)
values
  (
    '30000000-0000-0000-0000-000000000301',
    '10000000-0000-0000-0000-000000000301',
    '00000000-0000-0000-0000-000000000301',
    '20000000-0000-0000-0000-000000000303',
    'team_leader',
    true
  ),
  (
    '30000000-0000-0000-0000-000000000302',
    '10000000-0000-0000-0000-000000000301',
    '00000000-0000-0000-0000-000000000302',
    '20000000-0000-0000-0000-000000000303',
    'member',
    true
  ),
  (
    '30000000-0000-0000-0000-000000000303',
    '10000000-0000-0000-0000-000000000301',
    '00000000-0000-0000-0000-000000000303',
    '20000000-0000-0000-0000-000000000301',
    'world_team_member',
    true
  ),
  (
    '30000000-0000-0000-0000-000000000304',
    '10000000-0000-0000-0000-000000000301',
    '00000000-0000-0000-0000-000000000304',
    '20000000-0000-0000-0000-000000000305',
    'team_leader',
    true
  );

select authz.seed_tenant_role_permissions(
  '10000000-0000-0000-0000-000000000301'
);

insert into public.wallets (id, owner_user_id)
values (
  '60000000-0000-0000-0000-000000000302',
  '00000000-0000-0000-0000-000000000302'
);

insert into public.pocket_definitions (
  pocket_key, display_name, sort_order
)
values ('withdrawal_test', 'Withdrawal Test', 400);

insert into ledger.currency_definitions (currency_code, minor_unit_scale)
values ('NGN', 2);

insert into ledger.ledger_accounts (
  id, account_class, currency_code, wallet_id, tenant_id, office_id,
  membership_id, owner_user_id, pocket_key
)
values
  (
    '83000000-0000-0000-0000-000000000301',
    'member_value',
    'NGN',
    '60000000-0000-0000-0000-000000000302',
    '10000000-0000-0000-0000-000000000301',
    '20000000-0000-0000-0000-000000000303',
    '30000000-0000-0000-0000-000000000302',
    '00000000-0000-0000-0000-000000000302',
    'withdrawal_test'
  ),
  (
    '83000000-0000-0000-0000-000000000302',
    'member_value',
    'NGN',
    '60000000-0000-0000-0000-000000000302',
    '10000000-0000-0000-0000-000000000301',
    '20000000-0000-0000-0000-000000000303',
    '30000000-0000-0000-0000-000000000302',
    '00000000-0000-0000-0000-000000000302',
    'debt'
  );

insert into ledger.ledger_accounts (
  id, account_class, currency_code, system_account_key
)
values (
  '84000000-0000-0000-0000-000000000301',
  'system_counter',
  'NGN',
  'withdrawal_test_inflow'
);

select ledger.post_transaction(
  '90000000-0000-0000-0000-000000000301',
  extensions.digest('withdrawal-opening-balance', 'sha256'),
  'withdrawal_test_opening_balance',
  '30000000-0000-0000-0000-000000000302',
  '60000000-0000-0000-0000-000000000302',
  '00000000-0000-0000-0000-000000000303',
  jsonb_build_array(
    jsonb_build_object(
      'currency_code', 'NGN',
      'postings', jsonb_build_array(
        jsonb_build_object(
          'ledger_account_id', '84000000-0000-0000-0000-000000000301',
          'amount', '-500.00'
        ),
        jsonb_build_object(
          'ledger_account_id', '83000000-0000-0000-0000-000000000301',
          'amount', '500.00'
        )
      )
    )
  )
);

insert into financial_ops.payout_accounts (
  id, wallet_id, owner_user_id, country_code, payout_currency, payout_rail,
  institution_code, institution_name, account_reference, account_holder_name,
  verification_status, verification_method, verified_at, is_primary, created_at
)
values (
  '85000000-0000-0000-0000-000000000301',
  '60000000-0000-0000-0000-000000000302',
  '00000000-0000-0000-0000-000000000302',
  'NG',
  'NGN',
  'bank_transfer',
  '999',
  'Test Bank',
  '0123456789',
  'Withdrawal Owner',
  'verified',
  'manual_test_verification',
  statement_timestamp(),
  true,
  statement_timestamp()
);

select is(
  (
    financial_ops.submit_withdrawal(
      '91000000-0000-0000-0000-000000000301',
      '83000000-0000-0000-0000-000000000301',
      '85000000-0000-0000-0000-000000000301',
      100.00,
      '00000000-0000-0000-0000-000000000302'
    )
  ).status,
  'requested'::financial_ops.withdrawal_status,
  'Wallet holder can submit an explicit single-segment withdrawal'
);

select ok(
  exists (
    select 1
      from financial_ops.withdrawal_requests withdrawal
      join financial_ops.withdrawal_destination_snapshots snapshot
        on snapshot.withdrawal_id = withdrawal.id
      join financial_ops.funding_reservations reservation
        on reservation.withdrawal_id = withdrawal.id
     where withdrawal.withdrawal_reference ~ '^WR-[A-F0-9]{16}$'
       and withdrawal.tenant_id = '10000000-0000-0000-0000-000000000301'
       and withdrawal.office_id = '20000000-0000-0000-0000-000000000303'
       and withdrawal.membership_id = '30000000-0000-0000-0000-000000000302'
       and withdrawal.wallet_id = '60000000-0000-0000-0000-000000000302'
       and withdrawal.source_pocket_key = 'withdrawal_test'
       and withdrawal.source_currency_code = 'NGN'
       and withdrawal.requested_amount = 100.00
       and snapshot.account_reference = '0123456789'
       and snapshot.institution_name = 'Test Bank'
       and snapshot.verification_status = 'verified'
       and reservation.ledger_account_id = withdrawal.source_ledger_account_id
       and reservation.amount = withdrawal.requested_amount
       and reservation.status = 'active'
  ),
  'submission atomically preserves provenance, destination snapshot, and reservation'
);

select is(
  financial_ops.available_balance(
    '83000000-0000-0000-0000-000000000301'
  ),
  400.000000000000000000::numeric,
  'active reservation reduces available balance'
);

select is(
  (
    select balance
      from ledger.wallet_balance_projections
     where ledger_account_id = '83000000-0000-0000-0000-000000000301'
  ),
  500.000000000000000000::numeric,
  'withdrawal request does not reduce posted ledger balance'
);

select is(
  (
    financial_ops.submit_withdrawal(
      '91000000-0000-0000-0000-000000000301',
      '83000000-0000-0000-0000-000000000301',
      '85000000-0000-0000-0000-000000000301',
      100.00,
      '00000000-0000-0000-0000-000000000302'
    )
  ).reused,
  true,
  'same withdrawal submission idempotency key reuses the original result'
);

select is(
  (
    select count(*)
      from financial_ops.withdrawal_requests withdrawal
      join financial_ops.withdrawal_command_idempotency command
        on command.withdrawal_id = withdrawal.id
     where command.idempotency_key = '91000000-0000-0000-0000-000000000301'
  ),
  1::bigint,
  'idempotent retry creates no duplicate withdrawal'
);

select throws_ok(
  $$select financial_ops.submit_withdrawal(
      '91000000-0000-0000-0000-000000000301',
      '83000000-0000-0000-0000-000000000301',
      '85000000-0000-0000-0000-000000000301',
      101.00,
      '00000000-0000-0000-0000-000000000302'
    )$$,
  '23505',
  'idempotency key already used with different withdrawal command data',
  'conflicting withdrawal idempotency reuse is rejected'
);

select throws_ok(
  $$select financial_ops.submit_withdrawal(
      '91000000-0000-0000-0000-000000000302',
      '83000000-0000-0000-0000-000000000301',
      '85000000-0000-0000-0000-000000000301',
      401.00,
      '00000000-0000-0000-0000-000000000302'
    )$$,
  '23514',
  'insufficient available balance for withdrawal reservation',
  'concurrent-safe availability excludes existing active reservations'
);

select throws_ok(
  $$select financial_ops.submit_withdrawal(
      '91000000-0000-0000-0000-000000000303',
      '83000000-0000-0000-0000-000000000301',
      '85000000-0000-0000-0000-000000000301',
      0.001,
      '00000000-0000-0000-0000-000000000302'
    )$$,
  '22003',
  'withdrawal amount exceeds the currency minor-unit scale',
  'withdrawal amount obeys the source currency scale'
);

select throws_ok(
  $$select financial_ops.submit_withdrawal(
      '91000000-0000-0000-0000-000000000304',
      '83000000-0000-0000-0000-000000000302',
      '85000000-0000-0000-0000-000000000301',
      1.00,
      '00000000-0000-0000-0000-000000000302'
    )$$,
  '23514',
  'selected pocket does not allow withdrawal funding',
  'Debt pocket cannot fund a withdrawal'
);

select throws_ok(
  $$select financial_ops.approve_withdrawal(
      '92000000-0000-0000-0000-000000000301',
      (
        select command.withdrawal_id
          from financial_ops.withdrawal_command_idempotency command
         where command.idempotency_key = '91000000-0000-0000-0000-000000000301'
      ),
      '00000000-0000-0000-0000-000000000304'
    )$$,
  '42501',
  'withdrawal command is not authorized',
  'approver outside the stored office scope cannot approve'
);

select is(
  (
    financial_ops.approve_withdrawal(
      '92000000-0000-0000-0000-000000000302',
      (
        select command.withdrawal_id
          from financial_ops.withdrawal_command_idempotency command
         where command.idempotency_key = '91000000-0000-0000-0000-000000000301'
      ),
      '00000000-0000-0000-0000-000000000301'
    )
  ).status,
  'approved'::financial_ops.withdrawal_status,
  'in-scope approve_withdrawal authority approves the request'
);

select is(
  (
    financial_ops.approve_withdrawal(
      '92000000-0000-0000-0000-000000000302',
      (
        select command.withdrawal_id
          from financial_ops.withdrawal_command_idempotency command
         where command.idempotency_key = '91000000-0000-0000-0000-000000000301'
      ),
      '00000000-0000-0000-0000-000000000301'
    )
  ).reused,
  true,
  'withdrawal approval is idempotent'
);

select ok(
  exists (
    select 1
      from financial_ops.withdrawal_requests withdrawal
      join financial_ops.funding_reservations reservation
        on reservation.withdrawal_id = withdrawal.id
     where withdrawal.id = (
       select command.withdrawal_id
         from financial_ops.withdrawal_command_idempotency command
        where command.idempotency_key = '91000000-0000-0000-0000-000000000301'
     )
       and withdrawal.status = 'approved'
       and withdrawal.approved_by_user_id = '00000000-0000-0000-0000-000000000301'
       and withdrawal.version = 1
       and reservation.status = 'active'
  ),
  'approval preserves the active reservation and records the approving actor'
);

select is(
  (
    select count(*)
      from ledger.financial_transactions
  ),
  1::bigint,
  'approval creates no final Withdrawal ledger transaction'
);

select throws_ok(
  $$select financial_ops.cancel_withdrawal(
      '93000000-0000-0000-0000-000000000301',
      (
        select command.withdrawal_id
          from financial_ops.withdrawal_command_idempotency command
         where command.idempotency_key = '91000000-0000-0000-0000-000000000301'
      ),
      '00000000-0000-0000-0000-000000000302',
      'Owner cannot cancel an approved payout workflow'
    )$$,
  '42501',
  'withdrawal command is not authorized',
  'leadership approval authority cannot target the actor own Wallet'
);

select is(
  (
    financial_ops.cancel_withdrawal(
      '93000000-0000-0000-0000-000000000302',
      (
        select command.withdrawal_id
          from financial_ops.withdrawal_command_idempotency command
         where command.idempotency_key = '91000000-0000-0000-0000-000000000301'
      ),
      '00000000-0000-0000-0000-000000000301',
      'External payout did not occur'
    )
  ).status,
  'cancelled'::financial_ops.withdrawal_status,
  'authorized actor can cancel an approved unpaid withdrawal'
);

select is(
  financial_ops.available_balance(
    '83000000-0000-0000-0000-000000000301'
  ),
  500.000000000000000000::numeric,
  'approved-withdrawal cancellation releases its reservation'
);

select is(
  (
    financial_ops.submit_withdrawal(
      '91000000-0000-0000-0000-000000000305',
      '83000000-0000-0000-0000-000000000301',
      '85000000-0000-0000-0000-000000000301',
      60.00,
      '00000000-0000-0000-0000-000000000303'
    )
  ).status,
  'requested'::financial_ops.withdrawal_status,
  'authorized world-team actor can initiate a withdrawal on behalf'
);

select is(
  (
    financial_ops.approve_withdrawal(
      '92000000-0000-0000-0000-000000000305',
      (
        select command.withdrawal_id
          from financial_ops.withdrawal_command_idempotency command
         where command.idempotency_key = '91000000-0000-0000-0000-000000000305'
      ),
      '00000000-0000-0000-0000-000000000303'
    )
  ).status,
  'approved'::financial_ops.withdrawal_status,
  'same authorized actor may initiate and approve an on-behalf withdrawal'
);

select is(
  financial_ops.available_balance(
    '83000000-0000-0000-0000-000000000301'
  ),
  440.000000000000000000::numeric,
  'approved request remains reserved without changing posted balance'
);

select financial_ops.submit_withdrawal(
  '91000000-0000-0000-0000-000000000306',
  '83000000-0000-0000-0000-000000000301',
  '85000000-0000-0000-0000-000000000301',
  70.00,
  '00000000-0000-0000-0000-000000000302'
);

select is(
  (
    financial_ops.reject_withdrawal(
      '94000000-0000-0000-0000-000000000306',
      (
        select command.withdrawal_id
          from financial_ops.withdrawal_command_idempotency command
         where command.idempotency_key = '91000000-0000-0000-0000-000000000306'
      ),
      '00000000-0000-0000-0000-000000000301',
      'Request is not eligible'
    )
  ).status,
  'rejected'::financial_ops.withdrawal_status,
  'authorized rejection closes the request'
);

select is(
  financial_ops.available_balance(
    '83000000-0000-0000-0000-000000000301'
  ),
  440.000000000000000000::numeric,
  'rejection releases only its own reservation'
);

select financial_ops.submit_withdrawal(
  '91000000-0000-0000-0000-000000000307',
  '83000000-0000-0000-0000-000000000301',
  '85000000-0000-0000-0000-000000000301',
  80.00,
  '00000000-0000-0000-0000-000000000302'
);

select is(
  (
    financial_ops.cancel_withdrawal(
      '93000000-0000-0000-0000-000000000307',
      (
        select command.withdrawal_id
          from financial_ops.withdrawal_command_idempotency command
         where command.idempotency_key = '91000000-0000-0000-0000-000000000307'
      ),
      '00000000-0000-0000-0000-000000000302',
      'Member changed their mind'
    )
  ).status,
  'cancelled'::financial_ops.withdrawal_status,
  'Wallet holder may cancel their own requested withdrawal'
);

select is(
  financial_ops.available_balance(
    '83000000-0000-0000-0000-000000000301'
  ),
  440.000000000000000000::numeric,
  'member cancellation releases its reservation'
);

select financial_ops.submit_withdrawal(
  '91000000-0000-0000-0000-000000000308',
  '83000000-0000-0000-0000-000000000301',
  '85000000-0000-0000-0000-000000000301',
  10.00,
  '00000000-0000-0000-0000-000000000302'
);

update public.memberships
   set status = 'suspended'
 where id = '30000000-0000-0000-0000-000000000302';

select throws_ok(
  $$select financial_ops.approve_withdrawal(
      '92000000-0000-0000-0000-000000000308',
      (
        select command.withdrawal_id
          from financial_ops.withdrawal_command_idempotency command
         where command.idempotency_key = '91000000-0000-0000-0000-000000000308'
      ),
      '00000000-0000-0000-0000-000000000301'
    )$$,
  '23514',
  'withdrawal approval requires active owner and membership context',
  'suspended target membership cannot be approved'
);

update public.memberships
   set status = 'active'
 where id = '30000000-0000-0000-0000-000000000302';

select throws_ok(
  $$update financial_ops.withdrawal_requests
       set status = 'approved', version = version + 1
     where id = (
       select command.withdrawal_id
         from financial_ops.withdrawal_command_idempotency command
        where command.idempotency_key = '91000000-0000-0000-0000-000000000308'
     )$$,
  '55000',
  'withdrawal lifecycle may only change through a trusted command',
  'withdrawal state cannot be mutated directly'
);

select throws_ok(
  $$update financial_ops.withdrawal_destination_snapshots
       set account_reference = 'tampered'
     where withdrawal_id = (
       select command.withdrawal_id
         from financial_ops.withdrawal_command_idempotency command
        where command.idempotency_key = '91000000-0000-0000-0000-000000000308'
     )$$,
  '55000',
  'financial_ops.withdrawal_destination_snapshots is immutable',
  'withdrawal destination snapshot is immutable'
);

select throws_ok(
  $$insert into financial_ops.payout_accounts (
      wallet_id, owner_user_id, country_code, payout_currency, payout_rail,
      institution_code, institution_name, account_reference,
      account_holder_name, verification_status, verification_method,
      verified_at, created_at
    ) values (
      '60000000-0000-0000-0000-000000000302',
      '00000000-0000-0000-0000-000000000304',
      'NG', 'NGN', 'bank_transfer', '998', 'Wrong Owner Bank',
      '0000000000', 'Wrong Owner', 'verified', 'manual_test_verification',
      statement_timestamp(), statement_timestamp()
    )$$,
  '23514',
  'payout account must match an active Wallet owner',
  'payout destination ownership derives from the Wallet'
);

select ok(
  exists (
    select 1
      from authz.security_audit_events event
     where event.event_type = 'withdrawal_approved'
       and event.target_type = 'withdrawal'
       and event.permission_key = 'approve_withdrawal'
       and event.allowed
  ),
  'successful withdrawal authorization is auditable'
);

select ok(
  not has_schema_privilege('authenticated', 'financial_ops', 'usage'),
  'authenticated role has no usage on the private financial operations schema'
);

select ok(
  not has_table_privilege(
    'service_role',
    'financial_ops.withdrawal_requests',
    'select'
  ),
  'service role has no direct withdrawal table access'
);

select ok(
  not has_function_privilege(
    'service_role',
    'financial_ops.approve_withdrawal(uuid,uuid,uuid,uuid)',
    'execute'
  ),
  'service role cannot bypass authorization through the approval command'
);

select is(
  (
    select count(*)
      from pg_class relation
      join pg_namespace namespace on namespace.oid = relation.relnamespace
     where namespace.nspname = 'financial_ops'
       and relation.relkind = 'r'
       and relation.relrowsecurity
       and relation.relforcerowsecurity
  ),
  (
    select count(*)
      from pg_class relation
      join pg_namespace namespace on namespace.oid = relation.relnamespace
     where namespace.nspname = 'financial_ops'
       and relation.relkind = 'r'
  ),
  'every private financial operations table has RLS enabled and forced'
);

select is(
  (
    select count(*)
      from pg_policy policy
      join pg_class relation on relation.oid = policy.polrelid
      join pg_namespace namespace on namespace.oid = relation.relnamespace
     where namespace.nspname = 'financial_ops'
       and not policy.polpermissive
       and pg_get_expr(policy.polqual, policy.polrelid) = 'false'
       and pg_get_expr(policy.polwithcheck, policy.polrelid) = 'false'
  ),
  (
    select count(*)
      from pg_class relation
      join pg_namespace namespace on namespace.oid = relation.relnamespace
     where namespace.nspname = 'financial_ops'
       and relation.relkind = 'r'
  ),
  'every private financial operations table has an explicit restrictive deny policy'
);

-- The same successful request remains actor-bound but is not an authorization cache.
select set_config('test.replay_withdrawal', (select withdrawal_id::text from financial_ops.withdrawal_command_idempotency where idempotency_key='91000000-0000-0000-0000-000000000301'), true);
set local role service_role;
select is((command_api.approve_withdrawal('92000000-0000-0000-0000-000000000302', current_setting('test.replay_withdrawal')::uuid, '00000000-0000-0000-0000-000000000301')).reused, true, 'service transport permits authorized approval retry after cancellation');
select is((command_api.cancel_withdrawal('93000000-0000-0000-0000-000000000302', current_setting('test.replay_withdrawal')::uuid, '00000000-0000-0000-0000-000000000301', 'External payout did not occur')).reused, true, 'approved cancellation retry retains original authority path');
reset role;
update public.memberships set status='suspended' where id='30000000-0000-0000-0000-000000000301';
set local role service_role;
select throws_ok($$select command_api.approve_withdrawal('92000000-0000-0000-0000-000000000302', current_setting('test.replay_withdrawal')::uuid, '00000000-0000-0000-0000-000000000301')$$, '42501', null, 'suspended leadership cannot replay approval');
select throws_ok($$select command_api.cancel_withdrawal('93000000-0000-0000-0000-000000000302', current_setting('test.replay_withdrawal')::uuid, '00000000-0000-0000-0000-000000000301', 'External payout did not occur')$$, '42501', null, 'suspended leadership cannot replay approved cancellation');
reset role;
update public.memberships set status='active' where id='30000000-0000-0000-0000-000000000301';
update public.user_accounts set status='suspended' where user_id='00000000-0000-0000-0000-000000000302';
set local role service_role;
select throws_ok($$select command_api.submit_withdrawal('91000000-0000-0000-0000-000000000301','83000000-0000-0000-0000-000000000301','85000000-0000-0000-0000-000000000301',100.00,'00000000-0000-0000-0000-000000000302')$$, '42501', null, 'suspended Wallet owner cannot replay submission');
reset role;
update public.user_accounts set status='active' where user_id='00000000-0000-0000-0000-000000000302';
select is((select count(*) from ledger.financial_transactions),1::bigint,'authorized and rejected replays leave ledger entries unchanged');

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000302',
  true
);

select throws_ok(
  $$select count(*) from financial_ops.withdrawal_requests$$,
  '42501',
  null,
  'authenticated clients cannot read private withdrawal data directly'
);

select throws_ok(
  $$select financial_ops.approve_withdrawal(
      '92000000-0000-0000-0000-000000000399',
      '95000000-0000-0000-0000-000000000399',
      '00000000-0000-0000-0000-000000000302'
    )$$,
  '42501',
  null,
  'authenticated clients cannot execute the private approval command'
);

reset role;

select finish();
rollback;
