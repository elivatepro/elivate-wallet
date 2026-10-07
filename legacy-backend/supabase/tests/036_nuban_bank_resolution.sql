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

insert into ledger.currency_definitions(currency_code,minor_unit_scale) values('NGN',2);
-- Elevation is valid only while the same user's real Auth session has aal2.
-- This isolated database fixture models the server-verified session, as test020 does.
insert into auth.sessions(id,user_id,aal,created_at,updated_at)
values('99000000-0000-0000-0000-000000000502','00000000-0000-0000-0000-000000000502','aal2',now(),now());
insert into authz.elevated_sessions(session_id,user_id,verified_at,valid_until,factor_method)
values('99000000-0000-0000-0000-000000000502','00000000-0000-0000-0000-000000000502',clock_timestamp(),clock_timestamp()+interval '4 minutes','totp');
select ok(authz.is_elevated_session_valid('99000000-0000-0000-0000-000000000502','00000000-0000-0000-0000-000000000502'),'fixture elevation belongs to a current aal2 Auth session');
create function pg_temp.prepare_bank(k uuid, bank text default '044', account text default '0123456789', existing uuid default null)
returns jsonb language sql as $$ select command_api.prepare_bank_resolution(k,'00000000-0000-0000-0000-000000000502','99000000-0000-0000-0000-000000000502','30000000-0000-0000-0000-000000000502',bank,account,existing); $$;
create function pg_temp.record_bank(k uuid,name text default 'Provider Person') returns jsonb language sql as $$
 select command_api.record_bank_resolution(k,'00000000-0000-0000-0000-000000000502','99000000-0000-0000-0000-000000000502','30000000-0000-0000-0000-000000000502','044','0123456789',name,'Provider Bank'); $$;
create function pg_temp.confirm_bank(k uuid,confirmation uuid) returns jsonb language sql as $$
 select command_api.confirm_bank_account(k,'00000000-0000-0000-0000-000000000502','99000000-0000-0000-0000-000000000502','30000000-0000-0000-0000-000000000502',confirmation,true); $$;
