begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

create temporary table operation_test_ids (
  key text primary key,
  id uuid not null
);

insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
values
  ('00000000-0000-0000-0000-000000000501', 'authenticated', 'authenticated', 'operations-leader@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000502', 'authenticated', 'authenticated', 'operations-owner@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000503', 'authenticated', 'authenticated', 'operations-president@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000504', 'authenticated', 'authenticated', 'operations-reviewer@example.test', '{}'::jsonb, '{}'::jsonb)
on conflict (id) do nothing;

insert into public.user_accounts (user_id)
values
  ('00000000-0000-0000-0000-000000000501'),
  ('00000000-0000-0000-0000-000000000502'),
  ('00000000-0000-0000-0000-000000000503'),
  ('00000000-0000-0000-0000-000000000504');

insert into public.tenants (id, name)
values ('10000000-0000-0000-0000-000000000501', 'Financial Operations Tenant');

insert into public.offices (id, tenant_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000501',
  '10000000-0000-0000-0000-000000000501',
  'world_team',
  'Operations World Team'
);
insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000502',
  '10000000-0000-0000-0000-000000000501',
  '20000000-0000-0000-0000-000000000501',
  'director',
  'Operations Director'
);
insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000503',
  '10000000-0000-0000-0000-000000000501',
  '20000000-0000-0000-0000-000000000502',
  'team_leader',
  'Operations Team'
);

insert into public.memberships (
  id, tenant_id, user_id, office_id, role_key, is_primary
)
values
  ('30000000-0000-0000-0000-000000000501', '10000000-0000-0000-0000-000000000501', '00000000-0000-0000-0000-000000000501', '20000000-0000-0000-0000-000000000503', 'team_leader', true),
  ('30000000-0000-0000-0000-000000000502', '10000000-0000-0000-0000-000000000501', '00000000-0000-0000-0000-000000000502', '20000000-0000-0000-0000-000000000503', 'member', true),
  ('30000000-0000-0000-0000-000000000503', '10000000-0000-0000-0000-000000000501', '00000000-0000-0000-0000-000000000503', null, 'president_team_member', true),
  ('30000000-0000-0000-0000-000000000504', '10000000-0000-0000-0000-000000000501', '00000000-0000-0000-0000-000000000504', '20000000-0000-0000-0000-000000000502', 'director', true);

select authz.seed_tenant_role_permissions('10000000-0000-0000-0000-000000000501');

insert into public.wallets (id, owner_user_id)
values ('60000000-0000-0000-0000-000000000502', '00000000-0000-0000-0000-000000000502');

insert into public.pocket_definitions (pocket_key, display_name, sort_order)
values
  ('operations_main', 'Operations Main', 600),
  ('operations_savings', 'Operations Savings', 601);

insert into public.allocation_policy_versions (
  id, tenant_id, version_number, created_by_user_id
)
values (
  '61000000-0000-0000-0000-000000000501',
  '10000000-0000-0000-0000-000000000501',
  1,
  '00000000-0000-0000-0000-000000000503'
);
insert into public.allocation_policy_rules (
  tenant_id, policy_version_id, pocket_key, allocation_basis_points, remainder_rank
)
values
  ('10000000-0000-0000-0000-000000000501', '61000000-0000-0000-0000-000000000501', 'operations_main', 7000, 1),
  ('10000000-0000-0000-0000-000000000501', '61000000-0000-0000-0000-000000000501', 'operations_savings', 3000, 2);
update public.allocation_policy_versions
   set activated_at = clock_timestamp()
 where id = '61000000-0000-0000-0000-000000000501';
insert into public.tenant_active_allocation_policies (
  tenant_id, policy_version_id, activated_by_user_id
)
values (
  '10000000-0000-0000-0000-000000000501',
  '61000000-0000-0000-0000-000000000501',
  '00000000-0000-0000-0000-000000000503'
);

insert into ledger.currency_definitions (currency_code, minor_unit_scale)
values ('NGN', 2), ('USD', 2);

