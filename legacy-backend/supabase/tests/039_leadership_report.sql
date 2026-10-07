begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data) values
 ('00000000-0000-0000-0000-000000000701','authenticated','authenticated','report-leader@example.test','{}','{}'),
 ('00000000-0000-0000-0000-000000000702','authenticated','authenticated','report-member@example.test','{}','{}');
insert into public.user_accounts(user_id) values
 ('00000000-0000-0000-0000-000000000701'),('00000000-0000-0000-0000-000000000702');
insert into public.tenants(id,name) values
 ('10000000-0000-0000-0000-000000000701','Report tenant'),('10000000-0000-0000-0000-000000000702','Excluded tenant');
insert into public.offices(id,tenant_id,office_type,name) values
 ('20000000-0000-0000-0000-000000000701','10000000-0000-0000-0000-000000000701','world_team','Report office'),
 ('20000000-0000-0000-0000-000000000702','10000000-0000-0000-0000-000000000702','world_team','Excluded office');
insert into public.offices(id,tenant_id,parent_office_id,office_type,name) values
 ('20000000-0000-0000-0000-000000000703','10000000-0000-0000-0000-000000000701','20000000-0000-0000-0000-000000000701','director','Report directorate'),
 ('20000000-0000-0000-0000-000000000704','10000000-0000-0000-0000-000000000701','20000000-0000-0000-0000-000000000703','team_leader','Report team'),
 ('20000000-0000-0000-0000-000000000705','10000000-0000-0000-0000-000000000702','20000000-0000-0000-0000-000000000702','director','Excluded directorate'),
 ('20000000-0000-0000-0000-000000000706','10000000-0000-0000-0000-000000000702','20000000-0000-0000-0000-000000000705','team_leader','Excluded team');
insert into public.memberships(id,tenant_id,user_id,office_id,role_key,is_primary) values
 ('30000000-0000-0000-0000-000000000701','10000000-0000-0000-0000-000000000701','00000000-0000-0000-0000-000000000701','20000000-0000-0000-0000-000000000701','world_team_member',true),
 ('30000000-0000-0000-0000-000000000702','10000000-0000-0000-0000-000000000701','00000000-0000-0000-0000-000000000702','20000000-0000-0000-0000-000000000704','member',true),
 ('30000000-0000-0000-0000-000000000703','10000000-0000-0000-0000-000000000702','00000000-0000-0000-0000-000000000702','20000000-0000-0000-0000-000000000702','world_team_member',false);
select authz.seed_tenant_role_permissions('10000000-0000-0000-0000-000000000701');
insert into public.wallets(id,owner_user_id) values('60000000-0000-0000-0000-000000000702','00000000-0000-0000-0000-000000000702');
insert into public.pocket_definitions(pocket_key,display_name,sort_order) values('report_main','Report main',701);
insert into ledger.currency_definitions(currency_code,minor_unit_scale) values('NGN',2),('EUR',2);
insert into ledger.ledger_accounts(id,account_class,currency_code,wallet_id,tenant_id,office_id,membership_id,owner_user_id,pocket_key) values
 ('83000000-0000-0000-0000-000000000701','member_value','NGN','60000000-0000-0000-0000-000000000702','10000000-0000-0000-0000-000000000701','20000000-0000-0000-0000-000000000704','30000000-0000-0000-0000-000000000702','00000000-0000-0000-0000-000000000702','report_main'),
 ('83000000-0000-0000-0000-000000000702','member_value','EUR','60000000-0000-0000-0000-000000000702','10000000-0000-0000-0000-000000000702','20000000-0000-0000-0000-000000000702','30000000-0000-0000-0000-000000000703','00000000-0000-0000-0000-000000000702','report_main');

select ok(not has_function_privilege('anon','read_api.leadership_report(uuid,uuid,date,date,text)','EXECUTE'),'anonymous direct report denied');
select ok(not has_function_privilege('authenticated','read_api.leadership_report(uuid,uuid,date,date,text)','EXECUTE'),'authenticated direct report denied');
select ok(has_function_privilege('service_role','read_api.leadership_report(uuid,uuid,date,date,text)','EXECUTE'),'service transport allowed');
select throws_ok($$select read_api.leadership_report('00000000-0000-0000-0000-000000000702','30000000-0000-0000-0000-000000000702','2026-10-01','2026-10-04',null)$$,'42501','active leadership workspace is required','plain member rejected');
select throws_ok($$select read_api.leadership_report('00000000-0000-0000-0000-000000000701','30000000-0000-0000-0000-000000000701','2026-10-05','2026-10-04',null)$$,'22023','report query is invalid','reversed period rejected');
select ok(read_api.leadership_report('00000000-0000-0000-0000-000000000701','30000000-0000-0000-0000-000000000701','2026-10-01','2026-10-04',null)->'currencies' ? 'NGN','authorized context included');
select ok(not (read_api.leadership_report('00000000-0000-0000-0000-000000000701','30000000-0000-0000-0000-000000000701','2026-10-01','2026-10-04',null)->'currencies' ? 'EUR'),'other tenant context excluded');
select * from finish();
rollback;
