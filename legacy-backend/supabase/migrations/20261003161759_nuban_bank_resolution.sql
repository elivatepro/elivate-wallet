-- Private provider proof is operational destination data, never financial value.
create table financial_ops.bank_resolution_intents (
 id uuid primary key, actor_user_id uuid not null references public.user_accounts(user_id),
 membership_id uuid not null references public.memberships(id), wallet_id uuid not null references public.wallets(id),
 bank_code text not null check(bank_code ~ '^[0-9]{3,6}$'),
 account_number text not null check(account_number ~ '^[0-9]{10}$'),
 existing_payout_account_id uuid references financial_ops.payout_accounts(id),
 account_holder_name text, institution_name text, resolved_at timestamptz,
 created_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null default clock_timestamp()+interval '15 minutes',
 confirmation_key uuid unique, result_payout_account_id uuid references financial_ops.payout_accounts(id),
 check((resolved_at is null)=(account_holder_name is null)),
 check((resolved_at is null)=(institution_name is null)),
 check((confirmation_key is null)=(result_payout_account_id is null)),
 check(result_payout_account_id is null or resolved_at is not null),
 check(expires_at>created_at), check(resolved_at is null or (resolved_at>=created_at and resolved_at<=expires_at))
);
alter table financial_ops.bank_resolution_intents enable row level security;
alter table financial_ops.bank_resolution_intents force row level security;
create policy bank_resolution_intents_private_deny on financial_ops.bank_resolution_intents as restrictive for all to public using(false) with check(false);
revoke all on financial_ops.bank_resolution_intents from public,anon,authenticated,service_role;

-- Provider facts and original intent cannot be rewritten after the first resolution.
create function financial_ops.guard_bank_resolution_intent()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if tg_op='DELETE' then raise exception using errcode='55000',message='bank resolution proof is retained'; end if;
 if new.id is distinct from old.id or new.actor_user_id is distinct from old.actor_user_id or new.membership_id is distinct from old.membership_id
 or new.wallet_id is distinct from old.wallet_id or new.bank_code is distinct from old.bank_code or new.account_number is distinct from old.account_number
 or new.existing_payout_account_id is distinct from old.existing_payout_account_id or new.created_at is distinct from old.created_at or new.expires_at is distinct from old.expires_at
 or (old.resolved_at is not null and (new.resolved_at is distinct from old.resolved_at or new.account_holder_name is distinct from old.account_holder_name or new.institution_name is distinct from old.institution_name))
 or (old.result_payout_account_id is not null and (new.result_payout_account_id is distinct from old.result_payout_account_id or new.confirmation_key is distinct from old.confirmation_key)) then
 raise exception using errcode='55000',message='bank resolution intent and verified proof are immutable'; end if;
 return new;
end;
$$;
create trigger bank_resolution_intents_guard before update or delete on financial_ops.bank_resolution_intents for each row execute function financial_ops.guard_bank_resolution_intent();
revoke all on function financial_ops.guard_bank_resolution_intent() from public,anon,authenticated,service_role;

create function financial_ops.authorize_bank_account_context(p_actor uuid,p_session uuid,p_membership uuid)
returns public.memberships language plpgsql security invoker set search_path='' as $$
declare m public.memberships%rowtype; w uuid; d authz.authorization_decision;
begin
 perform financial_ops.require_command_actor(p_actor);
 select membership.* into m from public.memberships membership
 join public.user_accounts account on account.user_id=membership.user_id and account.status='active'
 join public.tenants tenant on tenant.id=membership.tenant_id and tenant.status='active'
 join public.offices office on office.id=membership.office_id and office.tenant_id=membership.tenant_id and office.status='active'
 where membership.id=p_membership and membership.user_id=p_actor and membership.status='active'
 and membership.role_key<>'president_team_member' for share of membership,account,tenant,office;
 select id into w from public.wallets where owner_user_id=p_actor;
 if m.id is null or w is null then raise exception using errcode='42501',message='active own-wallet membership is required'; end if;
 d:=authz.authorize(p_actor,p_session,'manage_own_payout_accounts',m.tenant_id,m.office_id,m.id,p_actor,w,p_actor,'manage_own_payout_accounts');
 if d.decision='STEP_UP_REQUIRED' then raise exception using errcode='P0401',message='recent authenticator verification is required'; end if;
 perform financial_ops.enforce_authorization(d);
 if not authz.is_elevated_session_valid(p_session,p_actor) then raise exception using errcode='P0401',message='recent authenticator verification is required'; end if;
 return m;
end;
$$;
revoke all on function financial_ops.authorize_bank_account_context(uuid,uuid,uuid) from public,anon,authenticated,service_role;

create function financial_ops.bank_resolution_response(p_intent financial_ops.bank_resolution_intents)
returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('resolutionId',p_intent.id,'bankCode',p_intent.bank_code,
 'accountNumber',p_intent.account_number,'accountReferenceMasked','••••'||right(p_intent.account_number,4),
 'accountHolderName',p_intent.account_holder_name,'institutionName',p_intent.institution_name,
 'expiresAt',p_intent.expires_at,'resolved',p_intent.resolved_at is not null,
 'confirmed',p_intent.result_payout_account_id is not null,
 'expired',p_intent.result_payout_account_id is null and p_intent.expires_at<=clock_timestamp(),
 'payoutAccountId',p_intent.result_payout_account_id);
