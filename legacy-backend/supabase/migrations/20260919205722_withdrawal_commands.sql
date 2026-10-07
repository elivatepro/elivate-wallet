create or replace function financial_ops.available_balance(
  p_ledger_account_id uuid
)
returns numeric
language sql
stable
security invoker
set search_path = ''
as $$
  select
    coalesce((
      select projection.balance
        from ledger.wallet_balance_projections projection
       where projection.ledger_account_id = p_ledger_account_id
    ), 0::numeric)
    - coalesce((
      select sum(reservation.amount)
        from financial_ops.funding_reservations reservation
       where reservation.ledger_account_id = p_ledger_account_id
         and reservation.status = 'active'
    ), 0::numeric);
$$;

create or replace function financial_ops.enforce_authorization(
  p_decision authz.authorization_decision
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if p_decision.decision = 'STEP_UP_REQUIRED' then
    raise exception using
      errcode = '42501',
      message = 'withdrawal command requires fresh authorization';
  end if;

  if p_decision.decision <> 'ALLOW' then
    raise exception using
      errcode = '42501',
      message = 'withdrawal command is not authorized';
  end if;
end;
$$;

create or replace function financial_ops.record_authorization_audit(
  p_decision authz.authorization_decision,
  p_session_id uuid,
  p_event_type text,
  p_target_id uuid,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language sql
security invoker
set search_path = ''
as $$
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
    p_decision.actor_user_id,
    p_session_id,
    p_decision.target_tenant_id,
    p_event_type,
    p_decision.permission_key,
    'withdrawal',
    p_target_id,
    true,
    p_decision.source,
    p_decision.source_id,
    p_decision.reason_code,
    p_metadata
  );
$$;

create or replace function financial_ops.submit_withdrawal(
  p_idempotency_key uuid,
  p_source_ledger_account_id uuid,
  p_payout_account_id uuid,
  p_requested_amount numeric,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.withdrawal_command_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.withdrawal_command_idempotency%rowtype;
  source_account ledger.ledger_accounts%rowtype;
  payout_account financial_ops.payout_accounts%rowtype;
  target_membership public.memberships%rowtype;
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
  authorization_decision authz.authorization_decision;
  owner_status public.account_status;
  tenant_status public.tenant_status;
  office_status public.office_status;
  currency_scale smallint;
  transfer_out_allowed boolean;
  posted_balance numeric(38, 18);
  reserved_total numeric(38, 18);
  target_permission text;
begin
  if p_idempotency_key is null
     or p_source_ledger_account_id is null
     or p_payout_account_id is null
     or p_requested_amount is null
     or p_requested_amount <= 0
     or p_actor_user_id is null then
    raise exception using
      errcode = '22023',
      message = 'withdrawal submission input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'withdrawal command actor does not match the authenticated user';
  end if;

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'payout_account_id', p_payout_account_id,
      'requested_amount', p_requested_amount::text,
      'source_ledger_account_id', p_source_ledger_account_id
    )::text,
    'sha256'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  select *
    into existing_command
    from financial_ops.withdrawal_command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.command_type <> 'submit_withdrawal'
       or existing_command.request_fingerprint <> request_fingerprint
       or existing_command.actor_user_id <> p_actor_user_id then
      raise exception using
        errcode = '23505',
        message = 'idempotency key already used with different withdrawal command data';
    end if;

    select *
      into target_withdrawal
      from financial_ops.withdrawal_requests withdrawal
     where withdrawal.id = existing_command.withdrawal_id;

    return (
      target_withdrawal.id,
      target_withdrawal.withdrawal_reference,
      existing_command.result_status,
      true
    )::financial_ops.withdrawal_command_result;
  end if;

  select *
    into source_account
    from ledger.ledger_accounts account
   where account.id = p_source_ledger_account_id
   for update;

  if source_account.id is null or source_account.account_class <> 'member_value' then
    raise exception using
      errcode = '23514',
      message = 'withdrawal source must be a member-value ledger account';
  end if;

  select definition.minor_unit_scale
    into currency_scale
    from ledger.currency_definitions definition
   where definition.currency_code = source_account.currency_code;

  select definition.transfer_out_allowed
    into transfer_out_allowed
    from public.pocket_definitions definition
   where definition.pocket_key = source_account.pocket_key;

  if currency_scale is null
     or p_requested_amount <> round(p_requested_amount, currency_scale) then
    raise exception using
      errcode = '22003',
      message = 'withdrawal amount exceeds the currency minor-unit scale';
  end if;

  if not coalesce(transfer_out_allowed, false) then
    raise exception using
      errcode = '23514',
      message = 'selected pocket does not allow withdrawal funding';
  end if;

  select *
    into target_membership
    from public.memberships membership
   where membership.id = source_account.membership_id;

  select account.status
    into owner_status
    from public.user_accounts account
   where account.user_id = source_account.owner_user_id;

  select tenant.status
    into tenant_status
    from public.tenants tenant
   where tenant.id = source_account.tenant_id;

  select office.status
    into office_status
    from public.offices office
   where office.tenant_id = source_account.tenant_id
     and office.id = source_account.office_id;

  if target_membership.id is null
     or target_membership.status <> 'active'
     or target_membership.user_id <> source_account.owner_user_id
     or target_membership.office_id <> source_account.office_id
     or owner_status <> 'active'
     or tenant_status <> 'active'
     or office_status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'withdrawal source requires active account and organizational provenance';
  end if;

  select *
    into payout_account
    from financial_ops.payout_accounts account
   where account.id = p_payout_account_id;

  if payout_account.id is null
     or payout_account.wallet_id <> source_account.wallet_id
     or payout_account.owner_user_id <> source_account.owner_user_id
     or payout_account.status <> 'active'
     or payout_account.verification_status <> 'verified' then
    raise exception using
      errcode = '23514',
      message = 'withdrawal requires an active verified payout destination owned by the Wallet holder';
  end if;

  target_permission := case
    when p_actor_user_id = source_account.owner_user_id
      then 'initiate_own_withdrawal'
    else 'withdraw_on_behalf'
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
    'submit_withdrawal',
    p_requested_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);

  select projection.balance
    into posted_balance
    from ledger.wallet_balance_projections projection
   where projection.ledger_account_id = source_account.id;

  select coalesce(sum(reservation.amount), 0)
    into reserved_total
    from financial_ops.funding_reservations reservation
   where reservation.ledger_account_id = source_account.id
     and reservation.status = 'active';

  if coalesce(posted_balance, 0) - reserved_total < p_requested_amount then
    raise exception using
      errcode = '23514',
      message = 'insufficient available balance for withdrawal reservation';
  end if;

  insert into financial_ops.withdrawal_requests (
    tenant_id,
    office_id,
    membership_id,
    wallet_id,
    owner_user_id,
    source_ledger_account_id,
    source_currency_code,
    source_pocket_key,
    requested_amount,
    payout_account_id,
    initiated_by_user_id
  )
  values (
    source_account.tenant_id,
    source_account.office_id,
    source_account.membership_id,
    source_account.wallet_id,
    source_account.owner_user_id,
    source_account.id,
    source_account.currency_code,
    source_account.pocket_key,
    p_requested_amount,
    payout_account.id,
    p_actor_user_id
  )
  returning * into target_withdrawal;

  insert into financial_ops.withdrawal_destination_snapshots (
    withdrawal_id,
    source_payout_account_id,
    institution_code,
    institution_name,
    account_reference,
    account_holder_name,
    payout_rail,
    payout_currency,
    country_code,
    verification_status,
    verification_method
  )
  values (
    target_withdrawal.id,
    payout_account.id,
    payout_account.institution_code,
    payout_account.institution_name,
    payout_account.account_reference,
    payout_account.account_holder_name,
    payout_account.payout_rail,
    payout_account.payout_currency,
    payout_account.country_code,
    payout_account.verification_status,
    payout_account.verification_method
  );

  insert into financial_ops.funding_reservations (
    withdrawal_id,
    ledger_account_id,
    amount
  )
  values (
    target_withdrawal.id,
    source_account.id,
    p_requested_amount
  );

  insert into financial_ops.withdrawal_command_idempotency (
    idempotency_key,
    command_type,
    request_fingerprint,
    withdrawal_id,
    actor_user_id,
    result_status
  )
  values (
    p_idempotency_key,
    'submit_withdrawal',
    request_fingerprint,
    target_withdrawal.id,
    p_actor_user_id,
    target_withdrawal.status
  );

  perform financial_ops.record_authorization_audit(
    authorization_decision,
    p_session_id,
    'withdrawal_requested',
    target_withdrawal.id,
    jsonb_build_object('withdrawal_reference', target_withdrawal.withdrawal_reference)
  );

  return (
    target_withdrawal.id,
    target_withdrawal.withdrawal_reference,
    target_withdrawal.status,
    false
  )::financial_ops.withdrawal_command_result;
