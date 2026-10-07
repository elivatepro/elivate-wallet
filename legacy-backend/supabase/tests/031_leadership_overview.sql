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

select is(read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->>'financial_access','true','authorized tenant with no financial source remains accessible');
select is(jsonb_array_length(read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->'currencies'),0,'authorized empty tenant is not populated with synthetic currency totals');

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
 from generate_series(1,7) n;

-- Same global Wallet holds a foreign provenance segment; it cannot leak.
insert into public.tenants(id,name) values('10000000-0000-0000-0000-000000000601','Foreign Dashboard Tenant');
insert into public.offices(id,tenant_id,office_type,name) values('20000000-0000-0000-0000-000000000601','10000000-0000-0000-0000-000000000601','world_team','Foreign World');
insert into public.offices(id,tenant_id,parent_office_id,office_type,name) values('20000000-0000-0000-0000-000000000602','10000000-0000-0000-0000-000000000601','20000000-0000-0000-0000-000000000601','director','Foreign Director');
insert into public.offices(id,tenant_id,parent_office_id,office_type,name) values('20000000-0000-0000-0000-000000000603','10000000-0000-0000-0000-000000000601','20000000-0000-0000-0000-000000000602','team_leader','Foreign Team');
insert into public.memberships(id,tenant_id,user_id,office_id,role_key,is_primary) values('30000000-0000-0000-0000-000000000601','10000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000502','20000000-0000-0000-0000-000000000603','member',false);
insert into ledger.currency_definitions(currency_code,minor_unit_scale) values('EUR',2);
insert into ledger.ledger_accounts(id,account_class,currency_code,wallet_id,tenant_id,office_id,membership_id,owner_user_id,pocket_key)
values('83000000-0000-0000-0000-000000000601','member_value','EUR','60000000-0000-0000-0000-000000000502','10000000-0000-0000-0000-000000000601','20000000-0000-0000-0000-000000000603','30000000-0000-0000-0000-000000000601','00000000-0000-0000-0000-000000000502','operations_main');

-- A genuine ordinary Member cannot edit tenant brand settings, even through
-- trusted transport; missing elevation must not disguise missing permission.
select is((authz.authorize('00000000-0000-0000-0000-000000000502',null,'manage_tenant_configuration','10000000-0000-0000-0000-000000000501')).decision::text,'DENY'::text,'Member brand editing denied before step-up');
select throws_ok($$select command_api.update_team_configuration(
 '93000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000502','94000000-0000-0000-0000-000000000502',
 '10000000-0000-0000-0000-000000000501','Changed Team',null,null,null,null,'en-NG','Africa/Lagos',
 null,null,null,null,null,null,null,'Member mutation test')$$,'42501',null,'trusted brand wrapper rejects genuine Member actor');
select is((select count(*)::integer from tenant_config.configuration_revisions where tenant_id='10000000-0000-0000-0000-000000000501'),0,'denied Member branding creates no revision');