$$;
revoke all on function financial_ops.bank_resolution_response(financial_ops.bank_resolution_intents) from public,anon,authenticated,service_role;

create function command_api.prepare_bank_resolution(p_idempotency_key uuid,p_actor_user_id uuid,p_session_id uuid,p_membership_id uuid,
 p_bank_code text default null,p_account_number text default null,p_payout_account_id uuid default null,
 p_country_code text default 'NG',p_payout_currency text default 'NGN',p_payout_rail text default 'bank_transfer')
returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.memberships%rowtype; s financial_ops.bank_resolution_intents%rowtype; a financial_ops.payout_accounts%rowtype; w uuid;
begin
 m:=financial_ops.authorize_bank_account_context(p_actor_user_id,p_session_id,p_membership_id);
 if p_idempotency_key is null or p_country_code is distinct from 'NG' or p_payout_currency is distinct from 'NGN' or p_payout_rail is distinct from 'bank_transfer'
 or (p_payout_account_id is not null and (p_bank_code is not null or p_account_number is not null))
 or (p_payout_account_id is null and (p_bank_code is null or p_account_number is null)) then
 raise exception using errcode='22023',message='supported bank account selection is required'; end if;
 select id into w from public.wallets where owner_user_id=p_actor_user_id;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('bank-resolution:'||p_idempotency_key::text,0));
 select * into s from financial_ops.bank_resolution_intents where id=p_idempotency_key for update;
 if s.id is not null then
  if s.actor_user_id<>p_actor_user_id or s.membership_id<>m.id or s.wallet_id<>w
   or s.existing_payout_account_id is distinct from p_payout_account_id
   or (p_payout_account_id is null and (s.bank_code<>p_bank_code or s.account_number<>p_account_number)) then
   raise exception using errcode='23505',message='bank resolution key has different account intent'; end if;
  if s.result_payout_account_id is null and s.existing_payout_account_id is not null then
   select * into a from financial_ops.payout_accounts where id=s.existing_payout_account_id for share;
   if a.id is null or a.wallet_id<>w or a.owner_user_id<>p_actor_user_id or a.status<>'active' or a.verification_status<>'pending'
    or a.institution_code<>s.bank_code or a.account_reference<>s.account_number then
    raise exception using errcode='42501',message='owned active pending bank account is required'; end if;
  end if;
  return financial_ops.bank_resolution_response(s);
 end if;
 if p_payout_account_id is not null then
  select * into a from financial_ops.payout_accounts where id=p_payout_account_id for share;
  if a.id is null or a.wallet_id<>w or a.owner_user_id<>p_actor_user_id or a.status<>'active' or a.verification_status<>'pending' then
   raise exception using errcode='42501',message='owned active pending bank account is required'; end if;
  if a.country_code<>'NG' or a.payout_currency<>'NGN' or a.payout_rail<>'bank_transfer' then
   raise exception using errcode='22023',message='this payout destination does not support NUBAN verification'; end if;
  p_bank_code:=a.institution_code; p_account_number:=a.account_reference;
 end if;
 if p_bank_code !~ '^[0-9]{3,6}$' or p_account_number !~ '^[0-9]{10}$' then
  raise exception using errcode='22023',message='bank code and ten digit account number are required'; end if;
 insert into financial_ops.bank_resolution_intents(id,actor_user_id,membership_id,wallet_id,bank_code,account_number,existing_payout_account_id)
 values(p_idempotency_key,p_actor_user_id,m.id,w,p_bank_code,p_account_number,p_payout_account_id) returning * into s;
 return financial_ops.bank_resolution_response(s);
end;
$$;

