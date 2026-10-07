begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select no_plan();
insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data) values
 ('00000000-0000-0000-0000-000000000801','authenticated','authenticated','access-leader@example.test','{}','{}'),
 ('00000000-0000-0000-0000-000000000802','authenticated','authenticated','access-member@example.test','{}','{}'),
 ('00000000-0000-0000-0000-000000000803','authenticated','authenticated','outside-member@example.test','{}','{}');
insert into public.user_accounts(user_id) values('00000000-0000-0000-0000-000000000801'),('00000000-0000-0000-0000-000000000802'),('00000000-0000-0000-0000-000000000803');
insert into public.tenants(id,name) values('10000000-0000-0000-0000-000000000801','Access tenant'),('10000000-0000-0000-0000-000000000802','Other tenant');
insert into public.offices(id,tenant_id,office_type,name) values('20000000-0000-0000-0000-000000000801','10000000-0000-0000-0000-000000000801','world_team','World'),('20000000-0000-0000-0000-000000000802','10000000-0000-0000-0000-000000000802','world_team','Other world');
insert into public.offices(id,tenant_id,parent_office_id,office_type,name) values
 ('20000000-0000-0000-0000-000000000803','10000000-0000-0000-0000-000000000801','20000000-0000-0000-0000-000000000801','director','Director'),
 ('20000000-0000-0000-0000-000000000804','10000000-0000-0000-0000-000000000801','20000000-0000-0000-0000-000000000803','team_leader','Team');
insert into public.memberships(id,tenant_id,user_id,office_id,role_key,is_primary) values
 ('30000000-0000-0000-0000-000000000801','10000000-0000-0000-0000-000000000801','00000000-0000-0000-0000-000000000801','20000000-0000-0000-0000-000000000801','world_team_member',true),
 ('30000000-0000-0000-0000-000000000802','10000000-0000-0000-0000-000000000801','00000000-0000-0000-0000-000000000802','20000000-0000-0000-0000-000000000804','member',true),
 ('30000000-0000-0000-0000-000000000803','10000000-0000-0000-0000-000000000802','00000000-0000-0000-0000-000000000803','20000000-0000-0000-0000-000000000802','world_team_member',true);
select authz.seed_tenant_role_permissions('10000000-0000-0000-0000-000000000801');
insert into auth.sessions(id,user_id,aal,created_at,updated_at) values('99000000-0000-0000-0000-000000000801','00000000-0000-0000-0000-000000000801','aal2',clock_timestamp(),clock_timestamp());
insert into authz.elevated_sessions(session_id,user_id,verified_at,valid_until,factor_method) values('99000000-0000-0000-0000-000000000801','00000000-0000-0000-0000-000000000801',clock_timestamp(),clock_timestamp()+interval '4 minutes','totp');
select ok(not has_function_privilege('authenticated','command_api.create_access_assignment(uuid,uuid,uuid,uuid,uuid,text,jsonb)','EXECUTE'),'authenticated direct create denied');
select ok(has_function_privilege('service_role','read_api.access_management(uuid,uuid)','EXECUTE'),'service read allowed');
select throws_ok($$select command_api.create_access_assignment(gen_random_uuid(),'00000000-0000-0000-0000-000000000801',gen_random_uuid(),'30000000-0000-0000-0000-000000000801','00000000-0000-0000-0000-000000000802','test','[{"permission_key":"invite_members","effect":"allow","scope_type":"office_subtree","scope_office_id":"20000000-0000-0000-0000-000000000801"}]')$$,'P0401','step_up_required','invalid elevation rejected');
create temporary table access_result(id uuid);
insert into access_result select command_api.create_access_assignment('88000000-0000-0000-0000-000000000801','00000000-0000-0000-0000-000000000801','99000000-0000-0000-0000-000000000801','30000000-0000-0000-0000-000000000801','00000000-0000-0000-0000-000000000802','temporary coverage','[{"permission_key":"invite_members","effect":"allow","scope_type":"office_subtree","scope_office_id":"20000000-0000-0000-0000-000000000801","expires_at":"2099-01-01T00:00:00Z"},{"permission_key":"record_income","effect":"deny","scope_type":"office_subtree","scope_office_id":"20000000-0000-0000-0000-000000000801"}]');
select is((select count(*) from authz.access_rules where assignment_id=(select id from access_result)),2::bigint,'one rule row per permission');
select is(command_api.create_access_assignment('88000000-0000-0000-0000-000000000801','00000000-0000-0000-0000-000000000801','99000000-0000-0000-0000-000000000801','30000000-0000-0000-0000-000000000801','00000000-0000-0000-0000-000000000802','temporary coverage','[{"permission_key":"invite_members","effect":"allow","scope_type":"office_subtree","scope_office_id":"20000000-0000-0000-0000-000000000801","expires_at":"2099-01-01T00:00:00Z"},{"permission_key":"record_income","effect":"deny","scope_type":"office_subtree","scope_office_id":"20000000-0000-0000-0000-000000000801"}]'),(select id from access_result),'idempotent replay returns assignment');
select throws_ok($$select command_api.create_access_assignment(gen_random_uuid(),'00000000-0000-0000-0000-000000000801','99000000-0000-0000-0000-000000000801','30000000-0000-0000-0000-000000000801','00000000-0000-0000-0000-000000000802','bad','[{"permission_key":"manage_security_settings","effect":"allow","scope_type":"office_subtree","scope_office_id":"20000000-0000-0000-0000-000000000801"}]')$$,'22023','permission_not_grantable','protected permission rejected');
select throws_ok($$select command_api.create_access_assignment(gen_random_uuid(),'00000000-0000-0000-0000-000000000801','99000000-0000-0000-0000-000000000801','30000000-0000-0000-0000-000000000801','00000000-0000-0000-0000-000000000803','bad','[{"permission_key":"invite_members","effect":"allow","scope_type":"office_subtree","scope_office_id":"20000000-0000-0000-0000-000000000801"}]')$$,'22023','subject_membership_required','cross-tenant subject rejected');
select is(command_api.revoke_access_assignment('88000000-0000-0000-0000-000000000802','00000000-0000-0000-0000-000000000801','99000000-0000-0000-0000-000000000801','30000000-0000-0000-0000-000000000801',(select id from access_result)),(select id from access_result),'assignment revoked');
select ok((select revoked_at is not null from authz.access_assignments where id=(select id from access_result)),'assignment marked revoked');
select is((select count(*) from authz.security_audit_events where event_type in ('access.assignment_created','access.assignment_revoked') and target_id=(select id from access_result)),2::bigint,'create and revoke audited');
select * from finish();
rollback;
