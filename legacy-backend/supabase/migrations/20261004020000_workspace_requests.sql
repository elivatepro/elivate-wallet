-- Workspace request onboarding. Tenant selection is accepted only when it is
-- corroborated by a stored, live entry-token digest; the tenant id supplied to
-- submit_workspace_request is therefore a lookup discriminator, not authority.

create table public.workspace_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  requested_office_name text not null check (length(btrim(requested_office_name)) between 2 and 120),
  requester_full_name text not null check (length(btrim(requester_full_name)) between 2 and 120),
  requester_email text not null check (length(btrim(requester_email)) between 5 and 254 and requester_email ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
  requester_phone text not null check (length(btrim(requester_phone)) between 7 and 32),
  requester_rank text not null check (length(btrim(requester_rank)) between 1 and 80),
  status text not null default 'pending' check (status in ('pending','approved','rejected','activated')),
  decision_reason text check (decision_reason is null or length(btrim(decision_reason)) between 1 and 1000),
  decided_by_user_id uuid references public.user_accounts(user_id) on delete restrict,
  decided_at timestamptz,
  office_id uuid references public.offices(id) on delete restrict,
  entry_token_digest text not null check (entry_token_digest ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check ((status='pending' and decided_by_user_id is null and decided_at is null and office_id is null)
    or (status in ('approved','rejected') and decided_by_user_id is not null and decided_at is not null and office_id is null)
    or (status='activated' and decided_by_user_id is not null and decided_at is not null and office_id is not null))
);
create unique index workspace_requests_one_pending_email on public.workspace_requests(tenant_id,lower(requester_email)) where status='pending';
create index workspace_requests_tenant_status_created on public.workspace_requests(tenant_id,status,created_at desc);
create trigger workspace_requests_touch_updated_at before update on public.workspace_requests for each row execute function public.touch_updated_at();
alter table public.workspace_requests enable row level security;
alter table public.workspace_requests force row level security;
revoke all on public.workspace_requests from public,anon,authenticated,service_role;

create table authz.workspace_request_entry_tokens (
  id uuid primary key default extensions.gen_random_uuid(), tenant_id uuid not null references public.tenants(id) on delete restrict,
  token_digest text not null unique check(token_digest ~ '^[0-9a-f]{64}$'), expires_at timestamptz not null,
  revoked_at timestamptz, created_by_user_id uuid not null references public.user_accounts(user_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp()
);
create index workspace_request_entry_tokens_tenant on authz.workspace_request_entry_tokens(tenant_id,expires_at) where revoked_at is null;
alter table authz.workspace_request_entry_tokens enable row level security;
revoke all on authz.workspace_request_entry_tokens from public,anon,authenticated,service_role;

create table authz.workspace_request_delegations (
  id uuid primary key default extensions.gen_random_uuid(), tenant_id uuid not null references public.tenants(id) on delete restrict,
  delegate_user_id uuid not null references public.user_accounts(user_id) on delete restrict,
  created_by_user_id uuid not null references public.user_accounts(user_id) on delete restrict,
  expires_at timestamptz not null, revoked_at timestamptz, revoked_by_user_id uuid references public.user_accounts(user_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(), check(expires_at>created_at)
);
create unique index workspace_request_one_live_delegation on authz.workspace_request_delegations(tenant_id,delegate_user_id) where revoked_at is null;
alter table authz.workspace_request_delegations enable row level security;
revoke all on authz.workspace_request_delegations from public,anon,authenticated,service_role;

create table authz.workspace_request_command_idempotency (
  actor_key text not null, idempotency_key uuid not null, command_type text not null,
  request_fingerprint text not null, result_id uuid not null, created_at timestamptz not null default clock_timestamp(),
  primary key(actor_key,idempotency_key)
);
alter table authz.workspace_request_command_idempotency enable row level security;
revoke all on authz.workspace_request_command_idempotency from public,anon,authenticated,service_role;

create function authz.workspace_request_actor(p_user_id uuid,p_membership_id uuid,p_require_ptm boolean default false)
returns public.memberships language plpgsql stable security definer set search_path='' as $$
declare m public.memberships%rowtype;
begin
  perform financial_ops.require_command_actor(p_user_id);
  select x.* into m from public.memberships x join public.tenants t on t.id=x.tenant_id and t.status='active'
   join public.user_accounts a on a.user_id=x.user_id and a.status='active'
   where x.id=p_membership_id and x.user_id=p_user_id and x.status='active'
   and (x.role_key='president_team_member' or (not p_require_ptm and x.role_key='world_team_member' and exists(
     select 1 from authz.workspace_request_delegations d where d.tenant_id=x.tenant_id and d.delegate_user_id=x.user_id and d.revoked_at is null and d.expires_at>clock_timestamp())));
  if m.id is null then raise exception using errcode='42501',message='workspace_request_not_authorized'; end if;
  return m;
end $$;
revoke all on function authz.workspace_request_actor(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function authz.workspace_request_actor(uuid,uuid,boolean) to service_role;

create function command_api.submit_workspace_request(p_idempotency_key uuid,p_tenant_id uuid,p_entry_token_digest text,p_full_name text,p_email text,p_phone text,p_team_name text,p_rank text)
returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid; fp text; prior authz.workspace_request_command_idempotency%rowtype; normalized_email text:=lower(btrim(p_email));
begin
 if p_idempotency_key is null or p_tenant_id is null or p_entry_token_digest !~ '^[0-9a-f]{64}$' or length(btrim(p_full_name)) not between 2 and 120 or length(normalized_email) not between 5 and 254 or normalized_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or length(btrim(p_phone)) not between 7 and 32 or length(btrim(p_team_name)) not between 2 and 120 or length(btrim(p_rank)) not between 1 and 80 then raise exception using errcode='22023',message='workspace_request_invalid'; end if;
 if not exists(select 1 from authz.workspace_request_entry_tokens t where t.tenant_id=p_tenant_id and t.token_digest=p_entry_token_digest and t.revoked_at is null and t.expires_at>clock_timestamp()) then raise exception using errcode='42501',message='workspace_request_entry_invalid'; end if;
 fp:=encode(extensions.digest(convert_to(jsonb_build_object('tenant',p_tenant_id,'token',p_entry_token_digest,'name',btrim(p_full_name),'email',normalized_email,'phone',btrim(p_phone),'team',btrim(p_team_name),'rank',btrim(p_rank))::text,'UTF8'),'sha256'),'hex');
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('workspace-request:anonymous:'||p_idempotency_key,0));
 select * into prior from authz.workspace_request_command_idempotency where actor_key='anonymous' and idempotency_key=p_idempotency_key;
 if prior.result_id is not null then if prior.command_type<>'submit' or prior.request_fingerprint<>fp then raise exception using errcode='23505',message='idempotency_key_reused'; end if; return prior.result_id; end if;
 if exists(select 1 from public.workspace_requests where tenant_id=p_tenant_id and lower(requester_email)=normalized_email and status='pending') then raise exception using errcode='23505',message='workspace_request_pending_exists'; end if;
 insert into public.workspace_requests(tenant_id,requested_office_name,requester_full_name,requester_email,requester_phone,requester_rank,entry_token_digest) values(p_tenant_id,btrim(p_team_name),btrim(p_full_name),normalized_email,btrim(p_phone),btrim(p_rank),p_entry_token_digest) returning id into result;
 insert into authz.workspace_request_command_idempotency values('anonymous',p_idempotency_key,'submit',fp,result,clock_timestamp());
 insert into authz.security_audit_events(tenant_id,event_type,target_type,target_id,allowed,source,reason_code) values(p_tenant_id,'workspace_request.submitted','workspace_request',result,true,'system_rule','valid_entry_token');
 return result;
end $$;
revoke all on function command_api.submit_workspace_request(uuid,uuid,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function command_api.submit_workspace_request(uuid,uuid,text,text,text,text,text,text) to service_role;

create function read_api.workspace_requests(p_actor_user_id uuid,p_actor_membership_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor public.memberships%rowtype;
begin
 actor:=authz.workspace_request_actor(p_actor_user_id,p_actor_membership_id,false);
 return jsonb_build_object('can_decide',true,'scope',jsonb_build_object('tenant_id',actor.tenant_id,'role',actor.role_key),
 'requests',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'team_name',r.requested_office_name,'full_name',r.requester_full_name,'email',r.requester_email,'phone',r.requester_phone,'rank',r.requester_rank,'status',r.status,'decision_reason',r.decision_reason,'decided_by_user_id',r.decided_by_user_id,'decided_at',r.decided_at,'office_id',r.office_id,'created_at',r.created_at) order by r.created_at desc),'[]') from public.workspace_requests r where r.tenant_id=actor.tenant_id),
 'director_offices',(select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'name',o.name) order by o.name),'[]') from public.offices o where o.tenant_id=actor.tenant_id and o.office_type='director' and o.status='active'),
 'delegations',(select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'delegate_user_id',d.delegate_user_id,'expires_at',d.expires_at,'revoked_at',d.revoked_at) order by d.created_at desc),'[]') from authz.workspace_request_delegations d where d.tenant_id=actor.tenant_id),
 'world_team_members',(select coalesce(jsonb_agg(jsonb_build_object('user_id',m.user_id,'membership_id',m.id) order by m.id),'[]') from public.memberships m where m.tenant_id=actor.tenant_id and m.role_key='world_team_member' and m.status='active'));
