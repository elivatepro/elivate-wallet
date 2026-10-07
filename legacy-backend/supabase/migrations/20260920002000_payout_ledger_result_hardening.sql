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
         financial_transaction_id = posting_result.transaction_id
   where id = target_withdrawal.id;

  update financial_ops.payout_completion_assertions
     set status = 'posted',
         version = version + 1,
         accepted_via = p_resolution,
         accepted_at = clock_timestamp(),
         posted_financial_transaction_id = posting_result.transaction_id
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
      'financial_transaction_id', posting_result.transaction_id,
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
      'financial_transaction_id', posting_result.transaction_id
    )
  );

  return posting_result;
end;
$$;

revoke all on function financial_ops.complete_withdrawal_from_assertion(
  uuid, financial_ops.payout_resolution, uuid
) from public, anon, authenticated, service_role;