insert into ledger.ledger_accounts (
  id, account_class, currency_code, wallet_id, tenant_id, office_id,
  membership_id, owner_user_id, pocket_key
)
values
  ('83000000-0000-0000-0000-000000000501', 'member_value', 'NGN', '60000000-0000-0000-0000-000000000502', '10000000-0000-0000-0000-000000000501', '20000000-0000-0000-0000-000000000503', '30000000-0000-0000-0000-000000000502', '00000000-0000-0000-0000-000000000502', 'operations_main'),
  ('83000000-0000-0000-0000-000000000502', 'member_value', 'NGN', '60000000-0000-0000-0000-000000000502', '10000000-0000-0000-0000-000000000501', '20000000-0000-0000-0000-000000000503', '30000000-0000-0000-0000-000000000502', '00000000-0000-0000-0000-000000000502', 'operations_savings'),
  ('83000000-0000-0000-0000-000000000503', 'member_value', 'NGN', '60000000-0000-0000-0000-000000000502', '10000000-0000-0000-0000-000000000501', '20000000-0000-0000-0000-000000000503', '30000000-0000-0000-0000-000000000502', '00000000-0000-0000-0000-000000000502', 'debt'),
  ('83000000-0000-0000-0000-000000000504', 'member_value', 'USD', '60000000-0000-0000-0000-000000000502', '10000000-0000-0000-0000-000000000501', '20000000-0000-0000-0000-000000000503', '30000000-0000-0000-0000-000000000502', '00000000-0000-0000-0000-000000000502', 'operations_main');

insert into ledger.ledger_accounts (id, account_class, currency_code, system_account_key)
values
  ('84000000-0000-0000-0000-000000000501', 'system_counter', 'NGN', 'opening_balance'),
  ('84000000-0000-0000-0000-000000000502', 'system_counter', 'NGN', 'income_external'),
  ('84000000-0000-0000-0000-000000000503', 'system_counter', 'NGN', 'fx_clearing'),
  ('84000000-0000-0000-0000-000000000504', 'system_counter', 'USD', 'fx_clearing'),
  ('84000000-0000-0000-0000-000000000505', 'system_counter', 'NGN', 'administrative_adjustment'),
  ('84000000-0000-0000-0000-000000000506', 'system_counter', 'NGN', 'returned_funds_external'),
  ('84000000-0000-0000-0000-000000000507', 'system_counter', 'NGN', 'external_payout'),
  ('84000000-0000-0000-0000-000000000508', 'system_counter', 'NGN', 'provider_fee');

insert into financial_ops.payout_accounts (
  id, wallet_id, owner_user_id, country_code, payout_currency, payout_rail,
  institution_code, institution_name, account_reference, account_holder_name,
  verification_status, verification_method, verified_at, is_primary, created_at
)
values (
  '85000000-0000-0000-0000-000000000501',
  '60000000-0000-0000-0000-000000000502',
  '00000000-0000-0000-0000-000000000502',
  'NG', 'NGN', 'bank_transfer', '999', 'Operations Test Bank',
  '0123456789', 'Operations Owner', 'verified', 'test_verification',
  statement_timestamp(), true, statement_timestamp()
);

select ledger.post_transaction(
  '90000000-0000-0000-0000-000000000501',
  extensions.digest('operations-opening-balance', 'sha256'),
  'operations_opening_balance',
  '30000000-0000-0000-0000-000000000502',
  '60000000-0000-0000-0000-000000000502',
  '00000000-0000-0000-0000-000000000501',
  jsonb_build_array(jsonb_build_object(
    'currency_code', 'NGN',
    'postings', jsonb_build_array(
      jsonb_build_object('ledger_account_id', '84000000-0000-0000-0000-000000000501', 'amount', '-1000.00'),
      jsonb_build_object('ledger_account_id', '83000000-0000-0000-0000-000000000501', 'amount', '1000.00')
    )
  ))
);

insert into operation_test_ids (key, id)
select 'income', (financial_ops.record_income(
  '91000000-0000-0000-0000-000000000501',
  '30000000-0000-0000-0000-000000000502',
  'NGN', 100.00,
  jsonb_build_array(jsonb_build_object(
    'storage_bucket_id', 'financial-evidence',
    'storage_object_path', 'income/operations-income.png',
    'original_filename', 'operations-income.png',
    'mime_type', 'image/png',
    'file_size_bytes', '1024',
    'sha256_hex', encode(extensions.digest('operations-income', 'sha256'), 'hex'),
    'observed_at', clock_timestamp()::text,
    'provider', 'manual'
  )),
  '00000000-0000-0000-0000-000000000501'
)).operation_id;