end $$;
revoke all on function read_api.workspace_requests(uuid,uuid) from public,anon,authenticated;
grant execute on function read_api.workspace_requests(uuid,uuid) to service_role;

create function command_api.create_workspace_request_delegation(p_idempotency_key uuid,p_actor_user_id uuid,p_session_id uuid,p_actor_membership_id uuid,p_delegate_user_id uuid,p_expires_at timestamptz) returns uuid language plpgsql security definer set search_path='' as $$
declare actor public.memberships%rowtype; result uuid; fp text; prior authz.workspace_request_command_idempotency%rowtype;
begin
 if p_idempotency_key is null or p_delegate_user_id is null or p_expires_at<=clock_timestamp() then raise exception using errcode='22023',message='workspace_request_delegation_invalid'; end if;
 fp:=encode(extensions.digest(convert_to(jsonb_build_object('membership',p_actor_membership_id,'delegate',p_delegate_user_id,'expires',p_expires_at)::text,'UTF8'),'sha256'),'hex'); perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('workspace-request:'||p_actor_user_id||':'||p_idempotency_key,0));
 select * into prior from authz.workspace_request_command_idempotency where actor_key=p_actor_user_id::text and idempotency_key=p_idempotency_key; if prior.result_id is not null then if prior.command_type<>'delegate' or prior.request_fingerprint<>fp then raise exception using errcode='23505',message='idempotency_key_reused'; end if; return prior.result_id; end if;
 if not authz.is_elevated_session_valid(p_session_id,p_actor_user_id) then raise exception using errcode='P0401',message='step_up_required'; end if; actor:=authz.workspace_request_actor(p_actor_user_id,p_actor_membership_id,true);
 if not exists(select 1 from public.memberships where tenant_id=actor.tenant_id and user_id=p_delegate_user_id and role_key='world_team_member' and status='active') then raise exception using errcode='22023',message='delegate_must_be_active_wtm'; end if;
 insert into authz.workspace_request_delegations(tenant_id,delegate_user_id,created_by_user_id,expires_at) values(actor.tenant_id,p_delegate_user_id,p_actor_user_id,p_expires_at) returning id into result;
 insert into authz.workspace_request_command_idempotency values(p_actor_user_id::text,p_idempotency_key,'delegate',fp,result,clock_timestamp()); insert into authz.security_audit_events(actor_user_id,session_id,tenant_id,event_type,target_type,target_id,allowed,reason_code) values(p_actor_user_id,p_session_id,actor.tenant_id,'workspace_request.delegation_created','workspace_request_delegation',result,true,'authorized'); return result;
