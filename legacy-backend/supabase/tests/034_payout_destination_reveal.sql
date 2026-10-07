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
 'requested'::financial_ops.withdrawal_status,
 null::uuid,
 null::timestamptz,
 statement_timestamp() - interval '1 minute'
 from generate_series(1,57) n;


insert into financial_ops.withdrawal_destination_snapshots(withdrawal_id,source_payout_account_id,institution_code,institution_name,account_reference,account_holder_name,payout_rail,payout_currency,country_code,verification_status,verification_method)
select id,'85000000-0000-0000-0000-000000000502','test','Test Bank','0123456789','Test Member','bank','NGN','NG','verified','manual'
from financial_ops.withdrawal_requests;

-- Synthetic fixture reservation; no provider or actual money is dispatched.
insert into financial_ops.funding_reservations(withdrawal_id,ledger_account_id,amount)
values('92000000-0000-0000-0000-000000000007','83000000-0000-0000-0000-000000000501',10.01);
select financial_ops.approve_withdrawal('95000000-0000-0000-0000-000000000007','92000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000501');
create temporary table stages(key text primary key,data jsonb);

select ok(not has_function_privilege('anon','command_api.payout_destination(uuid,uuid,uuid,uuid)','EXECUTE'),'anonymous cannot reveal destination');
select ok(not has_function_privilege('authenticated','command_api.payout_destination(uuid,uuid,uuid,uuid)','EXECUTE'),'ordinary client RPC cannot reveal destination');
select ok(has_function_privilege('service_role','command_api.payout_destination(uuid,uuid,uuid,uuid)','EXECUTE'),'trusted transport can execute guarded reveal');
select ok(not has_table_privilege('service_role','financial_ops.withdrawal_destination_snapshots','SELECT'),'service cannot bypass reveal through snapshot CRUD');
insert into stages values('reveal',command_api.payout_destination('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000007'));
select is((select data->'destination'->>'account_reference' from stages where key='reveal'),'0123456789','authorized execution gets exact immutable snapshot');
select isnt((select data->'destination'->>'account_reference' from stages where key='reveal'),(select account_reference from financial_ops.payout_accounts where id='85000000-0000-0000-0000-000000000502'),'execution does not substitute current reusable account');
select is((select data->>'withdrawal_id' from stages where key='reveal'),'92000000-0000-0000-0000-000000000007','response bound to stored withdrawal');
select is((select count(*)::integer from authz.security_audit_events where event_type='payout_destination_revealed'),1,'reveal audited before sensitive response');
select ok((select bool_and(metadata::text not like '%0123456789%' and metadata::text not like '%Test Member%') from authz.security_audit_events where event_type='payout_destination_revealed'),'audit excludes sensitive bank fields');
select is((select actor_user_id::text from authz.security_audit_events where event_type='payout_destination_revealed'),'00000000-0000-0000-0000-000000000501','sensitive access audit uses actual actor');
select lives_ok($$select command_api.payout_destination('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000007')$$,'every reveal reauthorizes');
select is((select count(*)::integer from authz.security_audit_events where event_type='payout_destination_revealed'),2,'repeated reveal separately audited');
select is(read_api.leadership_payouts('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501',null,null,null,'92000000-0000-0000-0000-000000000007')->'items'->0->'capabilities'->>'reveal','true','eligible original approver sees execution capability');
select ok(read_api.leadership_payouts('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501')::text not like '%0123456789%','queue stays masked even after reveal');
select is(read_api.leadership_payouts('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503',null,null,null,'92000000-0000-0000-0000-000000000007')->'items'->0->'capabilities'->>'reveal','false','different approver only has masked read');
select throws_ok($$select command_api.payout_destination('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503','92000000-0000-0000-0000-000000000007')$$,'42501','payout execution context is not authorized','other authorized leader cannot reveal original approver payout');
select throws_ok($$select command_api.payout_destination('00000000-0000-0000-0000-000000000502','30000000-0000-0000-0000-000000000502','92000000-0000-0000-0000-000000000007')$$,'42501','payout execution context is not authorized','member cannot use leadership reveal');
select throws_ok($$select command_api.payout_destination('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000503','92000000-0000-0000-0000-000000000007')$$,'42501','active leadership workspace is required','borrowed workspace denied');
select throws_ok($$select command_api.payout_destination('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000001')$$,'42501','payout execution context is not authorized','requested withdrawal cannot reveal');
select throws_ok($$select command_api.payout_destination('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000999')$$,'42501','payout execution context is not authorized','unknown target uniformly denied');
insert into public.offices(id,tenant_id,parent_office_id,office_type,name) values('20000000-0000-0000-0000-000000000504','10000000-0000-0000-0000-000000000501','20000000-0000-0000-0000-000000000502','team_leader','Other Team');
insert into public.memberships(id,tenant_id,user_id,office_id,role_key,is_primary) values('30000000-0000-0000-0000-000000000505','10000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501','20000000-0000-0000-0000-000000000504','team_leader',false);
select throws_ok($$select command_api.payout_destination('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000505','92000000-0000-0000-0000-000000000007')$$,'42501','payout execution context is not authorized','actor-owned sibling office selector cannot widen execution scope');
insert into public.tenants(id,name) values('10000000-0000-0000-0000-000000000601','Other Reveal Tenant');
insert into public.offices(id,tenant_id,office_type,name) values('20000000-0000-0000-0000-000000000601','10000000-0000-0000-0000-000000000601','world_team','Other World Team');
insert into public.memberships(id,tenant_id,user_id,office_id,role_key,is_primary) values('30000000-0000-0000-0000-000000000601','10000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000501','20000000-0000-0000-0000-000000000601','world_team_member',false);
select authz.seed_tenant_role_permissions('10000000-0000-0000-0000-000000000601');
select throws_ok($$select command_api.payout_destination('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000601','92000000-0000-0000-0000-000000000007')$$,'42501','payout execution context is not authorized','actor-owned foreign tenant cannot widen execution scope');
insert into public.wallets(id,owner_user_id) values('60000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501');
insert into ledger.ledger_accounts(id,account_class,currency_code,wallet_id,tenant_id,office_id,membership_id,owner_user_id,pocket_key)
values('83000000-0000-0000-0000-000000000606','member_value','NGN','60000000-0000-0000-0000-000000000501','10000000-0000-0000-0000-000000000501','20000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501','operations_main');
insert into financial_ops.payout_accounts(id,wallet_id,owner_user_id,country_code,payout_currency,payout_rail,institution_code,institution_name,account_reference,account_holder_name,verification_status,verification_method,created_at,verified_at)
values('85000000-0000-0000-0000-000000000501','60000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501','NG','NGN','bank','test','Test Bank','9887654321','Leader Test','verified','manual',clock_timestamp()-interval '1 minute',clock_timestamp());
insert into financial_ops.withdrawal_requests(id,tenant_id,office_id,membership_id,wallet_id,owner_user_id,source_ledger_account_id,source_currency_code,source_pocket_key,requested_amount,payout_account_id,initiated_by_user_id,status,approved_by_user_id,approved_at,created_at)
values('92000000-0000-0000-0000-000000000606','10000000-0000-0000-0000-000000000501','20000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000501','60000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501','83000000-0000-0000-0000-000000000606','NGN','operations_main',10.01,'85000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501','approved','00000000-0000-0000-0000-000000000501',clock_timestamp(),clock_timestamp()-interval '1 minute');
select throws_ok($$select command_api.payout_destination('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000606')$$,'42501','payout execution context is not authorized','leadership authority cannot reveal self-wallet payout');
savepoint inactive_reservation;
select set_config('financial_ops.reservation_transition',(select id::text from financial_ops.funding_reservations where withdrawal_id='92000000-0000-0000-0000-000000000007'),true);
update financial_ops.funding_reservations set status='released',released_at=clock_timestamp(),release_reason='Isolated inactive reservation fixture' where withdrawal_id='92000000-0000-0000-0000-000000000007';
select throws_ok($$select command_api.payout_destination('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000007')$$,'42501','payout execution context is not authorized','approved request without active reservation cannot reveal');
rollback to savepoint inactive_reservation;
insert into authz.access_assignments(id,tenant_id,subject_user_id,created_by_user_id,reason) values('40000000-0000-0000-0000-000000000521','10000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000503','Expired reveal authority fixture');
insert into authz.access_rules(id,tenant_id,assignment_id,permission_key,effect,scope_type,scope_membership_id,starts_at,expires_at) values('50000000-0000-0000-0000-000000000521','10000000-0000-0000-0000-000000000501','40000000-0000-0000-0000-000000000521','approve_withdrawal','allow','member','30000000-0000-0000-0000-000000000502',clock_timestamp()-interval '2 hours',clock_timestamp()-interval '1 hour');
update authz.tenant_role_permissions set allowed=false where tenant_id='10000000-0000-0000-0000-000000000501' and role_key='team_leader' and permission_key='approve_withdrawal';
select throws_ok($$select command_api.payout_destination('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000007')$$,'42501',null,'expired grant cannot recover execution authority');
update authz.tenant_role_permissions set allowed=true where tenant_id='10000000-0000-0000-0000-000000000501' and role_key='team_leader' and permission_key='approve_withdrawal';
update authz.permission_catalog set step_up_mode='elevated' where permission_key='approve_withdrawal';
select throws_ok($$select command_api.payout_destination('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000007')$$,'P0401',null,'reveal preserves fresh step-up challenge');
update authz.permission_catalog set step_up_mode='none' where permission_key='approve_withdrawal';
update public.memberships set status='suspended' where id='30000000-0000-0000-0000-000000000501';
select throws_ok($$select command_api.payout_destination('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000007')$$,'42501','active leadership workspace is required','suspended selected membership denied on repeated reveal');
update public.memberships set status='active' where id='30000000-0000-0000-0000-000000000501';
update public.memberships set status='ended',ended_at=clock_timestamp() where id='30000000-0000-0000-0000-000000000505';
select throws_ok($$select command_api.payout_destination('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000505','92000000-0000-0000-0000-000000000007')$$,'42501','active leadership workspace is required','ended selected membership cannot reveal');
update public.user_accounts set status='suspended' where user_id='00000000-0000-0000-0000-000000000501';
select throws_ok($$select command_api.payout_destination('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000007')$$,'42501',null,'suspended actor denied');
update public.user_accounts set status='active' where user_id='00000000-0000-0000-0000-000000000501';
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000502',true);
select throws_ok($$select command_api.payout_destination('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000007')$$,'42501','financial command actor does not match the authenticated user','forged authenticated actor denied');
select set_config('request.jwt.claim.sub','',true);
select financial_ops.cancel_withdrawal('98000000-0000-0000-0000-000000000007','92000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000501','No external payout occurred');
select throws_ok($$select command_api.payout_destination('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000007')$$,'42501','payout execution context is not authorized','terminal withdrawal cannot reveal');
select is((select count(*)::integer from authz.security_audit_events where event_type='payout_destination_revealed'),2,'denied attempts never emit successful sensitive access audit');
select * from finish();
rollback;
