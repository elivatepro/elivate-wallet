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


select ok(not has_table_privilege('service_role','evidence.income_upload_intents','SELECT'),'service cannot read staging receipts directly');
select ok(not has_function_privilege('authenticated','command_api.record_uploaded_income(uuid,uuid,bigint,text,uuid)','EXECUTE'),'clients cannot post through privileged transport');
select ok(has_function_privilege('service_role','command_api.record_uploaded_income(uuid,uuid,bigint,text,uuid)','EXECUTE'),'service has narrow income command');
select ok(not has_function_privilege('anon','read_api.income_targets(uuid,uuid,uuid)','EXECUTE'),'anonymous target reads denied');
select is(jsonb_array_length(read_api.income_targets('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501')->'items'),1,'only authorized target appears');
select is((read_api.income_targets('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501')->'items'->0->'currencies'->0->>'code'),'NGN','only fully provisioned currency appears');
select throws_ok($$select read_api.income_targets('00000000-0000-0000-0000-000000000502','30000000-0000-0000-0000-000000000501')$$,'42501','active workspace is required','cannot borrow another actor workspace');
select lives_ok($$select command_api.request_income_upload('91000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000502','NGN',100.00,'receipt.png','image/png',8,repeat('a',64),'2026-10-01T00:00:00Z','REF-1')$$,'authorized pre-post receipt request');
select is((select count(*) from financial_ops.income_records),0::bigint,'upload request never creates income');
select lives_ok($$select command_api.request_income_upload('91000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000502','NGN',100.00,'receipt.png','image/png',8,repeat('a',64),'2026-10-01T00:00:00Z','REF-1')$$,'identical receipt grant retry is safe');
select throws_ok($$select command_api.request_income_upload('91000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000502','NGN',200.00,'receipt.png','image/png',8,repeat('a',64),'2026-10-01T00:00:00Z','REF-1')$$,'23505','receipt request conflicts','changed amount cannot reuse receipt key');
select throws_ok($$select command_api.income_upload_object('91000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000502')$$,'42501','receipt is not authorized','another actor cannot download receipt');
select throws_ok($$select command_api.record_uploaded_income('91000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000501',8,repeat('b',64))$$,'23514','receipt bytes do not match','tampered bytes cannot post');
select is((select count(*) from financial_ops.income_records),0::bigint,'receipt mismatch leaves no financial effect');
select lives_ok($$select command_api.record_uploaded_income('91000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000501',8,repeat('a',64))$$,'verified receipt posts through canonical income');
select is((select sum(allocated_amount) from financial_ops.income_allocations),100::numeric,'allocation preserves exact income amount');
select is((select count(*) from evidence.financial_operation_evidence),1::bigint,'posted income has mandatory linked evidence');
select is((command_api.record_uploaded_income('91000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000501',8,repeat('a',64))->>'reused')::boolean,true,'posting replay reuses original result');
select is((select count(*) from financial_ops.income_records),1::bigint,'retry never duplicates income');
select is((command_api.income_upload_object('91000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000501')->>'posted')::boolean,true,'lost response can recover original receipt without re-upload');
update public.user_accounts set status='suspended' where user_id='00000000-0000-0000-0000-000000000501';
select throws_ok($$select command_api.income_upload_object('91000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000501')$$,'42501',null,'suspended actor cannot recover receipt');
select throws_ok($$select command_api.record_uploaded_income('91000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000501',8,repeat('a',64))$$,'42501',null,'suspended actor cannot replay financial command');
update public.user_accounts set status='active' where user_id='00000000-0000-0000-0000-000000000501';
update public.memberships set status='suspended' where id='30000000-0000-0000-0000-000000000502';
select throws_ok($$select command_api.record_uploaded_income('91000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000501',8,repeat('a',64))$$,'23514','income target is not eligible','suspended target denies replay');
update public.memberships set status='active' where id='30000000-0000-0000-0000-000000000502';
update public.memberships set status='suspended' where id='30000000-0000-0000-0000-000000000501';
select throws_ok($$select command_api.record_uploaded_income('91000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000501',8,repeat('a',64))$$,'42501',null,'removed leadership scope denies replay');
update public.memberships set status='active' where id='30000000-0000-0000-0000-000000000501';
select is((select count(*) from financial_ops.income_records),1::bigint,'denied replays preserve one original income');