select is(
  (select sum(allocated_amount) from financial_ops.income_allocations
    where income_record_id = (select id from operation_test_ids where key = 'income')),
  100.000000000000000000::numeric,
  'income persists an exact deterministic allocation snapshot'
);
select is(
  (select count(*) from evidence.financial_operation_evidence
    where income_record_id = (select id from operation_test_ids where key = 'income')),
  1::bigint,
  'manual income is posted with immutable evidence metadata'
);
select is(
  (financial_ops.record_income(
    '91000000-0000-0000-0000-000000000501',
    '30000000-0000-0000-0000-000000000502',
    'NGN', 100.00,
    jsonb_build_array(jsonb_build_object(
      'storage_bucket_id', 'financial-evidence',
      'storage_object_path', 'income/operations-income.png',
      'original_filename', 'operations-income.png',
      'mime_type', 'image/png', 'file_size_bytes', '1024',
      'sha256_hex', encode(extensions.digest('operations-income', 'sha256'), 'hex'),
      'observed_at', (select observed_at::text from evidence.financial_evidence
        where storage_object_path = 'income/operations-income.png'),
      'provider', 'manual'
    )),
    '00000000-0000-0000-0000-000000000501'
  )).reused,
  true,
  'income submission is idempotent'
);

insert into operation_test_ids (key, id)
select 'transfer', (financial_ops.submit_pocket_transfer(
  '91000000-0000-0000-0000-000000000502',
  '83000000-0000-0000-0000-000000000501',
  '83000000-0000-0000-0000-000000000502',
  100.00,
  '00000000-0000-0000-0000-000000000502'
)).operation_id;

select is(
  (select status from financial_ops.pocket_transfer_reservations
    where pocket_transfer_id = (select id from operation_test_ids where key = 'transfer')),
  'active'::financial_ops.reservation_status,
  'pocket transfer submission immediately reserves source funds'
);
select throws_ok(
  format($sql$select financial_ops.approve_pocket_transfer(
    '91000000-0000-0000-0000-000000000503', %L::uuid,
    '00000000-0000-0000-0000-000000000502'
  )$sql$, (select id from operation_test_ids where key = 'transfer')),
  '42501',
  'pocket transfer approval cannot target own Wallet',
  'the Wallet owner cannot approve their own transfer'
);
select is(
  (financial_ops.approve_pocket_transfer(
    '91000000-0000-0000-0000-000000000503',
    (select id from operation_test_ids where key = 'transfer'),
    '00000000-0000-0000-0000-000000000501'
  )).status,
  'completed',
  'authorized leadership approval posts the pocket transfer atomically'
);
select is(
  (select status from financial_ops.pocket_transfer_reservations
    where pocket_transfer_id = (select id from operation_test_ids where key = 'transfer')),
  'consumed'::financial_ops.reservation_status,
  'pocket transfer approval consumes its reservation'
);

insert into operation_test_ids (key, id)
select 'conversion', (financial_ops.submit_currency_conversion(
  '91000000-0000-0000-0000-000000000504',
  '83000000-0000-0000-0000-000000000501',
  '83000000-0000-0000-0000-000000000504',
  50.00, 1.00, 0.02, 'manual_fx', clock_timestamp(),
  jsonb_build_array(jsonb_build_object(
    'storage_bucket_id', 'financial-evidence',
    'storage_object_path', 'conversion/operations-original.png',
    'original_filename', 'operations-original.png', 'mime_type', 'image/png',
    'file_size_bytes', '1024',
    'sha256_hex', encode(extensions.digest('operations-fx-original', 'sha256'), 'hex'),
    'observed_at', clock_timestamp()::text, 'provider', 'manual_fx'
  )),
  '00000000-0000-0000-0000-000000000501'
)).operation_id;