end $$;

create function command_api.revoke_workspace_request_delegation(p_idempotency_key uuid,p_actor_user_id uuid,p_session_id uuid,p_actor_membership_id uuid,p_delegation_id uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare actor public.memberships%rowtype; target authz.workspace_request_delegations%rowtype; fp text; prior authz.workspace_request_command_idempotency%rowtype;
begin
 fp:=encode(extensions.digest(convert_to(jsonb_build_object('membership',p_actor_membership_id,'delegation',p_delegation_id)::text,'UTF8'),'sha256'),'hex'); perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('workspace-request:'||p_actor_user_id||':'||p_idempotency_key,0)); select * into prior from authz.workspace_request_command_idempotency where actor_key=p_actor_user_id::text and idempotency_key=p_idempotency_key; if prior.result_id is not null then if prior.command_type<>'revoke_delegation' or prior.request_fingerprint<>fp then raise exception using errcode='23505',message='idempotency_key_reused'; end if; return prior.result_id; end if;
 if not authz.is_elevated_session_valid(p_session_id,p_actor_user_id) then raise exception using errcode='P0401',message='step_up_required'; end if; actor:=authz.workspace_request_actor(p_actor_user_id,p_actor_membership_id,true); select * into target from authz.workspace_request_delegations where id=p_delegation_id and tenant_id=actor.tenant_id for update; if target.id is null then raise exception using errcode='P0002',message='workspace_request_delegation_not_found'; end if; update authz.workspace_request_delegations set revoked_at=coalesce(revoked_at,clock_timestamp()),revoked_by_user_id=coalesce(revoked_by_user_id,p_actor_user_id) where id=target.id; insert into authz.workspace_request_command_idempotency values(p_actor_user_id::text,p_idempotency_key,'revoke_delegation',fp,target.id,clock_timestamp()); insert into authz.security_audit_events(actor_user_id,session_id,tenant_id,event_type,target_type,target_id,allowed,reason_code) values(p_actor_user_id,p_session_id,actor.tenant_id,'workspace_request.delegation_revoked','workspace_request_delegation',target.id,true,'authorized'); return target.id;
