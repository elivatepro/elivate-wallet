begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(20);

insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
values (
  '00000000-0000-0000-0000-000000000601',
  'authenticated',
  'authenticated',
  'member-home-owner@example.test',
  '{}'::jsonb,
  '{}'::jsonb
);

insert into public.user_accounts (user_id)
values ('00000000-0000-0000-0000-000000000601');

insert into public.tenants (id, name)
values ('10000000-0000-0000-0000-000000000601', 'Member Home Tenant');

insert into public.offices (id, tenant_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000601',
  '10000000-0000-0000-0000-000000000601',
  'world_team',
  'Member Home World Team'
);

insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000603',
  '10000000-0000-0000-0000-000000000601',
  '20000000-0000-0000-0000-000000000601',
  'director',
  'Member Home Director'
);

insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000602',
  '10000000-0000-0000-0000-000000000601',
  '20000000-0000-0000-0000-000000000603',
  'team_leader',
  'Member Home Office'
);

insert into public.memberships (id, tenant_id, user_id, office_id, role_key, is_primary)
values (
  '30000000-0000-0000-0000-000000000601',
  '10000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000601',
  '20000000-0000-0000-0000-000000000602',
  'member',
  true
);

insert into public.wallets (id, owner_user_id)
values (
  '60000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000601'
);

insert into public.pocket_definitions (pocket_key, display_name, sort_order)
values ('member_home_test', 'Member Home Test', 601);

insert into ledger.currency_definitions (currency_code, minor_unit_scale)
values ('NGN', 2);

insert into ledger.ledger_accounts (
  id, account_class, currency_code, wallet_id, tenant_id, office_id,
  membership_id, owner_user_id, pocket_key
)
values (
  '81000000-0000-0000-0000-000000000601',
  'member_value',
  'NGN',
  '60000000-0000-0000-0000-000000000601',
  '10000000-0000-0000-0000-000000000601',
  '20000000-0000-0000-0000-000000000602',
  '30000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000601',
  'member_home_test'
);

insert into ledger.ledger_accounts (id, account_class, currency_code, system_account_key)
values (
  '82000000-0000-0000-0000-000000000601',
  'system_counter',
  'NGN',
  'member_home_external'
);

insert into financial_ops.payout_accounts (
  id, wallet_id, owner_user_id, country_code, payout_currency, payout_rail,
  institution_code, institution_name, account_reference, account_holder_name,
  verification_status, verification_method, verified_at, is_primary, created_at
)
values (
  '70000000-0000-0000-0000-000000000601',
  '60000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000601',
  'NG', 'NGN', 'bank_transfer', 'TEST001', 'Member Home Bank',
  '0123456789', 'Member Home Owner', 'verified', 'manual_fixture',
  '2026-09-20 10:00:01+00', true, '2026-09-20 10:00:00+00'
);

select ledger.post_transaction(
  '90000000-0000-0000-0000-000000000601',
  extensions.digest('member-home-income', 'sha256'),
  'member_home_income',
  '30000000-0000-0000-0000-000000000601',
  '60000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000601',
  jsonb_build_array(jsonb_build_object(
    'currency_code', 'NGN',
    'postings', jsonb_build_array(
      jsonb_build_object(
        'ledger_account_id', '82000000-0000-0000-0000-000000000601',
        'amount', '-250.00'
      ),
      jsonb_build_object(
        'ledger_account_id', '81000000-0000-0000-0000-000000000601',
        'amount', '250.00'
      )
    )
  ))
);

insert into financial_ops.withdrawal_requests (
  id, tenant_id, office_id, membership_id, wallet_id, owner_user_id,
  source_ledger_account_id, source_currency_code, source_pocket_key,
  requested_amount, payout_account_id, initiated_by_user_id,
  status, created_at, updated_at
)
values (
  '71000000-0000-0000-0000-000000000601',
  '10000000-0000-0000-0000-000000000601',
  '20000000-0000-0000-0000-000000000602',
  '30000000-0000-0000-0000-000000000601',
  '60000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000601',
  '81000000-0000-0000-0000-000000000601',
  'NGN', 'member_home_test', 100,
  '70000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000601',
  'requested', '2026-09-20 11:00:00+00', '2026-09-20 11:00:00+00'
);

insert into financial_ops.withdrawal_destination_snapshots (
  withdrawal_id, source_payout_account_id, institution_code, institution_name,
  account_reference, account_holder_name, payout_rail, payout_currency,
  country_code, verification_status, verification_method, snapshotted_at
)
values (
  '71000000-0000-0000-0000-000000000601',
  '70000000-0000-0000-0000-000000000601',
  'TEST001', 'Member Home Bank', '0123456789', 'Member Home Owner',
  'bank_transfer', 'NGN', 'NG', 'verified', 'manual_fixture',
  '2026-09-20 11:00:01+00'
);