select is(
  (financial_ops.record_currency_conversion_verification(
    '92000000-0000-0000-0000-000000000501',
    (select id from operation_test_ids where key = 'conversion'),
    '{}'::jsonb, '["destination_amount_mismatch"]'::jsonb,
    'operations-verifier', 'v1'
  )).status,
  'correction_required',
  'first conversion mismatch allows exactly one correction'
);
select is(
  (financial_ops.correct_currency_conversion(
    '92000000-0000-0000-0000-000000000502',
    (select id from operation_test_ids where key = 'conversion'),
    50.00, 1.00, 0.02, 'manual_fx', clock_timestamp(),
    jsonb_build_array(jsonb_build_object(
      'storage_bucket_id', 'financial-evidence',
      'storage_object_path', 'conversion/operations-correction.png',
      'original_filename', 'operations-correction.png', 'mime_type', 'image/png',
      'file_size_bytes', '1024',
      'sha256_hex', encode(extensions.digest('operations-fx-correction', 'sha256'), 'hex'),
      'observed_at', clock_timestamp()::text, 'provider', 'manual_fx'
    )),
    '00000000-0000-0000-0000-000000000501'
  )).status,
  'submitted',
  'conversion correction creates revision two'
);
select is(
  (financial_ops.record_currency_conversion_verification(
    '92000000-0000-0000-0000-000000000503',
    (select id from operation_test_ids where key = 'conversion'),
    '{}'::jsonb, '["destination_amount_mismatch"]'::jsonb,
    'operations-verifier', 'v1'
  )).status,
  'needs_review',
  'second conversion mismatch routes to manual review'
);

insert into authz.elevated_sessions (
  session_id, user_id, verified_at, valid_until, factor_method
)
values (
  '93000000-0000-0000-0000-000000000501',
  '00000000-0000-0000-0000-000000000503',
  clock_timestamp(), clock_timestamp() + interval '4 minutes', 'totp'
);

-- A verified elevation is tied to a real Auth session.
insert into auth.sessions(id,user_id,aal,created_at,updated_at)
select session_id,user_id,'aal2',verified_at,verified_at from authz.elevated_sessions
on conflict (id) do nothing;
select ok(
  authz.configure_financial_evidence_reviewer(
    '10000000-0000-0000-0000-000000000501',
    '30000000-0000-0000-0000-000000000504',
    true,
    '00000000-0000-0000-0000-000000000503',
    '93000000-0000-0000-0000-000000000501'
  ) is not null,
  'President assigns a designated evidence reviewer'
);
select is(
  (financial_ops.review_currency_conversion(
    '92000000-0000-0000-0000-000000000504',
    (select id from operation_test_ids where key = 'conversion'),
    'clear', 'Evidence reconciled to provider statement',
    '00000000-0000-0000-0000-000000000504'
  )).status,
  'posted',
  'designated non-submitting reviewer can clear and post a conversion'
);

select ledger.post_transaction(
  '94000000-0000-0000-0000-000000000500',
  extensions.digest('operations-debt-opening', 'sha256'),
  'operations_debt_opening',
  '30000000-0000-0000-0000-000000000502',
  '60000000-0000-0000-0000-000000000502',
  '00000000-0000-0000-0000-000000000503',
  jsonb_build_array(jsonb_build_object(
    'currency_code', 'NGN',
    'postings', jsonb_build_array(
      jsonb_build_object('ledger_account_id', '83000000-0000-0000-0000-000000000503', 'amount', '-40.00'),
      jsonb_build_object('ledger_account_id', '84000000-0000-0000-0000-000000000501', 'amount', '40.00')
    )
  ))
);
insert into public.allocation_policy_versions (
  id, tenant_id, version_number, created_by_user_id
)
values (
  '61000000-0000-0000-0000-000000000502',
  '10000000-0000-0000-0000-000000000501', 2,
  '00000000-0000-0000-0000-000000000503'
);
insert into public.allocation_policy_rules (
  tenant_id, policy_version_id, pocket_key, allocation_basis_points, remainder_rank
)
values
  ('10000000-0000-0000-0000-000000000501', '61000000-0000-0000-0000-000000000502', 'operations_main', 5000, 1),
  ('10000000-0000-0000-0000-000000000501', '61000000-0000-0000-0000-000000000502', 'debt', 5000, 2);
update public.allocation_policy_versions
   set activated_at = clock_timestamp()
 where id = '61000000-0000-0000-0000-000000000502';
update public.tenant_active_allocation_policies
   set policy_version_id = '61000000-0000-0000-0000-000000000502',
       activated_by_user_id = '00000000-0000-0000-0000-000000000503',
       activated_at = clock_timestamp()
 where tenant_id = '10000000-0000-0000-0000-000000000501';

