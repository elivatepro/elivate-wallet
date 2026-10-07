create or replace function evidence.attach_payout_evidence(
  p_tenant_id uuid,
  p_payout_assertion_revision_id uuid,
  p_submitted_by_user_id uuid,
  p_evidence_items jsonb
)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  evidence_item jsonb;
  target_evidence evidence.financial_evidence%rowtype;
  existing_evidence_id uuid;
  superseded_evidence_id uuid;
  attached_count integer := 0;
begin
  if p_tenant_id is null
     or p_payout_assertion_revision_id is null
     or p_submitted_by_user_id is null
     or p_evidence_items is null
     or jsonb_typeof(p_evidence_items) <> 'array'
     or jsonb_array_length(p_evidence_items) = 0 then
    raise exception using
      errcode = '22023',
      message = 'payout completion requires at least one evidence item';
  end if;

  for evidence_item in
    select value from jsonb_array_elements(p_evidence_items)
  loop
    if jsonb_typeof(evidence_item) <> 'object' then
      raise exception using
        errcode = '22023',
        message = 'payout evidence item must be an object';
    end if;

    existing_evidence_id := nullif(evidence_item ->> 'existing_evidence_id', '')::uuid;

    if existing_evidence_id is not null then
      select *
        into target_evidence
        from evidence.financial_evidence item
       where item.id = existing_evidence_id
         and item.tenant_id = p_tenant_id
         and item.submitted_by_user_id = p_submitted_by_user_id
         and item.evidence_type = 'payout_completion';

      if target_evidence.id is null then
        raise exception using
          errcode = '23514',
          message = 'reused payout evidence must belong to the same tenant and submitter';
      end if;
    else
      if coalesce(evidence_item ->> 'storage_bucket_id', '') = ''
         or coalesce(evidence_item ->> 'storage_object_path', '') = ''
         or coalesce(evidence_item ->> 'original_filename', '') = ''
         or coalesce(evidence_item ->> 'mime_type', '') = ''
         or coalesce(evidence_item ->> 'file_size_bytes', '') !~ '^[1-9][0-9]*$'
         or coalesce(evidence_item ->> 'sha256_hex', '') !~ '^[0-9A-Fa-f]{64}$'
         or coalesce(evidence_item ->> 'observed_at', '') = '' then
        raise exception using
          errcode = '22023',
          message = 'payout evidence metadata is incomplete';
      end if;

      superseded_evidence_id :=
        nullif(evidence_item ->> 'supersedes_evidence_id', '')::uuid;

      if superseded_evidence_id is not null
         and not exists (
           select 1
             from evidence.financial_evidence prior
            where prior.id = superseded_evidence_id
              and prior.tenant_id = p_tenant_id
              and prior.evidence_type = 'payout_completion'
         ) then
        raise exception using
          errcode = '23514',
          message = 'superseded payout evidence must belong to the same tenant';
      end if;

      insert into evidence.financial_evidence (
        tenant_id,
        evidence_type,
        storage_bucket_id,
        storage_object_path,
        original_filename,
        mime_type,
        file_size_bytes,
        sha256,
        submitted_by_user_id,
        provider,
        observed_at,
        provider_reference,
        notes,
        supersedes_evidence_id
      )
      values (
        p_tenant_id,
        'payout_completion',
        btrim(evidence_item ->> 'storage_bucket_id'),
        btrim(evidence_item ->> 'storage_object_path'),
        btrim(evidence_item ->> 'original_filename'),
        btrim(evidence_item ->> 'mime_type'),
        (evidence_item ->> 'file_size_bytes')::bigint,
        decode(lower(evidence_item ->> 'sha256_hex'), 'hex'),
        p_submitted_by_user_id,
        nullif(btrim(evidence_item ->> 'provider'), ''),
        (evidence_item ->> 'observed_at')::timestamptz,
        nullif(btrim(evidence_item ->> 'provider_reference'), ''),
        nullif(btrim(evidence_item ->> 'notes'), ''),
        superseded_evidence_id
      )
      returning * into target_evidence;
    end if;

    insert into financial_ops.payout_assertion_evidence (
      payout_assertion_revision_id,
      evidence_id
    )
    values (
      p_payout_assertion_revision_id,
      target_evidence.id
    );

    attached_count := attached_count + 1;
  end loop;

  return attached_count;
end;
$$;