end;
$$;

create or replace function financial_ops.approve_withdrawal(
  p_idempotency_key uuid,
  p_withdrawal_id uuid,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.withdrawal_command_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.withdrawal_command_idempotency%rowtype;
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
  target_reservation financial_ops.funding_reservations%rowtype;
  authorization_decision authz.authorization_decision;
  owner_status public.account_status;
  membership_status public.membership_status;
begin
  if p_idempotency_key is null or p_withdrawal_id is null or p_actor_user_id is null then
    raise exception using
      errcode = '22023',
      message = 'withdrawal approval input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'withdrawal command actor does not match the authenticated user';
  end if;

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'withdrawal_id', p_withdrawal_id
    )::text,
    'sha256'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  select *
    into existing_command
    from financial_ops.withdrawal_command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.command_type <> 'approve_withdrawal'
       or existing_command.request_fingerprint <> request_fingerprint
       or existing_command.actor_user_id <> p_actor_user_id then
      raise exception using
        errcode = '23505',
        message = 'idempotency key already used with different withdrawal command data';
    end if;

    select *
      into target_withdrawal
      from financial_ops.withdrawal_requests withdrawal
     where withdrawal.id = existing_command.withdrawal_id;

    return (
      target_withdrawal.id,
      target_withdrawal.withdrawal_reference,
      existing_command.result_status,
      true
    )::financial_ops.withdrawal_command_result;
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

  if target_withdrawal.status <> 'requested' then
    raise exception using
      errcode = '55000',
      message = 'only requested withdrawals may be approved';
  end if;

  select *
    into target_reservation
    from financial_ops.funding_reservations reservation
   where reservation.withdrawal_id = target_withdrawal.id
   for update;

  if target_reservation.id is null or target_reservation.status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'withdrawal approval requires an active funding reservation';
  end if;

  select account.status
    into owner_status
    from public.user_accounts account
   where account.user_id = target_withdrawal.owner_user_id;

  select membership.status
    into membership_status
    from public.memberships membership
   where membership.id = target_withdrawal.membership_id
     and membership.tenant_id = target_withdrawal.tenant_id;

  if owner_status <> 'active' or membership_status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'withdrawal approval requires active owner and membership context';
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
    'approve_withdrawal',
    target_withdrawal.requested_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);

  perform set_config(
    'financial_ops.withdrawal_transition',
    target_withdrawal.id::text,
    true
  );

  update financial_ops.withdrawal_requests
     set status = 'approved',
         version = version + 1,
         approved_by_user_id = p_actor_user_id,
         approved_at = clock_timestamp()
   where id = target_withdrawal.id
  returning * into target_withdrawal;

  perform set_config('financial_ops.withdrawal_transition', '', true);

  insert into financial_ops.withdrawal_command_idempotency (
    idempotency_key,
    command_type,
    request_fingerprint,
    withdrawal_id,
    actor_user_id,
    result_status
  )
  values (
    p_idempotency_key,
    'approve_withdrawal',
    request_fingerprint,
    target_withdrawal.id,
    p_actor_user_id,
    target_withdrawal.status
  );

  perform financial_ops.record_authorization_audit(
    authorization_decision,
    p_session_id,
    'withdrawal_approved',
    target_withdrawal.id,
    jsonb_build_object('withdrawal_reference', target_withdrawal.withdrawal_reference)
  );

  return (
    target_withdrawal.id,
    target_withdrawal.withdrawal_reference,
    target_withdrawal.status,
    false
  )::financial_ops.withdrawal_command_result;