create temporary table overview_result as select read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503') as data;
select ok(not has_function_privilege('anon','read_api.leadership_overview(uuid,uuid)','EXECUTE'),'anonymous overview denied');
select ok(not has_function_privilege('authenticated','read_api.leadership_overview(uuid,uuid)','EXECUTE'),'authenticated direct overview denied');
select ok(has_function_privilege('service_role','read_api.leadership_overview(uuid,uuid)','EXECUTE'),'trusted service transport allowed');
select ok((select (data->>'financial_access')::boolean from overview_result),'President report is available');
select is((select data->'members'->>'active' from overview_result),'1','counts ordinary member memberships only');
select is((select count(*)::integer from overview_result,jsonb_array_elements(data->'currencies')) ,2,'currencies remain separate including funded-source zero USD');
select is((select (currency->>'monthly_income')::numeric from overview_result,jsonb_array_elements(data->'currencies') currency where currency->>'currency_code'='NGN'),700.07::numeric,'monthly income includes all seven exact records');
select is((select (currency->>'posted_balance')::numeric from overview_result,jsonb_array_elements(data->'currencies') currency where currency->>'currency_code'='NGN'),700.07::numeric,'posted balance is ledger-derived independent of pending requests');
select is((select currency->>'requested_count' from overview_result,jsonb_array_elements(data->'currencies') currency where currency->>'currency_code'='NGN'),'6','request count is not truncated to activity limit');
select is((select (currency->>'requested_amount')::numeric from overview_result,jsonb_array_elements(data->'currencies') currency where currency->>'currency_code'='NGN'),60.06::numeric,'request amount exact over all rows');
select is((select currency->>'approved_count' from overview_result,jsonb_array_elements(data->'currencies') currency where currency->>'currency_code'='NGN'),'1','approved queue counted separately');
select is((select (currency->>'approved_amount')::numeric from overview_result,jsonb_array_elements(data->'currencies') currency where currency->>'currency_code'='NGN'),10.01::numeric,'approved queue exact amount');
select ok(not exists(select 1 from overview_result,jsonb_array_elements(data->'currencies') currency where currency->>'currency_code'='EUR'),'foreign provenance currency excluded despite common global Wallet');
select throws_ok($$select read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000601')$$,'42501','active President workspace is required','foreign membership selection rejected');
select is((select jsonb_array_length(data->'recent_income') from overview_result),5,'recent income is bounded separately from totals');
select is((select jsonb_array_length(data->'recent_withdrawals') from overview_result),5,'recent withdrawals bounded separately from totals');
select throws_ok($$select read_api.leadership_overview('00000000-0000-0000-0000-000000000502','30000000-0000-0000-0000-000000000503')$$,'42501','active President workspace is required','member cannot borrow President selection');
select throws_ok($$select read_api.leadership_overview('00000000-0000-0000-0000-000000000501','30000000-0000-0000-0000-000000000501')$$,'42501','active President workspace is required','other leadership not authorized by new President-only read');

insert into authz.access_assignments(id,tenant_id,subject_user_id,created_by_user_id,reason)
values('40000000-0000-0000-0000-000000000511','10000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000503','00000000-0000-0000-0000-000000000503','Dashboard scoped deny fixture');
-- A role-policy absence is not an explicit deny: narrow grants remain valid.
insert into public.wallets(id,owner_user_id) values('60000000-0000-0000-0000-000000000504','00000000-0000-0000-0000-000000000504');
insert into ledger.ledger_accounts(id,account_class,currency_code,wallet_id,tenant_id,office_id,membership_id,owner_user_id,pocket_key)
values('83000000-0000-0000-0000-000000000604','member_value','EUR','60000000-0000-0000-0000-000000000504','10000000-0000-0000-0000-000000000501','20000000-0000-0000-0000-000000000502','30000000-0000-0000-0000-000000000504','00000000-0000-0000-0000-000000000504','operations_main');
update authz.tenant_role_permissions set allowed=false where tenant_id='10000000-0000-0000-0000-000000000501' and role_key='president_team_member' and permission_key='view_scoped_financial_reports';
select is(read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->>'financial_access','false','disabled role report policy without grant denies financial access');
-- Create grants while the creator holds reporting authority, then remove the
-- general policy to exercise retained scoped access through valid rules.
update authz.tenant_role_permissions set allowed=true where tenant_id='10000000-0000-0000-0000-000000000501' and role_key='president_team_member' and permission_key='view_scoped_financial_reports';
insert into authz.access_rules(id,tenant_id,assignment_id,permission_key,effect,scope_type,scope_membership_id)
values('50000000-0000-0000-0000-000000000514','10000000-0000-0000-0000-000000000501','40000000-0000-0000-0000-000000000511','view_scoped_financial_reports','allow','member','30000000-0000-0000-0000-000000000502');
update authz.tenant_role_permissions set allowed=false where tenant_id='10000000-0000-0000-0000-000000000501' and role_key='president_team_member' and permission_key='view_scoped_financial_reports';
select is(read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->>'financial_access','true','member-scoped grant works without tenant-wide role allow');
select is(jsonb_array_length(read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->'currencies'),2,'member-scoped grant excludes unrelated and foreign EUR contexts');
select is(jsonb_array_length(read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->'recent_income'),5,'member-scoped grant returns permitted activity');
update authz.access_rules set revoked_at=clock_timestamp(),revoked_by_user_id='00000000-0000-0000-0000-000000000503' where id='50000000-0000-0000-0000-000000000514';
update authz.tenant_role_permissions set allowed=true where tenant_id='10000000-0000-0000-0000-000000000501' and role_key='president_team_member' and permission_key='view_scoped_financial_reports';
insert into authz.access_rules(id,tenant_id,assignment_id,permission_key,effect,scope_type,scope_office_id)
values('50000000-0000-0000-0000-000000000515','10000000-0000-0000-0000-000000000501','40000000-0000-0000-0000-000000000511','view_scoped_financial_reports','allow','office_subtree','20000000-0000-0000-0000-000000000503');
update authz.tenant_role_permissions set allowed=false where tenant_id='10000000-0000-0000-0000-000000000501' and role_key='president_team_member' and permission_key='view_scoped_financial_reports';
select is(read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->>'financial_access','true','office-scoped grant works without tenant-wide role allow');
select is(jsonb_array_length(read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->'currencies'),2,'office-scoped grant excludes another office and foreign contexts');
-- Keep the scoped grant while adding a matching deny: deny must still win.
insert into authz.access_rules(id,tenant_id,assignment_id,permission_key,effect,scope_type,scope_membership_id)
values('50000000-0000-0000-0000-000000000511','10000000-0000-0000-0000-000000000501','40000000-0000-0000-0000-000000000511','view_scoped_financial_reports','deny','member','30000000-0000-0000-0000-000000000502');
select is(jsonb_array_length(read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->'currencies'),0,'explicit member deny removes balances and totals');
select is(jsonb_array_length(read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->'recent_income'),0,'explicit member deny removes recent income');
select is(jsonb_array_length(read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->'recent_withdrawals'),0,'explicit member deny removes withdrawal activity');
update authz.access_rules set revoked_at=clock_timestamp(), revoked_by_user_id='00000000-0000-0000-0000-000000000503'
 where id='50000000-0000-0000-0000-000000000511';
insert into authz.access_rules(id,tenant_id,assignment_id,permission_key,effect,scope_type,scope_office_id)
values('50000000-0000-0000-0000-000000000513','10000000-0000-0000-0000-000000000501','40000000-0000-0000-0000-000000000511','view_scoped_financial_reports','deny','office_subtree','20000000-0000-0000-0000-000000000502');
select is(jsonb_array_length(read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->'currencies'),0,'ancestor-office explicit deny removes descendant totals');
select is(jsonb_array_length(read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->'recent_withdrawals'),0,'ancestor-office explicit deny removes descendant recent withdrawals');
insert into authz.access_rules(id,tenant_id,assignment_id,permission_key,effect,scope_type)
values('50000000-0000-0000-0000-000000000512','10000000-0000-0000-0000-000000000501','40000000-0000-0000-0000-000000000511','view_scoped_financial_reports','deny','tenant');
select is(read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->>'financial_access','false','tenant denial is distinguished from financial zero');
select is(read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')->'members'->>'active','1','financial denial does not fabricate zero member counts');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000502',true);
select throws_ok($$select read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')$$,'42501','financial command actor does not match the authenticated user','verified Member cannot substitute President actor');
select set_config('request.jwt.claim.sub','',true);
update public.tenants set status='suspended' where id='10000000-0000-0000-0000-000000000501';
select throws_ok($$select read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')$$,'42501','active President workspace is required','stopped tenant cannot read overview');
update public.tenants set status='active' where id='10000000-0000-0000-0000-000000000501';
update public.user_accounts set status='suspended' where user_id='00000000-0000-0000-0000-000000000503';
select throws_ok($$select read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')$$,'42501','active President workspace is required','suspended account cannot access dashboard');
update public.user_accounts set status='active' where user_id='00000000-0000-0000-0000-000000000503';
update public.memberships set status='suspended' where id='30000000-0000-0000-0000-000000000503';
select throws_ok($$select read_api.leadership_overview('00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503')$$,'42501','active President workspace is required','suspended President cannot read overview');
select * from finish();
rollback;