create or replace function financial_ops.validate_direct_payout_facts(
  p_withdrawal_id uuid,
  p_wallet_debit_amount numeric,
  p_beneficiary_payout_amount numeric,
  p_payout_currency text,
  p_provider_fee_amount numeric,
  p_paid_at timestamptz
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
  target_reservation financial_ops.funding_reservations%rowtype;
  destination_currency text;
  currency_scale smallint;
begin
  if p_withdrawal_id is null
     or p_wallet_debit_amount is null
     or p_wallet_debit_amount <= 0
     or p_beneficiary_payout_amount is null
     or p_beneficiary_payout_amount <= 0
     or p_payout_currency is null
     or p_payout_currency !~ '^[A-Z]{3}$'
     or p_provider_fee_amount is null
     or p_provider_fee_amount < 0
     or p_paid_at is null then
    raise exception using
      errcode = '22023',
      message = 'payout completion facts are invalid';
  end if;

  select *
    into target_withdrawal
    from financial_ops.withdrawal_requests withdrawal
   where withdrawal.id = p_withdrawal_id;

  select *
    into target_reservation
    from financial_ops.funding_reservations reservation
   where reservation.withdrawal_id = p_withdrawal_id;

  select snapshot.payout_currency
    into destination_currency
    from financial_ops.withdrawal_destination_snapshots snapshot
   where snapshot.withdrawal_id = p_withdrawal_id;

  select currency.minor_unit_scale
    into currency_scale
    from ledger.currency_definitions currency
   where currency.currency_code = p_payout_currency;

  if target_withdrawal.id is null
     or target_withdrawal.status <> 'approved'
     or target_reservation.id is null
     or target_reservation.status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'payout completion requires an approved funded withdrawal';
  end if;

  if p_payout_currency <> target_withdrawal.source_currency_code
     or p_payout_currency <> destination_currency then
    raise exception using
      errcode = '0A000',
      message = 'payout currency conversion must be completed by the conversion domain first';
  end if;

  if currency_scale is null
     or round(p_wallet_debit_amount, currency_scale) <> p_wallet_debit_amount
     or round(p_beneficiary_payout_amount, currency_scale)
          <> p_beneficiary_payout_amount
     or round(p_provider_fee_amount, currency_scale) <> p_provider_fee_amount then
    raise exception using
      errcode = '23514',
      message = 'payout amounts exceed the currency minor-unit scale';
  end if;

  if p_wallet_debit_amount > target_reservation.amount then
    raise exception using
      errcode = '23514',
      message = 'payout Wallet debit exceeds the authorized reservation';
  end if;

  if p_wallet_debit_amount
       <> p_beneficiary_payout_amount + p_provider_fee_amount then
    raise exception using
      errcode = '23514',
      message = 'payout amount and provider fee must explain the Wallet debit';
  end if;

  if p_paid_at < target_withdrawal.approved_at then
    raise exception using
      errcode = '23514',
      message = 'payout completion timestamp cannot precede withdrawal approval';
  end if;
end;
$$;

create or replace function evidence.validate_verification_attempt()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_assertion financial_ops.payout_completion_assertions%rowtype;
  revision_number smallint;
begin
  select assertion.*
    into target_assertion
    from financial_ops.payout_assertion_revisions revision
    join financial_ops.payout_completion_assertions assertion
      on assertion.id = revision.payout_assertion_id
   where revision.id = new.payout_assertion_revision_id;

  select revision.revision_number
    into revision_number
    from financial_ops.payout_assertion_revisions revision
   where revision.id = new.payout_assertion_revision_id;

  if target_assertion.id is null
     or target_assertion.status <> 'submitted'
     or target_assertion.current_revision_number <> revision_number then
    raise exception using
      errcode = '23514',
      message = 'verification attempt must target the submitted current payout revision';
  end if;

  return new;
end;
$$;

create trigger verification_attempts_validate
  before insert on evidence.verification_attempts
  for each row execute function evidence.validate_verification_attempt();

create or replace function evidence.validate_review_decision()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_assertion financial_ops.payout_completion_assertions%rowtype;
  assignment_user_id uuid;
begin
  select *
    into target_assertion
    from financial_ops.payout_completion_assertions assertion
   where assertion.id = new.payout_assertion_id;

  select assignment.reviewer_user_id
    into assignment_user_id
    from authz.financial_evidence_reviewer_assignments assignment
    join public.memberships membership
      on membership.tenant_id = assignment.tenant_id
     and membership.id = assignment.reviewer_membership_id
   where assignment.id = new.reviewer_assignment_id
     and assignment.revoked_at is null
     and membership.status = 'active';

  if target_assertion.id is null
     or target_assertion.status <> 'needs_review'
     or assignment_user_id is null
     or assignment_user_id <> new.reviewer_user_id
     or target_assertion.submitted_by_user_id = new.reviewer_user_id then
    raise exception using
      errcode = '23514',
      message = 'financial evidence review decision is outside the active review assignment';
  end if;

  return new;
end;
$$;

create trigger review_decisions_validate
  before insert on evidence.review_decisions
  for each row execute function evidence.validate_review_decision();

create or replace function financial_ops.complete_withdrawal_from_assertion(
  p_payout_assertion_id uuid,
  p_resolution financial_ops.payout_resolution,
  p_resolution_actor_user_id uuid default null
)
returns ledger.post_transaction_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_assertion financial_ops.payout_completion_assertions%rowtype;
  target_revision financial_ops.payout_assertion_revisions%rowtype;
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
  target_reservation financial_ops.funding_reservations%rowtype;
  external_payout_account_id uuid;
  provider_fee_account_id uuid;
  journal_postings jsonb;
  request_fingerprint bytea;
  posting_result ledger.post_transaction_result;
begin
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

  if (p_resolution = 'automated_match' and target_assertion.status <> 'submitted')
     or (p_resolution = 'manual_clear' and target_assertion.status <> 'needs_review') then
    raise exception using
      errcode = '55000',
      message = 'payout assertion is not ready for final posting';
  end if;

  select *
    into target_revision
    from financial_ops.payout_assertion_revisions revision
   where revision.payout_assertion_id = target_assertion.id
     and revision.revision_number = target_assertion.current_revision_number;

  select *
    into target_withdrawal
    from financial_ops.withdrawal_requests withdrawal
   where withdrawal.id = target_assertion.withdrawal_id
   for update;

  select *
    into target_reservation
    from financial_ops.funding_reservations reservation
   where reservation.withdrawal_id = target_withdrawal.id
   for update;

  if target_revision.id is null
     or target_withdrawal.id is null
     or target_withdrawal.status <> 'approved'
     or target_withdrawal.approved_by_user_id <> target_assertion.submitted_by_user_id
     or target_reservation.id is null
     or target_reservation.status <> 'active'
     or target_reservation.ledger_account_id
          <> target_withdrawal.source_ledger_account_id then
    raise exception using
      errcode = '23514',
      message = 'payout final posting requires its approved funded withdrawal';
  end if;

  perform financial_ops.validate_direct_payout_facts(
    target_withdrawal.id,
    target_revision.wallet_debit_amount,
    target_revision.beneficiary_payout_amount,
    target_revision.payout_currency,
    target_revision.provider_fee_amount,
    target_revision.paid_at
  );

  if not exists (
    select 1
      from financial_ops.payout_assertion_evidence link
     where link.payout_assertion_revision_id = target_revision.id
  ) then
    raise exception using
      errcode = '23514',
      message = 'payout final posting requires immutable evidence';
  end if;

  if p_resolution = 'automated_match'
     and not exists (
       select 1
         from evidence.verification_attempts attempt
        where attempt.payout_assertion_revision_id = target_revision.id
          and attempt.outcome = 'match'
     ) then
    raise exception using
      errcode = '23514',
      message = 'automated payout completion requires a matching verification attempt';
  end if;

  if p_resolution = 'manual_clear'
     and (
       p_resolution_actor_user_id is null
       or not exists (
         select 1
           from evidence.review_decisions decision
          where decision.payout_assertion_id = target_assertion.id
            and decision.reviewer_user_id = p_resolution_actor_user_id
            and decision.decision = 'clear'
       )
     ) then
    raise exception using
      errcode = '23514',
      message = 'manual payout completion requires an authorized clearance decision';
  end if;

  select account.id
    into external_payout_account_id
    from ledger.ledger_accounts account
   where account.account_class = 'system_counter'
     and account.currency_code = target_revision.payout_currency
     and account.system_account_key = 'external_payout';

  if external_payout_account_id is null then
    raise exception using
      errcode = '23514',
      message = 'external payout ledger account is not configured for the currency';
  end if;

  journal_postings := jsonb_build_array(
    jsonb_build_object(
      'ledger_account_id', target_withdrawal.source_ledger_account_id,
      'amount', -target_revision.wallet_debit_amount
    ),
    jsonb_build_object(
      'ledger_account_id', external_payout_account_id,
      'amount', target_revision.beneficiary_payout_amount
    )
  );

  if target_revision.provider_fee_amount > 0 then
    select account.id
      into provider_fee_account_id
      from ledger.ledger_accounts account
     where account.account_class = 'system_counter'
       and account.currency_code = target_revision.payout_currency
       and account.system_account_key = 'provider_fee';

    if provider_fee_account_id is null then
      raise exception using
        errcode = '23514',
        message = 'provider fee ledger account is not configured for the currency';
    end if;

    journal_postings := journal_postings || jsonb_build_array(
      jsonb_build_object(
        'ledger_account_id', provider_fee_account_id,
        'amount', target_revision.provider_fee_amount
      )
    );
  end if;

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'payout_assertion_id', target_assertion.id,
      'payout_assertion_revision_id', target_revision.id,
      'resolution', p_resolution,
      'wallet_debit_amount', target_revision.wallet_debit_amount,
      'beneficiary_payout_amount', target_revision.beneficiary_payout_amount,
      'provider_fee_amount', target_revision.provider_fee_amount,
      'payout_currency', target_revision.payout_currency,
      'withdrawal_id', target_withdrawal.id
    )::text,
    'sha256'
  );

  posting_result := ledger.post_transaction(
    target_assertion.id,
    request_fingerprint,
    'withdrawal',
    target_withdrawal.membership_id,
    target_withdrawal.wallet_id,
    target_withdrawal.approved_by_user_id,
    jsonb_build_array(
      jsonb_build_object(
        'currency_code', target_revision.payout_currency,
        'postings', journal_postings
      )
    ),
    jsonb_build_object(
      'withdrawal_id', target_withdrawal.id,
      'withdrawal_reference', target_withdrawal.withdrawal_reference,
      'payout_assertion_id', target_assertion.id,
      'payout_assertion_revision_id', target_revision.id,
      'resolution', p_resolution,
      'beneficiary_payout_amount', target_revision.beneficiary_payout_amount,
      'provider_fee_amount', target_revision.provider_fee_amount,
      'provider', target_revision.provider
    )
  );

  perform set_config(
    'financial_ops.withdrawal_transition',
    target_withdrawal.id::text,
    true
  );
  perform set_config(
    'financial_ops.reservation_transition',
    target_reservation.id::text,
    true
  );
  perform set_config(
    'financial_ops.payout_assertion_transition',
    target_assertion.id::text,
    true
  );

  update financial_ops.funding_reservations
     set status = 'consumed',
         consumed_at = clock_timestamp()
   where id = target_reservation.id;

  update financial_ops.withdrawal_requests
     set status = 'completed',
         version = version + 1,
         completed_at = clock_timestamp(),
         financial_transaction_id = posting_result.financial_transaction_id
   where id = target_withdrawal.id;

  update financial_ops.payout_completion_assertions
     set status = 'posted',
         version = version + 1,
         accepted_via = p_resolution,
         accepted_at = clock_timestamp(),
         posted_financial_transaction_id = posting_result.financial_transaction_id
   where id = target_assertion.id;

  perform set_config('financial_ops.withdrawal_transition', '', true);
  perform set_config('financial_ops.reservation_transition', '', true);
  perform set_config('financial_ops.payout_assertion_transition', '', true);

  insert into authz.security_audit_events (
    actor_user_id,
    tenant_id,
    event_type,
    permission_key,
    target_type,
    target_id,
    allowed,
    source,
    reason_code,
    metadata
  )
  values (
    target_withdrawal.approved_by_user_id,
    target_withdrawal.tenant_id,
    'withdrawal_completed',
    'approve_withdrawal',
    'withdrawal',
    target_withdrawal.id,
    true,
    'system_rule',
    'verified_payout_completion',
    jsonb_build_object(
      'payout_assertion_id', target_assertion.id,
      'financial_transaction_id', posting_result.financial_transaction_id,
      'resolution', p_resolution
    )
  );

  insert into internal.outbox_events (
    tenant_id,
    aggregate_type,
    aggregate_id,
    event_type,
    payload
  )
  values (
    target_withdrawal.tenant_id,
    'withdrawal',
    target_withdrawal.id,
    'withdrawal_completed',
    jsonb_build_object(
      'withdrawal_id', target_withdrawal.id,
      'payout_assertion_id', target_assertion.id,
      'financial_transaction_id', posting_result.financial_transaction_id
    )
  );

  return posting_result;
