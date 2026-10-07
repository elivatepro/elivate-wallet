begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data)
values
 ('00000000-0000-0000-0000-000000000b11','authenticated','authenticated','dev-empty-policy@example.test','{}'::jsonb,'{}'::jsonb),
 ('00000000-0000-0000-0000-000000000b12','authenticated','authenticated','dev-custom-policy@example.test','{}'::jsonb,'{}'::jsonb),
 ('00000000-0000-0000-0000-000000000b13','authenticated','authenticated','unrelated-policy@example.test','{}'::jsonb,'{}'::jsonb);
insert into public.user_accounts(user_id) values
 ('00000000-0000-0000-0000-000000000b11'),
 ('00000000-0000-0000-0000-000000000b12'),
 ('00000000-0000-0000-0000-000000000b13');
update auth.users set email_confirmed_at=clock_timestamp()
 where id in ('00000000-0000-0000-0000-000000000b11','00000000-0000-0000-0000-000000000b12');

create temporary table test_policy_networks(kind text primary key, tenant_id uuid);
insert into test_policy_networks values
 ('empty_development',command_api.bootstrap_development_network('00000000-0000-0000-0000-000000000b11',extensions.digest('development-empty-policy','sha256'),'Empty Development')),
 ('configured_development',command_api.bootstrap_development_network('00000000-0000-0000-0000-000000000b12',extensions.digest('development-configured-policy','sha256'),'Configured Development'));
insert into public.tenants(id,name) values('10000000-0000-0000-0000-000000000b13','Ordinary Unconfigured Tenant');
insert into test_policy_networks values('ordinary','10000000-0000-0000-0000-000000000b13');

-- Store an explicit deny while the creator still holds access-rule authority.
-- Losing tenant defaults must not erase or weaken this separate deny on repair.
insert into authz.access_assignments(id,tenant_id,subject_user_id,created_by_user_id,reason)
select '40000000-0000-0000-0000-000000000b11',tenant_id,
 '00000000-0000-0000-0000-000000000b11','00000000-0000-0000-0000-000000000b11','Test deny preserved by repair'
from test_policy_networks where kind='empty_development';
insert into authz.access_rules(id,tenant_id,assignment_id,permission_key,effect,scope_type)
select '50000000-0000-0000-0000-000000000b11',tenant_id,
 '40000000-0000-0000-0000-000000000b11','invite_members','deny','tenant'
from test_policy_networks where kind='empty_development';

-- Recreate the old bootstrap omission and a deliberately sparse configured policy.
delete from authz.tenant_role_permissions where tenant_id=(select tenant_id from test_policy_networks where kind='empty_development');
delete from authz.tenant_role_permissions where tenant_id=(select tenant_id from test_policy_networks where kind='configured_development')
 and not (role_key='president_team_member' and permission_key='invite_members');
update authz.tenant_role_permissions set allowed=false,
 updated_by='00000000-0000-0000-0000-000000000b12'
 where tenant_id=(select tenant_id from test_policy_networks where kind='configured_development');
create temporary table test_policy_versions as
 select network.kind, tenant.authz_version from test_policy_networks network
 join public.tenants tenant on tenant.id=network.tenant_id;
create temporary table test_policy_user_versions as
 select user_id,authz_version from public.user_accounts
 where user_id in ('00000000-0000-0000-0000-000000000b11','00000000-0000-0000-0000-000000000b12','00000000-0000-0000-0000-000000000b13');
create temporary table test_configured_policy_snapshot as
 select * from authz.tenant_role_permissions
 where tenant_id=(select tenant_id from test_policy_networks where kind='configured_development');

-- Fresh replay records the committed source in the migration history. The test
-- container mounts tests only, so replay those applied statements without a
-- host-file dependency or a duplicate implementation of the repair.
do $replay$
declare
  applied_statements text[];
  applied_statement text;
begin
  select statements into applied_statements
    from supabase_migrations.schema_migrations
   where version = '20261003061135';
  if coalesce(cardinality(applied_statements), 0) = 0 then
    raise exception 'committed policy repair is missing from migration history';
  end if;
  foreach applied_statement in array applied_statements loop
    execute applied_statement;
  end loop;
end;
$replay$;

select is((select count(*)::integer from authz.tenant_role_permissions
 where tenant_id=(select tenant_id from test_policy_networks where kind='empty_development')),
 (select count(*)::integer from authz.default_role_permissions),
 'empty registered development policy receives every default');
select ok(not exists(select role_key,permission_key from authz.default_role_permissions
 except select role_key,permission_key from authz.tenant_role_permissions
 where tenant_id=(select tenant_id from test_policy_networks where kind='empty_development') and allowed),
 'backfill copies exact role defaults with allow state');
select ok(not exists((select * from test_configured_policy_snapshot
 except select * from authz.tenant_role_permissions where tenant_id=(select tenant_id from test_policy_networks where kind='configured_development'))
 union all (select * from authz.tenant_role_permissions where tenant_id=(select tenant_id from test_policy_networks where kind='configured_development')
 except select * from test_configured_policy_snapshot)),
 'nonempty sparse configured policy is unchanged including custom deny and metadata');