create function command_api.record_bank_resolution(p_resolution_id uuid,p_actor_user_id uuid,p_session_id uuid,p_membership_id uuid,
 p_bank_code text,p_account_number text,p_account_holder_name text,p_institution_name text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.memberships%rowtype; s financial_ops.bank_resolution_intents%rowtype;
begin
 m:=financial_ops.authorize_bank_account_context(p_actor_user_id,p_session_id,p_membership_id);
 select * into s from financial_ops.bank_resolution_intents where id=p_resolution_id for update;
 if s.id is null or s.actor_user_id<>p_actor_user_id or s.membership_id<>m.id then raise exception using errcode='42501',message='bank resolution is not authorized'; end if;
 if s.bank_code is distinct from p_bank_code or s.account_number is distinct from p_account_number
  or p_account_holder_name is null or length(btrim(p_account_holder_name)) not between 1 and 160 or p_account_holder_name ~ '[[:cntrl:]]'
  or p_institution_name is null or length(btrim(p_institution_name)) not between 1 and 160 or p_institution_name ~ '[[:cntrl:]]' then
  raise exception using errcode='22023',message='trusted bank resolution does not match account intent'; end if;
 -- First durable provider result wins; retries cannot replace the reviewed name.
 if s.resolved_at is not null or s.expires_at<=clock_timestamp() then return financial_ops.bank_resolution_response(s); end if;
 update financial_ops.bank_resolution_intents set account_holder_name=btrim(p_account_holder_name),institution_name=btrim(p_institution_name),resolved_at=clock_timestamp()
 where id=s.id returning * into s;
 return financial_ops.bank_resolution_response(s);
end;
$$;

create function command_api.confirm_bank_account(p_resolution_id uuid,p_actor_user_id uuid,p_session_id uuid,p_membership_id uuid,p_idempotency_key uuid,p_confirmed boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.memberships%rowtype; s financial_ops.bank_resolution_intents%rowtype; a financial_ops.payout_accounts%rowtype;
 r financial_ops.payout_account_command_result; d authz.authorization_decision;
begin
 m:=financial_ops.authorize_bank_account_context(p_actor_user_id,p_session_id,p_membership_id);
 if p_idempotency_key is null or p_confirmed is distinct from true then raise exception using errcode='22023',message='resolved bank name confirmation is required'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('bank-confirmation:'||p_idempotency_key::text,0));
 select * into s from financial_ops.bank_resolution_intents where id=p_resolution_id for update;
 if s.id is null or s.actor_user_id<>p_actor_user_id or s.membership_id<>m.id then raise exception using errcode='42501',message='bank resolution is not authorized'; end if;
 if s.result_payout_account_id is not null then
  if s.confirmation_key<>p_idempotency_key then raise exception using errcode='23505',message='bank resolution already has a confirmation key'; end if;
  return jsonb_build_object('payout_account_id',s.result_payout_account_id,'verification_status','verified','replayed',true);
 end if;
 if s.expires_at<=clock_timestamp() then raise exception using errcode='55000',message='bank resolution has expired'; end if;
 if s.resolved_at is null then raise exception using errcode='55000',message='bank name has not been resolved'; end if;
 if exists(select 1 from financial_ops.bank_resolution_intents where confirmation_key=p_idempotency_key) then
  raise exception using errcode='23505',message='confirmation key already has different bank intent'; end if;
 if s.existing_payout_account_id is null then
  r:=financial_ops.add_payout_account(p_idempotency_key,p_actor_user_id,p_session_id,m.tenant_id,s.wallet_id,
   'NG','NGN','bank_transfer',s.bank_code,s.institution_name,s.account_number,s.account_holder_name,false);
  select * into a from financial_ops.payout_accounts where id=r.payout_account_id for update;
 else
  select * into a from financial_ops.payout_accounts where id=s.existing_payout_account_id for update;
 end if;
 if a.id is null or a.wallet_id<>s.wallet_id or a.owner_user_id<>p_actor_user_id or a.status<>'active' or a.verification_status<>'pending'
  or a.country_code<>'NG' or a.payout_currency<>'NGN' or a.payout_rail<>'bank_transfer'
  or a.institution_code<>s.bank_code or a.account_reference<>s.account_number then
  raise exception using errcode='42501',message='pending destination no longer matches resolved bank intent'; end if;
 perform set_config('financial_ops.payout_account_transition',a.id::text,true);
 update financial_ops.payout_accounts set account_holder_name=s.account_holder_name,institution_name=s.institution_name,
 verification_status='verified',verification_method='nuban',verified_at=clock_timestamp(),
 provider_metadata=jsonb_build_object('provider','nuban','resolution_id',s.id,'resolved_at',s.resolved_at)
 where id=a.id;
 update financial_ops.bank_resolution_intents set confirmation_key=p_idempotency_key,result_payout_account_id=a.id where id=s.id;
 d:=authz.authorize(p_actor_user_id,p_session_id,'manage_own_payout_accounts',m.tenant_id,m.office_id,m.id,p_actor_user_id,s.wallet_id,p_actor_user_id,'manage_own_payout_accounts');
 perform financial_ops.record_payout_account_change(d,p_session_id,m.tenant_id,a.id,'payout_account_verified',
  jsonb_build_object('verification_method','nuban','resolution_id',s.id));
 return jsonb_build_object('payout_account_id',a.id,'verification_status','verified','replayed',false);
end;
$$;
revoke all on function command_api.prepare_bank_resolution(uuid,uuid,uuid,uuid,text,text,uuid,text,text,text) from public,anon,authenticated,service_role;
revoke all on function command_api.record_bank_resolution(uuid,uuid,uuid,uuid,text,text,text,text) from public,anon,authenticated,service_role;
revoke all on function command_api.confirm_bank_account(uuid,uuid,uuid,uuid,uuid,boolean) from public,anon,authenticated,service_role;
grant execute on function command_api.prepare_bank_resolution(uuid,uuid,uuid,uuid,text,text,uuid,text,text,text) to service_role;
grant execute on function command_api.record_bank_resolution(uuid,uuid,uuid,uuid,text,text,text,text) to service_role;
grant execute on function command_api.confirm_bank_account(uuid,uuid,uuid,uuid,uuid,boolean) to service_role;