end;
$$;

create or replace function financial_ops.reject_withdrawal(
  p_idempotency_key uuid,
  p_withdrawal_id uuid,
  p_actor_user_id uuid,
  p_reason text,
  p_session_id uuid default null
)
returns financial_ops.withdrawal_command_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.withdrawal_command_idempotency%rowtype;
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
  target_reservation financial_ops.funding_reservations%rowtype;
  authorization_decision authz.authorization_decision;
begin
  if p_idempotency_key is null
     or p_withdrawal_id is null
     or p_actor_user_id is null
     or p_reason is null
     or length(btrim(p_reason)) = 0 then
    raise exception using
      errcode = '22023',
      message = 'withdrawal rejection input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'withdrawal command actor does not match the authenticated user';
  end if;

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'reason', btrim(p_reason),
      'withdrawal_id', p_withdrawal_id
    )::text,
    'sha256'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  select *
    into existing_command
    from financial_ops.withdrawal_command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.command_type <> 'reject_withdrawal'
       or existing_command.request_fingerprint <> request_fingerprint
       or existing_command.actor_user_id <> p_actor_user_id then
      raise exception using
        errcode = '23505',
        message = 'idempotency key already used with different withdrawal command data';
    end if;

    select *
      into target_withdrawal
      from financial_ops.withdrawal_requests withdrawal
     where withdrawal.id = existing_command.withdrawal_id;

    return (
      target_withdrawal.id,
      target_withdrawal.withdrawal_reference,
      existing_command.result_status,
      true
    )::financial_ops.withdrawal_command_result;
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

  if target_withdrawal.status <> 'requested' then
    raise exception using
      errcode = '55000',
      message = 'only requested withdrawals may be rejected';
  end if;

  select *
    into target_reservation
    from financial_ops.funding_reservations reservation
   where reservation.withdrawal_id = target_withdrawal.id
   for update;

  if target_reservation.id is null or target_reservation.status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'withdrawal rejection requires an active funding reservation';
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
    'reject_withdrawal',
    target_withdrawal.requested_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);

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

  update financial_ops.withdrawal_requests
     set status = 'rejected',
         version = version + 1,
         rejected_by_user_id = p_actor_user_id,
         rejected_at = clock_timestamp(),
         rejection_reason = btrim(p_reason)
   where id = target_withdrawal.id
  returning * into target_withdrawal;

  update financial_ops.funding_reservations
     set status = 'released',
         released_at = clock_timestamp(),
         release_reason = 'withdrawal rejected: ' || btrim(p_reason)
   where id = target_reservation.id;

  perform set_config('financial_ops.withdrawal_transition', '', true);
  perform set_config('financial_ops.reservation_transition', '', true);

  insert into financial_ops.withdrawal_command_idempotency (
    idempotency_key,
    command_type,
    request_fingerprint,
    withdrawal_id,
    actor_user_id,
    result_status
  )
  values (
    p_idempotency_key,
    'reject_withdrawal',
    request_fingerprint,
    target_withdrawal.id,
    p_actor_user_id,
    target_withdrawal.status
  );

  perform financial_ops.record_authorization_audit(
    authorization_decision,
    p_session_id,
    'withdrawal_rejected',
    target_withdrawal.id,
    jsonb_build_object('withdrawal_reference', target_withdrawal.withdrawal_reference)
  );

  return (
    target_withdrawal.id,
    target_withdrawal.withdrawal_reference,
    target_withdrawal.status,
    false
  )::financial_ops.withdrawal_command_result;
