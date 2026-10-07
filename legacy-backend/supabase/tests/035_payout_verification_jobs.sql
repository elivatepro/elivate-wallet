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
create function pg_temp.stage_request(k uuid,actor uuid default '00000000-0000-0000-0000-000000000501',operation text default 'submit',assertion_id uuid default null,withdrawal_id uuid default '92000000-0000-0000-0000-000000000007')
returns jsonb language sql as $$
 select command_api.request_payout_evidence_upload(k,actor,withdrawal_id,operation,assertion_id,
 '{"walletDebitAmount":"10.01","beneficiaryPayoutAmount":"9.01","payoutCurrency":"NGN","provider":"manual","paidAt":"2026-10-03T00:00:00.000Z","providerFeeAmount":"1","providerReference":null,"notes":null}'::jsonb || jsonb_build_object('paidAt',
 to_char((select approved_at+interval '1 second' from financial_ops.withdrawal_requests where id=withdrawal_id) at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')),
 jsonb_build_array(jsonb_build_object('originalFilename','receipt.pdf','mimeType','application/pdf','fileSizeBytes',8,'sha256Hex',repeat('a',64))));
$$;

-- Synthetic Auth session is required even when approval's catalogue step-up is none.
insert into auth.sessions(id,user_id,aal,created_at,updated_at)
values('99000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501','aal2',now(),now());
insert into authz.elevated_sessions(session_id,user_id,verified_at,valid_until,factor_method)
values('99000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501',clock_timestamp(),clock_timestamp()+interval '4 minutes','totp');
create temporary table worker_calls(key text primary key,data jsonb);
create function pg_temp.finalize_stage(k uuid) returns jsonb language sql as $$
 select command_api.finalize_payout_evidence(k,'00000000-0000-0000-0000-000000000501',
 (select jsonb_agg(jsonb_build_object('fileId',id,'mimeType',mime_type,'fileSizeBytes',file_size_bytes,'sha256Hex',sha256_hex)) from evidence.payout_upload_files where stage_id=k)); $$;
create function pg_temp.fail_claim(c jsonb,error_code text default 'network') returns jsonb language sql as $$
 select command_api.fail_payout_verification((c->>'jobId')::uuid,'98000000-0000-0000-0000-000000000001',(c->>'leaseToken')::uuid,(c->>'revisionId')::uuid,error_code); $$;
create function pg_temp.receipt_facts(c jsonb,matching boolean default true) returns jsonb language sql as $$
 select jsonb_build_object('policyVersion','strict-single-receipt-v1','evidenceCount',1,'extractionSkipped',null,
 'checks',jsonb_build_object('amount',matching,'currency',true,'recipientAccount',true,'recipientName',true,'paymentStatus',true,'paymentDate',true,'confidence',true),
 'receiptFacts',jsonb_build_array(jsonb_build_object('amount',case when matching then c->'facts'->>'beneficiaryPayoutAmount' else '999.00' end,
 'currency','NGN','recipientAccount','0123456789','recipientName','Test Member','institutionName','Test Bank',
 'transactionDateTime',c->'facts'->>'paidAt','transactionReference',null,'paymentStatus','successful','confidence','high',
 'notes',null,'walletDebitAmount',null,'providerFeeAmount',null))); $$;
create function pg_temp.finish_claim(c jsonb,matching boolean default true) returns jsonb language sql as $$
 select command_api.finish_payout_verification((c->>'jobId')::uuid,'98000000-0000-0000-0000-000000000001',(c->>'leaseToken')::uuid,(c->>'revisionId')::uuid,
 pg_temp.receipt_facts(c,matching),case when matching then '[]'::jsonb else '["amount_mismatch"]'::jsonb end,'openai','test-v1'); $$;
create function pg_temp.retry_job(k uuid) returns jsonb language sql as $$
 select command_api.retry_payout_verification('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501',
 '99000000-0000-0000-0000-000000000501',(select assertion_id from internal.payout_verification_jobs where revision_number=1 limit 1),k); $$;
select ok(not has_table_privilege('service_role','internal.payout_verification_jobs','SELECT'),'service cannot broadly read private jobs');
select ok(not has_function_privilege('authenticated','command_api.claim_payout_verification(uuid)','EXECUTE'),'clients cannot claim jobs');
select ok(not has_function_privilege('authenticated','command_api.finish_payout_verification(uuid,uuid,uuid,uuid,jsonb,jsonb,text,text)','EXECUTE'),'clients cannot finish verification');
select ok(not has_function_privilege('service_role','internal.enqueue_payout_verification(uuid)','EXECUTE'),'service cannot manufacture queued provenance');
select ok(has_function_privilege('service_role','command_api.claim_payout_verification(uuid)','EXECUTE'),'narrow service claim is allowed');
select throws_ok($$select command_api.claim_payout_verification(null)$$,'22023','verification worker is required','malformed worker rejected');
select is(command_api.claim_payout_verification('98000000-0000-0000-0000-000000000001'),null::jsonb,'genuine empty queue');
insert into stages values('first',pg_temp.stage_request('96000000-0000-0000-0000-000000000001'));
select is((select count(*)::integer from internal.payout_verification_jobs),0,'staging without verified bytes never enqueues');
insert into stages values('result',pg_temp.finalize_stage('96000000-0000-0000-0000-000000000001'));
select is((select count(*)::integer from internal.payout_verification_jobs),1,'finalization enqueues exactly one verified immutable revision');
select is(pg_temp.finalize_stage('96000000-0000-0000-0000-000000000001')->>'reused','true','finalized command replay remains recoverable');
select is((select count(*)::integer from internal.payout_verification_jobs),1,'finalization replay does not duplicate work');
select throws_ok($$update internal.payout_verification_jobs set destination='{}'$$,'55000','payout verification snapshot and terminal result are immutable','job destination cannot be edited');
insert into worker_calls values('first',command_api.claim_payout_verification('98000000-0000-0000-0000-000000000001'));
select is((select data->>'attemptNumber' from worker_calls where key='first'),'1','first lease bounded attempt');
select is((select data->'destination'->>'accountReference' from worker_calls where key='first'),'0123456789','private worker receives frozen exact destination');
select is(command_api.claim_payout_verification('98000000-0000-0000-0000-000000000002'),null::jsonb,'active lease prevents another claim');
select throws_ok($$select command_api.fail_payout_verification((select id from internal.payout_verification_jobs),'98000000-0000-0000-0000-000000000002',(select lease_token from internal.payout_verification_jobs),(select revision_id from internal.payout_verification_jobs),'network')$$,'42501','active verification lease is required','different worker cannot commit a failure');
update internal.payout_verification_jobs set lease_expires_at=clock_timestamp()-interval '1 second';
insert into worker_calls values('recovered',command_api.claim_payout_verification('98000000-0000-0000-0000-000000000001'));
select is((select data->>'attemptNumber' from worker_calls where key='recovered'),'2','expired lease recovered with new token and attempt');
select throws_ok($$select pg_temp.fail_claim((select data from worker_calls where key='first'))$$,'42501','active verification lease is required','expired displaced worker cannot commit');
insert into worker_calls select 'failed',pg_temp.fail_claim(data) from worker_calls where key='recovered';
select is((select data->>'status' from worker_calls where key='failed'),'retry_scheduled','technical failure schedules bounded retry');
select is(pg_temp.fail_claim((select data from worker_calls where key='recovered'))->>'reused','true','lost failure response idempotently recovers');
select throws_ok($$select pg_temp.fail_claim((select data from worker_calls where key='recovered'),'timeout')$$,'23505','verification lease already has different results','one lease cannot change committed failure intent');
select is((select count(*)::integer from evidence.verification_attempts),0,'technical failure consumes no financial verification attempt');
select is((select status::text from financial_ops.payout_completion_assertions),'submitted','technical failure consumes no correction');
select is((select status::text from financial_ops.funding_reservations where withdrawal_id='92000000-0000-0000-0000-000000000007'),'active','technical failure preserves reservation');
create function pg_temp.exhaust_job() returns text language plpgsql as $$ declare c jsonb; result jsonb; begin
 for attempt in 3..8 loop
 update internal.payout_verification_jobs set next_attempt_at=clock_timestamp()-interval '1 second' where status='retry_scheduled';
 c:=command_api.claim_payout_verification('98000000-0000-0000-0000-000000000001'); result:=pg_temp.fail_claim(c,'configuration');
 end loop; return result->>'status'; end; $$;
select is(pg_temp.exhaust_job(),'dead_lettered','eight technical attempts stop automatic retries');
select is(command_api.claim_payout_verification('98000000-0000-0000-0000-000000000001'),null::jsonb,'dead letter cannot auto claim');
select is(read_api.payout_read_item('00000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000007','{"approval":true,"review":false}')->'latest_assertion'->'verification'->>'last_error_code','configuration','masked read exposes only safe technical code');
select is(read_api.payout_read_item('00000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000007','{"approval":true,"review":false}')->'capabilities'->>'retryVerification','true','original approver has descriptive recovery capability');
update authz.elevated_sessions set verified_at=clock_timestamp()-interval '5 minutes',valid_until=clock_timestamp()-interval '1 second' where session_id='99000000-0000-0000-0000-000000000501';
select throws_ok($$select pg_temp.retry_job('97000000-0000-0000-0000-000000000001')$$,'P0401','verification retry requires device verification','retry requires fresh step-up even after valid JWT');
update authz.elevated_sessions set verified_at=clock_timestamp(),valid_until=clock_timestamp()+interval '4 minutes' where session_id='99000000-0000-0000-0000-000000000501';
select throws_ok($$select command_api.retry_payout_verification('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503',null,(select assertion_id from internal.payout_verification_jobs),'97000000-0000-0000-0000-000000000001')$$,'42501','original payout actor is required','another leader cannot retry original approver work');
select throws_ok($$select command_api.retry_payout_verification('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000503','99000000-0000-0000-0000-000000000501',(select assertion_id from internal.payout_verification_jobs),'97000000-0000-0000-0000-000000000001')$$,'42501','active leadership workspace is required','borrowed selected membership cannot retry');
insert into worker_calls values('retry',pg_temp.retry_job('97000000-0000-0000-0000-000000000001'));
select is((select data->>'payoutAssertionId' from worker_calls where key='retry'),(select assertion_id::text from internal.payout_verification_jobs),'retry response binds exact assertion');
select is(pg_temp.retry_job('97000000-0000-0000-0000-000000000001')->>'reused','true','retry key replay creates one retry cycle');
select is((select cycle from internal.payout_verification_jobs),2,'manual recovery resets one cycle only');
select is((select attempt_number::integer from internal.payout_verification_jobs),0,'recovery resets technical attempts without new revision');
update authz.tenant_role_permissions set allowed=false where tenant_id='10000000-0000-0000-0000-000000000501' and role_key='team_leader' and permission_key='approve_withdrawal';
select throws_ok($$select pg_temp.retry_job('97000000-0000-0000-0000-000000000001')$$,'42501',null,'idempotent recovery replay rechecks revoked authority');
update authz.tenant_role_permissions set allowed=true where tenant_id='10000000-0000-0000-0000-000000000501' and role_key='team_leader' and permission_key='approve_withdrawal';
insert into worker_calls values('mismatch',command_api.claim_payout_verification('98000000-0000-0000-0000-000000000001'));
select throws_ok($$select command_api.finish_payout_verification((select id from internal.payout_verification_jobs),'98000000-0000-0000-0000-000000000001',(select lease_token from internal.payout_verification_jobs),(select revision_id from internal.payout_verification_jobs),'{}','[]','openai','test-v1')$$,'22023','strict payout verification result is invalid','empty model result cannot post');
select throws_ok($$select command_api.finish_payout_verification((select id from internal.payout_verification_jobs),'98000000-0000-0000-0000-000000000001',(select lease_token from internal.payout_verification_jobs),(select revision_id from internal.payout_verification_jobs),pg_temp.receipt_facts((select data from worker_calls where key='mismatch'))||'{"policyVersion":"invented"}','[]','openai','test-v1')$$,'22023','strict payout verification result is invalid','unknown comparison policy cannot post');
select throws_ok($$select command_api.finish_payout_verification((select id from internal.payout_verification_jobs),'98000000-0000-0000-0000-000000000001',(select lease_token from internal.payout_verification_jobs),(select revision_id from internal.payout_verification_jobs),jsonb_set(pg_temp.receipt_facts((select data from worker_calls where key='mismatch')),'{receiptFacts,0,amount}','"999"'),'[]','openai','test-v1')$$,'22023','automatic match does not substantiate frozen payout facts','trusted worker false match cannot post wrong exact amount');
select throws_ok($$select command_api.finish_payout_verification((select id from internal.payout_verification_jobs),'98000000-0000-0000-0000-000000000001',(select lease_token from internal.payout_verification_jobs),(select revision_id from internal.payout_verification_jobs),jsonb_set(pg_temp.receipt_facts((select data from worker_calls where key='mismatch')),'{checks,confidence}','false'),'[]','openai','test-v1')$$,'22023','automatic match does not substantiate frozen payout facts','empty reasons cannot bypass failed confidence check');
select is(pg_temp.finish_claim((select data from worker_calls where key='mismatch'),false)->>'status','completed','actual comparison mismatch completes operational job');
select is((select status::text from financial_ops.payout_completion_assertions),'correction_required','first mismatch delegates frozen correction lifecycle');
insert into stages values('correction',pg_temp.stage_request('96000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000501','correct',(select (data->>'payout_assertion_id')::uuid from stages where key='result')));
select pg_temp.finalize_stage('96000000-0000-0000-0000-000000000002');
select is((select count(*)::integer from internal.payout_verification_jobs),2,'new correction revision gets a separate frozen job');
select is(pg_temp.finish_claim((select data from worker_calls where key='mismatch'),false)->>'reused','true','delayed committed first revision result replays only itself');
select is((select current_revision_number::integer from financial_ops.payout_completion_assertions),2,'first revision replay cannot alter current revision');
insert into worker_calls values('match',command_api.claim_payout_verification('98000000-0000-0000-0000-000000000001'));
select throws_ok($$select command_api.finish_payout_verification((select (data->>'jobId')::uuid from worker_calls where key='match'),'98000000-0000-0000-0000-000000000001',(select (data->>'leaseToken')::uuid from worker_calls where key='match'),(select (data->>'revisionId')::uuid from worker_calls where key='mismatch'),pg_temp.receipt_facts((select data from worker_calls where key='match')),'[]','openai','test-v1')$$,'42501','active verification lease is required','another revision cannot finish current job');
select is(pg_temp.finish_claim((select data from worker_calls where key='match'))->>'status','completed','strict exact receipt match completes through canonical helper');
select is((select status::text from financial_ops.withdrawal_requests where id='92000000-0000-0000-0000-000000000007'),'completed','verified payout posts canonical completion');
select is((select status::text from financial_ops.funding_reservations where withdrawal_id='92000000-0000-0000-0000-000000000007'),'consumed','verified payout consumes reservation once');
select is(pg_temp.finish_claim((select data from worker_calls where key='match'))->>'reused','true','lost successful response recoverable after terminal lease cleared');
select is((select count(*)::integer from evidence.verification_attempts),2,'match replay adds no verification attempt');
select is(pg_temp.retry_job('97000000-0000-0000-0000-000000000001')->>'reused','true','committed recovery receipt survives later financial completion');
select throws_ok($$delete from internal.payout_verification_results$$,'42501',null,'verification receipts retained immutable');

-- A delayed, uncommitted revision-one worker must never decide revision two.
insert into financial_ops.funding_reservations(withdrawal_id,ledger_account_id,amount)
values('92000000-0000-0000-0000-000000000008','83000000-0000-0000-0000-000000000501',10.01);
select financial_ops.approve_withdrawal('95000000-0000-0000-0000-000000000008','92000000-0000-0000-0000-000000000008','00000000-0000-0000-0000-000000000501');
select pg_temp.stage_request('96000000-0000-0000-0000-000000000008','00000000-0000-0000-0000-000000000501','submit',null,'92000000-0000-0000-0000-000000000008');
select pg_temp.finalize_stage('96000000-0000-0000-0000-000000000008');
insert into worker_calls values('stale',command_api.claim_payout_verification('98000000-0000-0000-0000-000000000001'));
-- Simulate another trusted verifier winning before the old worker returns.
select financial_ops.record_payout_verification('97000000-0000-0000-0000-000000000008',(select (data->>'assertionId')::uuid from worker_calls where key='stale'),
 pg_temp.receipt_facts((select data from worker_calls where key='stale'),false),'["amount_mismatch"]','openai','test-v1');
select pg_temp.stage_request('96000000-0000-0000-0000-000000000009','00000000-0000-0000-0000-000000000501','correct',
 (select (data->>'assertionId')::uuid from worker_calls where key='stale'),'92000000-0000-0000-0000-000000000008');
select pg_temp.finalize_stage('96000000-0000-0000-0000-000000000009');
select is(pg_temp.finish_claim((select data from worker_calls where key='stale'))->>'status','obsolete','late first revision cannot complete corrected payout');
select is((select status::text from financial_ops.withdrawal_requests where id='92000000-0000-0000-0000-000000000008'),'approved','obsolete success creates no ledger completion');
select is((select status::text from financial_ops.payout_completion_assertions where withdrawal_id='92000000-0000-0000-0000-000000000008'),'submitted','old revision cannot consume correction revision');
select is(pg_temp.finish_claim((select data from worker_calls where key='stale'))->>'reused','true','obsolete completion acknowledgement is stable');
insert into worker_calls values('second-mismatch',command_api.claim_payout_verification('98000000-0000-0000-0000-000000000001'));
select pg_temp.finish_claim((select data from worker_calls where key='second-mismatch'),false);
select is((select status::text from financial_ops.payout_completion_assertions where withdrawal_id='92000000-0000-0000-0000-000000000008'),'needs_review','second actual mismatch requires independent review');
select is((select status::text from financial_ops.funding_reservations where withdrawal_id='92000000-0000-0000-0000-000000000008'),'active','review state preserves reservation');
-- Multiple receipts are safely routed through mismatch, never aggregated into a match.
insert into financial_ops.funding_reservations(withdrawal_id,ledger_account_id,amount)
values('92000000-0000-0000-0000-000000000009','83000000-0000-0000-0000-000000000501',10.01);
select financial_ops.approve_withdrawal('95000000-0000-0000-0000-000000000009','92000000-0000-0000-0000-000000000009','00000000-0000-0000-0000-000000000501');
select command_api.request_payout_evidence_upload('96000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000501','92000000-0000-0000-0000-000000000009','submit',null,
 (select facts from evidence.payout_upload_stages where id='96000000-0000-0000-0000-000000000001')||jsonb_build_object('paidAt',
 to_char((select approved_at+interval '1 second' from financial_ops.withdrawal_requests where id='92000000-0000-0000-0000-000000000009') at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')),
 (select jsonb_agg(jsonb_build_object('originalFilename','receipt'||n||'.pdf','mimeType','application/pdf','fileSizeBytes',8,'sha256Hex',repeat('a',64))) from generate_series(1,2) n));
select pg_temp.finalize_stage('96000000-0000-0000-0000-000000000010');
insert into worker_calls values('multiple',command_api.claim_payout_verification('98000000-0000-0000-0000-000000000001'));
select throws_ok($$select pg_temp.finish_claim((select data from worker_calls where key='multiple'))$$,'22023','strict payout verification result is invalid','single receipt result cannot cover multiple verified files');
select lives_ok($$select command_api.finish_payout_verification((select (data->>'jobId')::uuid from worker_calls where key='multiple'),'98000000-0000-0000-0000-000000000001',
 (select (data->>'leaseToken')::uuid from worker_calls where key='multiple'),(select (data->>'revisionId')::uuid from worker_calls where key='multiple'),
 '{"policyVersion":"strict-single-receipt-v1","evidenceCount":2,"extractionSkipped":"multiple_receipts","receiptFacts":[],"checks":{"amount":false,"currency":false,"recipientAccount":false,"recipientName":false,"paymentStatus":false,"paymentDate":false,"confidence":false}}',
 '["ambiguous_evidence"]','openai','test-v1')$$,'multi-receipt ambiguity delegates canonical correction without claiming extraction');
select is((select status::text from financial_ops.payout_completion_assertions where withdrawal_id='92000000-0000-0000-0000-000000000009'),'correction_required','ambiguous evidence never automatically posts');

select * from finish();
rollback;
