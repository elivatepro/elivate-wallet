-- Private payout-specific operational queue. Evidence/model output is never a client command.
create table internal.payout_verification_jobs (
 id uuid primary key default extensions.gen_random_uuid(),
 stage_id uuid not null unique references evidence.payout_upload_stages(id),
 assertion_id uuid not null references financial_ops.payout_completion_assertions(id),
 revision_id uuid not null unique references financial_ops.payout_assertion_revisions(id),
 revision_number smallint not null check(revision_number in (1,2)),
 withdrawal_id uuid not null references financial_ops.withdrawal_requests(id),
 facts jsonb not null, destination jsonb not null, files jsonb not null,
 status text not null default 'queued' check(status in ('queued','leased','retry_scheduled','dead_lettered','completed','obsolete')),
 cycle integer not null default 1 check(cycle>0), attempt_number smallint not null default 0 check(attempt_number between 0 and 8),
 next_attempt_at timestamptz default clock_timestamp(), worker_id uuid, lease_token uuid unique, lease_expires_at timestamptz,
 last_error_code text, created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp(),
 check(jsonb_typeof(facts)='object' and jsonb_typeof(destination)='object' and jsonb_typeof(files)='array'),
 check(jsonb_array_length(files) between 1 and 20),
 check((status='leased')=(worker_id is not null and lease_token is not null and lease_expires_at is not null)),
 check((status in ('queued','retry_scheduled'))=(next_attempt_at is not null))
);
create index payout_verification_jobs_ready on internal.payout_verification_jobs(next_attempt_at,created_at,id) where status in ('queued','retry_scheduled');
create index payout_verification_jobs_leases on internal.payout_verification_jobs(lease_expires_at) where status='leased';
create table internal.payout_verification_results (
 lease_token uuid primary key, job_id uuid not null references internal.payout_verification_jobs(id), worker_id uuid not null,
 revision_id uuid not null references financial_ops.payout_assertion_revisions(id), request_fingerprint bytea not null,
 response jsonb not null, created_at timestamptz not null default clock_timestamp()
);
create table internal.payout_verification_retries (
 idempotency_key uuid primary key, actor_user_id uuid not null references public.user_accounts(user_id),
 assertion_id uuid not null references financial_ops.payout_completion_assertions(id),
 job_id uuid not null references internal.payout_verification_jobs(id), response jsonb not null,
 created_at timestamptz not null default clock_timestamp()
);
alter table internal.payout_verification_jobs enable row level security;
alter table internal.payout_verification_jobs force row level security;
alter table internal.payout_verification_results enable row level security;
alter table internal.payout_verification_results force row level security;
alter table internal.payout_verification_retries enable row level security;
alter table internal.payout_verification_retries force row level security;
create policy payout_verification_jobs_private_deny on internal.payout_verification_jobs as restrictive for all to public using(false) with check(false);
create policy payout_verification_results_private_deny on internal.payout_verification_results as restrictive for all to public using(false) with check(false);
create policy payout_verification_retries_private_deny on internal.payout_verification_retries as restrictive for all to public using(false) with check(false);
revoke all on internal.payout_verification_jobs,internal.payout_verification_results,internal.payout_verification_retries from public,anon,authenticated,service_role;
create trigger payout_verification_results_immutable before update or delete on internal.payout_verification_results for each row execute function authz.prevent_audit_mutation();
create trigger payout_verification_retries_immutable before update or delete on internal.payout_verification_retries for each row execute function authz.prevent_audit_mutation();

create function internal.guard_payout_verification_job()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if tg_op='DELETE' then raise exception using errcode='55000',message='payout verification history is retained'; end if;
 if new.id is distinct from old.id or new.stage_id is distinct from old.stage_id or new.assertion_id is distinct from old.assertion_id
 or new.revision_id is distinct from old.revision_id or new.revision_number is distinct from old.revision_number
 or new.withdrawal_id is distinct from old.withdrawal_id or new.facts is distinct from old.facts or new.destination is distinct from old.destination
 or new.files is distinct from old.files or new.created_at is distinct from old.created_at
 or old.status in ('completed','obsolete') then raise exception using errcode='55000',message='payout verification snapshot and terminal result are immutable'; end if;
 new.updated_at:=clock_timestamp(); return new;
end;
$$;
create trigger payout_verification_jobs_guard before update or delete on internal.payout_verification_jobs for each row execute function internal.guard_payout_verification_job();
revoke all on function internal.guard_payout_verification_job() from public,anon,authenticated,service_role;

