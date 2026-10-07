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
create function pg_temp.stage_request(k uuid,actor uuid default '00000000-0000-0000-0000-000000000501',operation text default 'submit',assertion_id uuid default null)
returns jsonb language sql as $$
 select command_api.request_payout_evidence_upload(k,actor,'92000000-0000-0000-0000-000000000007',operation,assertion_id,
 '{"walletDebitAmount":"10.01","beneficiaryPayoutAmount":"9.01","payoutCurrency":"NGN","provider":"manual","paidAt":"2026-10-03T00:00:00.000Z","providerFeeAmount":"1","providerReference":null,"notes":null}'::jsonb || jsonb_build_object('paidAt',
 to_char((select approved_at+interval '1 second' from financial_ops.withdrawal_requests where id='92000000-0000-0000-0000-000000000007') at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')),
 jsonb_build_array(jsonb_build_object('originalFilename','receipt.pdf','mimeType','application/pdf','fileSizeBytes',8,'sha256Hex',repeat('a',64))));
$$;
select ok(not has_table_privilege('service_role','evidence.payout_upload_stages','SELECT'),'stage inaccessible to service CRUD');
select ok(not has_table_privilege('authenticated','evidence.payout_upload_files','INSERT'),'client cannot manufacture files');
select ok(not has_function_privilege('authenticated','command_api.finalize_payout_evidence(uuid,uuid,jsonb,uuid)','EXECUTE'),'finalizer private transport');
select ok(has_function_privilege('service_role','command_api.finalize_payout_evidence(uuid,uuid,jsonb,uuid)','EXECUTE'),'service narrow finalizer allowed');
select throws_ok($$select pg_temp.stage_request('96000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000503')$$,'42501','original approving actor is required','different authorized leader cannot stage original approver receipts');
insert into stages values('first',pg_temp.stage_request('96000000-0000-0000-0000-000000000001'));
select is(pg_temp.stage_request('96000000-0000-0000-0000-000000000001'),(select data from stages where key='first'),'same request preserves stage, files and expiry');
select is((select count(*)::integer from evidence.payout_upload_files),1,'replay does not create new storage paths');
select is((select data->'files'->0->>'bucket' from stages where key='first'),'financial-evidence','fixed private bucket');
select ok((select data->'files'->0->>'path' from stages where key='first') like '10000000-0000-0000-0000-000000000501/payout/96000000-0000-0000-0000-000000000001/%','path derived from stored tenant stage and generated file');
select throws_ok($$select pg_temp.stage_request('96000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000503')$$,'23505','receipt key already has different facts','key cannot be claimed by another actor');
select throws_ok($$select command_api.request_payout_evidence_upload('96000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000007','submit',null,
 (select facts||'{"provider":"changed"}'::jsonb from evidence.payout_upload_stages where id='96000000-0000-0000-0000-000000000001'),
 (select descriptors from evidence.payout_upload_stages where id='96000000-0000-0000-0000-000000000001'))$$,'23505','receipt key already has different facts','same key cannot replace immutable payout facts');
insert into stages select 'twenty',command_api.request_payout_evidence_upload('96000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000007','submit',null,
 (select facts from evidence.payout_upload_stages where id='96000000-0000-0000-0000-000000000001'),
 (select jsonb_agg(jsonb_build_object('originalFilename','receipt'||n||'.pdf','mimeType','application/pdf','fileSizeBytes',8,'sha256Hex',repeat('a',64))) from generate_series(1,20) n));
select is(jsonb_array_length((select data->'files' from stages where key='twenty')),20,'maximum twenty descriptors get distinct bound paths');
select is((select count(distinct storage_object_path)::integer from evidence.payout_upload_files where stage_id='96000000-0000-0000-0000-000000000003'),20,'each descriptor has unique private path');
update evidence.payout_upload_stages set expires_at=clock_timestamp()-interval '1 minute' where id='96000000-0000-0000-0000-000000000003';
insert into stages select 'expired',command_api.request_payout_evidence_upload('96000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000007','submit',null,
 (select facts from evidence.payout_upload_stages where id='96000000-0000-0000-0000-000000000003'),
 (select descriptors from evidence.payout_upload_stages where id='96000000-0000-0000-0000-000000000003'));
select is((select data->>'expired' from stages where key='expired'),'true','locked matching retry definitively confirms expiry');
select is((select data->>'finalized' from stages where key='expired'),'false','expired stage has never finalized');
select is(jsonb_array_length((select data->'files' from stages where key='expired')),0,'expired stage cannot issue upload tokens');
select is((select (data->>'expiresAt')::timestamptz from stages where key='expired'),(select expires_at from evidence.payout_upload_stages where id='96000000-0000-0000-0000-000000000003'),'terminal expiry never renews TTL');
select throws_ok($$select command_api.finalize_payout_evidence('96000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000501','[]')$$,'55000','receipt upload has expired','terminal expired stage can never subsequently finalize');
select throws_ok($$select command_api.payout_upload_objects('96000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000501')$$,'55000','receipt upload has expired','expired unfinished stage cannot renew expiry');
select throws_ok($$select command_api.payout_upload_objects('96000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000502')$$,'42501','original approving actor is required','member cannot get private object');
select throws_ok($$select command_api.finalize_payout_evidence('96000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000501','[]')$$,'23514','receipt bytes do not match the upload request','missing file verification rejected');
select throws_ok($$select command_api.finalize_payout_evidence('96000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000501',jsonb_build_array(jsonb_build_object('fileId',(select id from evidence.payout_upload_files where stage_id='96000000-0000-0000-0000-000000000001'),'mimeType','application/pdf','fileSizeBytes',8,'sha256Hex',repeat('b',64))))$$,'23514','receipt bytes do not match the upload request','hash mismatch cannot create assertion');
select is((select count(*)::integer from financial_ops.payout_completion_assertions),0,'unverified receipts create no assertion');
insert into stages select 'result',command_api.finalize_payout_evidence('96000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000501',
 (select jsonb_agg(jsonb_build_object('fileId',id,'mimeType',mime_type,'fileSizeBytes',file_size_bytes,'sha256Hex',sha256_hex)) from evidence.payout_upload_files where stage_id='96000000-0000-0000-0000-000000000001'));
select is((select data->>'payout_assertion_status' from stages where key='result'),'submitted','verified stage delegates existing assertion command');
select is((select status::text from financial_ops.withdrawal_requests where id='92000000-0000-0000-0000-000000000007'),'approved','receipt submit never completes payout');
select is((select status::text from financial_ops.funding_reservations where withdrawal_id='92000000-0000-0000-0000-000000000007'),'active','reservation remains active');
select is((command_api.finalize_payout_evidence('96000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000501','[]')->>'reused'),'true','finalized retry canonical replay needs no file reverification');
update evidence.payout_upload_stages set expires_at=clock_timestamp()-interval '1 minute' where id='96000000-0000-0000-0000-000000000001';
select is(pg_temp.stage_request('96000000-0000-0000-0000-000000000001')->>'expired','false','already finalized result wins over wall-clock expiry');
select is(pg_temp.stage_request('96000000-0000-0000-0000-000000000001')->>'finalized','true','matching finalized retry remains recoverable forever');
select is(command_api.finalize_payout_evidence('96000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000501','[]')->>'reused','true','finalized aged stage canonically replays without fresh receipts');
select is((select count(*)::integer from financial_ops.payout_completion_assertions),1,'replay creates no duplicate assertion');
select is((select count(*)::integer from evidence.financial_evidence where evidence_type='payout_completion'),1,'replay creates no duplicate evidence');
select lives_ok($$select command_api.payout_evidence_download_object('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501',(select id from evidence.financial_evidence where evidence_type='payout_completion' and id<>'97000000-0000-0000-0000-000000000099'))$$,'authorized current detail receipt download');
-- Simulate historical metadata accepted by the old raw transport. It can be
-- visible in a read, but must not mint a signed URL for an unproven storage path.
insert into evidence.financial_evidence(id,tenant_id,evidence_type,storage_bucket_id,storage_object_path,original_filename,mime_type,file_size_bytes,sha256,submitted_by_user_id,observed_at)
values('97000000-0000-0000-0000-000000000099','10000000-0000-0000-0000-000000000501','payout_completion','financial-evidence','foreign-tenant/private-document','forged.pdf','application/pdf',8,decode(repeat('a',64),'hex'),'00000000-0000-0000-0000-000000000501',clock_timestamp());
insert into financial_ops.payout_assertion_evidence(payout_assertion_revision_id,evidence_id)
select id,'97000000-0000-0000-0000-000000000099' from financial_ops.payout_assertion_revisions;
select throws_ok($$select command_api.payout_evidence_download_object('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501','97000000-0000-0000-0000-000000000099')$$,'42501','receipt storage is not authorized','legacy metadata cannot mint cross-tenant storage capability');
select throws_ok($$select command_api.payout_evidence_download_object('00000000-0000-0000-0000-000000000502','30000000-0000-0000-0000-000000000502',(select id from evidence.financial_evidence where evidence_type='payout_completion' and id<>'97000000-0000-0000-0000-000000000099'))$$,'42501','active leadership workspace is required','member raw read cannot download leadership receipt');
select throws_ok($$select command_api.payout_evidence_download_object('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000503',(select id from evidence.financial_evidence where evidence_type='payout_completion' and id<>'97000000-0000-0000-0000-000000000099'))$$,'42501','active leadership workspace is required','borrowed membership cannot download');
select set_config('financial_ops.payout_assertion_transition',(select data->>'payout_assertion_id' from stages where key='result'),true);
update financial_ops.payout_completion_assertions set status='correction_required',version=version+1;
insert into stages select 'correction',pg_temp.stage_request('96000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000501','correct',(select (data->>'payout_assertion_id')::uuid from stages where key='result'));
insert into stages select 'corrected',command_api.finalize_payout_evidence('96000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000501',
 (select jsonb_agg(jsonb_build_object('fileId',id,'mimeType',mime_type,'fileSizeBytes',file_size_bytes,'sha256Hex',sha256_hex)) from evidence.payout_upload_files where stage_id='96000000-0000-0000-0000-000000000002'));
select is((select current_revision_number::integer from financial_ops.payout_completion_assertions),2,'correction creates one second revision');
select throws_ok($$select command_api.payout_evidence_download_object('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501',(select id from evidence.financial_evidence where evidence_type='payout_completion' and storage_object_path like '%96000000-0000-0000-0000-000000000001%'))$$,'42501','receipt is not authorized','superseded evidence not widened beyond current detail read');
select is(command_api.finalize_payout_evidence('96000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000501','[]')->>'reused','true','second revision same-key replay remains safe');
update authz.permission_catalog set step_up_mode='elevated' where permission_key='approve_withdrawal';
select throws_ok($$select command_api.finalize_payout_evidence('96000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000501','[]')$$,'P0401',null,'finalized replay rechecks current step-up');
update authz.permission_catalog set step_up_mode='none' where permission_key='approve_withdrawal';
update authz.tenant_role_permissions set allowed=false where tenant_id='10000000-0000-0000-0000-000000000501' and role_key='team_leader' and permission_key='approve_withdrawal';
select throws_ok($$select command_api.finalize_payout_evidence('96000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000501','[]')$$,'42501',null,'revoked approval authority denies finalized replay');
select throws_ok($$select command_api.request_payout_evidence_upload('96000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000007','submit',null,
 (select facts from evidence.payout_upload_stages where id='96000000-0000-0000-0000-000000000003'),
 (select descriptors from evidence.payout_upload_stages where id='96000000-0000-0000-0000-000000000003'))$$,'42501',null,'terminal expiry lookup cannot bypass revoked current authority');
select * from finish();
rollback;
