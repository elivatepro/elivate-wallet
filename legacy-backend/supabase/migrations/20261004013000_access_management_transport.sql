-- Access-rule administration is deliberately service-only. Although the catalog
-- marks manage_access_rules as not requiring elevation, every mutation through
-- this transport is high impact and therefore requires a current elevated session.

create table authz.access_command_idempotency (
  actor_user_id uuid not null references public.user_accounts(user_id) on delete restrict,
  idempotency_key uuid not null,
  command_type text not null check (command_type in ('create','revoke')),
  request_fingerprint text not null,
  assignment_id uuid not null references authz.access_assignments(id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  primary key (actor_user_id,idempotency_key)
);
alter table authz.access_command_idempotency enable row level security;
revoke all on table authz.access_command_idempotency from public,anon,authenticated,service_role;

create function read_api.access_management(p_actor_user_id uuid,p_actor_membership_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  actor public.memberships%rowtype;
  decision authz.authorization_decision;
  scope_name text;
begin
  perform financial_ops.require_command_actor(p_actor_user_id);
  select m.* into actor from public.memberships m
    join public.user_accounts a on a.user_id=m.user_id and a.status='active'
    join public.tenants t on t.id=m.tenant_id and t.status='active'
    left join public.offices o on o.id=m.office_id and o.status='active'
   where m.id=p_actor_membership_id and m.user_id=p_actor_user_id and m.status='active'
     and m.role_key in ('team_leader','director','world_team_member','president_team_member')
     and (m.office_id is null or o.id is not null);
  if actor.id is null then raise exception using errcode='42501',message='active leadership workspace is required'; end if;
  decision:=authz.authorize(p_actor_user_id,null,'manage_access_rules',actor.tenant_id,actor.office_id);
  if decision.decision<>'ALLOW' then raise exception using errcode='42501',message='access management is not authorized'; end if;
  select coalesce(o.name,t.name) into scope_name from public.tenants t left join public.offices o on o.id=actor.office_id where t.id=actor.tenant_id;

  return jsonb_build_object(
    'scope',jsonb_build_object('tenant_id',actor.tenant_id,'office_id',actor.office_id,'label',scope_name,'role',actor.role_key),
    'permissions',(select coalesce(jsonb_agg(jsonb_build_object('permission_key',p.permission_key,'area',p.area,'label',initcap(replace(p.permission_key,'_',' '))) order by p.area,p.permission_key),'[]'::jsonb)
      from authz.permission_catalog p where p.grantable and not p.protected),
    'offices',(select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'name',o.name,'office_type',o.office_type) order by o.name),'[]'::jsonb)
      from public.offices o where o.tenant_id=actor.tenant_id and o.status='active'
       and (authz.authorize(p_actor_user_id,null,'manage_access_rules',actor.tenant_id,o.id)).decision='ALLOW'),
    'memberships',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'user_id',m.user_id,'display_name',coalesce(nullif(btrim(p.display_name),''),a.public_uid),'public_uid',a.public_uid,'office_id',m.office_id) order by coalesce(p.display_name,a.public_uid),m.id),'[]'::jsonb)
      from public.memberships m join public.user_accounts a on a.user_id=m.user_id left join public.user_profiles p on p.user_id=m.user_id
      where m.tenant_id=actor.tenant_id and m.status='active'
       and (authz.authorize(p_actor_user_id,null,'manage_access_rules',actor.tenant_id,m.office_id,m.id,m.user_id)).decision='ALLOW'),
    'assignments',(select coalesce(jsonb_agg(jsonb_build_object(
      'assignment_id',x.id,'subject_user_id',x.subject_user_id,'subject_display_name',coalesce(nullif(btrim(up.display_name),''),ua.public_uid),'subject_public_uid',ua.public_uid,
      'reason',x.reason,'created_at',x.created_at,'created_by_user_id',x.created_by_user_id,'revoked_at',x.revoked_at,'revoked_by_user_id',x.revoked_by_user_id,
      'rules',(select jsonb_agg(jsonb_build_object('rule_id',r.id,'permission_key',r.permission_key,'effect',r.effect,'scope_type',r.scope_type,'scope_office_id',r.scope_office_id,'scope_membership_id',r.scope_membership_id,'starts_at',r.starts_at,'expires_at',r.expires_at,'revoked',r.revoked_at is not null) order by r.created_at,r.id) from authz.access_rules r where r.assignment_id=x.id)
    ) order by x.created_at desc,x.id desc),'[]'::jsonb)
      from authz.access_assignments x join public.user_accounts ua on ua.user_id=x.subject_user_id left join public.user_profiles up on up.user_id=x.subject_user_id
      where x.tenant_id=actor.tenant_id and exists(
        select 1 from authz.access_rules r where r.assignment_id=x.id and
        (authz.authorize(p_actor_user_id,null,'manage_access_rules',actor.tenant_id,r.scope_office_id,r.scope_membership_id)).decision='ALLOW')
    )
  );
