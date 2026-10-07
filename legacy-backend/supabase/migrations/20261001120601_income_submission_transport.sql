-- Pre-post receipt staging is not a financial record. Only the canonical
-- income command creates financial truth, atomically with verified evidence.
create table evidence.income_upload_intents (
  id uuid primary key,
  actor_user_id uuid not null references public.user_accounts(user_id),
  target_membership_id uuid not null references public.memberships(id),
  currency_code text not null references ledger.currency_definitions(currency_code),
  gross_amount numeric(38,18) not null check (gross_amount > 0),
  original_filename text not null check (length(original_filename) between 1 and 255),
  mime_type text not null check (mime_type in ('application/pdf','image/jpeg','image/png')),
  file_size_bytes bigint not null check (file_size_bytes between 1 and 10485760),
  sha256_hex text not null check (sha256_hex ~ '^[0-9a-f]{64}$'),
  observed_at timestamptz not null,
  provider_reference text not null default '' check (length(provider_reference) <= 200),
  storage_object_path text not null unique,
  expires_at timestamptz not null default (clock_timestamp() + interval '2 hours'),
  cancelled_at timestamptz,
  income_record_id uuid unique references financial_ops.income_records(id),
  created_at timestamptz not null default clock_timestamp()
);
create index income_upload_intents_actor on evidence.income_upload_intents(actor_user_id);
create index income_upload_intents_membership on evidence.income_upload_intents(target_membership_id);
alter table evidence.income_upload_intents enable row level security;
alter table evidence.income_upload_intents force row level security;
create policy income_upload_intents_private_deny on evidence.income_upload_intents
  as restrictive for all to public using (false) with check (false);
revoke all on evidence.income_upload_intents from public, anon, authenticated, service_role;

create function evidence.authorize_income_target(
  p_actor_user_id uuid, p_membership_id uuid, p_session_id uuid, p_amount numeric, p_income_id uuid default null
) returns public.memberships language plpgsql security invoker set search_path = '' as $$
declare
  target public.memberships%rowtype;
  wallet_id uuid;
  decision authz.authorization_decision;
  posted financial_ops.income_records%rowtype;
begin
  perform financial_ops.require_command_actor(p_actor_user_id);
  select * into target from public.memberships where id = p_membership_id;
  select id into wallet_id from public.wallets where owner_user_id = target.user_id;
  if target.id is null or target.status <> 'active' or target.office_id is null
     or target.role_key = 'president_team_member' or wallet_id is null then
    raise exception using errcode='23514', message='income target is not eligible';
  end if;
  if p_income_id is not null then
    select * into posted from financial_ops.income_records where id=p_income_id and membership_id=target.id;
    if posted.id is null then
      raise exception using errcode='23514', message='income provenance does not match receipt';
    end if;
  end if;
  decision := authz.authorize(p_actor_user_id, p_session_id, 'record_income',
    coalesce(posted.tenant_id,target.tenant_id), coalesce(posted.office_id,target.office_id),
    target.id, coalesce(posted.owner_user_id,target.user_id),
    coalesce(posted.wallet_id,wallet_id), coalesce(posted.owner_user_id,target.user_id), 'record_income', p_amount);
  perform financial_ops.enforce_authorization(decision);
  return target;
end;
$$;
revoke all on function evidence.authorize_income_target(uuid,uuid,uuid,numeric,uuid)
  from public, anon, authenticated, service_role;

