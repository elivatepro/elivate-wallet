begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(15);

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

-- Both amounts respect NGN's two-decimal scale but exceed JavaScript's safe
-- integer range. Opposite entries also exercise the negative serialized value.
select ledger.post_transaction(
  '90000000-0000-0000-0000-000000000619',
  extensions.digest('member-activity-exact-amount', 'sha256'),
  'member_activity_exact_amount',
  '30000000-0000-0000-0000-000000000601',
  '60000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000601',
  (select jsonb_agg(jsonb_build_object(
    'currency_code', 'NGN',
    'postings', jsonb_build_array(
      jsonb_build_object(
        'ledger_account_id', '82000000-0000-0000-0000-000000000601',
        'amount', -amount
      ),
      jsonb_build_object(
        'ledger_account_id', '81000000-0000-0000-0000-000000000601',
        'amount', amount
      )
    )
  ) order by sequence)
    from (values
      (1, 9007199254740993.01::numeric),
      (2, -9007199254740992.99::numeric)
    ) amounts(sequence, amount))
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
  'NGN', 'member_home_test', 9007199254740993.01,
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


set local role service_role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000601', true);

select extensions.is(
  jsonb_array_length(read_api.member_activity('00000000-0000-0000-0000-000000000601')->'items'),
  2,
  'activity keeps both exact-value journal entries'
);
select extensions.is(
  (select count(*) from jsonb_array_elements(
    read_api.member_activity('00000000-0000-0000-0000-000000000601')->'items'
  ) item where jsonb_typeof(item->'signed_amount') = 'string'),
  2::bigint,
  'every activity amount is a JSON string before any client parses it'
);
select extensions.is(
  (select item->>'signed_amount' from jsonb_array_elements(
    read_api.member_activity('00000000-0000-0000-0000-000000000601')->'items'
  ) item where (item->>'signed_amount')::numeric > 0),
  '9007199254740993.010000000000000000',
  'positive amount retains every digit beyond JavaScript safe integer precision'
);
select extensions.is(
  (select item->>'signed_amount' from jsonb_array_elements(
    read_api.member_activity('00000000-0000-0000-0000-000000000601')->'items'
  ) item where (item->>'signed_amount')::numeric < 0),
  '-9007199254740992.990000000000000000',
  'negative amount retains its sign and exact fractional cents'
);


select extensions.is(
  jsonb_typeof(read_api.member_home('00000000-0000-0000-0000-000000000601') #> path),
  'string', 'home amount is serialized as text: ' || array_to_string(path, '.')
) from (values
  (array['wallets','0','currencies','0','posted_balance']),
  (array['wallets','0','currencies','0','reserved_balance']),
  (array['wallets','0','currencies','0','pockets','0','posted_balance']),
  (array['wallets','0','currencies','0','pockets','0','reserved_balance']),
  (array['recent_activity','0','signed_amount']),
  (array['recent_withdrawals','0','amount'])
) fields(path);
select extensions.is(
  read_api.member_home('00000000-0000-0000-0000-000000000601') #>> '{wallets,0,currencies,0,posted_balance}',
  '0.020000000000000000', 'home aggregation retains exact net cents after large opposite postings'
);
select extensions.is(
  (select item->>'signed_amount' from jsonb_array_elements(read_api.member_home('00000000-0000-0000-0000-000000000601')->'recent_activity') item where (item->>'signed_amount')::numeric > 0),
  '9007199254740993.010000000000000000', 'home recent activity retains all digits independently of paginated activity'
);
select extensions.is(
  read_api.member_home('00000000-0000-0000-0000-000000000601') #>> '{recent_withdrawals,0,amount}',
  '9007199254740993.010000000000000000', 'home recent withdrawal retains all digits'
);
select extensions.is(
  jsonb_typeof(read_api.member_withdrawals('00000000-0000-0000-0000-000000000601') #> '{items,0,requested_amount}'),
  'string', 'paginated withdrawal amount is serialized as text'
);
select extensions.is(
  read_api.member_withdrawals('00000000-0000-0000-0000-000000000601') #>> '{items,0,requested_amount}',
  '9007199254740993.010000000000000000', 'paginated withdrawal retains all digits'
);

select extensions.finish();
rollback;