select throws_ok(
  $$select financial_ops.submit_administrative_adjustment(
    '94000000-0000-0000-0000-000000000501',
    '30000000-0000-0000-0000-000000000502', 'NGN', 'credit', 100.00,
    'Approved correction', '[]'::jsonb,
    '00000000-0000-0000-0000-000000000503',
    '93000000-0000-0000-0000-000000000501'
  )$$,
  '23514',
  'tenant settings require adjustment evidence',
  'adjustment evidence defaults to required'
);

insert into operation_test_ids (key, id)
select 'adjustment', (financial_ops.submit_administrative_adjustment(
  '94000000-0000-0000-0000-000000000502',
  '30000000-0000-0000-0000-000000000502', 'NGN', 'credit', 100.00,
  'Approved correction',
  jsonb_build_array(jsonb_build_object(
    'storage_bucket_id', 'financial-evidence',
    'storage_object_path', 'adjustment/operations.png',
    'original_filename', 'operations-adjustment.png', 'mime_type', 'image/png',
    'file_size_bytes', '1024',
    'sha256_hex', encode(extensions.digest('operations-adjustment', 'sha256'), 'hex'),
    'observed_at', clock_timestamp()::text, 'provider', 'manual'
  )),
  '00000000-0000-0000-0000-000000000503',
  '93000000-0000-0000-0000-000000000501'
)).operation_id;
select is(
  (financial_ops.record_administrative_adjustment_verification(
    '94000000-0000-0000-0000-000000000503',
    (select id from operation_test_ids where key = 'adjustment'),
    '{}'::jsonb, '[]'::jsonb, 'operations-verifier', 'v1'
  )).status,
  'posted',
  'matching required adjustment evidence posts the exact policy lines'
);
select is(
  (select amount from financial_ops.administrative_adjustment_lines
    where administrative_adjustment_id = (
      select id from operation_test_ids where key = 'adjustment'
    ) and pocket_key = 'debt'),
  40.000000000000000000::numeric,
  'adjustment credit caps Debt at zero'
);
select is(
  (select amount from financial_ops.administrative_adjustment_lines
    where administrative_adjustment_id = (
      select id from operation_test_ids where key = 'adjustment'
    ) and pocket_key = 'operations_main'),
  60.000000000000000000::numeric,
  'adjustment credit redistributes the Debt excess by remaining policy weights'
);

insert into authz.action_confirmations (
  session_id, user_id, action_key, target_type, target_id, expires_at
)
select
  '93000000-0000-0000-0000-000000000501',
  '00000000-0000-0000-0000-000000000503',
  'reverse_financial_transaction',
  'financial_transaction',
  transfer.financial_transaction_id,
  clock_timestamp() + interval '4 minutes'
from financial_ops.pocket_transfer_requests transfer
where transfer.id = (select id from operation_test_ids where key = 'transfer');

insert into operation_test_ids (key, id)
select 'reversal', (financial_ops.reverse_financial_transaction(
  '95000000-0000-0000-0000-000000000501',
  (select financial_transaction_id from financial_ops.pocket_transfer_requests
    where id = (select id from operation_test_ids where key = 'transfer')),
  'Approved correction of transfer',
  '00000000-0000-0000-0000-000000000503',
  '93000000-0000-0000-0000-000000000501'
)).operation_id;
select ok(
  exists (select 1 from authz.action_confirmations
    where action_key = 'reverse_financial_transaction' and consumed_at is not null),
  'transaction reversal consumes its one-time target confirmation'
);
select throws_ok(
  format($sql$select financial_ops.reverse_financial_transaction(
    '95000000-0000-0000-0000-000000000502', %L::uuid,
    'Duplicate reversal',
    '00000000-0000-0000-0000-000000000503',
    '93000000-0000-0000-0000-000000000501'
  )$sql$, (select original_financial_transaction_id from financial_ops.financial_reversals
    where id = (select id from operation_test_ids where key = 'reversal'))),
  '55000',
  'financial transaction already has a direct reversal',
  'a financial transaction has at most one effective direct reversal'
);