end $$;

create function command_api.create_workspace_request_entry_token(p_idempotency_key uuid,p_actor_user_id uuid,p_session_id uuid,p_actor_membership_id uuid,p_token_digest text,p_expires_at timestamptz) returns uuid language plpgsql security definer set search_path='' as $$
declare actor public.memberships%rowtype; result uuid; fp text; prior authz.workspace_request_command_idempotency%rowtype;
begin
 if p_token_digest !~ '^[0-9a-f]{64}$' or p_expires_at<=clock_timestamp() then raise exception using errcode='22023',message='workspace_request_entry_invalid'; end if; fp:=encode(extensions.digest(convert_to(jsonb_build_object('membership',p_actor_membership_id,'digest',p_token_digest,'expires',p_expires_at)::text,'UTF8'),'sha256'),'hex'); perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('workspace-request:'||p_actor_user_id||':'||p_idempotency_key,0)); select * into prior from authz.workspace_request_command_idempotency where actor_key=p_actor_user_id::text and idempotency_key=p_idempotency_key; if prior.result_id is not null then if prior.command_type<>'entry_token' or prior.request_fingerprint<>fp then raise exception using errcode='23505',message='idempotency_key_reused'; end if; return prior.result_id; end if;
 if not authz.is_elevated_session_valid(p_session_id,p_actor_user_id) then raise exception using errcode='P0401',message='step_up_required'; end if; actor:=authz.workspace_request_actor(p_actor_user_id,p_actor_membership_id,true); insert into authz.workspace_request_entry_tokens(tenant_id,token_digest,expires_at,created_by_user_id) values(actor.tenant_id,p_token_digest,p_expires_at,p_actor_user_id) returning id into result; insert into authz.workspace_request_command_idempotency values(p_actor_user_id::text,p_idempotency_key,'entry_token',fp,result,clock_timestamp()); insert into authz.security_audit_events(actor_user_id,session_id,tenant_id,event_type,target_type,target_id,allowed,reason_code) values(p_actor_user_id,p_session_id,actor.tenant_id,'workspace_request.entry_token_created','workspace_request_entry_token',result,true,'authorized'); return result;
end $$;

create function command_api.decide_workspace_request(p_idempotency_key uuid,p_actor_user_id uuid,p_session_id uuid,p_actor_membership_id uuid,p_request_id uuid,p_decision text,p_decision_reason text) returns uuid language plpgsql security definer set search_path='' as $$
declare actor public.memberships%rowtype; target public.workspace_requests%rowtype; fp text; prior authz.workspace_request_command_idempotency%rowtype;
begin
 if p_decision not in ('approved','rejected') or length(btrim(p_decision_reason)) not between 1 and 1000 then raise exception using errcode='22023',message='workspace_request_decision_invalid'; end if; fp:=encode(extensions.digest(convert_to(jsonb_build_object('membership',p_actor_membership_id,'request',p_request_id,'decision',p_decision,'reason',btrim(p_decision_reason))::text,'UTF8'),'sha256'),'hex'); perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('workspace-request:'||p_actor_user_id||':'||p_idempotency_key,0)); select * into prior from authz.workspace_request_command_idempotency where actor_key=p_actor_user_id::text and idempotency_key=p_idempotency_key; if prior.result_id is not null then if prior.command_type<>'decide' or prior.request_fingerprint<>fp then raise exception using errcode='23505',message='idempotency_key_reused'; end if; return prior.result_id; end if;
 if not authz.is_elevated_session_valid(p_session_id,p_actor_user_id) then raise exception using errcode='P0401',message='step_up_required'; end if; actor:=authz.workspace_request_actor(p_actor_user_id,p_actor_membership_id,false); select * into target from public.workspace_requests where id=p_request_id and tenant_id=actor.tenant_id for update; if target.id is null then raise exception using errcode='P0002',message='workspace_request_not_found'; end if; if target.status<>'pending' then raise exception using errcode='23514',message='workspace_request_not_pending'; end if; update public.workspace_requests set status=p_decision,decision_reason=btrim(p_decision_reason),decided_by_user_id=p_actor_user_id,decided_at=clock_timestamp() where id=target.id; insert into authz.workspace_request_command_idempotency values(p_actor_user_id::text,p_idempotency_key,'decide',fp,target.id,clock_timestamp()); insert into authz.security_audit_events(actor_user_id,session_id,tenant_id,event_type,target_type,target_id,allowed,reason_code,metadata) values(p_actor_user_id,p_session_id,actor.tenant_id,'workspace_request.decided','workspace_request',target.id,true,'authorized',jsonb_build_object('decision',p_decision)); return target.id;
