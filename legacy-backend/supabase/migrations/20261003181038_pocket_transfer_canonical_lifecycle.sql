-- Reconcile the already-frozen Pocket Transfer lifecycle; no public schema surface.
-- Renaming preserves the enum OID used by historical rows and parsed CHECK constants.
alter type financial_ops.pocket_transfer_status rename value 'approved' to 'completed';

create or replace function financial_ops.validate_pocket_transfer_request()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  source_account ledger.ledger_accounts%rowtype;
  destination_account ledger.ledger_accounts%rowtype;
begin
  if tg_op = 'INSERT' then
    select * into source_account from ledger.ledger_accounts where id = new.source_ledger_account_id;
    select * into destination_account from ledger.ledger_accounts where id = new.destination_ledger_account_id;
    if source_account.id is null or destination_account.id is null
       or source_account.account_class <> 'member_value'
       or destination_account.account_class <> 'member_value'
       or source_account.tenant_id <> new.tenant_id
       or source_account.office_id <> new.office_id
       or source_account.membership_id <> new.membership_id
       or source_account.wallet_id <> new.wallet_id
       or source_account.owner_user_id <> new.owner_user_id
       or source_account.currency_code <> new.currency_code
       or destination_account.tenant_id <> new.tenant_id
       or destination_account.office_id <> new.office_id
       or destination_account.membership_id <> new.membership_id
       or destination_account.wallet_id <> new.wallet_id
       or destination_account.owner_user_id <> new.owner_user_id
       or destination_account.currency_code <> new.currency_code
       or source_account.pocket_key = 'debt'
       or not exists (
         select 1 from public.pocket_definitions pocket
          where pocket.pocket_key = source_account.pocket_key and pocket.transfer_out_allowed
       )
       or not exists (
         select 1 from public.pocket_definitions pocket
          where pocket.pocket_key = destination_account.pocket_key and pocket.transfer_in_allowed
       ) then
      raise exception using errcode = '23514', message = 'pocket transfer context is invalid';
    end if;
    return new;
  end if;

  if current_setting('financial_ops.pocket_transfer_transition', true) is distinct from old.id::text
     or (to_jsonb(new) - 'status' - 'approved_by_user_id' - 'approved_at'
       - 'rejected_by_user_id' - 'rejected_at' - 'rejection_reason'
       - 'cancelled_by_user_id' - 'cancelled_at' - 'cancellation_reason'
       - 'financial_transaction_id' - 'version' - 'updated_at')
       <> (to_jsonb(old) - 'status' - 'approved_by_user_id' - 'approved_at'
       - 'rejected_by_user_id' - 'rejected_at' - 'rejection_reason'
       - 'cancelled_by_user_id' - 'cancelled_at' - 'cancellation_reason'
       - 'financial_transaction_id' - 'version' - 'updated_at')
     or new.version <> old.version + 1
     or old.status <> 'requested'
     or new.status not in ('completed', 'rejected', 'cancelled') then
    raise exception using errcode = '55000', message = 'pocket transfer lifecycle requires a trusted command';
  end if;
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