end; $$;
revoke all on function read_api.access_management(uuid,uuid) from public,anon,authenticated;
grant execute on function read_api.access_management(uuid,uuid) to service_role;

create function command_api.create_access_assignment(p_idempotency_key uuid,p_actor_user_id uuid,p_session_id uuid,p_actor_membership_id uuid,p_subject_user_id uuid,p_reason text,p_rules jsonb)
returns uuid language plpgsql volatile security definer set search_path='' as $$
declare actor public.memberships%rowtype; item jsonb; permission authz.permission_catalog%rowtype; management authz.authorization_decision; delegated authz.authorization_decision;
  office_id uuid; membership_id uuid; subject_id uuid; result_id uuid; fingerprint text; prior authz.access_command_idempotency%rowtype; expires timestamptz;
begin
  if p_idempotency_key is null or p_actor_user_id is null or p_session_id is null or p_subject_user_id is null or p_reason is null or length(btrim(p_reason)) not between 1 and 1000
    or jsonb_typeof(p_rules) is distinct from 'array' or jsonb_array_length(p_rules) not between 1 and 100 then
    raise exception using errcode='22023',message='access_assignment_invalid';
  end if;
  fingerprint:=encode(extensions.digest(convert_to(jsonb_build_object('membership',p_actor_membership_id,'subject',p_subject_user_id,'reason',btrim(p_reason),'rules',p_rules)::text,'UTF8'),'sha256'),'hex');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('access:'||p_actor_user_id::text||':'||p_idempotency_key::text,0));
  select * into prior from authz.access_command_idempotency where actor_user_id=p_actor_user_id and idempotency_key=p_idempotency_key;
  if prior.assignment_id is not null then
    if prior.command_type<>'create' or prior.request_fingerprint<>fingerprint then raise exception using errcode='23505',message='idempotency_key_reused'; end if;
    return prior.assignment_id;
  end if;
  perform financial_ops.require_command_actor(p_actor_user_id);
  if not authz.is_elevated_session_valid(p_session_id,p_actor_user_id) then raise exception using errcode='P0401',message='step_up_required'; end if;
  select m.* into actor from public.memberships m join public.tenants t on t.id=m.tenant_id and t.status='active'
   where m.id=p_actor_membership_id and m.user_id=p_actor_user_id and m.status='active' and m.role_key in ('team_leader','director','world_team_member','president_team_member');
  if actor.id is null then raise exception using errcode='42501',message='actor_membership_invalid'; end if;
  if not exists(select 1 from public.memberships where tenant_id=actor.tenant_id and user_id=p_subject_user_id and status='active') then raise exception using errcode='22023',message='subject_membership_required'; end if;
  -- Conservative delegation rule: every rule requires manage_access_rules on
  -- the exact target; allows additionally require the actor to hold P there.
  for item in select value from jsonb_array_elements(p_rules) loop
    if item - array['permission_key','effect','scope_type','scope_office_id','scope_membership_id','expires_at'] <> '{}'::jsonb
      or jsonb_typeof(item->'permission_key')<>'string' or item->>'effect' not in ('allow','deny') or item->>'scope_type' not in ('tenant','office_subtree','member') then
      raise exception using errcode='22023',message='access_rule_invalid'; end if;
    begin office_id:=nullif(item->>'scope_office_id','')::uuid; membership_id:=nullif(item->>'scope_membership_id','')::uuid; expires:=nullif(item->>'expires_at','')::timestamptz;
    exception when others then raise exception using errcode='22023',message='access_rule_invalid'; end;
    if (item->>'scope_type'='tenant' and (office_id is not null or membership_id is not null)) or (item->>'scope_type'='office_subtree' and (office_id is null or membership_id is not null)) or (item->>'scope_type'='member' and (office_id is not null or membership_id is null))
      or (item->>'effect'='deny' and expires is not null) or (expires is not null and expires<=clock_timestamp()) then raise exception using errcode='22023',message='access_rule_invalid'; end if;
    select * into permission from authz.permission_catalog where permission_key=item->>'permission_key';
    if permission.permission_key is null or not permission.grantable or permission.protected then raise exception using errcode='22023',message='permission_not_grantable'; end if;
    if membership_id is not null then select user_id into subject_id from public.memberships where id=membership_id and tenant_id=actor.tenant_id and status='active'; if subject_id is null then raise exception using errcode='22023',message='scope_target_invalid'; end if; end if;
    if office_id is not null and not exists(select 1 from public.offices where id=office_id and tenant_id=actor.tenant_id and status='active') then raise exception using errcode='22023',message='scope_target_invalid'; end if;
    management:=authz.authorize(p_actor_user_id,p_session_id,'manage_access_rules',actor.tenant_id,office_id,membership_id,subject_id);
    if management.decision<>'ALLOW' then raise exception using errcode='42501',message='scope_not_managed'; end if;
    if item->>'effect'='allow' then delegated:=authz.authorize(p_actor_user_id,p_session_id,item->>'permission_key',actor.tenant_id,office_id,membership_id,subject_id); if delegated.decision<>'ALLOW' then raise exception using errcode='42501',message='delegation_privilege_escalation'; end if; end if;
  end loop;
  -- Authorization above intentionally occurs after elevation validation.
  insert into authz.access_assignments(tenant_id,subject_user_id,created_by_user_id,reason) values(actor.tenant_id,p_subject_user_id,p_actor_user_id,btrim(p_reason)) returning id into result_id;
  for item in select value from jsonb_array_elements(p_rules) loop
    insert into authz.access_rules(tenant_id,assignment_id,permission_key,effect,scope_type,scope_office_id,scope_membership_id,expires_at)
    values(actor.tenant_id,result_id,item->>'permission_key',(item->>'effect')::authz.access_effect,(item->>'scope_type')::authz.access_scope_type,nullif(item->>'scope_office_id','')::uuid,nullif(item->>'scope_membership_id','')::uuid,nullif(item->>'expires_at','')::timestamptz);
  end loop;
  insert into authz.access_command_idempotency values(p_actor_user_id,p_idempotency_key,'create',fingerprint,result_id,clock_timestamp());
  insert into authz.security_audit_events(actor_user_id,session_id,tenant_id,event_type,target_type,target_id,allowed,reason_code,metadata)
    values(p_actor_user_id,p_session_id,actor.tenant_id,'access.assignment_created','access_assignment',result_id,true,'authorized',jsonb_build_object('subject_user_id',p_subject_user_id,'rule_count',jsonb_array_length(p_rules)));
  return result_id;