end $$;

create function command_api.activate_workspace_request(p_idempotency_key uuid,p_actor_user_id uuid,p_session_id uuid,p_actor_membership_id uuid,p_request_id uuid,p_parent_office_id uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare actor public.memberships%rowtype; target public.workspace_requests%rowtype; new_office_id uuid; fp text; prior authz.workspace_request_command_idempotency%rowtype;
begin
 fp:=encode(extensions.digest(convert_to(jsonb_build_object('membership',p_actor_membership_id,'request',p_request_id,'parent',p_parent_office_id)::text,'UTF8'),'sha256'),'hex'); perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('workspace-request:'||p_actor_user_id||':'||p_idempotency_key,0)); select * into prior from authz.workspace_request_command_idempotency where actor_key=p_actor_user_id::text and idempotency_key=p_idempotency_key; if prior.result_id is not null then if prior.command_type<>'activate' or prior.request_fingerprint<>fp then raise exception using errcode='23505',message='idempotency_key_reused'; end if; return prior.result_id; end if;
 if not authz.is_elevated_session_valid(p_session_id,p_actor_user_id) then raise exception using errcode='P0401',message='step_up_required'; end if; actor:=authz.workspace_request_actor(p_actor_user_id,p_actor_membership_id,false); select * into target from public.workspace_requests where id=p_request_id and tenant_id=actor.tenant_id for update; if target.id is null then raise exception using errcode='P0002',message='workspace_request_not_found'; end if; if target.status<>'approved' then raise exception using errcode='23514',message='workspace_request_not_approved'; end if; if not exists(select 1 from public.offices where id=p_parent_office_id and tenant_id=actor.tenant_id and office_type='director' and status='active') then raise exception using errcode='22023',message='workspace_request_parent_invalid'; end if; insert into public.offices(tenant_id,parent_office_id,office_type,name) values(actor.tenant_id,p_parent_office_id,'team_leader',target.requested_office_name) returning id into new_office_id; update public.workspace_requests set status='activated',office_id=new_office_id where id=target.id; insert into authz.workspace_request_command_idempotency values(p_actor_user_id::text,p_idempotency_key,'activate',fp,new_office_id,clock_timestamp()); insert into authz.security_audit_events(actor_user_id,session_id,tenant_id,event_type,target_type,target_id,allowed,reason_code,metadata) values(p_actor_user_id,p_session_id,actor.tenant_id,'workspace_request.activated','workspace_request',target.id,true,'authorized',jsonb_build_object('office_id',new_office_id)); return new_office_id;
end $$;

revoke all on function command_api.create_workspace_request_delegation(uuid,uuid,uuid,uuid,uuid,timestamptz),command_api.revoke_workspace_request_delegation(uuid,uuid,uuid,uuid,uuid),command_api.create_workspace_request_entry_token(uuid,uuid,uuid,uuid,text,timestamptz),command_api.decide_workspace_request(uuid,uuid,uuid,uuid,uuid,text,text),command_api.activate_workspace_request(uuid,uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function command_api.create_workspace_request_delegation(uuid,uuid,uuid,uuid,uuid,timestamptz),command_api.revoke_workspace_request_delegation(uuid,uuid,uuid,uuid,uuid),command_api.create_workspace_request_entry_token(uuid,uuid,uuid,uuid,text,timestamptz),command_api.decide_workspace_request(uuid,uuid,uuid,uuid,uuid,text,text),command_api.activate_workspace_request(uuid,uuid,uuid,uuid,uuid,uuid) to service_role;
