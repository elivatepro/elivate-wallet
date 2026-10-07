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

-- Reuse the command fixture's organizational context, then add a second eligible
-- pocket with no projection and a pocket excluded by its transfer-out policy.
insert into public.pocket_definitions (pocket_key, display_name, sort_order, transfer_out_allowed)
values ('withdrawal_zero', 'Zero Pocket', 401, true), ('withdrawal_locked', 'Locked Pocket', 402, false);
insert into ledger.ledger_accounts (id, account_class, currency_code, wallet_id, tenant_id, office_id, membership_id, owner_user_id, pocket_key)
select value.id::uuid, 'member_value', 'NGN', '60000000-0000-0000-0000-000000000302',
 '10000000-0000-0000-0000-000000000301', '20000000-0000-0000-0000-000000000303',
 '30000000-0000-0000-0000-000000000302', '00000000-0000-0000-0000-000000000302', value.pocket
from (values ('83000000-0000-0000-0000-000000000303', 'withdrawal_zero'), ('83000000-0000-0000-0000-000000000304', 'withdrawal_locked')) value(id,pocket);

select ok(has_function_privilege('service_role', 'read_api.member_withdrawal_sources(uuid,uuid,integer,uuid)', 'EXECUTE'), 'trusted service can read funding sources');
select ok(not has_function_privilege('authenticated', 'read_api.member_withdrawal_sources(uuid,uuid,integer,uuid)', 'EXECUTE'), 'client cannot directly read private sources');
select ok(not has_function_privilege('anon', 'read_api.member_withdrawal_sources(uuid,uuid,integer,uuid)', 'EXECUTE'), 'anonymous cannot directly read private sources');
select ok(has_function_privilege('service_role', 'read_api.member_withdrawal_target(uuid,uuid)', 'EXECUTE'), 'trusted service can read own exact target');
select ok(not has_function_privilege('authenticated', 'read_api.member_withdrawal_target(uuid,uuid)', 'EXECUTE'), 'client cannot directly read private target');
select ok(not has_function_privilege('anon', 'read_api.member_withdrawal_target(uuid,uuid)', 'EXECUTE'), 'anonymous cannot directly read private target');
select is(jsonb_array_length(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302')->'items'), 2, 'eligible sources include zero balance, exclude Debt and locked pocket');
select is(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302')->'items'->0->>'tenant_name','Withdrawal Tenant','tenant label comes from stored source');
select is(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302')->'items'->0->>'office_name','Withdrawal Team One','office label comes from stored source');
select is((read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302')->'items'->0->>'minor_unit_scale')::integer,2,'source currency minor-unit scale is explicit');
select is(jsonb_typeof(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302')->'items'->0->'posted_balance'),'string','posted monetary value remains exact text');
select is((read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302',null,50,'83000000-0000-0000-0000-000000000303')->'items'->0->>'available_balance')::numeric,0::numeric,'source without projection is available with zero balance');
select is(jsonb_array_length(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000301',null,50,'83000000-0000-0000-0000-000000000301')->'items'),0,'leader cannot select another Wallet owner source');
select is(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302',null,1)->>'nextCursor','83000000-0000-0000-0000-000000000301','cursor identifies last delivered source');
select is(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302','83000000-0000-0000-0000-000000000301',1)->'items'->0->>'source_ledger_account_id','83000000-0000-0000-0000-000000000303','next page excludes previous source');
select is(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302','83000000-0000-0000-0000-000000000301',1)->>'nextCursor',null::text,'last page has no cursor');
select throws_ok($$select read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302',null,0)$$,'22023',null,'source limit rejects zero');
select throws_ok($$select read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302',null,101)$$,'22023',null,'source limit rejects excess');
select throws_ok($$select read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302','83000000-0000-0000-0000-000000000301',50,'83000000-0000-0000-0000-000000000301')$$,'22023',null,'exact selector cannot mix with pagination');

-- The member has 500 posted. A transfer reserves 300, and a withdrawal reserves 100.
select financial_ops.submit_pocket_transfer('92000000-0000-0000-0000-000000000391','83000000-0000-0000-0000-000000000301','83000000-0000-0000-0000-000000000303',300,'00000000-0000-0000-0000-000000000302');
select is((financial_ops.submit_withdrawal('91000000-0000-0000-0000-000000000391','83000000-0000-0000-0000-000000000301','85000000-0000-0000-0000-000000000301',100,'00000000-0000-0000-0000-000000000302')).status,'requested'::financial_ops.withdrawal_status,'available funding permits withdrawal alongside transfer hold');
select is((read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302')->'items'->0->>'reserved_balance')::numeric,400::numeric,'read includes both reservation types');
select is((read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302')->'items'->0->>'available_balance')::numeric,100::numeric,'read reports exact remaining spendable amount');
select throws_ok($$select financial_ops.submit_withdrawal('91000000-0000-0000-0000-000000000392','83000000-0000-0000-0000-000000000301','85000000-0000-0000-0000-000000000301',100.01,'00000000-0000-0000-0000-000000000302')$$,'23514','insufficient available balance for withdrawal reservation','withdrawal cannot reuse pocket-transfer reserved funds');
select is((select count(*)::integer from financial_ops.withdrawal_requests),1,'failed over-reservation creates no withdrawal');
select throws_ok($$select financial_ops.submit_withdrawal('91000000-0000-0000-0000-000000000393','83000000-0000-0000-0000-000000000301','85000000-0000-0000-0000-000000000301',0.001,'00000000-0000-0000-0000-000000000302')$$,'22003',null,'currency scale remains enforced');
select set_config('test.own_withdrawal',(select id::text from financial_ops.withdrawal_requests limit 1),true);
select is(read_api.member_withdrawal_target('00000000-0000-0000-0000-000000000302',current_setting('test.own_withdrawal')::uuid)->>'status','requested','exact own target returns stored lifecycle state');
select throws_ok($$select read_api.member_withdrawal_target('00000000-0000-0000-0000-000000000301',current_setting('test.own_withdrawal')::uuid)$$,'42501',null,'leader cannot inspect other owner target via own lookup');
select throws_ok($$select read_api.member_withdrawal_target('00000000-0000-0000-0000-000000000302','71000000-0000-0000-0000-000000000399')$$,'42501',null,'missing target fails closed');
select financial_ops.cancel_withdrawal('93000000-0000-0000-0000-000000000391',current_setting('test.own_withdrawal')::uuid,'00000000-0000-0000-0000-000000000302','Changed plans');
select is(read_api.member_withdrawal_target('00000000-0000-0000-0000-000000000302',current_setting('test.own_withdrawal')::uuid)->>'status','cancelled','own target allows cancelled-state check for authenticated idempotent retry');
select is((financial_ops.cancel_withdrawal('93000000-0000-0000-0000-000000000391',current_setting('test.own_withdrawal')::uuid,'00000000-0000-0000-0000-000000000302','Changed plans')).reused,true,'same cancelled command retries idempotently');

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000301',true);
select throws_ok($$select read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302')$$,'42501',null,'source read rejects JWT actor mismatch');
select throws_ok($$select read_api.member_withdrawal_target('00000000-0000-0000-0000-000000000302',current_setting('test.own_withdrawal')::uuid)$$,'42501',null,'target read rejects JWT actor mismatch');
select set_config('request.jwt.claim.sub','',true);

-- Values above JavaScript's safe integer retain every minor unit in the read.
select ledger.post_transaction('90000000-0000-0000-0000-000000000392',extensions.digest('withdrawal-exact-read','sha256'),'withdrawal_exact_read','30000000-0000-0000-0000-000000000302','60000000-0000-0000-0000-000000000302','00000000-0000-0000-0000-000000000303',
 jsonb_build_array(jsonb_build_object('currency_code','NGN','postings',jsonb_build_array(
 jsonb_build_object('ledger_account_id','84000000-0000-0000-0000-000000000301','amount','-9007199254740993.01'),
 jsonb_build_object('ledger_account_id','83000000-0000-0000-0000-000000000301','amount','9007199254740993.01')))));
select is(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302')->'items'->0->>'posted_balance','9007199254741493.010000000000000000','posted balance exceeds safe integer without precision loss');
select is(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302')->'items'->0->>'available_balance','9007199254741193.010000000000000000','available balance remains exact after transfer reservation');

-- One Wallet may contain several stored membership contexts for the same pocket.
insert into public.memberships(id,tenant_id,user_id,office_id,role_key,is_primary)
values('30000000-0000-0000-0000-000000000391','10000000-0000-0000-0000-000000000301','00000000-0000-0000-0000-000000000302','20000000-0000-0000-0000-000000000305','member',false);
insert into ledger.ledger_accounts(id,account_class,currency_code,wallet_id,tenant_id,office_id,membership_id,owner_user_id,pocket_key)
values('83000000-0000-0000-0000-000000000391','member_value','NGN','60000000-0000-0000-0000-000000000302','10000000-0000-0000-0000-000000000301','20000000-0000-0000-0000-000000000305','30000000-0000-0000-0000-000000000391','00000000-0000-0000-0000-000000000302','withdrawal_test');
select is(jsonb_array_length(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302')->'items'),3,'same pocket in another membership context remains separate');
select is(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302',null,50,'83000000-0000-0000-0000-000000000391')->'items'->0->>'office_name','Withdrawal Team Two','exact source selector preserves its distinct office');
-- End the auxiliary membership before moving the primary one into its office.
-- Suspended memberships still occupy the current-role uniqueness slot; ended
-- history retains the immutable Ledger context without reserving that slot.
update public.memberships set status='ended', ended_at=clock_timestamp()
 where id='30000000-0000-0000-0000-000000000391';
select is(jsonb_array_length(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302')->'items'),2,'ended auxiliary membership is excluded from eligible funding list');
select is(jsonb_array_length(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302',null,50,'83000000-0000-0000-0000-000000000391')->'items'),1,'ended membership preserves owned historical Ledger context lookup');

-- Exact ownership lookup must not block a replay after source eligibility changes.
update public.pocket_definitions set transfer_out_allowed=false where pocket_key='withdrawal_test';
select is(jsonb_array_length(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302')->'items'),1,'source list excludes newly locked pocket');
select is(jsonb_array_length(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302',null,50,'83000000-0000-0000-0000-000000000301')->'items'),1,'exact ownership lookup survives transfer-out eligibility change');
select is((financial_ops.submit_withdrawal('91000000-0000-0000-0000-000000000391','83000000-0000-0000-0000-000000000301','85000000-0000-0000-0000-000000000301',100,'00000000-0000-0000-0000-000000000302')).reused,true,'authorized submission replay survives transfer-out policy change');
select is(jsonb_array_length(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000301',null,50,'83000000-0000-0000-0000-000000000301')->'items'),0,'ineligible source exact lookup still excludes foreign owner');
update public.pocket_definitions set transfer_out_allowed=true where pocket_key='withdrawal_test';

-- Membership moves preserve historical Ledger contexts; obsolete sources disappear.
update public.memberships set office_id='20000000-0000-0000-0000-000000000305'
 where id='30000000-0000-0000-0000-000000000302';
select is(jsonb_array_length(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302')->'items'),0,'moved membership cannot fund old-office context');
select is(jsonb_array_length(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302',null,50,'83000000-0000-0000-0000-000000000301')->'items'),1,'exact ownership lookup survives membership office move');
update public.memberships set office_id='20000000-0000-0000-0000-000000000303',status='suspended'
 where id='30000000-0000-0000-0000-000000000302';
select is(jsonb_array_length(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302')->'items'),0,'inactive membership has no eligible sources');
update public.memberships set status='active' where id='30000000-0000-0000-0000-000000000302';
update public.offices set status='closed' where id='20000000-0000-0000-0000-000000000303';
select is(jsonb_array_length(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302')->'items'),0,'inactive source office is excluded');
update public.offices set status='active' where id='20000000-0000-0000-0000-000000000303';
update public.tenants set status='suspended' where id='10000000-0000-0000-0000-000000000301';
select is(jsonb_array_length(read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302')->'items'),0,'inactive source tenant is excluded');
update public.user_accounts set status='suspended' where user_id='00000000-0000-0000-0000-000000000302';
select throws_ok($$select read_api.member_withdrawal_sources('00000000-0000-0000-0000-000000000302')$$,'42501',null,'inactive account cannot read funding sources');
select throws_ok($$select read_api.member_withdrawal_target('00000000-0000-0000-0000-000000000302',current_setting('test.own_withdrawal')::uuid)$$,'42501',null,'inactive account cannot read mutation target');
select * from finish();
rollback;