create or replace function financial_ops.submit_pocket_transfer(
  p_idempotency_key uuid,
  p_source_ledger_account_id uuid,
  p_destination_ledger_account_id uuid,
  p_amount numeric,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.financial_operation_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_transfer financial_ops.pocket_transfer_requests%rowtype;
  source_account ledger.ledger_accounts%rowtype;
  destination_account ledger.ledger_accounts%rowtype;
  target_membership public.memberships%rowtype;
  source_transfer_allowed boolean;
  destination_transfer_allowed boolean;
  target_permission text;
  authorization_decision authz.authorization_decision;
begin
  if p_idempotency_key is null
     or p_source_ledger_account_id is null
     or p_destination_ledger_account_id is null
     or p_source_ledger_account_id = p_destination_ledger_account_id then
    raise exception using errcode = '22023', message = 'pocket transfer input is invalid';
  end if;

  perform financial_ops.require_command_actor(p_actor_user_id);

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'amount', p_amount::text,
      'destination_ledger_account_id', p_destination_ledger_account_id,
      'source_ledger_account_id', p_source_ledger_account_id
    )::text,
    'sha256'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  select *
    into existing_transfer
    from financial_ops.pocket_transfer_requests transfer
   where transfer.idempotency_key = p_idempotency_key;

  if found then
    if existing_transfer.request_fingerprint <> request_fingerprint then
      raise exception using
        errcode = '23505',
        message = 'idempotency key already used with different pocket transfer data';
    end if;

  end if;

  perform account.id
    from ledger.ledger_accounts account
   where account.id in (p_source_ledger_account_id, p_destination_ledger_account_id)
   order by account.id
   for update;

  select * into source_account
    from ledger.ledger_accounts account
   where account.id = p_source_ledger_account_id;

  select * into destination_account
    from ledger.ledger_accounts account
   where account.id = p_destination_ledger_account_id;

  if source_account.id is null
     or destination_account.id is null
     or source_account.account_class <> 'member_value'
     or destination_account.account_class <> 'member_value'
     or source_account.wallet_id <> destination_account.wallet_id
     or source_account.tenant_id <> destination_account.tenant_id
     or source_account.office_id <> destination_account.office_id
     or source_account.membership_id <> destination_account.membership_id
     or source_account.owner_user_id <> destination_account.owner_user_id
     or source_account.currency_code <> destination_account.currency_code
     or source_account.pocket_key = destination_account.pocket_key then
    raise exception using
      errcode = '23514',
      message = 'pocket transfer accounts must share one Wallet context and currency';
  end if;

  select * into target_membership
    from public.memberships membership
   where membership.id = source_account.membership_id;

  select pocket.transfer_out_allowed into source_transfer_allowed
    from public.pocket_definitions pocket
   where pocket.pocket_key = source_account.pocket_key;

  select pocket.transfer_in_allowed into destination_transfer_allowed
    from public.pocket_definitions pocket
   where pocket.pocket_key = destination_account.pocket_key;

  if target_membership.status <> 'active'
     or not coalesce(source_transfer_allowed, false)
     or not coalesce(destination_transfer_allowed, false)
     or source_account.pocket_key = 'debt' then
    raise exception using
      errcode = '23514',
      message = 'pocket transfer is not permitted for the selected accounts';
  end if;

  perform financial_ops.assert_currency_amount(p_amount, source_account.currency_code);

  target_permission := case
    when p_actor_user_id = source_account.owner_user_id
      then 'transfer_between_own_pockets'
    else 'transfer_between_pockets_on_behalf'
  end;

  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    target_permission,
    source_account.tenant_id,
    source_account.office_id,
    source_account.membership_id,
    source_account.owner_user_id,
    source_account.wallet_id,
    source_account.owner_user_id,
    'submit_pocket_transfer',
    p_amount
  );
  if authorization_decision.decision = 'STEP_UP_REQUIRED' then
    raise exception using errcode='P0401',message='pocket transfer requires device verification';
  end if;
  perform financial_ops.enforce_authorization(authorization_decision);

  if existing_transfer.id is not null then
    return (
      existing_transfer.id,
      existing_transfer.operation_reference,
      existing_transfer.status::text,
      existing_transfer.financial_transaction_id,
      true
    )::financial_ops.financial_operation_result;
  end if;

  if destination_account.pocket_key = 'debt' and p_amount >
       -coalesce((select balance from ledger.wallet_balance_projections where ledger_account_id=destination_account.id),0) then
    raise exception using errcode='23514',message='pocket transfer exceeds Debt repayment deficit';
  end if;

  if financial_ops.available_balance(source_account.id) < p_amount then
    raise exception using
      errcode = '23514',
      message = 'pocket transfer exceeds available funds';
  end if;

  insert into financial_ops.pocket_transfer_requests (
    idempotency_key,
    request_fingerprint,
    tenant_id,
    office_id,
    membership_id,
    wallet_id,
    owner_user_id,
    source_ledger_account_id,
    destination_ledger_account_id,
    currency_code,
    amount,
    requested_by_user_id
  )
  values (
    p_idempotency_key,
    request_fingerprint,
    source_account.tenant_id,
    source_account.office_id,
    source_account.membership_id,
    source_account.wallet_id,
    source_account.owner_user_id,
    source_account.id,
    destination_account.id,
    source_account.currency_code,
    p_amount,
    p_actor_user_id
  )
  returning * into existing_transfer;

  insert into financial_ops.pocket_transfer_reservations (
    pocket_transfer_id,
    ledger_account_id,
    amount
  )
  values (existing_transfer.id, source_account.id, p_amount);

  perform financial_ops.record_operation_authorization_audit(
    authorization_decision,
    p_session_id,
    'pocket_transfer_requested',
    'pocket_transfer',
    existing_transfer.id
  );

  return (
    existing_transfer.id,
    existing_transfer.operation_reference,
    existing_transfer.status::text,
    null,
    false
  )::financial_ops.financial_operation_result;
end;
$$;


