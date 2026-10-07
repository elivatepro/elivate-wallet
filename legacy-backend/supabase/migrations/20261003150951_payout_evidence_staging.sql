-- Transport staging is private, temporary evidence state, never financial truth.
create table evidence.payout_upload_stages (
  id uuid primary key,
  actor_user_id uuid not null references public.user_accounts(user_id),
  withdrawal_id uuid not null references financial_ops.withdrawal_requests(id),
  operation text not null check (operation in ('submit','correct')),
  payout_assertion_id uuid references financial_ops.payout_completion_assertions(id),
  facts jsonb not null,
  descriptors jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null default clock_timestamp()+interval '2 hours',
  result_assertion_id uuid references financial_ops.payout_completion_assertions(id),
  check ((operation='correct') = (payout_assertion_id is not null))
);
create table evidence.payout_upload_files (
  id uuid primary key default extensions.gen_random_uuid(),
  stage_id uuid not null references evidence.payout_upload_stages(id),
  ordinal smallint not null check (ordinal between 1 and 20),
  original_filename text not null,
  mime_type text not null check (mime_type in ('application/pdf','image/jpeg','image/png')),
  file_size_bytes bigint not null check (file_size_bytes between 1 and 10485760),
  sha256_hex text not null check (sha256_hex ~ '^[0-9a-f]{64}$'),
  storage_object_path text not null unique,
  unique(stage_id,ordinal)
);
alter table evidence.payout_upload_stages enable row level security;
alter table evidence.payout_upload_stages force row level security;
alter table evidence.payout_upload_files enable row level security;
alter table evidence.payout_upload_files force row level security;
create policy payout_upload_stages_private_deny on evidence.payout_upload_stages as restrictive for all to public using(false) with check(false);
create policy payout_upload_files_private_deny on evidence.payout_upload_files as restrictive for all to public using(false) with check(false);
revoke all on evidence.payout_upload_stages,evidence.payout_upload_files from public,anon,authenticated,service_role;

create function evidence.authorize_payout_stage(p_stage evidence.payout_upload_stages,p_actor uuid,p_session uuid,p_allow_expired boolean default false)
returns void language plpgsql security invoker set search_path='' as $$
declare w financial_ops.withdrawal_requests%rowtype; a financial_ops.payout_completion_assertions%rowtype; decision authz.authorization_decision;
begin
  perform financial_ops.require_command_actor(p_actor);
  select * into w from financial_ops.withdrawal_requests where id=p_stage.withdrawal_id;
  if p_stage.actor_user_id <> p_actor or w.id is null or w.approved_by_user_id is distinct from p_actor then
    raise exception using errcode='42501',message='original approving actor is required';
  end if;
  decision:=authz.authorize(p_actor,p_session,'approve_withdrawal',w.tenant_id,w.office_id,w.membership_id,
    w.owner_user_id,w.wallet_id,w.owner_user_id,
    case when p_stage.operation='submit' then 'record_payout_completion' else 'correct_payout_completion' end,
    (p_stage.facts->>'walletDebitAmount')::numeric);
  -- Preserve the public transport distinction between a device-verification
  -- challenge and a denial. The older canonical helper maps both to 42501.
  if decision.decision = 'STEP_UP_REQUIRED' then
    raise exception using errcode='P0401',message='receipt recording requires device verification';
  end if;
  perform financial_ops.enforce_authorization(decision);
  -- Finalized stages replay the canonical command: its result and current authority
  -- survive status transitions, but stale unposted uploads never become new commands.
  if p_stage.result_assertion_id is null then
    if w.status <> 'approved' then raise exception using errcode='55000',message='approved withdrawal is required'; end if;
    if p_stage.expires_at <= clock_timestamp() and not p_allow_expired then raise exception using errcode='55000',message='receipt upload has expired'; end if;
    if p_stage.operation='correct' then
      select * into a from financial_ops.payout_completion_assertions where id=p_stage.payout_assertion_id;
      if a.id is null or a.withdrawal_id <> w.id or a.submitted_by_user_id <> p_actor then
        raise exception using errcode='42501',message='original assertion actor is required';
      end if;
      if a.status <> 'correction_required' or a.current_revision_number <> 1 then
        raise exception using errcode='55000',message='assertion is not awaiting its first correction';
      end if;
    elsif exists(select 1 from financial_ops.payout_completion_assertions where withdrawal_id=w.id
       and status in ('submitted','correction_required','needs_review')) then
      raise exception using errcode='55000',message='withdrawal already has an unresolved assertion';
    end if;
    perform financial_ops.validate_direct_payout_facts(w.id,(p_stage.facts->>'walletDebitAmount')::numeric,
      (p_stage.facts->>'beneficiaryPayoutAmount')::numeric,p_stage.facts->>'payoutCurrency',
      (p_stage.facts->>'providerFeeAmount')::numeric,(p_stage.facts->>'paidAt')::timestamptz);
  end if;