end;
$$;

create or replace function financial_ops.cancel_withdrawal(
  p_idempotency_key uuid,
  p_withdrawal_id uuid,
  p_actor_user_id uuid,
  p_reason text,
  p_session_id uuid default null
)
returns financial_ops.withdrawal_command_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.withdrawal_command_idempotency%rowtype;
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
  target_reservation financial_ops.funding_reservations%rowtype;
  authorization_decision authz.authorization_decision;
  target_permission text;
begin
  if p_idempotency_key is null
     or p_withdrawal_id is null
     or p_actor_user_id is null
     or p_reason is null
     or length(btrim(p_reason)) = 0 then
    raise exception using
      errcode = '22023',
      message = 'withdrawal cancellation input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'withdrawal command actor does not match the authenticated user';
  end if;

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'reason', btrim(p_reason),
      'withdrawal_id', p_withdrawal_id
    )::text,
    'sha256'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  select *
    into existing_command
    from financial_ops.withdrawal_command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.command_type <> 'cancel_withdrawal'
       or existing_command.request_fingerprint <> request_fingerprint
       or existing_command.actor_user_id <> p_actor_user_id then
      raise exception using
        errcode = '23505',
        message = 'idempotency key already used with different withdrawal command data';
    end if;

    select *
      into target_withdrawal
      from financial_ops.withdrawal_requests withdrawal
     where withdrawal.id = existing_command.withdrawal_id;

    return (
      target_withdrawal.id,
      target_withdrawal.withdrawal_reference,
      existing_command.result_status,
      true
    )::financial_ops.withdrawal_command_result;
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

  if target_withdrawal.status not in ('requested', 'approved') then
    raise exception using
      errcode = '55000',
      message = 'only requested or approved withdrawals may be cancelled';
  end if;

  select *
    into target_reservation
    from financial_ops.funding_reservations reservation
   where reservation.withdrawal_id = target_withdrawal.id
   for update;

  if target_reservation.id is null or target_reservation.status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'withdrawal cancellation requires an active funding reservation';
  end if;

  if target_withdrawal.status = 'requested' then
    if p_actor_user_id <> target_withdrawal.owner_user_id then
      raise exception using
        errcode = '42501',
        message = 'requested withdrawal may only be cancelled by its Wallet owner';
    end if;
    target_permission := 'initiate_own_withdrawal';
  else
    target_permission := 'approve_withdrawal';
  end if;

  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    target_permission,
    target_withdrawal.tenant_id,
    target_withdrawal.office_id,
    target_withdrawal.membership_id,
    target_withdrawal.owner_user_id,
    target_withdrawal.wallet_id,
    target_withdrawal.owner_user_id,
    'cancel_withdrawal',
    target_withdrawal.requested_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);

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

  update financial_ops.withdrawal_requests
     set status = 'cancelled',
         version = version + 1,
         cancelled_by_user_id = p_actor_user_id,
         cancelled_at = clock_timestamp(),
         cancellation_reason = btrim(p_reason)
   where id = target_withdrawal.id
  returning * into target_withdrawal;

  update financial_ops.funding_reservations
     set status = 'released',
         released_at = clock_timestamp(),
         release_reason = 'withdrawal cancelled: ' || btrim(p_reason)
   where id = target_reservation.id;

  perform set_config('financial_ops.withdrawal_transition', '', true);
  perform set_config('financial_ops.reservation_transition', '', true);

  insert into financial_ops.withdrawal_command_idempotency (
    idempotency_key,
    command_type,
    request_fingerprint,
    withdrawal_id,
    actor_user_id,
    result_status
  )
  values (
    p_idempotency_key,
    'cancel_withdrawal',
    request_fingerprint,
    target_withdrawal.id,
    p_actor_user_id,
    target_withdrawal.status
  );

  perform financial_ops.record_authorization_audit(
    authorization_decision,
    p_session_id,
    'withdrawal_cancelled',
    target_withdrawal.id,
    jsonb_build_object('withdrawal_reference', target_withdrawal.withdrawal_reference)
  );

  return (
    target_withdrawal.id,
    target_withdrawal.withdrawal_reference,
    target_withdrawal.status,
    false
  )::financial_ops.withdrawal_command_result;
end;
$$;

revoke all on function financial_ops.available_balance(uuid)
  from public, anon, authenticated, service_role;
revoke all on function financial_ops.enforce_authorization(authz.authorization_decision)
  from public, anon, authenticated, service_role;
revoke all on function financial_ops.record_authorization_audit(
  authz.authorization_decision, uuid, text, uuid, jsonb
) from public, anon, authenticated, service_role;
revoke all on function financial_ops.submit_withdrawal(
  uuid, uuid, uuid, numeric, uuid, uuid
) from public, anon, authenticated, service_role;
revoke all on function financial_ops.approve_withdrawal(uuid, uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function financial_ops.reject_withdrawal(uuid, uuid, uuid, text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function financial_ops.cancel_withdrawal(uuid, uuid, uuid, text, uuid)
  from public, anon, authenticated, service_role;