insert into authz.action_confirmations (
  session_id, user_id, action_key, target_type, target_id, expires_at
)
select
  '93000000-0000-0000-0000-000000000501',
  '00000000-0000-0000-0000-000000000503',
  'reverse_financial_transaction',
  'financial_transaction',
  reversal.reversal_financial_transaction_id,
  clock_timestamp() + interval '4 minutes'
from financial_ops.financial_reversals reversal
where reversal.id = (select id from operation_test_ids where key = 'reversal');
insert into operation_test_ids (key, id)
select 'reinstatement', (financial_ops.reverse_financial_transaction(
  '95000000-0000-0000-0000-000000000503',
  (select reversal_financial_transaction_id from financial_ops.financial_reversals
    where id = (select id from operation_test_ids where key = 'reversal')),
  'Reinstate the corrected transfer',
  '00000000-0000-0000-0000-000000000503',
  '93000000-0000-0000-0000-000000000501'
)).operation_id;
select is(
  (select reinstates_reversal_id from financial_ops.financial_reversals
    where id = (select id from operation_test_ids where key = 'reinstatement')),
  (select id from operation_test_ids where key = 'reversal'),
  'reversal-of-reversal creates one explicit reinstatement relationship'
);

insert into operation_test_ids (key, id)
select 'withdrawal', (financial_ops.submit_withdrawal(
  '96000000-0000-0000-0000-000000000501',
  '83000000-0000-0000-0000-000000000501',
  '85000000-0000-0000-0000-000000000501',
  100.00,
  '00000000-0000-0000-0000-000000000502'
)).withdrawal_id;
select is(
  (financial_ops.approve_withdrawal(
    '96000000-0000-0000-0000-000000000502',
    (select id from operation_test_ids where key = 'withdrawal'),
    '00000000-0000-0000-0000-000000000501'
  )).status,
  'approved'::financial_ops.withdrawal_status,
  'returned-funds fixture starts from an approved reserved withdrawal'
);
insert into operation_test_ids (key, id)
select 'payout_assertion', (financial_ops.submit_payout_assertion(
  '96000000-0000-0000-0000-000000000503',
  (select id from operation_test_ids where key = 'withdrawal'),
  100.00, 95.00, 'NGN', 'manual_bank', clock_timestamp(),
  jsonb_build_array(jsonb_build_object(
    'storage_bucket_id', 'financial-evidence',
    'storage_object_path', 'payout/operations-returned-source.png',
    'original_filename', 'operations-returned-source.png', 'mime_type', 'image/png',
    'file_size_bytes', '1024',
    'sha256_hex', encode(extensions.digest('operations-payout', 'sha256'), 'hex'),
    'observed_at', clock_timestamp()::text, 'provider', 'manual_bank'
  )),
  '00000000-0000-0000-0000-000000000501',
  5.00, 'OPS-PAYOUT-1'
)).payout_assertion_id;
select is(
  (financial_ops.record_payout_verification(
    '96000000-0000-0000-0000-000000000504',
    (select id from operation_test_ids where key = 'payout_assertion'),
    '{}'::jsonb, '[]'::jsonb, 'operations-verifier', 'v1'
  )).withdrawal_status,
  'completed'::financial_ops.withdrawal_status,
  'returned funds can only follow a completed evidence-backed withdrawal'
);