create or replace function financial_ops.approve_pocket_transfer(
  p_idempotency_key uuid,
  p_pocket_transfer_id uuid,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.financial_operation_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_transfer financial_ops.pocket_transfer_requests%rowtype;
  target_reservation financial_ops.pocket_transfer_reservations%rowtype;
  target_membership public.memberships%rowtype;
  authorization_decision authz.authorization_decision;
  request_fingerprint bytea;
  posting_result ledger.post_transaction_result;
begin
  if p_idempotency_key is null or p_pocket_transfer_id is null then
    raise exception using errcode = '22023', message = 'pocket transfer approval input is invalid';
  end if;
  perform financial_ops.require_command_actor(p_actor_user_id);

  select * into target_transfer
    from financial_ops.pocket_transfer_requests transfer
   where transfer.id = p_pocket_transfer_id
   for update;

  if target_transfer.id is null then
    raise exception using errcode = 'P0002', message = 'pocket transfer was not found';
  end if;

  select * into target_membership
    from public.memberships membership
   where membership.id = target_transfer.membership_id;

  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'approve_pocket_transfer',
    target_transfer.tenant_id,
    target_transfer.office_id,
    target_transfer.membership_id,
    target_transfer.owner_user_id,
    target_transfer.wallet_id,
    target_transfer.owner_user_id,
    'approve_pocket_transfer',
    target_transfer.amount
  );
  if p_actor_user_id = target_transfer.owner_user_id then
    raise exception using errcode='42501',message='pocket transfer approval cannot target own Wallet';
  end if;
  if authorization_decision.decision = 'STEP_UP_REQUIRED' then
    raise exception using errcode='P0401',message='pocket transfer approval requires device verification';
  end if;
  perform financial_ops.enforce_authorization(authorization_decision);

  if target_transfer.status = 'completed' then
    if target_transfer.approved_by_user_id is distinct from p_actor_user_id or not exists (
      select 1 from ledger.financial_transactions tx where tx.id=target_transfer.financial_transaction_id
       and tx.idempotency_key=p_idempotency_key and tx.actor_user_id=p_actor_user_id
    ) then raise exception using errcode='23505',message='pocket transfer approval already has different intent'; end if;
    return (target_transfer.id,target_transfer.operation_reference,target_transfer.status::text,
      target_transfer.financial_transaction_id,true)::financial_ops.financial_operation_result;
  end if;
  if target_transfer.status <> 'requested' then
    raise exception using errcode='55000',message='only a requested pocket transfer may be approved';
  end if;

  -- Every balance-dependent direction/funding decision shares ledger's account lock order.
  perform account.id from ledger.ledger_accounts account
   where account.id in (target_transfer.source_ledger_account_id,target_transfer.destination_ledger_account_id)
   order by account.id for update;
  select * into target_reservation
    from financial_ops.pocket_transfer_reservations reservation
   where reservation.pocket_transfer_id = target_transfer.id
   for update;

  if target_reservation.pocket_transfer_id is null or target_reservation.status <> 'active'
     or target_membership.id is null or target_membership.status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'pocket transfer approval requires active reservation and membership';
  end if;


  if exists(select 1 from ledger.ledger_accounts destination
    where destination.id=target_transfer.destination_ledger_account_id and destination.pocket_key='debt'
      and target_transfer.amount > -coalesce((select balance from ledger.wallet_balance_projections
        where ledger_account_id=destination.id),0)) then
    raise exception using errcode='23514',message='pocket transfer exceeds Debt repayment deficit';
  end if;


  if exists(select 1 from ledger.ledger_accounts source
    where source.id=target_transfer.source_ledger_account_id and (source.pocket_key='debt' or not exists(
      select 1 from public.pocket_definitions pocket where pocket.pocket_key=source.pocket_key and pocket.transfer_out_allowed)))
    or not exists(select 1 from ledger.ledger_accounts destination join public.pocket_definitions pocket using(pocket_key)
      where destination.id=target_transfer.destination_ledger_account_id and pocket.transfer_in_allowed) then
    raise exception using errcode='23514',message='pocket transfer is not permitted for the selected accounts';
  end if;

  if financial_ops.available_balance(target_transfer.source_ledger_account_id)
       + target_reservation.amount < target_transfer.amount then
    raise exception using
      errcode = '23514',
      message = 'pocket transfer funds are no longer available';
  end if;

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'pocket_transfer_id', target_transfer.id,
      'amount', target_transfer.amount::text
    )::text,
    'sha256'
  );

  posting_result := ledger.post_transaction(
    p_idempotency_key,
    request_fingerprint,
    'pocket_transfer',
    target_transfer.membership_id,
    target_transfer.wallet_id,
    p_actor_user_id,
    jsonb_build_array(jsonb_build_object(
      'currency_code', target_transfer.currency_code,
      'postings', jsonb_build_array(
        jsonb_build_object(
          'ledger_account_id', target_transfer.source_ledger_account_id,
          'amount', (-target_transfer.amount)::text
        ),
        jsonb_build_object(
          'ledger_account_id', target_transfer.destination_ledger_account_id,
          'amount', target_transfer.amount::text
        )
      )
    )),
    jsonb_build_object('pocket_transfer_id', target_transfer.id)
  );

  perform set_config('financial_ops.pocket_transfer_transition', target_transfer.id::text, true);

  update financial_ops.pocket_transfer_requests
     set status = 'completed',
         approved_by_user_id = p_actor_user_id,
         approved_at = clock_timestamp(),
         financial_transaction_id = posting_result.transaction_id,
         version = version + 1,
         updated_at = clock_timestamp()
   where id = target_transfer.id
  returning * into target_transfer;

  update financial_ops.pocket_transfer_reservations
     set status = 'consumed', consumed_at = clock_timestamp()
   where pocket_transfer_id = target_transfer.id;

  perform set_config('financial_ops.pocket_transfer_transition', '', true);

  perform financial_ops.record_operation_authorization_audit(
    authorization_decision,
    p_session_id,
    'pocket_transfer_approved',
    'pocket_transfer',
    target_transfer.id,
    jsonb_build_object('financial_transaction_id', posting_result.transaction_id)
  );

  return (
    target_transfer.id,
    target_transfer.operation_reference,
    target_transfer.status::text,
    posting_result.transaction_id,
    false
  )::financial_ops.financial_operation_result;