-- Reconstruct only verified staged evidence and immutable revision/destination facts.
create function evidence.payout_verification_snapshot(p_stage_id uuid)
returns jsonb language plpgsql volatile security invoker set search_path='' as $$
declare s evidence.payout_upload_stages%rowtype; a financial_ops.payout_completion_assertions%rowtype;
 r financial_ops.payout_assertion_revisions%rowtype; d financial_ops.withdrawal_destination_snapshots%rowtype;
 files jsonb; expected_count integer;
begin
 select * into s from evidence.payout_upload_stages where id=p_stage_id;
 if s.result_assertion_id is null then return null; end if;
 select * into a from financial_ops.payout_completion_assertions where id=s.result_assertion_id;
 select * into r from financial_ops.payout_assertion_revisions where payout_assertion_id=a.id
 and revision_number=case when s.operation='submit' then 1 else 2 end;
 select * into d from financial_ops.withdrawal_destination_snapshots where withdrawal_id=s.withdrawal_id;
 if a.id is null or r.id is null or d.withdrawal_id is null or a.withdrawal_id<>s.withdrawal_id
 or a.submitted_by_user_id<>s.actor_user_id or r.submitted_by_user_id<>s.actor_user_id
 or not exists(select 1 from financial_ops.payout_command_idempotency c where c.idempotency_key=s.id
 and c.payout_assertion_id=a.id and c.actor_user_id=s.actor_user_id
 and c.command_type=case when s.operation='submit' then 'submit_payout_assertion' else 'correct_payout_assertion' end) then return null; end if;
 select count(*) into expected_count from evidence.payout_upload_files where stage_id=s.id;
 select jsonb_agg(jsonb_build_object('evidenceId',e.id,'bucket',e.storage_bucket_id,'path',e.storage_object_path,
 'mimeType',e.mime_type,'fileSizeBytes',e.file_size_bytes,'sha256Hex',encode(e.sha256,'hex')) order by f.ordinal)
 into files from evidence.payout_upload_files f
 join evidence.financial_evidence e on e.storage_object_path=f.storage_object_path and e.storage_bucket_id='financial-evidence'
 and e.file_size_bytes=f.file_size_bytes and e.mime_type=f.mime_type and encode(e.sha256,'hex')=f.sha256_hex
 and e.evidence_type='payout_completion' and e.submitted_by_user_id=s.actor_user_id
 join financial_ops.withdrawal_requests w on w.id=s.withdrawal_id and e.tenant_id=w.tenant_id
 join financial_ops.payout_assertion_evidence link on link.evidence_id=e.id and link.payout_assertion_revision_id=r.id
 where f.stage_id=s.id;
 if expected_count not between 1 and 20 or files is null or jsonb_array_length(files)<>expected_count
 or (select count(*) from financial_ops.payout_assertion_evidence where payout_assertion_revision_id=r.id)<>expected_count then return null; end if;
 return jsonb_build_object('assertionId',a.id,'revisionId',r.id,'revisionNumber',r.revision_number,'withdrawalId',s.withdrawal_id,
 'facts',jsonb_build_object('walletDebitAmount',r.wallet_debit_amount::text,'beneficiaryPayoutAmount',r.beneficiary_payout_amount::text,
 'providerFeeAmount',r.provider_fee_amount::text,'payoutCurrency',r.payout_currency,'provider',r.provider,
 'providerReference',r.provider_reference,'paidAt',r.paid_at),
 'destination',jsonb_build_object('accountReference',d.account_reference,'accountHolderName',d.account_holder_name,
 'institutionName',d.institution_name,'payoutCurrency',d.payout_currency),'files',files);
end;
$$;
revoke all on function evidence.payout_verification_snapshot(uuid) from public,anon,authenticated,service_role;

create function internal.enqueue_payout_verification(p_stage_id uuid)
returns void language plpgsql security invoker set search_path='' as $$
declare snapshot jsonb;
begin
 snapshot:=evidence.payout_verification_snapshot(p_stage_id);
 if snapshot is null or not exists(select 1 from financial_ops.payout_completion_assertions a
 where a.id=(snapshot->>'assertionId')::uuid and a.status='submitted'
 and a.current_revision_number=(snapshot->>'revisionNumber')::smallint) then return; end if;
 insert into internal.payout_verification_jobs(stage_id,assertion_id,revision_id,revision_number,withdrawal_id,facts,destination,files)
 values(p_stage_id,(snapshot->>'assertionId')::uuid,(snapshot->>'revisionId')::uuid,(snapshot->>'revisionNumber')::smallint,
 (snapshot->>'withdrawalId')::uuid,snapshot->'facts',snapshot->'destination',snapshot->'files') on conflict(revision_id) do nothing;