insert into operation_test_ids (key, id)
select 'returned_fund', (financial_ops.submit_returned_fund(
  '96000000-0000-0000-0000-000000000505',
  (select id from operation_test_ids where key = 'withdrawal'),
  40.00, 'manual_bank', clock_timestamp(),
  jsonb_build_array(jsonb_build_object(
    'storage_bucket_id', 'financial-evidence',
    'storage_object_path', 'returned/operations-returned.png',
    'original_filename', 'operations-returned.png', 'mime_type', 'image/png',
    'file_size_bytes', '1024',
    'sha256_hex', encode(extensions.digest('operations-returned', 'sha256'), 'hex'),
    'observed_at', clock_timestamp()::text, 'provider', 'manual_bank'
  )),
  '00000000-0000-0000-0000-000000000501', 'OPS-RETURN-1'
)).operation_id;
select is(
  (financial_ops.record_returned_fund_verification(
    '96000000-0000-0000-0000-000000000506',
    (select id from operation_test_ids where key = 'returned_fund'),
    '{}'::jsonb, '[]'::jsonb, 'operations-verifier', 'v1'
  )).status,
  'posted',
  'matching returned-fund evidence posts to the original final debited account'
);
select throws_ok(
  format($sql$select financial_ops.submit_returned_fund(
    '96000000-0000-0000-0000-000000000507', %L::uuid,
    70.00, 'manual_bank', clock_timestamp(),
    jsonb_build_array(jsonb_build_object(
      'storage_bucket_id', 'financial-evidence',
      'storage_object_path', 'returned/operations-excess.png',
      'original_filename', 'operations-excess.png', 'mime_type', 'image/png',
      'file_size_bytes', '1024',
      'sha256_hex', encode(extensions.digest('operations-excess-return', 'sha256'), 'hex'),
      'observed_at', clock_timestamp()::text, 'provider', 'manual_bank'
    )),
    '00000000-0000-0000-0000-000000000501', 'OPS-RETURN-EXCESS'
  )$sql$, (select id from operation_test_ids where key = 'withdrawal')),
  '23514',
  'cumulative returned funds exceed the final Wallet debit',
  'partial returned-fund records cannot cumulatively exceed the final Wallet debit'
);
select ok(
  exists (select 1 from internal.outbox_events where event_type = 'income_recorded')
  and exists (select 1 from internal.outbox_events where event_type = 'pocket_transfer_completed')
  and exists (select 1 from internal.outbox_events where event_type = 'currency_conversion_posted')
  and exists (select 1 from internal.outbox_events where event_type = 'administrative_adjustment_posted')
  and exists (select 1 from internal.outbox_events where event_type = 'financial_transaction_reversed')
  and exists (select 1 from internal.outbox_events where event_type = 'financial_transaction_reinstated')
  and exists (select 1 from internal.outbox_events where event_type = 'returned_fund_posted'),
  'financial operation state transitions emit transactional outbox events'
);

select ok(
  not has_table_privilege('authenticated', 'financial_ops.income_records', 'SELECT')
  and not has_table_privilege('authenticated', 'evidence.financial_operation_evidence', 'SELECT'),
  'financial operations and evidence tables are not directly client-readable'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'financial_ops.record_income(uuid,uuid,text,numeric,jsonb,uuid,uuid)',
    'EXECUTE'
  ),
  'trusted financial command functions are not directly client-executable'
);

-- The linked remote query channel does not stream pgTAP's intermediate TAP
-- rows. Keep a fail-fast aggregate guard so remote-only validation still
-- fails the SQL batch when a material final invariant is false.
do $$
begin
  if (select sum(allocated_amount) from financial_ops.income_allocations
        where income_record_id = (select id from operation_test_ids where key = 'income'))
       <> 100.00
     or (select status from financial_ops.pocket_transfer_requests
          where id = (select id from operation_test_ids where key = 'transfer'))
       <> 'completed'
     or (select status from financial_ops.pocket_transfer_reservations
          where pocket_transfer_id = (select id from operation_test_ids where key = 'transfer'))
       <> 'consumed'
     or (select status from financial_ops.currency_conversions
          where id = (select id from operation_test_ids where key = 'conversion'))
       <> 'posted'
     or (select status from financial_ops.administrative_adjustments
          where id = (select id from operation_test_ids where key = 'adjustment'))
       <> 'posted'
     or (select amount from financial_ops.administrative_adjustment_lines
          where administrative_adjustment_id = (
            select id from operation_test_ids where key = 'adjustment'
          ) and pocket_key = 'debt') <> 40.00
     or (select amount from financial_ops.administrative_adjustment_lines
          where administrative_adjustment_id = (
            select id from operation_test_ids where key = 'adjustment'
          ) and pocket_key = 'operations_main') <> 60.00
     or not exists (
       select 1 from authz.action_confirmations
        where action_key = 'reverse_financial_transaction' and consumed_at is not null
     )
     or (select count(*) from financial_ops.financial_reversals
          where id = (select id from operation_test_ids where key = 'reversal')) <> 1
     or (select reinstates_reversal_id from financial_ops.financial_reversals
          where id = (select id from operation_test_ids where key = 'reinstatement'))
       <> (select id from operation_test_ids where key = 'reversal')
     or (select status from financial_ops.returned_funds
          where id = (select id from operation_test_ids where key = 'returned_fund'))
       <> 'posted'
     or (select destination_ledger_account_id from financial_ops.returned_funds
          where id = (select id from operation_test_ids where key = 'returned_fund'))
       <> '83000000-0000-0000-0000-000000000501'::uuid
     or not exists (select 1 from internal.outbox_events where event_type = 'income_recorded')
     or not exists (select 1 from internal.outbox_events where event_type = 'pocket_transfer_completed')
     or not exists (select 1 from internal.outbox_events where event_type = 'currency_conversion_posted')
     or not exists (select 1 from internal.outbox_events where event_type = 'administrative_adjustment_posted')
     or not exists (select 1 from internal.outbox_events where event_type = 'financial_transaction_reversed')
     or not exists (select 1 from internal.outbox_events where event_type = 'financial_transaction_reinstated')
     or not exists (select 1 from internal.outbox_events where event_type = 'returned_fund_posted')
     or has_table_privilege('authenticated', 'financial_ops.income_records', 'SELECT')
     or has_table_privilege('authenticated', 'evidence.financial_operation_evidence', 'SELECT')
     or has_function_privilege(
       'authenticated',
       'financial_ops.record_income(uuid,uuid,text,numeric,jsonb,uuid,uuid)',
       'EXECUTE'
     ) then
    raise exception using
      errcode = 'P0001',
      message = 'financial operations aggregate acceptance guard failed';
  end if;
