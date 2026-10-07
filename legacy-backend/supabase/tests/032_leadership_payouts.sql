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



select financial_ops.record_income(
  ('91000000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid,
  '30000000-0000-0000-0000-000000000502', 'NGN', 100.01,
  jsonb_build_array(jsonb_build_object(
    'storage_bucket_id','financial-evidence', 'storage_object_path','overview/'||n||'.png',
    'original_filename','receipt.png','mime_type','image/png','file_size_bytes','1024',
    'sha256_hex',repeat('a',64),'observed_at',clock_timestamp()::text,'provider','manual'
  )), '00000000-0000-0000-0000-000000000501'
) from generate_series(1,7) n;

insert into financial_ops.payout_accounts(id,wallet_id,owner_user_id,country_code,payout_currency,payout_rail,institution_code,institution_name,account_reference,account_holder_name,verification_status,verification_method,created_at,verified_at)
values('85000000-0000-0000-0000-000000000502','60000000-0000-0000-0000-000000000502','00000000-0000-0000-0000-000000000502','NG','NGN','bank','test','Test Bank','fixture-only','Test Member','verified','manual',clock_timestamp()-interval '1 minute',clock_timestamp());
-- These workflow fixture rows exercise reporting only, without dispatching payouts.
insert into financial_ops.withdrawal_requests(id,tenant_id,office_id,membership_id,wallet_id,owner_user_id,source_ledger_account_id,source_currency_code,source_pocket_key,requested_amount,payout_account_id,initiated_by_user_id,status,approved_by_user_id,approved_at,created_at)
select ('92000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
 '10000000-0000-0000-0000-000000000501','20000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000502','60000000-0000-0000-0000-000000000502','00000000-0000-0000-0000-000000000502','83000000-0000-0000-0000-000000000501','NGN','operations_main',10.01,'85000000-0000-0000-0000-000000000502','00000000-0000-0000-0000-000000000502',
 case when n=7 then 'approved'::financial_ops.withdrawal_status else 'requested'::financial_ops.withdrawal_status end,
 case when n=7 then '00000000-0000-0000-0000-000000000501'::uuid end,
 case when n=7 then clock_timestamp() end,
 statement_timestamp() - interval '1 minute'
 from generate_series(1,57) n;


insert into financial_ops.withdrawal_destination_snapshots(withdrawal_id,source_payout_account_id,institution_code,institution_name,account_reference,account_holder_name,payout_rail,payout_currency,country_code,verification_status,verification_method)
select id,'85000000-0000-0000-0000-000000000502','test','Test Bank','0123456789','Test Member','bank','NGN','NG','verified','manual'
from financial_ops.withdrawal_requests;
create temporary table payout_pages(key text primary key,data jsonb);
insert into payout_pages values('first',read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503'));
insert into payout_pages select 'second',read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503',null,(data->'next_cursor'->>'created_at')::timestamptz,(data->'next_cursor'->>'withdrawal_id')::uuid) from payout_pages where key='first';
select is(jsonb_array_length((select data from payout_pages where key='first')->'items'),50,'queue bounded to fifty authorized rows');
select is(jsonb_array_length((select data from payout_pages where key='second')->'items'),7,'cursor reaches remaining authorized rows');
select ok((select data->'next_cursor'='null'::jsonb from payout_pages where key='second'),'terminal page cursor null');
select ok(not exists(select 1 from payout_pages a,payout_pages b,jsonb_array_elements(a.data->'items') first,jsonb_array_elements(b.data->'items') second where a.key='first' and b.key='second' and first->>'withdrawal_id'=second->>'withdrawal_id'),'pages do not duplicate withdrawals');
select ok(not has_function_privilege('anon','read_api.leadership_payouts(uuid,uuid,text,timestamptz,uuid,uuid,text)','EXECUTE'),'anon RPC denied');
select ok(not has_function_privilege('authenticated','read_api.leadership_payouts(uuid,uuid,text,timestamptz,uuid,uuid,text)','EXECUTE'),'authenticated direct RPC denied');
select ok(has_function_privilege('service_role','read_api.leadership_payouts(uuid,uuid,text,timestamptz,uuid,uuid,text)','EXECUTE'),'service has narrow transport');
select ok(not has_function_privilege('service_role','read_api.payout_read_item(uuid,uuid,jsonb)','EXECUTE'),'service cannot forge item capability helper');
select ok(not has_function_privilege('service_role','read_api.payout_read_permissions(uuid,uuid)','EXECUTE'),'service cannot directly invoke private helper');
select is((select data->'items'->0->>'requested_amount' from payout_pages where key='first')::numeric,10.01::numeric,'exact decimal amount preserved');
select is((select data->'items'->0->'destination'->>'account_reference_masked' from payout_pages where key='first'),'••••6789','only masked frozen destination returned');
select ok((select data::text not like '%0123456789%' and data::text not like '%storage_object_path%' from payout_pages where key='first'),'read omits raw account and storage coordinates');
select is(jsonb_array_length(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503','approved')->'items'),1,'status filter applied');
select is(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503',null,null,null,'92000000-0000-0000-0000-000000000007')->'items'->0->'capabilities'->>'record','false','other authorized leader cannot record approver payout');
select is(read_api.leadership_payouts('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501',null,null,null,'92000000-0000-0000-0000-000000000007')->'items'->0->'capabilities'->>'record','true','original approving leader sees record capability');
select is(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503',null,null,null,'92000000-0000-0000-0000-000000000001')->'items'->0->'capabilities'->>'cancel','false','requested owner-only cancellation not exposed to leader');
select throws_ok($$select read_api.leadership_payouts('00000000-0000-0000-0000-000000000502','30000000-0000-0000-0000-000000000503')$$,'42501','active leadership workspace is required','actor cannot borrow another workspace');
select throws_ok($$select read_api.leadership_payouts('00000000-0000-0000-0000-000000000502','30000000-0000-0000-0000-000000000502')$$,'42501','active leadership workspace is required','Member cannot access leadership queue');
select throws_ok($$select read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503','bad')$$,'22023','payout read query is invalid','SQL malformed filter rejected');
select throws_ok($$select read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503',null,now())$$,'22023','payout read query is invalid','SQL partial cursor rejected');
select is(jsonb_array_length(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503',null,null,null,'92000000-0000-0000-0000-000000000999')->'items'),0,'unknown detail empty uniformly');
-- Receipt reporting fixtures follow the assertion lifecycle without completing any payout.
insert into financial_ops.payout_completion_assertions(id,withdrawal_id,assertion_number,submitted_by_user_id)
values('93000000-0000-0000-0000-000000000007','92000000-0000-0000-0000-000000000007',1,'00000000-0000-0000-0000-000000000501');
insert into financial_ops.payout_assertion_revisions(id,payout_assertion_id,revision_number,wallet_debit_amount,beneficiary_payout_amount,payout_currency,provider_fee_amount,provider_fee_currency,provider,provider_reference,paid_at,submitted_by_user_id)
values('94000000-0000-0000-0000-000000000007','93000000-0000-0000-0000-000000000007',1,10.01,9.01,'NGN',1,'NGN','manual','test-reference',clock_timestamp(),'00000000-0000-0000-0000-000000000501');
insert into financial_ops.payout_assertion_evidence(payout_assertion_revision_id,evidence_id)
select '94000000-0000-0000-0000-000000000007',id from evidence.financial_evidence order by id limit 1;
select is(read_api.leadership_payouts('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501',null,null,null,'92000000-0000-0000-0000-000000000007')->'items'->0->'latest_assertion'->'revision'->>'wallet_debit_amount','10.010000000000000000','assertion keeps exact debit decimal');
select is(jsonb_array_length(read_api.leadership_payouts('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501',null,null,null,'92000000-0000-0000-0000-000000000007')->'items'->0->'latest_assertion'->'evidence'),1,'linked receipt metadata returned');
select ok(read_api.leadership_payouts('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501',null,null,null,'92000000-0000-0000-0000-000000000007')::text not like '%overview/%','receipt storage coordinates remain private');
select is(read_api.leadership_payouts('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501',null,null,null,'92000000-0000-0000-0000-000000000007')->'items'->0->'capabilities'->>'record','false','pending assertion prevents recording another payout');
select set_config('financial_ops.payout_assertion_transition','93000000-0000-0000-0000-000000000007',true);
update financial_ops.payout_completion_assertions set status='correction_required',version=version+1 where id='93000000-0000-0000-0000-000000000007';
select is(read_api.leadership_payouts('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501',null,null,null,'92000000-0000-0000-0000-000000000007')->'items'->0->'capabilities'->>'correct','true','only original approver can correct first revision');
select is(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503',null,null,null,'92000000-0000-0000-0000-000000000007')->'items'->0->'capabilities'->>'correct','false','different approver cannot correct');
insert into financial_ops.payout_assertion_revisions(id,payout_assertion_id,revision_number,wallet_debit_amount,beneficiary_payout_amount,payout_currency,provider_fee_amount,provider_fee_currency,provider,provider_reference,paid_at,submitted_by_user_id)
values('94000000-0000-0000-0000-000000000008','93000000-0000-0000-0000-000000000007',2,10.01,10.01,'NGN',0,null,'manual','corrected-test-reference',clock_timestamp(),'00000000-0000-0000-0000-000000000501');
update financial_ops.payout_completion_assertions set status='submitted',current_revision_number=2,version=version+1 where id='93000000-0000-0000-0000-000000000007';
update financial_ops.payout_completion_assertions set status='needs_review',version=version+1 where id='93000000-0000-0000-0000-000000000007';
select is(read_api.leadership_payouts('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501',null,null,null,'92000000-0000-0000-0000-000000000007')->'items'->0->'latest_assertion'->'revision'->>'provider_reference','corrected-test-reference','latest revision facts replace prior revision');
-- Foreign tenant, sibling office and leadership self-wallet fixtures.
insert into public.tenants(id,name) values('10000000-0000-0000-0000-000000000601','Foreign Dashboard Tenant');
insert into public.offices(id,tenant_id,office_type,name) values('20000000-0000-0000-0000-000000000601','10000000-0000-0000-0000-000000000601','world_team','Foreign World');
insert into public.offices(id,tenant_id,parent_office_id,office_type,name) values('20000000-0000-0000-0000-000000000602','10000000-0000-0000-0000-000000000601','20000000-0000-0000-0000-000000000601','director','Foreign Director');
insert into public.offices(id,tenant_id,parent_office_id,office_type,name) values('20000000-0000-0000-0000-000000000603','10000000-0000-0000-0000-000000000601','20000000-0000-0000-0000-000000000602','team_leader','Foreign Team');
insert into public.memberships(id,tenant_id,user_id,office_id,role_key,is_primary) values('30000000-0000-0000-0000-000000000601','10000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000502','20000000-0000-0000-0000-000000000603','member',false);
insert into ledger.currency_definitions(currency_code,minor_unit_scale) values('EUR',2);
insert into ledger.ledger_accounts(id,account_class,currency_code,wallet_id,tenant_id,office_id,membership_id,owner_user_id,pocket_key)
values('83000000-0000-0000-0000-000000000601','member_value','EUR','60000000-0000-0000-0000-000000000502','10000000-0000-0000-0000-000000000601','20000000-0000-0000-0000-000000000603','30000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000502','operations_main');


insert into public.offices(id,tenant_id,parent_office_id,office_type,name) values('20000000-0000-0000-0000-000000000504','10000000-0000-0000-0000-000000000501','20000000-0000-0000-0000-000000000502','team_leader','Sibling Team');
insert into public.memberships(id,tenant_id,user_id,office_id,role_key,is_primary) values('30000000-0000-0000-0000-000000000505','10000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000502','20000000-0000-0000-0000-000000000504','member',false);
insert into ledger.ledger_accounts(id,account_class,currency_code,wallet_id,tenant_id,office_id,membership_id,owner_user_id,pocket_key)
values('83000000-0000-0000-0000-000000000605','member_value','EUR','60000000-0000-0000-0000-000000000502','10000000-0000-0000-0000-000000000501','20000000-0000-0000-0000-000000000504','30000000-0000-0000-0000-000000000505','00000000-0000-0000-0000-000000000502','operations_main');
insert into public.wallets(id,owner_user_id) values('60000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501');
insert into ledger.ledger_accounts(id,account_class,currency_code,wallet_id,tenant_id,office_id,membership_id,owner_user_id,pocket_key)
values('83000000-0000-0000-0000-000000000606','member_value','NGN','60000000-0000-0000-0000-000000000501','10000000-0000-0000-0000-000000000501','20000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501','operations_main');
insert into financial_ops.payout_accounts(id,wallet_id,owner_user_id,country_code,payout_currency,payout_rail,institution_code,institution_name,account_reference,account_holder_name,verification_status,verification_method,created_at,verified_at)
values('85000000-0000-0000-0000-000000000501','60000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501','NG','NGN','bank','test','Test Bank','9887654321','Leader Test','verified','manual',clock_timestamp()-interval '1 minute',clock_timestamp());
insert into financial_ops.withdrawal_requests(id,tenant_id,office_id,membership_id,wallet_id,owner_user_id,source_ledger_account_id,source_currency_code,source_pocket_key,requested_amount,payout_account_id,initiated_by_user_id)
select ('92000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,account.tenant_id,account.office_id,account.membership_id,account.wallet_id,account.owner_user_id,account.id,account.currency_code,account.pocket_key,10.01,
 case when n=606 then '85000000-0000-0000-0000-000000000501'::uuid else '85000000-0000-0000-0000-000000000502'::uuid end,account.owner_user_id
from (values(601,'83000000-0000-0000-0000-000000000601'::uuid),(605,'83000000-0000-0000-0000-000000000605'::uuid),(606,'83000000-0000-0000-0000-000000000606'::uuid)) fixture(n,account_id) join ledger.ledger_accounts account on account.id=fixture.account_id;
insert into financial_ops.withdrawal_destination_snapshots(withdrawal_id,source_payout_account_id,institution_code,institution_name,account_reference,account_holder_name,payout_rail,payout_currency,country_code,verification_status,verification_method)
select withdrawal.id,payout.id,payout.institution_code,payout.institution_name,payout.account_reference,payout.account_holder_name,payout.payout_rail,payout.payout_currency,payout.country_code,payout.verification_status,payout.verification_method
from financial_ops.withdrawal_requests withdrawal join financial_ops.payout_accounts payout on payout.id=withdrawal.payout_account_id
where not exists(select 1 from financial_ops.withdrawal_destination_snapshots snapshot where snapshot.withdrawal_id=withdrawal.id);
select is(jsonb_array_length(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503',null,null,null,'92000000-0000-0000-0000-000000000601')->'items'),0,'foreign tenant detail cannot leak common Wallet provenance');
select is(jsonb_array_length(read_api.leadership_payouts('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501',null,null,null,'92000000-0000-0000-0000-000000000606')->'items'),0,'leadership self-wallet detail forbidden');
insert into authz.access_assignments(id,tenant_id,subject_user_id,created_by_user_id,reason) values('40000000-0000-0000-0000-000000000523','10000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000503','Payout selection boundary test');
insert into authz.access_rules(id,tenant_id,assignment_id,permission_key,effect,scope_type,scope_membership_id) values('50000000-0000-0000-0000-000000000523','10000000-0000-0000-0000-000000000501','40000000-0000-0000-0000-000000000523','approve_withdrawal','allow','member','30000000-0000-0000-0000-000000000505');
select is(jsonb_array_length(read_api.leadership_payouts('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501',null,null,null,'92000000-0000-0000-0000-000000000605')->'items'),0,'selected office boundary prevents unrelated cross-access rows');
select is(jsonb_array_length(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503',null,null,null,'92000000-0000-0000-0000-000000000605')->'items'),1,'tenant President sees authorized sibling office');
select is(jsonb_array_length(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503',null,null,null,null,'Sibling Team')->'items'),1,'search filters entire authorized queue before pagination');
select is(jsonb_array_length(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503',null,null,null,null,'_%')->'items'),0,'search wildcard characters are literal');

-- A missing fresh step-up affects commands, but keeps the approved masked read.
update authz.permission_catalog set step_up_mode='elevated' where permission_key='approve_withdrawal';
select is(read_api.leadership_payouts('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501',null,null,null,'92000000-0000-0000-0000-000000000001')->'items'->0->'capabilities'->>'approve','true','known step-up requirement permits descriptive approval capability');
select is((authz.authorize('00000000-0000-0000-0000-000000000501',null,'approve_withdrawal','10000000-0000-0000-0000-000000000501','20000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000502','00000000-0000-0000-0000-000000000502','60000000-0000-0000-0000-000000000502','00000000-0000-0000-0000-000000000502')).decision::text,'STEP_UP_REQUIRED','read never grants command step-up');
update authz.permission_catalog set step_up_mode='none' where permission_key='approve_withdrawal';

-- Approvers do not require the separate reporting permission.
update authz.tenant_role_permissions set allowed=false where tenant_id='10000000-0000-0000-0000-000000000501' and role_key='president_team_member' and permission_key='view_scoped_financial_reports';
select is(jsonb_array_length(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->'items'),50,'approver read works without report policy');
update authz.tenant_role_permissions set allowed=false where tenant_id='10000000-0000-0000-0000-000000000501' and role_key='president_team_member' and permission_key='approve_withdrawal';
select is(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->>'restricted','true','missing every effective permission distinguished from empty queue');
-- Build a valid scoped approval grant under creator authority before disabling general policy.
update authz.tenant_role_permissions set allowed=true where tenant_id='10000000-0000-0000-0000-000000000501' and role_key='president_team_member' and permission_key='approve_withdrawal';
insert into authz.access_assignments(id,tenant_id,subject_user_id,created_by_user_id,reason) values('40000000-0000-0000-0000-000000000521','10000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000503','00000000-0000-0000-0000-000000000503','Payout scoped authorization test');
insert into authz.access_rules(id,tenant_id,assignment_id,permission_key,effect,scope_type,scope_membership_id) values('50000000-0000-0000-0000-000000000521','10000000-0000-0000-0000-000000000501','40000000-0000-0000-0000-000000000521','approve_withdrawal','allow','member','30000000-0000-0000-0000-000000000502');
update authz.tenant_role_permissions set allowed=false where tenant_id='10000000-0000-0000-0000-000000000501' and role_key='president_team_member' and permission_key='approve_withdrawal';
select is(jsonb_array_length(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->'items'),50,'scoped grant survives lack of tenant-wide policy');
select is(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->>'restricted','false','scoped grant has valid read access');
insert into authz.access_rules(id,tenant_id,assignment_id,permission_key,effect,scope_type,scope_office_id) values('50000000-0000-0000-0000-000000000522','10000000-0000-0000-0000-000000000501','40000000-0000-0000-0000-000000000521','approve_withdrawal','deny','office_subtree','20000000-0000-0000-0000-000000000502');
select is(jsonb_array_length(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->'items'),0,'ancestor-office deny defeats scoped approval grant');
select is(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->>'restricted','true','denied queue distinguished from zero work');
-- Dedicated reviewer assignment authorizes masked read without approval/report grants.
insert into authz.financial_evidence_reviewer_assignments(tenant_id,reviewer_membership_id,reviewer_user_id,assigned_by_user_id)
values('10000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000503','00000000-0000-0000-0000-000000000503','00000000-0000-0000-0000-000000000503');
select is(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->>'restricted','false','dedicated reviewer has read access independently of approval deny');
select is(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503',null,null,null,'92000000-0000-0000-0000-000000000007')->'items'->0->'capabilities'->>'review','true','assigned independent reviewer sees review capability');
select is(jsonb_array_length(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->'items'),50,'reviewer queue remains bounded and scoped');
select is(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503',null,null,null,'92000000-0000-0000-0000-000000000001')->'items'->0->'capabilities'->>'approve','false','reviewer read does not grant approval');
insert into authz.access_rules(id,tenant_id,assignment_id,permission_key,effect,scope_type,scope_office_id)
values('50000000-0000-0000-0000-000000000524','10000000-0000-0000-0000-000000000501','40000000-0000-0000-0000-000000000521','review_financial_evidence','deny','office_subtree','20000000-0000-0000-0000-000000000502');
select is(jsonb_array_length(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->'items'),0,'explicit reviewer deny defeats dedicated assignment');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000502',true);
select throws_ok($$select read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')$$,'42501','financial command actor does not match the authenticated user','verified actor mismatch denied');
select set_config('request.jwt.claim.sub','',true);
update public.user_accounts set status='suspended' where user_id='00000000-0000-0000-0000-000000000503';
select throws_ok($$select read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')$$,'42501','active leadership workspace is required','inactive account denied');
select * from finish();
rollback;