end;
$$;
revoke all on function internal.enqueue_payout_verification(uuid) from public,anon,authenticated,service_role;
create function internal.enqueue_finalized_payout_stage()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if old.result_assertion_id is null and new.result_assertion_id is not null then perform internal.enqueue_payout_verification(new.id); end if;
 return new;
end;
$$;
revoke all on function internal.enqueue_finalized_payout_stage() from public,anon,authenticated,service_role;
create trigger payout_stage_queue_verified_revision after update of result_assertion_id on evidence.payout_upload_stages for each row execute function internal.enqueue_finalized_payout_stage();
-- Existing finalized stages are eligible only when their exact verified revision is still submitted.
do $$ declare stage uuid; begin for stage in select id from evidence.payout_upload_stages where result_assertion_id is not null loop
 perform internal.enqueue_payout_verification(stage); end loop; end $$;

create function command_api.claim_payout_verification(p_worker_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare j internal.payout_verification_jobs%rowtype;
begin
 if p_worker_id is null then raise exception using errcode='22023',message='verification worker is required'; end if;
 -- Retire at most one hundred exhausted crashed leases per poll.
 update internal.payout_verification_jobs set status='dead_lettered',worker_id=null,lease_token=null,lease_expires_at=null,
 next_attempt_at=null,last_error_code='timeout' where id in(select id from internal.payout_verification_jobs
 where status='leased' and lease_expires_at<=clock_timestamp() and attempt_number=8 order by lease_expires_at limit 100 for update skip locked);
 select * into j from internal.payout_verification_jobs
 where attempt_number<8 and ((status in ('queued','retry_scheduled') and next_attempt_at<=clock_timestamp())
 or (status='leased' and lease_expires_at<=clock_timestamp())) order by coalesce(next_attempt_at,lease_expires_at),created_at,id
 limit 1 for update skip locked;
 if j.id is null then return null; end if;
 update internal.payout_verification_jobs set status='leased',worker_id=p_worker_id,lease_token=extensions.gen_random_uuid(),
 lease_expires_at=clock_timestamp()+interval '120 seconds',attempt_number=attempt_number+1,next_attempt_at=null where id=j.id returning * into j;
 return jsonb_build_object('jobId',j.id,'leaseToken',j.lease_token,'leaseExpiresAt',j.lease_expires_at,'attemptNumber',j.attempt_number,
 'assertionId',j.assertion_id,'revisionId',j.revision_id,'revisionNumber',j.revision_number,'verificationRequestId',j.id,
 'withdrawalId',j.withdrawal_id,'facts',j.facts,'destination',j.destination,'files',j.files);
end;
$$;

create function internal.payout_verification_replay(p_job uuid,p_worker uuid,p_token uuid,p_revision uuid,p_fingerprint bytea)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare receipt internal.payout_verification_results%rowtype;
begin
 select * into receipt from internal.payout_verification_results where lease_token=p_token;
 if receipt.lease_token is null then return null; end if;
 if receipt.job_id is distinct from p_job or receipt.worker_id is distinct from p_worker or receipt.revision_id is distinct from p_revision
 or receipt.request_fingerprint is distinct from p_fingerprint then raise exception using errcode='23505',message='verification lease already has different results'; end if;
 return receipt.response||jsonb_build_object('reused',true);
end;
$$;
revoke all on function internal.payout_verification_replay(uuid,uuid,uuid,uuid,bytea) from public,anon,authenticated,service_role;

create function command_api.fail_payout_verification(p_job_id uuid,p_worker_id uuid,p_lease_token uuid,p_revision_id uuid,p_error_code text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare j internal.payout_verification_jobs%rowtype; fingerprint bytea; response jsonb;
begin
 if p_job_id is null or p_worker_id is null or p_lease_token is null or p_revision_id is null or p_error_code is null
 or p_error_code not in ('configuration','invalid_receipt','provider_error','rate_limited','network','timeout','response_too_large','refused','incomplete','invalid_response','evidence_invalid','internal_error') then
 raise exception using errcode='22023',message='verification failure is invalid'; end if;
 fingerprint:=extensions.digest(jsonb_build_object('operation','fail','errorCode',p_error_code)::text,'sha256');
 select * into j from internal.payout_verification_jobs where id=p_job_id for update;
 response:=internal.payout_verification_replay(p_job_id,p_worker_id,p_lease_token,p_revision_id,fingerprint);
 if response is not null then return response; end if;
 if j.id is null or j.status<>'leased' or j.worker_id is distinct from p_worker_id or j.lease_token is distinct from p_lease_token
 or j.revision_id is distinct from p_revision_id or j.lease_expires_at<=clock_timestamp() then
 raise exception using errcode='42501',message='active verification lease is required'; end if;
 update internal.payout_verification_jobs set status=case when attempt_number=8 then 'dead_lettered' else 'retry_scheduled' end,
 next_attempt_at=case when attempt_number<8 then clock_timestamp()+make_interval(secs=>least(3600,30*(2^(attempt_number-1))::integer)) end,
 worker_id=null,lease_token=null,lease_expires_at=null,last_error_code=p_error_code where id=j.id returning * into j;
 response:=jsonb_build_object('jobId',j.id,'status',j.status,'retryAt',j.next_attempt_at,'reused',false);
 insert into internal.payout_verification_results(lease_token,job_id,worker_id,revision_id,request_fingerprint,response)
 values(p_lease_token,j.id,p_worker_id,p_revision_id,fingerprint,response);
 return response;
end;
$$;

-- Validate the trusted worker result schema before any automated posting.
create function internal.validate_payout_verification_result(p_job internal.payout_verification_jobs,p_facts jsonb,p_reasons jsonb)
returns void language plpgsql security invoker set search_path='' as $$
declare receipt jsonb; pair record; date_text text; observed_date date;
begin
 if jsonb_typeof(p_facts) is distinct from 'object' or jsonb_typeof(p_reasons) is distinct from 'array'
 or octet_length(p_facts::text)>65536 or jsonb_array_length(p_reasons)>20 then
 raise exception using errcode='22023',message='strict payout verification result is invalid'; end if;
 if (select count(*) from jsonb_object_keys(p_facts))<>5
 or exists(select 1 from jsonb_object_keys(p_facts) k where k not in ('policyVersion','checks','receiptFacts','evidenceCount','extractionSkipped'))
 or p_facts->>'policyVersion' is distinct from 'strict-single-receipt-v1'
 or jsonb_typeof(p_facts->'checks') is distinct from 'object' or jsonb_typeof(p_facts->'receiptFacts') is distinct from 'array'
 or p_facts->'evidenceCount' is distinct from to_jsonb(jsonb_array_length(p_job.files)) then
 raise exception using errcode='22023',message='strict payout verification result is invalid'; end if;
 if (select count(*) from jsonb_object_keys(p_facts->'checks'))<>7
 or exists(select 1 from jsonb_each(p_facts->'checks') c where c.key not in ('amount','currency','recipientAccount','recipientName','paymentStatus','paymentDate','confidence') or jsonb_typeof(c.value)<>'boolean')
 or exists(select 1 from jsonb_array_elements(p_reasons) r where jsonb_typeof(r)<>'string' or r#>>'{}' not in
 ('missing_evidence','ambiguous_evidence','invalid_expected','reading_confidence','payment_not_successful',
 'amount_missing','amount_invalid','amount_mismatch','currency_missing','currency_invalid','currency_mismatch',
 'recipientAccount_missing','recipientAccount_invalid','recipientAccount_mismatch','recipientName_missing','recipientName_invalid','recipientName_mismatch',
 'paymentDate_missing','paymentDate_invalid','paymentDate_mismatch')) then
 raise exception using errcode='22023',message='strict payout verification result is invalid'; end if;
 if jsonb_array_length(p_job.files)>1 then
  if p_facts->>'extractionSkipped' is distinct from 'multiple_receipts' or jsonb_array_length(p_facts->'receiptFacts')<>0
   or not p_reasons @> '["ambiguous_evidence"]'::jsonb or exists(select 1 from jsonb_each(p_facts->'checks') c where c.value<>'false'::jsonb) then
   raise exception using errcode='22023',message='multiple receipts cannot automatically verify a payout'; end if;
  return;
 end if;
 if p_facts->'extractionSkipped' is distinct from 'null'::jsonb or jsonb_array_length(p_facts->'receiptFacts')<>1 then
 raise exception using errcode='22023',message='single receipt facts are required'; end if;
 receipt:=p_facts->'receiptFacts'->0;
 if jsonb_typeof(receipt) is distinct from 'object' then raise exception using errcode='22023',message='receipt extraction schema is invalid'; end if;
 if (select count(*) from jsonb_object_keys(receipt))<>12 or exists(select 1 from jsonb_object_keys(receipt) k where k not in
 ('amount','currency','recipientAccount','recipientName','institutionName','transactionDateTime','transactionReference','paymentStatus','confidence','notes','walletDebitAmount','providerFeeAmount'))
 or receipt->>'paymentStatus' not in ('successful','failed','pending','unknown') or receipt->>'paymentStatus' is null
 or receipt->>'confidence' not in ('high','medium','low') or receipt->>'confidence' is null then
 raise exception using errcode='22023',message='receipt extraction schema is invalid'; end if;
 for pair in select * from jsonb_each(receipt) where key not in ('paymentStatus','confidence') loop
  if pair.value<>'null'::jsonb and (jsonb_typeof(pair.value)<>'string' or length(pair.value#>>'{}')>case pair.key when 'currency' then 3 when 'recipientAccount' then 64 when 'transactionDateTime' then 128 when 'notes' then 1000 else 255 end
    or length(btrim(pair.value#>>'{}'))=0 or pair.value#>>'{}'<>btrim(pair.value#>>'{}') or pair.value#>>'{}' ~ '[[:cntrl:]]') then
   raise exception using errcode='22023',message='receipt extraction schema is invalid'; end if;
  if pair.key in ('amount','walletDebitAmount','providerFeeAmount') and pair.value<>'null'::jsonb
   and pair.value#>>'{}' !~ '^(0|[1-9][0-9]{0,19})([.][0-9]{1,18})?$' then
   raise exception using errcode='22023',message='receipt extraction amount is invalid'; end if;
 end loop;
 if receipt->'recipientAccount'<>'null'::jsonb and receipt->>'recipientAccount' !~ '^[A-Za-z0-9*• -]+$' then raise exception using errcode='22023',message='receipt extraction account is invalid'; end if;
 if receipt->'currency'<>'null'::jsonb and receipt->>'currency' !~ '^[A-Z]{3}$' then raise exception using errcode='22023',message='receipt extraction currency is invalid'; end if;
 if jsonb_array_length(p_reasons)=0 then
  if exists(select 1 from jsonb_each(p_facts->'checks') c where c.value<>'true'::jsonb)
   or receipt->>'paymentStatus'<>'successful' or receipt->>'confidence'<>'high'
   or receipt->>'amount' is null or (receipt->>'amount')::numeric<>(p_job.facts->>'beneficiaryPayoutAmount')::numeric
   or receipt->>'currency' is distinct from p_job.facts->>'payoutCurrency'
   or receipt->>'recipientAccount' is null or length(receipt->>'recipientAccount')>64
   or replace(replace(receipt->>'recipientAccount',' ',''),'-','') !~ '^[0-9]+$'
   or replace(replace(receipt->>'recipientAccount',' ',''),'-','') is distinct from replace(replace(p_job.destination->>'accountReference',' ',''),'-','')
   or receipt->>'recipientName' is null or length(receipt->>'recipientName')>255
   or lower(regexp_replace(btrim(receipt->>'recipientName'),'[[:space:]]+',' ','g')) is distinct from lower(regexp_replace(btrim(p_job.destination->>'accountHolderName'),'[[:space:]]+',' ','g')) then
   raise exception using errcode='22023',message='automatic match does not substantiate frozen payout facts'; end if;
  date_text:=receipt->>'transactionDateTime';
  if date_text ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then observed_date:=date_text::date;
  elsif date_text ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9]([.][0-9]{1,9})?)?(Z|[+-](0[0-9]|1[0-4]):[0-5][0-9])$'
   and date_text !~ '[+-]14:(?!00)' then
   observed_date:=(regexp_replace(date_text,'([.][0-9]{3})[0-9]+','\1')::timestamptz at time zone 'UTC')::date;
  else raise exception using errcode='22023',message='automatic match has no unambiguous payment date'; end if;
  if observed_date is distinct from ((p_job.facts->>'paidAt')::timestamptz at time zone 'UTC')::date then
   raise exception using errcode='22023',message='automatic match has a different payment date'; end if;
 end if;
end;
$$;
revoke all on function internal.validate_payout_verification_result(internal.payout_verification_jobs,jsonb,jsonb) from public,anon,authenticated,service_role;

create function command_api.finish_payout_verification(p_job_id uuid,p_worker_id uuid,p_lease_token uuid,p_revision_id uuid,
 p_extracted_facts jsonb,p_mismatch_reasons jsonb,p_verifier_name text,p_verifier_version text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare j internal.payout_verification_jobs%rowtype; a financial_ops.payout_completion_assertions%rowtype;
 fingerprint bytea; response jsonb; snapshot jsonb; result financial_ops.payout_assertion_command_result;
begin
 if p_job_id is null or p_worker_id is null or p_lease_token is null or p_revision_id is null
 or p_verifier_name is distinct from 'openai' or p_verifier_version is null or p_verifier_version !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' then
 raise exception using errcode='22023',message='verification result identity is invalid'; end if;
 fingerprint:=extensions.digest(jsonb_build_object('operation','finish','facts',p_extracted_facts,'reasons',p_mismatch_reasons,
 'verifier',p_verifier_name,'version',p_verifier_version)::text,'sha256');
 select * into j from internal.payout_verification_jobs where id=p_job_id for update;
 response:=internal.payout_verification_replay(p_job_id,p_worker_id,p_lease_token,p_revision_id,fingerprint);
 if response is not null then return response; end if;
 if j.id is null or j.status<>'leased' or j.worker_id is distinct from p_worker_id or j.lease_token is distinct from p_lease_token
 or j.revision_id is distinct from p_revision_id or j.lease_expires_at<=clock_timestamp() then
 raise exception using errcode='42501',message='active verification lease is required'; end if;
 perform internal.validate_payout_verification_result(j,p_extracted_facts,p_mismatch_reasons);
 -- Lock the exact assertion before the legacy helper resolves current_revision_number.
 -- A delayed first-revision result can never affect a later correction revision.
 select * into a from financial_ops.payout_completion_assertions where id=j.assertion_id for update;
 if j.lease_expires_at<=clock_timestamp() then raise exception using errcode='42501',message='active verification lease is required'; end if;
 if a.status is distinct from 'submitted' or a.current_revision_number is distinct from j.revision_number then
  update internal.payout_verification_jobs set status='obsolete',worker_id=null,lease_token=null,lease_expires_at=null,next_attempt_at=null where id=j.id;
  response:=jsonb_build_object('jobId',j.id,'status','obsolete','result',null,'reused',false);
 else
  snapshot:=evidence.payout_verification_snapshot(j.stage_id);
  if snapshot is null or snapshot->>'revisionId' is distinct from j.revision_id::text
   or snapshot->'facts' is distinct from j.facts or snapshot->'destination' is distinct from j.destination or snapshot->'files' is distinct from j.files then
   raise exception using errcode='23514',message='verification evidence provenance is invalid'; end if;
  -- Assertion locking may wait: expiry is checked again at the posting boundary.
  if j.lease_expires_at<=clock_timestamp() then raise exception using errcode='42501',message='active verification lease is required'; end if;
  result:=financial_ops.record_payout_verification(j.id,j.assertion_id,p_extracted_facts,p_mismatch_reasons,p_verifier_name,p_verifier_version);
  update internal.payout_verification_jobs set status='completed',worker_id=null,lease_token=null,lease_expires_at=null,next_attempt_at=null,last_error_code=null where id=j.id;
  response:=jsonb_build_object('jobId',j.id,'status','completed','result',to_jsonb(result),'reused',false);
 end if;
 insert into internal.payout_verification_results(lease_token,job_id,worker_id,revision_id,request_fingerprint,response)
 values(p_lease_token,j.id,p_worker_id,p_revision_id,fingerprint,response);
 return response;
end;
$$;

create function command_api.retry_payout_verification(p_actor_user_id uuid,p_actor_membership_id uuid,p_session_id uuid,p_assertion_id uuid,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a financial_ops.payout_completion_assertions%rowtype; w financial_ops.withdrawal_requests%rowtype;
 j internal.payout_verification_jobs%rowtype; prior internal.payout_verification_retries%rowtype;
 decision authz.authorization_decision; selection jsonb; response jsonb;
begin
 perform financial_ops.require_command_actor(p_actor_user_id);
 if p_idempotency_key is null then raise exception using errcode='22023',message='verification retry key is required'; end if;
 select * into a from financial_ops.payout_completion_assertions where id=p_assertion_id;
 select * into w from financial_ops.withdrawal_requests where id=a.withdrawal_id;
 if a.id is null or a.submitted_by_user_id is distinct from p_actor_user_id or w.approved_by_user_id is distinct from p_actor_user_id then
 raise exception using errcode='42501',message='original payout actor is required'; end if;
 selection:=read_api.leadership_payouts(p_actor_user_id,p_actor_membership_id,null,null,null,w.id);
 if jsonb_array_length(selection->'items')<>1 then raise exception using errcode='42501',message='verification retry is outside the selected workspace'; end if;
 decision:=authz.authorize(p_actor_user_id,p_session_id,'approve_withdrawal',w.tenant_id,w.office_id,w.membership_id,w.owner_user_id,w.wallet_id,w.owner_user_id,'retry_payout_verification');
 if decision.decision='STEP_UP_REQUIRED' then raise exception using errcode='P0401',message='verification retry requires device verification'; end if;
 perform financial_ops.enforce_authorization(decision);
 if not authz.is_elevated_session_valid(p_session_id,p_actor_user_id) then raise exception using errcode='P0401',message='verification retry requires device verification'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('payout-verification-retry:'||p_idempotency_key::text,0));
 select * into prior from internal.payout_verification_retries where idempotency_key=p_idempotency_key;
 if prior.idempotency_key is not null then
  if prior.actor_user_id<>p_actor_user_id or prior.assertion_id<>p_assertion_id then raise exception using errcode='23505',message='retry key already has different payout intent'; end if;
  return prior.response||jsonb_build_object('reused',true);
 end if;
 -- Use the worker lock order (job then assertion) to avoid correction/finish races.
 select * into j from internal.payout_verification_jobs where assertion_id=a.id and revision_number=a.current_revision_number for update;
 select * into a from financial_ops.payout_completion_assertions where id=p_assertion_id for update;
 if j.id is null or j.status<>'dead_lettered' or a.status<>'submitted' or a.current_revision_number<>j.revision_number then
 raise exception using errcode='55000',message='current payout verification is not awaiting retry'; end if;
 update internal.payout_verification_jobs set status='queued',attempt_number=0,cycle=cycle+1,next_attempt_at=clock_timestamp(),
 last_error_code=null,worker_id=null,lease_token=null,lease_expires_at=null where id=j.id;
 response:=jsonb_build_object('jobId',j.id,'payoutAssertionId',a.id,'status','queued','reused',false);
 insert into internal.payout_verification_retries(idempotency_key,actor_user_id,assertion_id,job_id,response)
 values(p_idempotency_key,p_actor_user_id,a.id,j.id,response);
 perform financial_ops.record_authorization_audit(decision,p_session_id,'payout_verification_retried',w.id,
 jsonb_build_object('job_id',j.id,'assertion_id',a.id,'revision_id',j.revision_id));
 return response;
end;
$$;
revoke all on function command_api.claim_payout_verification(uuid) from public,anon,authenticated,service_role;
revoke all on function command_api.fail_payout_verification(uuid,uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
revoke all on function command_api.finish_payout_verification(uuid,uuid,uuid,uuid,jsonb,jsonb,text,text) from public,anon,authenticated,service_role;
revoke all on function command_api.retry_payout_verification(uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function command_api.claim_payout_verification(uuid) to service_role;
grant execute on function command_api.fail_payout_verification(uuid,uuid,uuid,uuid,text) to service_role;
grant execute on function command_api.finish_payout_verification(uuid,uuid,uuid,uuid,jsonb,jsonb,text,text) to service_role;
grant execute on function command_api.retry_payout_verification(uuid,uuid,uuid,uuid,uuid) to service_role;

-- Safe status only; private proofs, destination and file coordinates stay in the worker boundary.
create or replace function read_api.payout_read_item(p_actor_user_id uuid, p_withdrawal_id uuid, p_permissions jsonb)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'withdrawal_id', withdrawal.id, 'reference', withdrawal.withdrawal_reference,
    'currency_code', withdrawal.source_currency_code, 'scale', currency.minor_unit_scale,
    'wallet_uid', owner.public_uid, 'office_name', office.name, 'pocket_name', pocket.display_name,
    'requested_amount', withdrawal.requested_amount::text, 'status', withdrawal.status,
    'created_at', withdrawal.created_at, 'updated_at', withdrawal.updated_at,
    'approved_at', withdrawal.approved_at, 'completed_at', withdrawal.completed_at,
    'destination', jsonb_build_object('institution_name', snapshot.institution_name,
      'account_reference_masked', case when length(snapshot.account_reference)>4 then '••••' || right(snapshot.account_reference,4) else '••••' end,
      'account_holder_name', snapshot.account_holder_name, 'payout_currency', snapshot.payout_currency,
      'payout_rail', snapshot.payout_rail, 'country_code', snapshot.country_code),
    'latest_assertion', case when assertion.id is null then null else jsonb_build_object(
      'assertion_id', assertion.id, 'status', assertion.status,
      'current_revision_number', assertion.current_revision_number,
      'verification',case when verification.id is null then null else jsonb_build_object('status',verification.status,
        'last_error_code',verification.last_error_code,'next_attempt_at',verification.next_attempt_at,
        'attempt_number',verification.attempt_number,'updated_at',verification.updated_at) end,
      'revision', jsonb_build_object('wallet_debit_amount', revision.wallet_debit_amount::text,
        'beneficiary_payout_amount', revision.beneficiary_payout_amount::text,
        'provider_fee_amount', revision.provider_fee_amount::text, 'payout_currency', revision.payout_currency,
        'provider', revision.provider, 'provider_reference', revision.provider_reference,
        'paid_at', revision.paid_at, 'notes', revision.notes),
      'evidence', coalesce((select jsonb_agg(jsonb_build_object('evidence_id', evidence.id,
        'original_filename', evidence.original_filename, 'mime_type', evidence.mime_type,
        'file_size_bytes', evidence.file_size_bytes) order by evidence.id)
        from financial_ops.payout_assertion_evidence link
        join evidence.financial_evidence evidence on evidence.id = link.evidence_id
        where link.payout_assertion_revision_id = revision.id), '[]'::jsonb)
    ) end,
    'capabilities', jsonb_build_object(
      'retryVerification',coalesce((p_permissions->>'approval')::boolean and withdrawal.approved_by_user_id=p_actor_user_id
        and assertion.submitted_by_user_id=p_actor_user_id and assertion.status='submitted'
        and verification.status='dead_lettered',false),
      'reveal', coalesce((p_permissions->>'approval')::boolean and withdrawal.status='approved'
        and withdrawal.approved_by_user_id=p_actor_user_id and withdrawal.owner_user_id<>p_actor_user_id
        and exists(select 1 from financial_ops.funding_reservations reservation where reservation.withdrawal_id=withdrawal.id and reservation.status='active'),false),
      'approve', (p_permissions->>'approval')::boolean and withdrawal.status = 'requested',
      'reject', (p_permissions->>'approval')::boolean and withdrawal.status = 'requested',
      'cancel', (p_permissions->>'approval')::boolean and withdrawal.status = 'approved'
        and (assertion.id is null or assertion.status not in ('submitted','correction_required','needs_review')),
      'record', (p_permissions->>'approval')::boolean and withdrawal.status = 'approved'
        and withdrawal.approved_by_user_id = p_actor_user_id
        and (assertion.id is null or assertion.status not in ('submitted','correction_required','needs_review')),
      'correct', coalesce((p_permissions->>'approval')::boolean and withdrawal.status = 'approved'
        and withdrawal.approved_by_user_id = p_actor_user_id and assertion.submitted_by_user_id = p_actor_user_id
        and assertion.status = 'correction_required' and assertion.current_revision_number = 1,false),
      'review', coalesce((p_permissions->>'review')::boolean and assertion.status = 'needs_review'
        and assertion.submitted_by_user_id <> p_actor_user_id,false)
    )
  ) from financial_ops.withdrawal_requests withdrawal
  join ledger.currency_definitions currency on currency.currency_code = withdrawal.source_currency_code
  join public.user_accounts owner on owner.user_id = withdrawal.owner_user_id
  join public.offices office on office.id = withdrawal.office_id and office.tenant_id = withdrawal.tenant_id
  join public.pocket_definitions pocket on pocket.pocket_key = withdrawal.source_pocket_key
  join financial_ops.withdrawal_destination_snapshots snapshot on snapshot.withdrawal_id = withdrawal.id
  left join lateral (select * from financial_ops.payout_completion_assertions candidate
    where candidate.withdrawal_id = withdrawal.id order by candidate.assertion_number desc limit 1) assertion on true
  left join financial_ops.payout_assertion_revisions revision on revision.payout_assertion_id = assertion.id
    and revision.revision_number = assertion.current_revision_number
  left join internal.payout_verification_jobs verification on verification.revision_id=revision.id
  where withdrawal.id = p_withdrawal_id;
$$;