end;
$$;

select set_config('test.upload_target',(select id::text from operation_test_ids where key='income'),true);

set local role service_role;

select is((command_api.request_financial_evidence_upload('99000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501','income_record',current_setting('test.upload_target')::uuid,'income','receipt.pdf','application/pdf',128,repeat('c',64))).storage_bucket_id,'financial-evidence'::text,'service role requests evidence for its own immutable operation');

select set_config('test.financial_intent',(command_api.request_financial_evidence_upload('99000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501','income_record',current_setting('test.upload_target')::uuid,'income','receipt.pdf','application/pdf',128,repeat('c',64))).id::text,true);

select is((command_api.read_financial_upload_intent(current_setting('test.financial_intent')::uuid,'00000000-0000-0000-0000-000000000501'))->>'storage_bucket_id','financial-evidence'::text,'service role resolves authorized financial object path');

select throws_ok($$select command_api.read_financial_upload_intent(current_setting('test.financial_intent')::uuid,'00000000-0000-0000-0000-000000000502')$$,'42501',null,'foreign submitter cannot retrieve financial upload path');

select is((command_api.finalize_financial_evidence_upload(current_setting('test.financial_intent')::uuid,'00000000-0000-0000-0000-000000000501',128,repeat('c',64),clock_timestamp())).storage_bucket_id,'financial-evidence'::text,'service role finalizes verified financial evidence');

select is((command_api.finalize_financial_evidence_upload(current_setting('test.financial_intent')::uuid,'00000000-0000-0000-0000-000000000501',128,repeat('c',64),clock_timestamp())).storage_bucket_id,'financial-evidence'::text,'authorized financial finalization retry remains successful');

reset role;

update public.user_accounts set status='suspended' where user_id='00000000-0000-0000-0000-000000000501';

set local role service_role;

select throws_ok($$select command_api.read_financial_upload_intent(current_setting('test.financial_intent')::uuid,'00000000-0000-0000-0000-000000000501')$$,'42501',null,'suspended actor cannot read private financial object location');

select throws_ok($$select command_api.request_financial_evidence_upload('99000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501','income_record',current_setting('test.upload_target')::uuid,'income','receipt.pdf','application/pdf',128,repeat('c',64))$$,'42501',null,'suspended actor cannot replay evidence upload request');

select throws_ok($$select command_api.finalize_financial_evidence_upload(current_setting('test.financial_intent')::uuid,'00000000-0000-0000-0000-000000000501',128,repeat('c',64),clock_timestamp())$$,'42501',null,'suspended actor cannot replay finalized evidence');

reset role;

select is((select count(*) from evidence.financial_upload_intents where idempotency_key='99000000-0000-0000-0000-000000000501'),1::bigint,'retries preserve one financial upload intent');

select * from finish();
rollback;