end;
$$;

create or replace function financial_ops.submit_payout_assertion(
  p_idempotency_key uuid,
  p_withdrawal_id uuid,
  p_wallet_debit_amount numeric,
  p_beneficiary_payout_amount numeric,
  p_payout_currency text,
  p_provider text,
  p_paid_at timestamptz,
  p_evidence_items jsonb,
  p_actor_user_id uuid,
  p_provider_fee_amount numeric default 0,
  p_provider_reference text default null,
  p_notes text default null,
  p_session_id uuid default null
)
returns financial_ops.payout_assertion_command_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.payout_command_idempotency%rowtype;
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
  target_reservation financial_ops.funding_reservations%rowtype;
  target_assertion financial_ops.payout_completion_assertions%rowtype;
  target_revision financial_ops.payout_assertion_revisions%rowtype;
  authorization_decision authz.authorization_decision;
  next_assertion_number smallint;
begin
  if p_idempotency_key is null
     or p_withdrawal_id is null
     or p_actor_user_id is null
     or p_provider is null
     or length(btrim(p_provider)) = 0 then
    raise exception using
      errcode = '22023',
      message = 'payout assertion input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'payout assertion actor does not match the authenticated user';
  end if;

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'beneficiary_payout_amount', p_beneficiary_payout_amount,
      'evidence_items', p_evidence_items,
      'notes', nullif(btrim(p_notes), ''),
      'paid_at', p_paid_at,
      'payout_currency', p_payout_currency,
      'provider', btrim(p_provider),
      'provider_fee_amount', p_provider_fee_amount,
      'provider_reference', nullif(btrim(p_provider_reference), ''),
      'wallet_debit_amount', p_wallet_debit_amount,
      'withdrawal_id', p_withdrawal_id
    )::text,
    'sha256'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  select *
    into existing_command
    from financial_ops.payout_command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.command_type <> 'submit_payout_assertion'
       or existing_command.request_fingerprint <> request_fingerprint
       or existing_command.actor_user_id <> p_actor_user_id then
      raise exception using
        errcode = '23505',
        message = 'idempotency key already used with different payout command data';
    end if;

    return (
      existing_command.payout_assertion_id,
      existing_command.result_assertion_status,
      p_withdrawal_id,
      existing_command.result_withdrawal_status,
      true
    )::financial_ops.payout_assertion_command_result;
  end if;

  select *
    into target_withdrawal
    from financial_ops.withdrawal_requests withdrawal
   where withdrawal.id = p_withdrawal_id
   for update;

  if target_withdrawal.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'withdrawal request was not found';
  end if;

  if target_withdrawal.status <> 'approved'
     or target_withdrawal.approved_by_user_id <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'payout assertion must be submitted by the withdrawal approving actor';
  end if;

  select *
    into target_reservation
    from financial_ops.funding_reservations reservation
   where reservation.withdrawal_id = target_withdrawal.id
   for update;

  if target_reservation.id is null or target_reservation.status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'payout assertion requires an active funding reservation';
  end if;

  if exists (
    select 1
      from financial_ops.payout_completion_assertions assertion
     where assertion.withdrawal_id = target_withdrawal.id
       and assertion.status in ('submitted', 'correction_required', 'needs_review')
  ) then
    raise exception using
      errcode = '55000',
      message = 'withdrawal already has an unresolved payout assertion';
  end if;

  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'approve_withdrawal',
    target_withdrawal.tenant_id,
    target_withdrawal.office_id,
    target_withdrawal.membership_id,
    target_withdrawal.owner_user_id,
    target_withdrawal.wallet_id,
    target_withdrawal.owner_user_id,
    'record_payout_completion',
    p_wallet_debit_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);

  perform financial_ops.validate_direct_payout_facts(
    target_withdrawal.id,
    p_wallet_debit_amount,
    p_beneficiary_payout_amount,
    p_payout_currency,
    p_provider_fee_amount,
    p_paid_at
  );

  select (coalesce(max(assertion.assertion_number), 0) + 1)::smallint
    into next_assertion_number
    from financial_ops.payout_completion_assertions assertion
   where assertion.withdrawal_id = target_withdrawal.id;

  insert into financial_ops.payout_completion_assertions (
    withdrawal_id,
    assertion_number,
    submitted_by_user_id
  )
  values (
    target_withdrawal.id,
    next_assertion_number,
    p_actor_user_id
  )
  returning * into target_assertion;

  insert into financial_ops.payout_assertion_revisions (
    payout_assertion_id,
    revision_number,
    wallet_debit_amount,
    beneficiary_payout_amount,
    payout_currency,
    provider_fee_amount,
    provider_fee_currency,
    provider,
    provider_reference,
    paid_at,
    notes,
    submitted_by_user_id
  )
  values (
    target_assertion.id,
    1,
    p_wallet_debit_amount,
    p_beneficiary_payout_amount,
    p_payout_currency,
    p_provider_fee_amount,
    case when p_provider_fee_amount > 0 then p_payout_currency end,
    btrim(p_provider),
    nullif(btrim(p_provider_reference), ''),
    p_paid_at,
    nullif(btrim(p_notes), ''),
    p_actor_user_id
  )
  returning * into target_revision;

  perform evidence.attach_payout_evidence(
    target_withdrawal.tenant_id,
    target_revision.id,
    p_actor_user_id,
    p_evidence_items
  );

  insert into financial_ops.payout_command_idempotency (
    idempotency_key,
    command_type,
    request_fingerprint,
    payout_assertion_id,
    actor_user_id,
    result_assertion_status,
    result_withdrawal_status
  )
  values (
    p_idempotency_key,
    'submit_payout_assertion',
    request_fingerprint,
    target_assertion.id,
    p_actor_user_id,
    target_assertion.status,
    target_withdrawal.status
  );

  perform financial_ops.record_authorization_audit(
    authorization_decision,
    p_session_id,
    'payout_assertion_submitted',
    target_withdrawal.id,
    jsonb_build_object(
      'payout_assertion_id', target_assertion.id,
      'revision_number', 1
    )
  );

  return (
    target_assertion.id,
    target_assertion.status,
    target_withdrawal.id,
    target_withdrawal.status,
    false
  )::financial_ops.payout_assertion_command_result;