end;
$$;
revoke all on function evidence.authorize_payout_stage(evidence.payout_upload_stages,uuid,uuid,boolean) from public,anon,authenticated,service_role;

create function command_api.request_payout_evidence_upload(p_idempotency_key uuid,p_actor_user_id uuid,p_withdrawal_id uuid,
  p_operation text,p_payout_assertion_id uuid,p_facts jsonb,p_files jsonb,p_session_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s evidence.payout_upload_stages%rowtype; item jsonb; file_id uuid; n smallint:=0; tenant uuid;
begin
  perform financial_ops.require_command_actor(p_actor_user_id);
  if p_idempotency_key is null or p_withdrawal_id is null or p_operation not in ('submit','correct')
    or p_operation is null or ((p_operation='correct') is distinct from (p_payout_assertion_id is not null))
    or jsonb_typeof(p_facts) is distinct from 'object' or jsonb_typeof(p_files) is distinct from 'array' then
    raise exception using errcode='22023',message='receipt request is invalid';
  end if;
  if jsonb_array_length(p_files) not between 1 and 20
    or exists(select 1 from jsonb_object_keys(p_facts) k where k not in
      ('walletDebitAmount','beneficiaryPayoutAmount','payoutCurrency','provider','paidAt','providerFeeAmount','providerReference','notes'))
    or coalesce(p_facts->>'walletDebitAmount','') !~ '^(0|[1-9][0-9]{0,19})([.][0-9]{1,18})?$'
    or coalesce(p_facts->>'beneficiaryPayoutAmount','') !~ '^(0|[1-9][0-9]{0,19})([.][0-9]{1,18})?$'
    or coalesce(p_facts->>'providerFeeAmount','') !~ '^(0|[1-9][0-9]{0,19})([.][0-9]{1,18})?$'
    or coalesce(p_facts->>'payoutCurrency','') !~ '^[A-Z]{3}$'
    or coalesce(p_facts->>'paidAt','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{3}Z$'
    or length(btrim(coalesce(p_facts->>'provider',''))) not between 1 and 100
    or length(coalesce(p_facts->>'providerReference',''))>255 or length(coalesce(p_facts->>'notes',''))>2000 then
    raise exception using errcode='22023',message='receipt facts are invalid';
  end if;
  for item in select value from jsonb_array_elements(p_files) loop
    if jsonb_typeof(item) <> 'object' or exists(select 1 from jsonb_object_keys(item) k where k not in
      ('originalFilename','mimeType','fileSizeBytes','sha256Hex'))
      or length(btrim(coalesce(item->>'originalFilename',''))) not between 1 and 255
      or coalesce(item->>'mimeType','') not in ('application/pdf','image/jpeg','image/png')
      or coalesce(item->>'fileSizeBytes','') !~ '^[1-9][0-9]{0,7}$'
      or (item->>'fileSizeBytes')::bigint>10485760
      or coalesce(item->>'sha256Hex','') !~ '^[0-9a-f]{64}$' then
      raise exception using errcode='22023',message='receipt descriptor is invalid';
    end if;
  end loop;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_idempotency_key::text,0));
  select * into s from evidence.payout_upload_stages where id=p_idempotency_key for update;
  if s.id is not null then
    if s.actor_user_id<>p_actor_user_id or s.withdrawal_id<>p_withdrawal_id or s.operation<>p_operation
       or s.payout_assertion_id is distinct from p_payout_assertion_id or s.facts<>p_facts or s.descriptors<>p_files then
      raise exception using errcode='23505',message='receipt key already has different facts';
    end if;
  else
    s.id:=p_idempotency_key; s.actor_user_id:=p_actor_user_id; s.withdrawal_id:=p_withdrawal_id;
    s.operation:=p_operation; s.payout_assertion_id:=p_payout_assertion_id; s.facts:=p_facts; s.descriptors:=p_files;
    s.created_at:=clock_timestamp(); s.expires_at:=s.created_at+interval '2 hours';
    perform evidence.authorize_payout_stage(s,p_actor_user_id,p_session_id);
    insert into evidence.payout_upload_stages select s.*;
    select tenant_id into tenant from financial_ops.withdrawal_requests where id=p_withdrawal_id;
    for item in select value from jsonb_array_elements(p_files) loop
      n:=n+1; file_id:=extensions.gen_random_uuid();
      insert into evidence.payout_upload_files(id,stage_id,ordinal,original_filename,mime_type,file_size_bytes,sha256_hex,storage_object_path)
      values(file_id,s.id,n,item->>'originalFilename',item->>'mimeType',(item->>'fileSizeBytes')::bigint,item->>'sha256Hex',
        tenant::text||'/payout/'||s.id::text||'/'||file_id::text);
    end loop;
  end if;
  -- Holding the same key and row locks as finalization proves an expired,
  -- unfinalized stage cannot subsequently commit. Retry never extends its TTL.
  perform evidence.authorize_payout_stage(s,p_actor_user_id,p_session_id,true);
  if s.result_assertion_id is null and s.expires_at <= clock_timestamp() then
    return jsonb_build_object('stageId',s.id,'expiresAt',s.expires_at,'operation',s.operation,
      'finalized',false,'expired',true,'files','[]'::jsonb);
  end if;
  return command_api.payout_upload_objects(s.id,p_actor_user_id,p_session_id);
