begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();
select ok(not has_function_privilege('anon','read_api.invitation_preview(bytea)','EXECUTE'),'anon cannot call preview RPC');
select ok(not has_function_privilege('authenticated','read_api.invitation_preview(bytea)','EXECUTE'),'authenticated cannot call preview RPC');
select ok(has_function_privilege('service_role','read_api.invitation_preview(bytea)','EXECUTE'),'trusted service can call minimal preview');
select ok(not has_schema_privilege('anon','read_api','USAGE'),'anon cannot access read schema');
select ok(not has_schema_privilege('authenticated','read_api','USAGE'),'authenticated cannot access read schema');
select ok(not has_schema_privilege('service_role','internal','USAGE'),'private domain remains unavailable');
select ok((select prosecdef from pg_proc where oid='read_api.invitation_preview(bytea)'::regprocedure),'preview pins definer privileges');
select ok((select proconfig @> array['search_path=""'] from pg_proc where oid='read_api.invitation_preview(bytea)'::regprocedure),'preview uses empty search path');
insert into public.tenants(id,name) values('00000000-0000-0000-0000-000000000d01','Preview test');
insert into public.offices(id,tenant_id,parent_office_id,office_type,name) values
('00000000-0000-0000-0000-000000000d11','00000000-0000-0000-0000-000000000d01',null,'world_team','World'),
('00000000-0000-0000-0000-000000000d12','00000000-0000-0000-0000-000000000d01','00000000-0000-0000-0000-000000000d11','director','Director'),
('00000000-0000-0000-0000-000000000d13','00000000-0000-0000-0000-000000000d01','00000000-0000-0000-0000-000000000d12','team_leader','Team');
insert into public.invitations(id,tenant_id,office_id,role_key,email,token_digest,expires_at)
values('00000000-0000-0000-0000-000000000d21','00000000-0000-0000-0000-000000000d01','00000000-0000-0000-0000-000000000d13','member','invited@example.test',extensions.digest('preview-pending','sha256'),'2099-01-01');
set local role service_role;
select is(read_api.invitation_preview(extensions.digest('preview-pending','sha256')),'{"email":"invited@example.test"}'::jsonb,'valid pending token returns only recipient');
select is(read_api.invitation_preview(extensions.digest('preview-unknown','sha256')),null::jsonb,'unknown token has no recipient');
select is(read_api.invitation_preview(null),null::jsonb,'null digest has no recipient');
select is(read_api.invitation_preview(decode('01','hex')),null::jsonb,'invalid digest size has no recipient');
reset role;
update public.invitations set expires_at=statement_timestamp() where id='00000000-0000-0000-0000-000000000d21';
select is(read_api.invitation_preview(extensions.digest('preview-pending','sha256')),null::jsonb,'expired pending token has no recipient');
update public.invitations set expires_at='2099-01-01',status='revoked' where id='00000000-0000-0000-0000-000000000d21';
select is(read_api.invitation_preview(extensions.digest('preview-pending','sha256')),null::jsonb,'revoked token has no recipient');
update public.invitations set status='expired' where id='00000000-0000-0000-0000-000000000d21';
select is(read_api.invitation_preview(extensions.digest('preview-pending','sha256')),null::jsonb,'expired status has no recipient');
update public.invitations set status='pending' where id='00000000-0000-0000-0000-000000000d21';
update public.tenants set status='suspended' where id='00000000-0000-0000-0000-000000000d01';
select is(read_api.invitation_preview(extensions.digest('preview-pending','sha256')),null::jsonb,'suspended network has no preview');
update public.tenants set status='deactivated' where id='00000000-0000-0000-0000-000000000d01';
select is(read_api.invitation_preview(extensions.digest('preview-pending','sha256')),null::jsonb,'deactivated network has no preview');
update public.tenants set status='active' where id='00000000-0000-0000-0000-000000000d01';
select is((select status::text from public.invitations where id='00000000-0000-0000-0000-000000000d21'),'pending','preview never consumes invitation');
select is((select count(*) from public.memberships where tenant_id='00000000-0000-0000-0000-000000000d01'),0::bigint,'preview never creates membership');
update public.offices set status='closed' where id='00000000-0000-0000-0000-000000000d13';
select is(read_api.invitation_preview(extensions.digest('preview-pending','sha256')),null::jsonb,'closed office has no preview');
update public.offices set status='active' where id='00000000-0000-0000-0000-000000000d13';
insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data,email_confirmed_at)
values('00000000-0000-0000-0000-000000000d31','authenticated','authenticated','invited@example.test','{}','{}',statement_timestamp());
insert into public.user_accounts(user_id) values('00000000-0000-0000-0000-000000000d31');
select is(read_api.invitation_preview(extensions.digest('preview-pending','sha256')),'{"email":"invited@example.test"}'::jsonb,'account existence does not change minimal preview');
insert into public.memberships(id,tenant_id,user_id,office_id,role_key)
values('00000000-0000-0000-0000-000000000d41','00000000-0000-0000-0000-000000000d01','00000000-0000-0000-0000-000000000d31','00000000-0000-0000-0000-000000000d13','member');
update public.invitations set status='accepted',accepted_user_id='00000000-0000-0000-0000-000000000d31',accepted_membership_id='00000000-0000-0000-0000-000000000d41'
where id='00000000-0000-0000-0000-000000000d21';
select is(read_api.invitation_preview(extensions.digest('preview-pending','sha256')),null::jsonb,'accepted token has no preview');
select * from finish();
rollback;
