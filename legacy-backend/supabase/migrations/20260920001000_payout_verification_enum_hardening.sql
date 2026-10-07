create or replace function financial_ops.record_payout_verification(
  p_verification_request_id uuid,
  p_payout_assertion_id uuid,
  p_extracted_facts jsonb,
  p_mismatch_reasons jsonb,
  p_verifier_name text,
  p_verifier_version text default null
)
returns financial_ops.payout_assertion_command_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_attempt evidence.verification_attempts%rowtype;
  existing_assertion_id uuid;
  target_assertion financial_ops.payout_completion_assertions%rowtype;
  target_revision financial_ops.payout_assertion_revisions%rowtype;
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
  verification_outcome evidence.verification_outcome;
begin
  if p_verification_request_id is null
     or p_payout_assertion_id is null
     or p_extracted_facts is null
     or jsonb_typeof(p_extracted_facts) <> 'object'
     or p_mismatch_reasons is null
     or jsonb_typeof(p_mismatch_reasons) <> 'array'
     or p_verifier_name is null
     or length(btrim(p_verifier_name)) = 0 then
    raise exception using
      errcode = '22023',
      message = 'payout verification input is invalid';
  end if;

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'extracted_facts', p_extracted_facts,
      'mismatch_reasons', p_mismatch_reasons,
      'payout_assertion_id', p_payout_assertion_id,
      'verifier_name', btrim(p_verifier_name),
      'verifier_version', nullif(btrim(p_verifier_version), '')
    )::text,
    'sha256'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_verification_request_id::text, 0)
  );

  select attempt.*
    into existing_attempt
    from evidence.verification_attempts attempt
   where attempt.verification_request_id = p_verification_request_id;

  if existing_attempt.id is not null then
    select revision.payout_assertion_id
      into existing_assertion_id
      from financial_ops.payout_assertion_revisions revision
     where revision.id = existing_attempt.payout_assertion_revision_id;
  end if;

  if existing_attempt.id is not null then
    if existing_attempt.request_fingerprint <> request_fingerprint
       or existing_assertion_id <> p_payout_assertion_id then
      raise exception using
        errcode = '23505',
        message = 'verification request already used with different payout data';
    end if;

    select *
      into target_assertion
      from financial_ops.payout_completion_assertions assertion
     where assertion.id = p_payout_assertion_id;

    select *
      into target_withdrawal
      from financial_ops.withdrawal_requests withdrawal
     where withdrawal.id = target_assertion.withdrawal_id;

    return (
      target_assertion.id,
      target_assertion.status,
      target_withdrawal.id,
      target_withdrawal.status,
      true
    )::financial_ops.payout_assertion_command_result;
  end if;

  select *
    into target_assertion
    from financial_ops.payout_completion_assertions assertion
   where assertion.id = p_payout_assertion_id
   for update;

  if target_assertion.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'payout completion assertion was not found';
  end if;

  if target_assertion.status <> 'submitted' then
    raise exception using
      errcode = '55000',
      message = 'only submitted payout evidence may be verified';
  end if;

  select *
    into target_revision
    from financial_ops.payout_assertion_revisions revision
   where revision.payout_assertion_id = target_assertion.id
     and revision.revision_number = target_assertion.current_revision_number;

  select *
    into target_withdrawal
    from financial_ops.withdrawal_requests withdrawal
   where withdrawal.id = target_assertion.withdrawal_id;

  verification_outcome := case
    when jsonb_array_length(p_mismatch_reasons) = 0
      then 'match'::evidence.verification_outcome
    else 'mismatch'::evidence.verification_outcome
  end;

  insert into evidence.verification_attempts (
    verification_request_id,
    payout_assertion_revision_id,
    request_fingerprint,
    outcome,
    extracted_facts,
    mismatch_reasons,
    verifier_name,
    verifier_version
  )
  values (
    p_verification_request_id,
    target_revision.id,
    request_fingerprint,
    verification_outcome,
    p_extracted_facts,
    p_mismatch_reasons,
    btrim(p_verifier_name),
    nullif(btrim(p_verifier_version), '')
  );

  if verification_outcome = 'match' then
    perform financial_ops.complete_withdrawal_from_assertion(
      target_assertion.id,
      'automated_match',
      null
    );
  else
    perform set_config(
      'financial_ops.payout_assertion_transition',
      target_assertion.id::text,
      true
    );

    update financial_ops.payout_completion_assertions
       set status = case
             when current_revision_number = 1
               then 'correction_required'::financial_ops.payout_assertion_status
             else 'needs_review'::financial_ops.payout_assertion_status
           end,
           version = version + 1
     where id = target_assertion.id
    returning * into target_assertion;

    perform set_config('financial_ops.payout_assertion_transition', '', true);

    insert into internal.outbox_events (
      tenant_id,
      aggregate_type,
      aggregate_id,
      event_type,
      payload
    )
    values (
      target_withdrawal.tenant_id,
      'payout_assertion',
      target_assertion.id,
      case
        when target_assertion.status = 'correction_required'
          then 'payout_correction_required'
        else 'financial_evidence_review_required'
      end,
      jsonb_build_object(
        'payout_assertion_id', target_assertion.id,
        'withdrawal_id', target_withdrawal.id,
        'status', target_assertion.status
      )
    );
  end if;

  select *
    into target_assertion
    from financial_ops.payout_completion_assertions assertion
   where assertion.id = p_payout_assertion_id;

  select *
    into target_withdrawal
    from financial_ops.withdrawal_requests withdrawal
   where withdrawal.id = target_assertion.withdrawal_id;

  return (
    target_assertion.id,
    target_assertion.status,
    target_withdrawal.id,
    target_withdrawal.status,
    false
  )::financial_ops.payout_assertion_command_result;
end;
$$;

revoke all on function financial_ops.record_payout_verification(
  uuid, uuid, jsonb, jsonb, text, text
) from public, anon, authenticated, service_role;