end;
$$;

create or replace function financial_ops.correct_payout_assertion(
  p_idempotency_key uuid,
  p_payout_assertion_id uuid,
  p_wallet_debit_amount numeric,
  p_beneficiary_payout_amount numeric,
  p_payout_currency text,
  p_provider text,
  p_paid_at timestamptz,
  p_evidence_items jsonb,
  p_actor_user_id uuid,
  p_provider_fee_amount numeric default 0,
  p_provider_reference text default null,
  p_notes text default null,
  p_session_id uuid default null
)
returns financial_ops.payout_assertion_command_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.payout_command_idempotency%rowtype;
  target_assertion financial_ops.payout_completion_assertions%rowtype;
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
  target_revision financial_ops.payout_assertion_revisions%rowtype;
  authorization_decision authz.authorization_decision;
begin
  if p_idempotency_key is null
     or p_payout_assertion_id is null
     or p_actor_user_id is null
     or p_provider is null
     or length(btrim(p_provider)) = 0 then
    raise exception using
      errcode = '22023',
      message = 'payout assertion correction input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'payout assertion actor does not match the authenticated user';
  end if;

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'beneficiary_payout_amount', p_beneficiary_payout_amount,
      'evidence_items', p_evidence_items,
      'notes', nullif(btrim(p_notes), ''),
      'paid_at', p_paid_at,
      'payout_assertion_id', p_payout_assertion_id,
      'payout_currency', p_payout_currency,
      'provider', btrim(p_provider),
      'provider_fee_amount', p_provider_fee_amount,
      'provider_reference', nullif(btrim(p_provider_reference), ''),
      'wallet_debit_amount', p_wallet_debit_amount
    )::text,
    'sha256'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  select *
    into existing_command
    from financial_ops.payout_command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.command_type <> 'correct_payout_assertion'
       or existing_command.request_fingerprint <> request_fingerprint
       or existing_command.actor_user_id <> p_actor_user_id then
      raise exception using
        errcode = '23505',
        message = 'idempotency key already used with different payout command data';
    end if;

    select *
      into target_assertion
      from financial_ops.payout_completion_assertions assertion
     where assertion.id = existing_command.payout_assertion_id;

    select *
      into target_withdrawal
      from financial_ops.withdrawal_requests withdrawal
     where withdrawal.id = target_assertion.withdrawal_id;

    return (
      existing_command.payout_assertion_id,
      existing_command.result_assertion_status,
      target_withdrawal.id,
      existing_command.result_withdrawal_status,
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

  select *
    into target_withdrawal
    from financial_ops.withdrawal_requests withdrawal
   where withdrawal.id = target_assertion.withdrawal_id
   for update;

  if target_assertion.status <> 'correction_required'
     or target_assertion.current_revision_number <> 1
     or target_assertion.submitted_by_user_id <> p_actor_user_id
     or target_withdrawal.status <> 'approved'
     or target_withdrawal.approved_by_user_id <> p_actor_user_id then
    raise exception using
      errcode = '55000',
      message = 'payout assertion does not allow another correction';
  end if;

  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'approve_withdrawal',
    target_withdrawal.tenant_id,
    target_withdrawal.office_id,
    target_withdrawal.membership_id,
    target_withdrawal.owner_user_id,
    target_withdrawal.wallet_id,
    target_withdrawal.owner_user_id,
    'correct_payout_completion',
    p_wallet_debit_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);

  perform financial_ops.validate_direct_payout_facts(
    target_withdrawal.id,
    p_wallet_debit_amount,
    p_beneficiary_payout_amount,
    p_payout_currency,
    p_provider_fee_amount,
    p_paid_at
  );

  insert into financial_ops.payout_assertion_revisions (
    payout_assertion_id,
    revision_number,
    wallet_debit_amount,
    beneficiary_payout_amount,
    payout_currency,
    provider_fee_amount,
    provider_fee_currency,
    provider,
    provider_reference,
    paid_at,
    notes,
    submitted_by_user_id
  )
  values (
    target_assertion.id,
    2,
    p_wallet_debit_amount,
    p_beneficiary_payout_amount,
    p_payout_currency,
    p_provider_fee_amount,
    case when p_provider_fee_amount > 0 then p_payout_currency end,
    btrim(p_provider),
    nullif(btrim(p_provider_reference), ''),
    p_paid_at,
    nullif(btrim(p_notes), ''),
    p_actor_user_id
  )
  returning * into target_revision;

  perform evidence.attach_payout_evidence(
    target_withdrawal.tenant_id,
    target_revision.id,
    p_actor_user_id,
    p_evidence_items
  );

  perform set_config(
    'financial_ops.payout_assertion_transition',
    target_assertion.id::text,
    true
  );

  update financial_ops.payout_completion_assertions
     set status = 'submitted',
         current_revision_number = 2,
         version = version + 1
   where id = target_assertion.id
  returning * into target_assertion;

  perform set_config('financial_ops.payout_assertion_transition', '', true);

  insert into financial_ops.payout_command_idempotency (
    idempotency_key,
    command_type,
    request_fingerprint,
    payout_assertion_id,
    actor_user_id,
    result_assertion_status,
    result_withdrawal_status
  )
  values (
    p_idempotency_key,
    'correct_payout_assertion',
    request_fingerprint,
    target_assertion.id,
    p_actor_user_id,
    target_assertion.status,
    target_withdrawal.status
  );

  perform financial_ops.record_authorization_audit(
    authorization_decision,
    p_session_id,
    'payout_assertion_corrected',
    target_withdrawal.id,
    jsonb_build_object(
      'payout_assertion_id', target_assertion.id,
      'revision_number', 2
    )
  );

  return (
    target_assertion.id,
    target_assertion.status,
    target_withdrawal.id,
    target_withdrawal.status,
    false
  )::financial_ops.payout_assertion_command_result;