select extensions.is(
  has_function_privilege('service_role', 'read_api.member_home(uuid)', 'EXECUTE'),
  true,
  'member home read model is callable only by trusted transport'
);

select extensions.isnt(
  has_function_privilege('authenticated', 'read_api.member_home(uuid)', 'EXECUTE'),
  true,
  'authenticated clients cannot call the private member home function directly'
);

set local role service_role;

select extensions.is(
  (read_api.member_home('00000000-0000-0000-0000-000000000601')->'wallets'->0->'currencies'->0->>'currency_code'),
  'NGN',
  'member home exposes the wallet currency'
);

select extensions.is(
  ((read_api.member_home('00000000-0000-0000-0000-000000000601')->'wallets'->0->'currencies'->0->>'posted_balance')::numeric),
  250.000000000000000000::numeric,
  'member home derives posted balance from the ledger projection'
);

select extensions.is(
  ((read_api.member_home('00000000-0000-0000-0000-000000000601')->'recent_activity'->0->>'signed_amount')::numeric),
  250.000000000000000000::numeric,
  'member home includes signed recent activity from journal postings'
);

select extensions.is(
  jsonb_array_length(read_api.member_home('00000000-0000-0000-0000-000000000601')->'recent_withdrawals'),
  1,
  'member home includes withdrawal history from persisted requests'
);

select extensions.is(
  (select relation.relforcerowsecurity
     from pg_class relation
     join pg_namespace namespace on namespace.oid = relation.relnamespace
    where namespace.nspname = 'ledger'
      and relation.relname = 'ledger_accounts'),
  true,
  'private ledger remains forced-RLS protected behind the read model'
);

select extensions.is(
  has_function_privilege(
    'service_role',
    'read_api.member_activity(uuid,timestamptz,uuid,integer,text,text,text)',
    'EXECUTE'
  ),
  true,
  'member activity read model is callable only by trusted transport'
);

select extensions.isnt(
  has_function_privilege(
    'authenticated',
    'read_api.member_activity(uuid,timestamptz,uuid,integer,text,text,text)',
    'EXECUTE'
  ),
  true,
  'authenticated clients cannot call the private member activity function directly'
);

select extensions.is(
  jsonb_array_length(read_api.member_activity(
    '00000000-0000-0000-0000-000000000601', null, null, 10, null, null, null
  )->'items'),
  1,
  'member activity returns the posted owner activity page'
);

select extensions.is(
  ((read_api.member_activity(
    '00000000-0000-0000-0000-000000000601', null, null, 10, null, null, null
  )->'items'->0->>'signed_amount')::numeric),
  250.000000000000000000::numeric,
  'member activity derives signed amount from owner postings'
);

select extensions.is(
  read_api.member_activity(
    '00000000-0000-0000-0000-000000000601', null, null, 10, null, null, null
  )->>'next_cursor',
  null,
  'member activity omits the cursor when the page is complete'
);

select extensions.is(
  has_function_privilege('service_role', 'read_api.member_payout_accounts(uuid)', 'EXECUTE'),
  true,
  'member payout account read model is callable only by trusted transport'
);

select extensions.is(
  (read_api.member_payout_accounts('00000000-0000-0000-0000-000000000601')->'items'->0->>'account_reference_masked'),
  '******6789',
  'member payout account read model masks the full account reference'
);

select extensions.is(
  (read_api.member_payout_accounts('00000000-0000-0000-0000-000000000601')->'items'->0 ? 'account_reference'),
  false,
  'member payout account read model does not expose the full account reference'
);

select extensions.is(
  has_function_privilege('service_role', 'read_api.member_withdrawals(uuid,timestamptz,uuid,integer,text)', 'EXECUTE'),
  true,
  'member withdrawal read model is callable only by trusted transport'
);

select extensions.isnt(
  has_function_privilege('authenticated', 'read_api.member_withdrawals(uuid,timestamptz,uuid,integer,text)', 'EXECUTE'),
  true,
  'authenticated clients cannot call the private member withdrawal function directly'
);

select extensions.is(
  jsonb_array_length(read_api.member_withdrawals(
    '00000000-0000-0000-0000-000000000601', null, null, 10, null
  )->'items'),
  1,
  'member withdrawals returns the owner withdrawal history'
);

select extensions.is(
  (read_api.member_withdrawals(
    '00000000-0000-0000-0000-000000000601', null, null, 10, null
  )->'items'->0->'destination'->>'account_reference_masked'),
  '******6789',
  'member withdrawals masks the snapshotted account reference'
);

select extensions.is(
  (read_api.member_withdrawals(
    '00000000-0000-0000-0000-000000000601', null, null, 10, null
  )->'items'->0->'destination' ? 'account_reference'),
  false,
  'member withdrawals does not expose the full snapshotted account reference'
);

select extensions.finish();
rollback;