end;
$$;


create or replace function financial_ops.reject_pocket_transfer(
  p_pocket_transfer_id uuid,
  p_reason text,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.financial_operation_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_transfer financial_ops.pocket_transfer_requests%rowtype;
  authorization_decision authz.authorization_decision;
begin
  if p_pocket_transfer_id is null or coalesce(length(btrim(p_reason)), 0) = 0 then
    raise exception using errcode = '22023', message = 'pocket transfer rejection input is invalid';
  end if;
  perform financial_ops.require_command_actor(p_actor_user_id);

  select * into target_transfer
    from financial_ops.pocket_transfer_requests transfer
   where transfer.id = p_pocket_transfer_id
   for update;

  if target_transfer.id is null then
    raise exception using errcode = 'P0002', message = 'pocket transfer was not found';
  end if;
  authorization_decision := authz.authorize(
    p_actor_user_id, p_session_id, 'approve_pocket_transfer',
    target_transfer.tenant_id, target_transfer.office_id,
    target_transfer.membership_id, target_transfer.owner_user_id,
    target_transfer.wallet_id, target_transfer.owner_user_id,
    'reject_pocket_transfer', target_transfer.amount
  );
  if p_actor_user_id=target_transfer.owner_user_id then
    raise exception using errcode='42501',message='pocket transfer approval cannot target own Wallet';
  end if;
  if authorization_decision.decision='STEP_UP_REQUIRED' then
    raise exception using errcode='P0401',message='pocket transfer requires device verification';
  end if;
  perform financial_ops.enforce_authorization(authorization_decision);

  if target_transfer.status = 'rejected' then
    if target_transfer.rejected_by_user_id is distinct from p_actor_user_id or target_transfer.rejection_reason is distinct from btrim(p_reason) then
      raise exception using errcode='23505',message='pocket transfer terminal decision already has different intent';
    end if;
    return (target_transfer.id,target_transfer.operation_reference,target_transfer.status::text,null,true)::financial_ops.financial_operation_result;
  end if;
  if target_transfer.status <> 'requested' then
    raise exception using errcode='55000',message='pocket transfer cannot be rejected in its current state';
  end if;


  perform set_config('financial_ops.pocket_transfer_transition', target_transfer.id::text, true);
  update financial_ops.pocket_transfer_requests
     set status = 'rejected', rejected_by_user_id = p_actor_user_id,
         rejected_at = clock_timestamp(), rejection_reason = btrim(p_reason),
         version = version + 1, updated_at = clock_timestamp()
   where id = target_transfer.id
  returning * into target_transfer;
  update financial_ops.pocket_transfer_reservations
     set status = 'released', released_at = clock_timestamp(), release_reason = 'rejected'
   where pocket_transfer_id = target_transfer.id and status = 'active';
  perform set_config('financial_ops.pocket_transfer_transition', '', true);

  perform financial_ops.record_operation_authorization_audit(
    authorization_decision, p_session_id, 'pocket_transfer_rejected',
    'pocket_transfer', target_transfer.id,
    jsonb_build_object('reason', btrim(p_reason))
  );
  return (target_transfer.id, target_transfer.operation_reference,
    target_transfer.status::text, null, false)::financial_ops.financial_operation_result;
end;
$$;


create or replace function financial_ops.cancel_pocket_transfer(
  p_pocket_transfer_id uuid,
  p_reason text,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.financial_operation_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_transfer financial_ops.pocket_transfer_requests%rowtype;
  target_permission text;
  authorization_decision authz.authorization_decision;
begin
  if p_pocket_transfer_id is null or coalesce(length(btrim(p_reason)), 0) = 0 then
    raise exception using errcode = '22023', message = 'pocket transfer cancellation input is invalid';
  end if;
  perform financial_ops.require_command_actor(p_actor_user_id);

  select * into target_transfer
    from financial_ops.pocket_transfer_requests transfer
   where transfer.id = p_pocket_transfer_id
   for update;

  if target_transfer.id is null then
    raise exception using errcode = 'P0002', message = 'pocket transfer was not found';
  end if;
  target_permission := case
    when p_actor_user_id = target_transfer.owner_user_id
      then 'transfer_between_own_pockets'
    else 'transfer_between_pockets_on_behalf'
  end;
  authorization_decision := authz.authorize(
    p_actor_user_id, p_session_id, target_permission,
    target_transfer.tenant_id, target_transfer.office_id,
    target_transfer.membership_id, target_transfer.owner_user_id,
    target_transfer.wallet_id, target_transfer.owner_user_id,
    'cancel_pocket_transfer', target_transfer.amount
  );
  if p_actor_user_id not in (target_transfer.owner_user_id,target_transfer.requested_by_user_id) then
    raise exception using errcode='42501',message='only Wallet owner or initiating actor may cancel a pocket transfer';
  end if;
  if authorization_decision.decision='STEP_UP_REQUIRED' then
    raise exception using errcode='P0401',message='pocket transfer requires device verification';
  end if;
  perform financial_ops.enforce_authorization(authorization_decision);

  if target_transfer.status = 'cancelled' then
    if target_transfer.cancelled_by_user_id is distinct from p_actor_user_id or target_transfer.cancellation_reason is distinct from btrim(p_reason) then
      raise exception using errcode='23505',message='pocket transfer terminal decision already has different intent';
    end if;
    return (target_transfer.id,target_transfer.operation_reference,target_transfer.status::text,null,true)::financial_ops.financial_operation_result;
  end if;
  if target_transfer.status <> 'requested' then
    raise exception using errcode='55000',message='pocket transfer cannot be cancelled in its current state';
  end if;


  perform set_config('financial_ops.pocket_transfer_transition', target_transfer.id::text, true);
  update financial_ops.pocket_transfer_requests
     set status = 'cancelled', cancelled_by_user_id = p_actor_user_id,
         cancelled_at = clock_timestamp(), cancellation_reason = btrim(p_reason),
         version = version + 1, updated_at = clock_timestamp()
   where id = target_transfer.id
  returning * into target_transfer;
  update financial_ops.pocket_transfer_reservations
     set status = 'released', released_at = clock_timestamp(), release_reason = 'cancelled'
   where pocket_transfer_id = target_transfer.id and status = 'active';
  perform set_config('financial_ops.pocket_transfer_transition', '', true);

  perform financial_ops.record_operation_authorization_audit(
    authorization_decision, p_session_id, 'pocket_transfer_cancelled',
    'pocket_transfer', target_transfer.id,
    jsonb_build_object('reason', btrim(p_reason))
  );
  return (target_transfer.id, target_transfer.operation_reference,
    target_transfer.status::text, null, false)::financial_ops.financial_operation_result;
end;
$$;

revoke all on function financial_ops.submit_pocket_transfer(uuid,uuid,uuid,numeric,uuid,uuid),
 financial_ops.approve_pocket_transfer(uuid,uuid,uuid,uuid),financial_ops.reject_pocket_transfer(uuid,text,uuid,uuid),
 financial_ops.cancel_pocket_transfer(uuid,text,uuid,uuid),financial_ops.validate_pocket_transfer_request()
 from public,anon,authenticated,service_role;