end; $$;
revoke all on function command_api.create_access_assignment(uuid,uuid,uuid,uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function command_api.create_access_assignment(uuid,uuid,uuid,uuid,uuid,text,jsonb) to service_role;

create function command_api.revoke_access_assignment(p_idempotency_key uuid,p_actor_user_id uuid,p_session_id uuid,p_actor_membership_id uuid,p_assignment_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' as $$
declare actor public.memberships%rowtype; target authz.access_assignments%rowtype; rule authz.access_rules%rowtype; decision authz.authorization_decision; prior authz.access_command_idempotency%rowtype; fingerprint text;
begin
  if p_idempotency_key is null or p_actor_user_id is null or p_session_id is null or p_assignment_id is null then raise exception using errcode='22023',message='revoke_access_assignment_invalid'; end if;
  fingerprint:=encode(extensions.digest(convert_to(jsonb_build_object('membership',p_actor_membership_id,'assignment',p_assignment_id)::text,'UTF8'),'sha256'),'hex');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('access:'||p_actor_user_id::text||':'||p_idempotency_key::text,0));
  select * into prior from authz.access_command_idempotency where actor_user_id=p_actor_user_id and idempotency_key=p_idempotency_key;
  if prior.assignment_id is not null then if prior.command_type<>'revoke' or prior.request_fingerprint<>fingerprint then raise exception using errcode='23505',message='idempotency_key_reused'; end if; return prior.assignment_id; end if;
  perform financial_ops.require_command_actor(p_actor_user_id);
  if not authz.is_elevated_session_valid(p_session_id,p_actor_user_id) then raise exception using errcode='P0401',message='step_up_required'; end if;
  select m.* into actor from public.memberships m where m.id=p_actor_membership_id and m.user_id=p_actor_user_id and m.status='active' and m.role_key in ('team_leader','director','world_team_member','president_team_member');
  select * into target from authz.access_assignments where id=p_assignment_id for update;
  if actor.id is null then raise exception using errcode='42501',message='actor_membership_invalid'; end if;
  if target.id is null or target.tenant_id<>actor.tenant_id then raise exception using errcode='P0002',message='access_assignment_not_found'; end if;
  for rule in select * from authz.access_rules where assignment_id=target.id loop
    decision:=authz.authorize(p_actor_user_id,p_session_id,'manage_access_rules',target.tenant_id,rule.scope_office_id,rule.scope_membership_id);
    if decision.decision<>'ALLOW' then raise exception using errcode='42501',message='scope_not_managed'; end if;
  end loop;
  if target.revoked_at is null then
    update authz.access_assignments set revoked_at=clock_timestamp(),revoked_by_user_id=p_actor_user_id where id=target.id;
    update authz.access_rules set revoked_at=clock_timestamp(),revoked_by_user_id=p_actor_user_id where assignment_id=target.id and revoked_at is null;
    insert into authz.security_audit_events(actor_user_id,session_id,tenant_id,event_type,target_type,target_id,allowed,reason_code) values(p_actor_user_id,p_session_id,target.tenant_id,'access.assignment_revoked','access_assignment',target.id,true,'authorized');
  end if;
  insert into authz.access_command_idempotency values(p_actor_user_id,p_idempotency_key,'revoke',fingerprint,target.id,clock_timestamp());
  return target.id;
end; $$;
revoke all on function command_api.revoke_access_assignment(uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function command_api.revoke_access_assignment(uuid,uuid,uuid,uuid,uuid) to service_role;