-- Actor membership is a selector, never authority. Each result is independently
-- checked by the canonical resolver. IDs and labels only; no balances or policy internals.
create function read_api.income_targets(
  p_actor_user_id uuid, p_actor_membership_id uuid, p_after_id uuid default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  actor public.memberships%rowtype;
  target record;
  decision authz.authorization_decision;
  items jsonb := '[]'::jsonb;
  currencies jsonb;
  next_id uuid;
  allowed_count integer := 0;
begin
  perform financial_ops.require_command_actor(p_actor_user_id);
  select * into actor from public.memberships
    where id=p_actor_membership_id and user_id=p_actor_user_id and status='active';
  if actor.id is null then
    raise exception using errcode='42501', message='active workspace is required';
  end if;
  if commercial.is_tenant_commercially_restricted(actor.tenant_id) then
    return jsonb_build_object('items', items, 'next_cursor', null, 'restricted', true);
  end if;
  for target in
    select membership.*, wallet.id as wallet_id, account.public_uid, office.name as office_name
      from public.memberships membership
      join public.wallets wallet on wallet.owner_user_id=membership.user_id
      join public.user_accounts account on account.user_id=membership.user_id
      join public.offices office on office.id=membership.office_id
     where membership.tenant_id=actor.tenant_id and membership.status='active'
       and membership.role_key <> 'president_team_member'
       and (p_after_id is null or membership.id > p_after_id)
     order by membership.id
  loop
    decision := authz.authorize(p_actor_user_id, null, 'record_income',
      target.tenant_id, target.office_id, target.id, target.user_id,
      target.wallet_id, target.user_id, 'record_income', null);
    if decision.decision <> 'ALLOW' then continue; end if;
    select coalesce(jsonb_agg(jsonb_build_object('code', c.currency_code,
      'scale', c.minor_unit_scale) order by c.currency_code),'[]'::jsonb)
      into currencies from ledger.currency_definitions c
     where exists (select 1 from ledger.ledger_accounts system_account
       where system_account.currency_code=c.currency_code
         and system_account.system_account_key='income_external' and system_account.account_class='system_counter')
       and exists (select 1 from public.tenant_active_allocation_policies active
         join public.allocation_policy_versions policy on policy.id=active.policy_version_id
           and policy.tenant_id=active.tenant_id and policy.activated_at is not null
         where active.tenant_id=target.tenant_id
           and (select count(*) from public.allocation_policy_rules rule where rule.policy_version_id=active.policy_version_id)>0
           and (select count(*) from financial_ops.calculate_policy_allocations(
             active.policy_version_id,target.wallet_id,target.id,c.currency_code,1,false)) =
               (select count(*) from public.allocation_policy_rules rule where rule.policy_version_id=active.policy_version_id));
    allowed_count := allowed_count + 1;
    if allowed_count > 50 then exit; end if;
    items := items || jsonb_build_array(jsonb_build_object(
      'membership_id', target.id, 'wallet_uid', target.public_uid,
      'office_name', target.office_name, 'currencies', currencies));
    next_id := target.id;
  end loop;
  return jsonb_build_object('items', items, 'restricted', false,
    'next_cursor', case when allowed_count > 50 then next_id else null end);
end;
$$;
revoke all on function read_api.income_targets(uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function read_api.income_targets(uuid,uuid,uuid) to service_role;

create function command_api.request_income_upload(
  p_idempotency_key uuid, p_actor_user_id uuid, p_target_membership_id uuid,
  p_currency_code text, p_gross_amount numeric, p_original_filename text,
  p_mime_type text, p_file_size_bytes bigint, p_sha256_hex text,
  p_observed_at timestamptz, p_provider_reference text default '', p_session_id uuid default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  target public.memberships%rowtype;
  intent evidence.income_upload_intents%rowtype;
begin
  if p_gross_amount is null or p_gross_amount::text !~ '^(0|[1-9][0-9]{0,19})([.][0-9]{1,18})?$'
     or p_idempotency_key is null or p_observed_at is null
     or not isfinite(p_observed_at) or p_provider_reference is null
     or p_original_filename is null or p_mime_type is null
     or p_file_size_bytes is null or p_sha256_hex is null then
    raise exception using errcode='22023', message='receipt request is invalid';
  end if;
  target := evidence.authorize_income_target(p_actor_user_id,p_target_membership_id,p_session_id,p_gross_amount);
  perform financial_ops.assert_currency_amount(p_gross_amount,p_currency_code);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_idempotency_key::text,0));
  select * into intent from evidence.income_upload_intents where id=p_idempotency_key for update;
  if found then
    if intent.actor_user_id <> p_actor_user_id
       or intent.target_membership_id <> p_target_membership_id
       or intent.currency_code <> p_currency_code or intent.gross_amount <> p_gross_amount
       or intent.original_filename <> p_original_filename or intent.mime_type <> p_mime_type
       or intent.file_size_bytes <> p_file_size_bytes or intent.sha256_hex <> p_sha256_hex
       or intent.observed_at <> p_observed_at or intent.provider_reference <> p_provider_reference then
      raise exception using errcode='23505', message='receipt request conflicts';
    end if;
    if intent.cancelled_at is not null then
      raise exception using errcode='55000', message='receipt attempt was cancelled';
    end if;
    if intent.expires_at <= clock_timestamp() and intent.income_record_id is null then
      raise exception using errcode='55000', message='receipt upload expired';
    end if;
  else
    insert into evidence.income_upload_intents(id,actor_user_id,target_membership_id,
      currency_code,gross_amount,original_filename,mime_type,file_size_bytes,sha256_hex,
      observed_at,provider_reference,storage_object_path)
    values(p_idempotency_key,p_actor_user_id,p_target_membership_id,p_currency_code,p_gross_amount,
      p_original_filename,p_mime_type,p_file_size_bytes,p_sha256_hex,p_observed_at,p_provider_reference,
      target.tenant_id::text || '/income/' || p_idempotency_key::text)
    returning * into intent;
  end if;
  return jsonb_build_object('upload_intent_id',intent.id,'bucket','financial-evidence',
    'path',intent.storage_object_path,'expires_at',intent.expires_at);
end;
$$;

create function command_api.income_upload_object(
  p_intent_id uuid,p_actor_user_id uuid,p_session_id uuid default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare intent evidence.income_upload_intents%rowtype; posted financial_ops.income_records%rowtype;
begin
  select * into intent from evidence.income_upload_intents where id=p_intent_id;
  if intent.id is null or intent.actor_user_id <> p_actor_user_id then
    raise exception using errcode='42501', message='receipt is not authorized';
  end if;
  perform evidence.authorize_income_target(p_actor_user_id,intent.target_membership_id,p_session_id,intent.gross_amount,intent.income_record_id);
  if intent.cancelled_at is not null then
    raise exception using errcode='55000', message='receipt attempt was cancelled';
  end if;
  if intent.income_record_id is not null then
    select * into posted from financial_ops.income_records where id=intent.income_record_id;
    return jsonb_build_object('posted',true,'operation_reference',posted.operation_reference,
      'operation_id',posted.id,'reused',true);
  end if;
  if intent.expires_at <= clock_timestamp() then
    raise exception using errcode='55000', message='receipt upload expired';
  end if;
  return jsonb_build_object('posted',false,'bucket','financial-evidence','path',intent.storage_object_path,
    'file_size_bytes',intent.file_size_bytes,'mime_type',intent.mime_type);
end;
$$;

create function command_api.record_uploaded_income(
  p_intent_id uuid,p_actor_user_id uuid,p_verified_file_size_bytes bigint,
  p_verified_sha256_hex text,p_session_id uuid default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare intent evidence.income_upload_intents%rowtype; result financial_ops.financial_operation_result;
begin
  -- Same lock order as the upload request and canonical income command.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_intent_id::text,0));
  select * into intent from evidence.income_upload_intents where id=p_intent_id for update;
  if intent.id is null or intent.actor_user_id <> p_actor_user_id then
    raise exception using errcode='42501', message='receipt is not authorized';
  end if;
  perform evidence.authorize_income_target(p_actor_user_id,intent.target_membership_id,p_session_id,intent.gross_amount,intent.income_record_id);
  if intent.cancelled_at is not null then
    raise exception using errcode='55000', message='receipt attempt was cancelled';
  end if;
  if intent.income_record_id is null and intent.expires_at <= clock_timestamp() then
    raise exception using errcode='55000', message='receipt upload expired';
  end if;
  if p_verified_file_size_bytes is null or p_verified_sha256_hex is null
     or intent.file_size_bytes <> p_verified_file_size_bytes
     or intent.sha256_hex <> p_verified_sha256_hex then
    raise exception using errcode='23514', message='receipt bytes do not match';
  end if;
  result := financial_ops.record_income(intent.id,intent.target_membership_id,
    intent.currency_code,intent.gross_amount,jsonb_build_array(jsonb_build_object(
      'storage_bucket_id','financial-evidence','storage_object_path',intent.storage_object_path,
      'original_filename',intent.original_filename,'mime_type',intent.mime_type,
      'file_size_bytes',intent.file_size_bytes,'sha256_hex',intent.sha256_hex,
      'observed_at',intent.observed_at,'provider_reference',intent.provider_reference)),
    p_actor_user_id,p_session_id);
  update evidence.income_upload_intents set income_record_id=result.operation_id where id=intent.id;
  return jsonb_build_object('operation_id',result.operation_id,
    'operation_reference',result.operation_reference,'reused',result.reused);
end;
$$;
revoke all on function command_api.request_income_upload(uuid,uuid,uuid,text,numeric,text,text,bigint,text,timestamptz,text,uuid) from public,anon,authenticated,service_role;
revoke all on function command_api.income_upload_object(uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function command_api.record_uploaded_income(uuid,uuid,bigint,text,uuid) from public,anon,authenticated,service_role;
grant execute on function command_api.request_income_upload(uuid,uuid,uuid,text,numeric,text,text,bigint,text,timestamptz,text,uuid) to service_role;
grant execute on function command_api.income_upload_object(uuid,uuid,uuid) to service_role;
grant execute on function command_api.record_uploaded_income(uuid,uuid,bigint,text,uuid) to service_role;

-- Cancellation shares the posting lock: either recover the posted receipt, or
-- make this unposted upload permanently unable to post before allowing a new form.
create function command_api.cancel_income_upload(p_intent_id uuid,p_actor_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare intent evidence.income_upload_intents%rowtype; posted financial_ops.income_records%rowtype;
begin
  perform financial_ops.require_command_actor(p_actor_user_id);
  if not exists(select 1 from public.user_accounts where user_id=p_actor_user_id and status='active') then
    raise exception using errcode='42501', message='active receipt owner is required';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_intent_id::text,0));
  select * into intent from evidence.income_upload_intents where id=p_intent_id for update;
  if intent.id is null or intent.actor_user_id <> p_actor_user_id then
    raise exception using errcode='42501', message='receipt is not authorized';
  end if;
  if intent.income_record_id is not null then
    -- Cancellation is not a route around current financial-result authorization.
    perform evidence.authorize_income_target(p_actor_user_id,intent.target_membership_id,null,intent.gross_amount,intent.income_record_id);
    select * into posted from financial_ops.income_records where id=intent.income_record_id;
    return jsonb_build_object('cancelled',false,'operation_id',posted.id,
      'operation_reference',posted.operation_reference,'reused',true);
  end if;
  update evidence.income_upload_intents set cancelled_at=coalesce(cancelled_at,clock_timestamp()) where id=intent.id;
  return jsonb_build_object('cancelled',true);
end;
$$;
revoke all on function command_api.cancel_income_upload(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function command_api.cancel_income_upload(uuid,uuid) to service_role;