select is((select count(*)::integer from authz.tenant_role_permissions
 where tenant_id=(select tenant_id from test_policy_networks where kind='ordinary')),0,
 'ordinary unregistered empty tenant is not repaired');
select is((select tenant.authz_version-before.authz_version from public.tenants tenant
 join test_policy_networks network on network.tenant_id=tenant.id
 join test_policy_versions before on before.kind=network.kind where network.kind='empty_development'),1::bigint,
 'repaired tenant authorization version increments once');
select is((select account.authz_version-before.authz_version from public.user_accounts account
 join test_policy_user_versions before on before.user_id=account.user_id
 where account.user_id='00000000-0000-0000-0000-000000000b11'),1::bigint,
 'current member authorization version increments on repair');
select ok(not exists(select 1 from public.tenants tenant
 join test_policy_networks network on network.tenant_id=tenant.id
 join test_policy_versions before on before.kind=network.kind
 where network.kind<>'empty_development' and tenant.authz_version<>before.authz_version),
 'unmodified tenant authorization versions remain unchanged');
select ok(not exists(select 1 from public.user_accounts account
 join test_policy_user_versions before on before.user_id=account.user_id
 where account.user_id<>'00000000-0000-0000-0000-000000000b11' and account.authz_version<>before.authz_version),
 'unrelated account authorization versions remain unchanged');
select is((select count(*)::integer from authz.security_audit_events
 where event_type='development_network_role_defaults_initialized'
 and tenant_id=(select tenant_id from test_policy_networks where kind='empty_development')),1,
 'repair records exactly one system audit event');
select ok(not exists(select 1 from authz.security_audit_events
 where event_type='development_network_role_defaults_initialized'
 and tenant_id in (select tenant_id from test_policy_networks where kind<>'empty_development')),
 'unmodified tenants receive no repair audit event');
select is((authz.authorize('00000000-0000-0000-0000-000000000b11',null,'invite_members',
 (select tenant_id from test_policy_networks where kind='empty_development'),null,null,null,null,null,null,null)).reason_code,
 'explicit_deny','custom explicit deny still overrides restored default allows');
select is((authz.authorize('00000000-0000-0000-0000-000000000b12',null,'invite_members',
 (select tenant_id from test_policy_networks where kind='configured_development'),null,null,null,null,null,null,null)).decision,
 'DENY'::authz.authorization_decision_state,'nonempty denied invitation policy remains denied');
select ok(not exists(select 1 from commercial.tenant_subscriptions subscription
 where subscription.tenant_id in (select tenant_id from test_policy_networks where kind<>'ordinary')
 and subscription.status<>'suspended'),
 'repair leaves both development subscriptions suspended');
select is((authz.authorize('00000000-0000-0000-0000-000000000b11',null,'record_income',
 (select tenant_id from test_policy_networks where kind='empty_development'),null,null,null,null,null,null,null)).reason_code,
 'commercial_money_movement_restricted','repaired defaults retain financial suspension denial');
select ok(not has_function_privilege('service_role','internal.bootstrap_development_network(uuid,bytea,text)','EXECUTE'),
 'migration retains private helper ACL after replacement');
select ok(has_function_privilege('service_role','command_api.bootstrap_development_network(uuid,bytea,text)','EXECUTE'),
 'existing narrow bootstrap wrapper remains callable by trusted service');

-- Reapplying the data repair finds no candidate and must not bump versions/audit.
do $replay$
declare
  applied_statements text[];
  applied_statement text;
begin
  select statements into applied_statements
    from supabase_migrations.schema_migrations
   where version = '20261003061135';
  if coalesce(cardinality(applied_statements), 0) = 0 then
    raise exception 'committed policy repair is missing from migration history';
  end if;
  foreach applied_statement in array applied_statements loop
    execute applied_statement;
  end loop;
end;
$replay$;
select is((select tenant.authz_version-before.authz_version from public.tenants tenant
 join test_policy_networks network on network.tenant_id=tenant.id
 join test_policy_versions before on before.kind=network.kind where network.kind='empty_development'),1::bigint,
 'repeated repair does not increment tenant authorization again');
select is((select account.authz_version-before.authz_version from public.user_accounts account
 join test_policy_user_versions before on before.user_id=account.user_id
 where account.user_id='00000000-0000-0000-0000-000000000b11'),1::bigint,
 'repeated repair does not increment member authorization again');
select is((select count(*)::integer from authz.security_audit_events
 where event_type='development_network_role_defaults_initialized'
 and tenant_id=(select tenant_id from test_policy_networks where kind='empty_development')),1,
 'repeated repair does not duplicate its system audit event');
select is((select count(*)::integer from authz.tenant_role_permissions
 where tenant_id=(select tenant_id from test_policy_networks where kind='empty_development')),
 (select count(*)::integer from authz.default_role_permissions),
 'repeated repair does not duplicate default policy rows');
select * from finish();
rollback;