-- A moved membership cannot make old financial provenance belong to a new office.
insert into public.offices(id,tenant_id,parent_office_id,office_type,name) values('20000000-0000-0000-0000-000000000504','10000000-0000-0000-0000-000000000501','20000000-0000-0000-0000-000000000502','team_leader','Other Team');
update public.memberships set office_id='20000000-0000-0000-0000-000000000504',role_key='member' where id='30000000-0000-0000-0000-000000000502';
select throws_ok($$select command_api.income_upload_object('91000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000504')$$,'42501','receipt is not authorized','new office leader cannot borrow prior submitter receipt');
select throws_ok($$select command_api.income_upload_object('91000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000501')$$,'42501',null,'moved membership cannot reinterpret original income office context');
update public.memberships set office_id='20000000-0000-0000-0000-000000000503' where id='30000000-0000-0000-0000-000000000502';
select is((command_api.cancel_income_upload('91000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000501')->>'cancelled')::boolean,false,'discard recovers existing posted income instead of erasing it');
select command_api.request_income_upload('91000000-0000-0000-0000-000000000602','00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000502','NGN',100,'receipt.png','image/png',8,repeat('a',64),'2026-10-01T00:00:00Z');
select is((command_api.cancel_income_upload('91000000-0000-0000-0000-000000000602','00000000-0000-0000-0000-000000000501')->>'cancelled')::boolean,true,'unposted attempt can be discarded safely');
select throws_ok($$select command_api.record_uploaded_income('91000000-0000-0000-0000-000000000602','00000000-0000-0000-0000-000000000501',8,repeat('a',64))$$,'55000','receipt attempt was cancelled','discarded attempt can never post later');
select command_api.request_income_upload('91000000-0000-0000-0000-000000000603','00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000502','NGN',100,'receipt.png','image/png',8,repeat('a',64),'2026-10-01T00:00:00Z');
update evidence.income_upload_intents set expires_at=clock_timestamp()-interval '1 second' where id='91000000-0000-0000-0000-000000000603';
select throws_ok($$select command_api.income_upload_object('91000000-0000-0000-0000-000000000603','00000000-0000-0000-0000-000000000501')$$,'55000','receipt upload expired','expired unposted receipt cannot be downloaded');
select throws_ok($$select command_api.record_uploaded_income('91000000-0000-0000-0000-000000000603','00000000-0000-0000-0000-000000000501',8,repeat('a',64))$$,'55000','receipt upload expired','expired unposted receipt cannot post');
select lives_ok($$select command_api.cancel_income_upload('91000000-0000-0000-0000-000000000603','00000000-0000-0000-0000-000000000501')$$,'expired attempt can be discarded');
insert into public.wallets(id,owner_user_id) values('60000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501');
select throws_ok($$select command_api.request_income_upload('91000000-0000-0000-0000-000000000604','00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501','NGN',100,'receipt.png','image/png',8,repeat('a',64),'2026-10-01T00:00:00Z')$$,'42501',null,'leadership cannot credit own Wallet');
select throws_ok($$select command_api.request_income_upload('91000000-0000-0000-0000-000000000604','00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000503','NGN',100,'receipt.png','image/png',8,repeat('a',64),'2026-10-01T00:00:00Z')$$,'23514','income target is not eligible','President cannot receive income');

insert into public.tenants(id,name) values('10000000-0000-0000-0000-000000000601','Other Network');
insert into public.offices(id,tenant_id,office_type,name) values('20000000-0000-0000-0000-000000000601','10000000-0000-0000-0000-000000000601','world_team','Other World');
insert into public.offices(id,tenant_id,parent_office_id,office_type,name) values('20000000-0000-0000-0000-000000000602','10000000-0000-0000-0000-000000000601','20000000-0000-0000-0000-000000000601','director','Other Director');
insert into public.offices(id,tenant_id,parent_office_id,office_type,name) values('20000000-0000-0000-0000-000000000603','10000000-0000-0000-0000-000000000601','20000000-0000-0000-0000-000000000602','team_leader','Other Team');
insert into public.memberships(id,tenant_id,user_id,office_id,role_key,is_primary) values('30000000-0000-0000-0000-000000000601','10000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000502','20000000-0000-0000-0000-000000000603','member',false);
select authz.seed_tenant_role_permissions('10000000-0000-0000-0000-000000000601');
select throws_ok($$select command_api.request_income_upload('91000000-0000-0000-0000-000000000605','00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000601','NGN',100,'receipt.png','image/png',8,repeat('a',64),'2026-10-01T00:00:00Z')$$,'42501',null,'same global Wallet does not authorize another tenant income');

insert into commercial.tenant_subscriptions(tenant_id,plan_version_id,status,starts_at,status_reason,status_changed_by_user_id,created_by_user_id)
values('10000000-0000-0000-0000-000000000501','c1000000-0000-4000-8000-000000000001','suspended',clock_timestamp(),'test_pause','00000000-0000-0000-0000-000000000503','00000000-0000-0000-0000-000000000503');
select is((read_api.income_targets('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501')->>'restricted')::boolean,true,'subscription restriction gets explicit paused state');
select throws_ok($$select command_api.income_upload_object('91000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000501')$$,'42501',null,'commercial restriction denies posted replay');
select throws_ok($$select command_api.request_income_upload('91000000-0000-0000-0000-000000000604','00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000502','NGN',100,'receipt.png','image/png',8,repeat('a',64),'2026-10-01T00:00:00Z')$$,'42501',null,'commercial restriction denies new income');

select * from finish();
rollback;