end;
$$;

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
    when jsonb_array_length(p_mismatch_reasons) = 0 then 'match'
    else 'mismatch'
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
             when current_revision_number = 1 then 'correction_required'
             else 'needs_review'
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

create or replace function financial_ops.review_payout_assertion(
  p_idempotency_key uuid,
  p_payout_assertion_id uuid,
  p_decision evidence.review_decision,
  p_review_note text,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.payout_assertion_command_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.payout_command_idempotency%rowtype;
  target_assertion financial_ops.payout_completion_assertions%rowtype;
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
  authorization_decision authz.authorization_decision;
  reviewer_assignment_id uuid;
begin
  if p_idempotency_key is null
     or p_payout_assertion_id is null
     or p_decision is null
     or p_review_note is null
     or length(btrim(p_review_note)) = 0
     or p_actor_user_id is null then
    raise exception using
      errcode = '22023',
      message = 'financial evidence review input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'financial evidence reviewer does not match the authenticated user';
  end if;

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'decision', p_decision,
      'payout_assertion_id', p_payout_assertion_id,
      'review_note', btrim(p_review_note)
    )::text,
    'sha256'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  select *
    into existing_command
    from financial_ops.payout_command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.command_type <> 'review_payout_assertion'
       or existing_command.request_fingerprint <> request_fingerprint
       or existing_command.actor_user_id <> p_actor_user_id then
      raise exception using
        errcode = '23505',
        message = 'idempotency key already used with different payout command data';
    end if;

    select *
      into target_assertion
      from financial_ops.payout_completion_assertions assertion
     where assertion.id = existing_command.payout_assertion_id;

    select *
      into target_withdrawal
      from financial_ops.withdrawal_requests withdrawal
     where withdrawal.id = target_assertion.withdrawal_id;

    return (
      existing_command.payout_assertion_id,
      existing_command.result_assertion_status,
      target_withdrawal.id,
      existing_command.result_withdrawal_status,
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

  select *
    into target_withdrawal
    from financial_ops.withdrawal_requests withdrawal
   where withdrawal.id = target_assertion.withdrawal_id
   for update;

  if target_assertion.status <> 'needs_review' then
    raise exception using
      errcode = '55000',
      message = 'payout assertion is not awaiting financial evidence review';
  end if;

  if target_assertion.submitted_by_user_id = p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'financial evidence reviewer cannot review their own payout operation';
  end if;

  authorization_decision := authz.authorize_financial_evidence_review(
    p_actor_user_id,
    p_session_id,
    target_withdrawal.tenant_id,
    target_withdrawal.office_id,
    target_withdrawal.membership_id,
    target_withdrawal.owner_user_id,
    target_withdrawal.wallet_id,
    'review_payout_assertion'
  );

  perform financial_ops.enforce_authorization(authorization_decision);
  reviewer_assignment_id := authorization_decision.source_id;

  insert into evidence.review_decisions (
    payout_assertion_id,
    reviewer_assignment_id,
    reviewer_user_id,
    decision,
    review_note
  )
  values (
    target_assertion.id,
    reviewer_assignment_id,
    p_actor_user_id,
    p_decision,
    btrim(p_review_note)
  );

  if p_decision = 'clear' then
    perform financial_ops.complete_withdrawal_from_assertion(
      target_assertion.id,
      'manual_clear',
      p_actor_user_id
    );
  else
    perform set_config(
      'financial_ops.payout_assertion_transition',
      target_assertion.id::text,
      true
    );

    update financial_ops.payout_completion_assertions
       set status = 'rejected',
           version = version + 1
     where id = target_assertion.id;

    perform set_config('financial_ops.payout_assertion_transition', '', true);
  end if;

  select *
    into target_assertion
    from financial_ops.payout_completion_assertions assertion
   where assertion.id = p_payout_assertion_id;

  select *
    into target_withdrawal
    from financial_ops.withdrawal_requests withdrawal
   where withdrawal.id = target_assertion.withdrawal_id;

  insert into financial_ops.payout_command_idempotency (
    idempotency_key,
    command_type,
    request_fingerprint,
    payout_assertion_id,
    actor_user_id,
    result_assertion_status,
    result_withdrawal_status
  )
  values (
    p_idempotency_key,
    'review_payout_assertion',
    request_fingerprint,
    target_assertion.id,
    p_actor_user_id,
    target_assertion.status,
    target_withdrawal.status
  );

  insert into authz.security_audit_events (
    actor_user_id,
    session_id,
    tenant_id,
    event_type,
    permission_key,
    target_type,
    target_id,
    allowed,
    source,
    source_id,
    reason_code,
    metadata
  )
  values (
    p_actor_user_id,
    p_session_id,
    target_withdrawal.tenant_id,
    case
      when p_decision = 'clear' then 'payout_evidence_cleared'
      else 'payout_evidence_rejected'
    end,
    authorization_decision.permission_key,
    'payout_assertion',
    target_assertion.id,
    true,
    authorization_decision.source,
    authorization_decision.source_id,
    authorization_decision.reason_code,
    jsonb_build_object(
      'decision', p_decision,
      'withdrawal_id', target_withdrawal.id
    )
  );

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
      when p_decision = 'clear' then 'payout_evidence_cleared'
      else 'payout_evidence_rejected'
    end,
    jsonb_build_object(
      'payout_assertion_id', target_assertion.id,
      'withdrawal_id', target_withdrawal.id,
      'status', target_assertion.status
    )
  );

  return (
    target_assertion.id,
    target_assertion.status,
    target_withdrawal.id,
    target_withdrawal.status,
    false
  )::financial_ops.payout_assertion_command_result;