end;
$$;

create function command_api.payout_upload_objects(p_stage_id uuid,p_actor_user_id uuid,p_session_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s evidence.payout_upload_stages%rowtype;
begin
  select * into s from evidence.payout_upload_stages where id=p_stage_id;
  if s.id is null then raise exception using errcode='42501',message='receipt is not authorized'; end if;
  perform evidence.authorize_payout_stage(s,p_actor_user_id,p_session_id);
  return jsonb_build_object('stageId',s.id,'expiresAt',s.expires_at,'operation',s.operation,
    'finalized',s.result_assertion_id is not null,'expired',false,'files',coalesce((select jsonb_agg(jsonb_build_object(
      'fileId',f.id,'bucket','financial-evidence','path',f.storage_object_path,'originalFilename',f.original_filename,
      'mimeType',f.mime_type,'fileSizeBytes',f.file_size_bytes,'sha256Hex',f.sha256_hex) order by f.ordinal)
      from evidence.payout_upload_files f where f.stage_id=s.id),'[]'::jsonb));
end;
$$;

create function command_api.finalize_payout_evidence(p_stage_id uuid,p_actor_user_id uuid,p_verified_files jsonb,p_session_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s evidence.payout_upload_stages%rowtype; metadata jsonb; result financial_ops.payout_assertion_command_result;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_stage_id::text,0));
  select * into s from evidence.payout_upload_stages where id=p_stage_id for update;
  if s.id is null then raise exception using errcode='42501',message='receipt is not authorized'; end if;
  perform evidence.authorize_payout_stage(s,p_actor_user_id,p_session_id);
  if s.result_assertion_id is null then
    if jsonb_typeof(p_verified_files) is distinct from 'array' then
      raise exception using errcode='22023',message='verified receipts are required';
    end if;
    if jsonb_array_length(p_verified_files)<>(select count(*) from evidence.payout_upload_files where stage_id=s.id)
      or exists(select 1 from evidence.payout_upload_files f where f.stage_id=s.id and
        (select count(*) from jsonb_array_elements(p_verified_files) v where v->>'fileId'=f.id::text
         and v->>'mimeType'=f.mime_type and v->>'sha256Hex'=f.sha256_hex
         and v->>'fileSizeBytes'=f.file_size_bytes::text)<>1) then
      raise exception using errcode='23514',message='receipt bytes do not match the upload request';
    end if;
  end if;
  select jsonb_agg(jsonb_build_object('storage_bucket_id','financial-evidence','storage_object_path',f.storage_object_path,
    'original_filename',f.original_filename,'mime_type',f.mime_type,'file_size_bytes',f.file_size_bytes,
    'sha256_hex',f.sha256_hex,'observed_at',to_char(s.created_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'provider',s.facts->>'provider',
    'provider_reference',s.facts->>'providerReference','notes',s.facts->>'notes') order by f.ordinal)
    into metadata from evidence.payout_upload_files f where f.stage_id=s.id;
  if s.operation='submit' then
    result:=financial_ops.submit_payout_assertion(s.id,s.withdrawal_id,(s.facts->>'walletDebitAmount')::numeric,
      (s.facts->>'beneficiaryPayoutAmount')::numeric,s.facts->>'payoutCurrency',s.facts->>'provider',
      (s.facts->>'paidAt')::timestamptz,metadata,p_actor_user_id,(s.facts->>'providerFeeAmount')::numeric,
      s.facts->>'providerReference',s.facts->>'notes',p_session_id);
  else
    result:=financial_ops.correct_payout_assertion(s.id,s.payout_assertion_id,(s.facts->>'walletDebitAmount')::numeric,
      (s.facts->>'beneficiaryPayoutAmount')::numeric,s.facts->>'payoutCurrency',s.facts->>'provider',
      (s.facts->>'paidAt')::timestamptz,metadata,p_actor_user_id,(s.facts->>'providerFeeAmount')::numeric,
      s.facts->>'providerReference',s.facts->>'notes',p_session_id);
  end if;
  update evidence.payout_upload_stages set result_assertion_id=result.payout_assertion_id where id=s.id;
  return to_jsonb(result);
end;
$$;

-- Only evidence visible in the selected leadership detail can be downloaded.
create function command_api.payout_evidence_download_object(p_actor_user_id uuid,p_actor_membership_id uuid,p_evidence_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare withdrawal uuid; item jsonb; e evidence.financial_evidence%rowtype;
begin
  perform financial_ops.require_command_actor(p_actor_user_id);
  select a.withdrawal_id into withdrawal from evidence.financial_evidence fe
    join financial_ops.payout_assertion_evidence link on link.evidence_id=fe.id
    join financial_ops.payout_assertion_revisions r on r.id=link.payout_assertion_revision_id
    join financial_ops.payout_completion_assertions a on a.id=r.payout_assertion_id
    where fe.id=p_evidence_id and fe.evidence_type='payout_completion';
  if withdrawal is null then raise exception using errcode='42501',message='receipt is not authorized'; end if;
  item:=read_api.leadership_payouts(p_actor_user_id,p_actor_membership_id,null,null,null,withdrawal)->'items'->0;
  if item is null or not exists(select 1 from jsonb_array_elements(coalesce(item->'latest_assertion'->'evidence','[]'::jsonb)) v
    where v->>'evidence_id'=p_evidence_id::text) then
    raise exception using errcode='42501',message='receipt is not authorized';
  end if;
  select * into e from evidence.financial_evidence where id=p_evidence_id;
  -- Prior raw transports accepted client paths. Metadata alone is not proof
  -- that the file belongs to this tenant: only verified staged objects are signed.
  if e.storage_bucket_id<>'financial-evidence' or not exists(
    select 1 from evidence.payout_upload_files f join evidence.payout_upload_stages s on s.id=f.stage_id
    where f.storage_object_path=e.storage_object_path and s.withdrawal_id=withdrawal
      and s.result_assertion_id is not null and s.actor_user_id=e.submitted_by_user_id
      and f.file_size_bytes=e.file_size_bytes and f.mime_type=e.mime_type
      and f.sha256_hex=encode(e.sha256,'hex')
  ) then raise exception using errcode='42501',message='receipt storage is not authorized'; end if;
  return jsonb_build_object('bucket',e.storage_bucket_id,'path',e.storage_object_path,'originalFilename',e.original_filename);
end;
$$;
revoke all on function command_api.request_payout_evidence_upload(uuid,uuid,uuid,text,uuid,jsonb,jsonb,uuid) from public,anon,authenticated,service_role;
revoke all on function command_api.payout_upload_objects(uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function command_api.finalize_payout_evidence(uuid,uuid,jsonb,uuid) from public,anon,authenticated,service_role;
revoke all on function command_api.payout_evidence_download_object(uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function command_api.request_payout_evidence_upload(uuid,uuid,uuid,text,uuid,jsonb,jsonb,uuid) to service_role;
grant execute on function command_api.payout_upload_objects(uuid,uuid,uuid) to service_role;
grant execute on function command_api.finalize_payout_evidence(uuid,uuid,jsonb,uuid) to service_role;
grant execute on function command_api.payout_evidence_download_object(uuid,uuid,uuid) to service_role;
