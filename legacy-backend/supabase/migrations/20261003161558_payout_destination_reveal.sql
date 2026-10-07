-- Frozen canonical destination visibility: execution-only immutable snapshot,
-- audited before returning exact sensitive fields. Ordinary reads remain masked.
create function command_api.payout_destination(
  p_actor_user_id uuid,p_actor_membership_id uuid,p_withdrawal_id uuid,p_session_id uuid default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  target financial_ops.withdrawal_requests%rowtype;
  reservation financial_ops.funding_reservations%rowtype;
  snapshot financial_ops.withdrawal_destination_snapshots%rowtype;
  decision authz.authorization_decision;
  selection jsonb;
begin
  perform financial_ops.require_command_actor(p_actor_user_id);
  -- Lock in the canonical withdrawal/reservation order so completion/cancellation
  -- cannot race the approved execution check and its sensitive-access audit.
  select * into target from financial_ops.withdrawal_requests where id=p_withdrawal_id for share;
  if target.id is null or target.status<>'approved'
     or target.approved_by_user_id is distinct from p_actor_user_id
     or target.owner_user_id=p_actor_user_id then
    raise exception using errcode='42501',message='payout execution context is not authorized';
  end if;
  selection:=read_api.leadership_payouts(p_actor_user_id,p_actor_membership_id,null,null,null,target.id);
  if not exists(select 1 from jsonb_array_elements(selection->'items') item
    where item->>'withdrawal_id'=target.id::text) then
    raise exception using errcode='42501',message='payout execution context is not authorized';
  end if;
  decision:=authz.authorize(p_actor_user_id,p_session_id,'approve_withdrawal',target.tenant_id,
    target.office_id,target.membership_id,target.owner_user_id,target.wallet_id,target.owner_user_id,
    'reveal_payout_destination',target.requested_amount);
  if decision.decision='STEP_UP_REQUIRED' then
    raise exception using errcode='P0401',message='payout execution requires device verification';
  end if;
  perform financial_ops.enforce_authorization(decision);
  select * into reservation from financial_ops.funding_reservations where withdrawal_id=target.id for share;
  if reservation.id is null or reservation.status<>'active' then
    raise exception using errcode='42501',message='payout execution context is not authorized';
  end if;
  select * into snapshot from financial_ops.withdrawal_destination_snapshots where withdrawal_id=target.id;
  if snapshot.withdrawal_id is null then
    raise exception using errcode='42501',message='payout execution context is not authorized';
  end if;
  perform financial_ops.record_authorization_audit(decision,p_session_id,
    'payout_destination_revealed',target.id,jsonb_build_object('actor_membership_id',p_actor_membership_id));
  return jsonb_build_object('withdrawal_id',target.id,'withdrawal_reference',target.withdrawal_reference,
    'destination',jsonb_build_object('institution_code',snapshot.institution_code,'institution_name',snapshot.institution_name,
      'account_reference',snapshot.account_reference,'account_holder_name',snapshot.account_holder_name,
      'payout_rail',snapshot.payout_rail,'payout_currency',snapshot.payout_currency,'country_code',snapshot.country_code,
      'verification_status',snapshot.verification_status,'verification_method',snapshot.verification_method,
      'snapshotted_at',snapshot.snapshotted_at));
end;
$$;
revoke all on function command_api.payout_destination(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function command_api.payout_destination(uuid,uuid,uuid,uuid) to service_role;

-- Descriptive execution capability; no exact account data enters ordinary reads.
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
  where withdrawal.id = p_withdrawal_id;
$$;