select ok(not has_table_privilege('service_role','financial_ops.bank_resolution_intents','SELECT'),'service cannot read raw proof table');
select ok(not has_function_privilege('authenticated','command_api.record_bank_resolution(uuid,uuid,uuid,uuid,text,text,text,text)','EXECUTE'),'client cannot claim provider verification');
select ok(has_function_privilege('service_role','command_api.confirm_bank_account(uuid,uuid,uuid,uuid,uuid,boolean)','EXECUTE'),'service narrow confirmation allowed');
select throws_ok($$ select command_api.prepare_bank_resolution('98000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000502',null,'30000000-0000-0000-0000-000000000502','044','0123456789') $$,'P0401',null,'lookup requires fresh step-up before external provider');
select throws_ok($$ select command_api.prepare_bank_resolution('98000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000501','99000000-0000-0000-0000-000000000502','30000000-0000-0000-0000-000000000502','044','0123456789') $$,'42501','active own-wallet membership is required','actor cannot borrow member context');
select is(pg_temp.prepare_bank('98000000-0000-0000-0000-000000000001')->>'resolved','false','intent alone is not trusted resolution');
select is((select count(*)::integer from financial_ops.payout_accounts),0,'lookup creates no reusable account before confirmation');
select is(pg_temp.record_bank('98000000-0000-0000-0000-000000000001')->>'accountHolderName','Provider Person','trusted result persists provider name');
select is(pg_temp.record_bank('98000000-0000-0000-0000-000000000001','Different Provider Person')->>'accountHolderName','Provider Person','first resolved name cannot be replaced on retry');
select throws_ok($$ select pg_temp.prepare_bank('98000000-0000-0000-0000-000000000001','033') $$,'23505','bank resolution key has different account intent','same key cannot change bank intent');
select throws_ok($$ update financial_ops.bank_resolution_intents set account_holder_name='Changed' $$,'55000','bank resolution intent and verified proof are immutable','resolved proof immutable');
select throws_ok($$ select command_api.record_bank_resolution('98000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000502','99000000-0000-0000-0000-000000000502','30000000-0000-0000-0000-000000000502','033','0123456789','Name','Bank') $$,'22023','trusted bank resolution does not match account intent','provider result cannot target different bank');
select is(pg_temp.confirm_bank('98000000-0000-0000-0000-000000000001','98000000-0000-0000-0000-000000000002')->>'verification_status','verified','name confirmation atomically creates verified destination');
select is((select account_holder_name from financial_ops.payout_accounts),'Provider Person','confirmed destination uses stored provider name');
select is((select verification_method from financial_ops.payout_accounts),'nuban','method explicit');
select is((select account_reference from financial_ops.payout_accounts),'0123456789','leading zero preserved');
select is(pg_temp.confirm_bank('98000000-0000-0000-0000-000000000001','98000000-0000-0000-0000-000000000002')->>'replayed','true','same confirmation key reuses result');
select is((select count(*)::integer from financial_ops.payout_accounts),1,'retry no duplicate account');
select is((select count(*)::integer from authz.security_audit_events where event_type='payout_account_verified'),1,'verification audited once');
select ok(not exists(select 1 from internal.outbox_events where payload::text like '%0123456789%' or payload::text like '%Provider Person%'),'sensitive account and name excluded from outbox');
select throws_ok($$ select pg_temp.confirm_bank('98000000-0000-0000-0000-000000000001','98000000-0000-0000-0000-000000000003') $$,'23505','bank resolution already has a confirmation key','different confirmation key cannot silently replay');
-- Stored pending record path derives the account identifiers, never changes its number.
insert into financial_ops.payout_accounts(id,wallet_id,owner_user_id,country_code,payout_currency,payout_rail,institution_code,institution_name,account_reference,account_holder_name,verification_status)
values('97000000-0000-0000-0000-000000000002','60000000-0000-0000-0000-000000000502','00000000-0000-0000-0000-000000000502','NG','NGN','bank_transfer','044','Typed Bank','0123456789','Typed Person','pending');
select is(pg_temp.prepare_bank('98000000-0000-0000-0000-000000000004',null,null,'97000000-0000-0000-0000-000000000002')->>'accountNumber','0123456789','stored pending account drives lookup');
select pg_temp.record_bank('98000000-0000-0000-0000-000000000004');
select is(pg_temp.confirm_bank('98000000-0000-0000-0000-000000000004','98000000-0000-0000-0000-000000000005')->>'payout_account_id','97000000-0000-0000-0000-000000000002','pending record verified in place');
select is((select account_holder_name from financial_ops.payout_accounts where id='97000000-0000-0000-0000-000000000002'),'Provider Person','typed pending name replaced only by trusted result');
select is((select count(*)::integer from financial_ops.payout_accounts),2,'pending verification creates no replacement number');
-- Synthetic expired proof models recovery, not a live financial mutation.
insert into financial_ops.bank_resolution_intents(id,actor_user_id,membership_id,wallet_id,bank_code,account_number,created_at,expires_at)
values('98000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000502','30000000-0000-0000-0000-000000000502','60000000-0000-0000-0000-000000000502','044','0123456789',clock_timestamp()-interval '16 minutes',clock_timestamp()-interval '1 minute');
select is(pg_temp.prepare_bank('98000000-0000-0000-0000-000000000006')->>'expired','true','authoritative expired intent permits frontend renewal');
select throws_ok($$ select pg_temp.confirm_bank('98000000-0000-0000-0000-000000000006','98000000-0000-0000-0000-000000000007') $$,'55000','bank resolution has expired','expired unconfirmed proof cannot verify account');
select throws_ok($$ select command_api.prepare_bank_resolution('98000000-0000-0000-0000-000000000008','00000000-0000-0000-0000-000000000502','99000000-0000-0000-0000-000000000502','30000000-0000-0000-0000-000000000502','044','0123456789',null,'US','NGN','bank_transfer') $$,'22023','supported bank account selection is required','unsupported country cannot falsely verify');
-- A confirmation committed before expiry is recoverable afterwards.
insert into financial_ops.bank_resolution_intents(id,actor_user_id,membership_id,wallet_id,bank_code,account_number,account_holder_name,institution_name,resolved_at,created_at,expires_at,confirmation_key,result_payout_account_id)
select '98000000-0000-0000-0000-000000000009','00000000-0000-0000-0000-000000000502','30000000-0000-0000-0000-000000000502','60000000-0000-0000-0000-000000000502','044','0123456789','Provider Person','Provider Bank',clock_timestamp()-interval '15 minutes',clock_timestamp()-interval '16 minutes',clock_timestamp()-interval '1 minute','98000000-0000-0000-0000-000000000010',result_payout_account_id
from financial_ops.bank_resolution_intents where id='98000000-0000-0000-0000-000000000001';
select is(pg_temp.confirm_bank('98000000-0000-0000-0000-000000000009','98000000-0000-0000-0000-000000000010')->>'replayed','true','committed confirmation survives proof expiry under current authority');
select is(pg_temp.prepare_bank('98000000-0000-0000-0000-000000000009')->>'expired','false','committed result takes precedence over expiry');
-- Expired elevated window returns actionable step-up even with a real session ID.
update authz.elevated_sessions set verified_at=clock_timestamp()-interval '6 minutes',valid_until=clock_timestamp()-interval '2 minutes' where session_id='99000000-0000-0000-0000-000000000502';
select throws_ok($$ select pg_temp.prepare_bank('98000000-0000-0000-0000-000000000001') $$,'P0401','recent authenticator verification is required','expired session replay requires fresh authenticator');
update authz.elevated_sessions set verified_at=clock_timestamp(),valid_until=clock_timestamp()+interval '4 minutes' where session_id='99000000-0000-0000-0000-000000000502';
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000501',true);
select throws_ok($$ select pg_temp.prepare_bank('98000000-0000-0000-0000-000000000001') $$,'42501','financial command actor does not match the authenticated user','actor mismatch denied on replay');
select set_config('request.jwt.claim.sub','',true);
update public.user_accounts set status='suspended' where user_id='00000000-0000-0000-0000-000000000502';
select throws_ok($$ select pg_temp.confirm_bank('98000000-0000-0000-0000-000000000001','98000000-0000-0000-0000-000000000002') $$,'42501','active own-wallet membership is required','finalized replay still checks current account authority');
select * from finish();
rollback;