end;
$$;

revoke all on function evidence.attach_payout_evidence(uuid, uuid, uuid, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function financial_ops.validate_direct_payout_facts(
  uuid, numeric, numeric, text, numeric, timestamptz
) from public, anon, authenticated, service_role;
revoke all on function evidence.validate_verification_attempt()
  from public, anon, authenticated, service_role;
revoke all on function evidence.validate_review_decision()
  from public, anon, authenticated, service_role;
revoke all on function financial_ops.complete_withdrawal_from_assertion(
  uuid, financial_ops.payout_resolution, uuid
) from public, anon, authenticated, service_role;
revoke all on function financial_ops.submit_payout_assertion(
  uuid, uuid, numeric, numeric, text, text, timestamptz, jsonb, uuid,
  numeric, text, text, uuid
) from public, anon, authenticated, service_role;
revoke all on function financial_ops.correct_payout_assertion(
  uuid, uuid, numeric, numeric, text, text, timestamptz, jsonb, uuid,
  numeric, text, text, uuid
) from public, anon, authenticated, service_role;
revoke all on function financial_ops.record_payout_verification(
  uuid, uuid, jsonb, jsonb, text, text
) from public, anon, authenticated, service_role;
revoke all on function financial_ops.review_payout_assertion(
  uuid, uuid, evidence.review_decision, text, uuid, uuid
) from public, anon, authenticated, service_role;
