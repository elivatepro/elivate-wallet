-- Source IDs select stored contexts and do not convey mutation authority.
create function read_api.member_withdrawal_sources(
  p_actor_user_id uuid,
  p_after uuid default null,
  p_limit integer default 50,
  p_source_ledger_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_status public.account_status;
  result_items jsonb;
  next_cursor uuid;
begin
  if p_actor_user_id is null or p_limit is null or p_limit < 1 or p_limit > 100
    or (p_source_ledger_account_id is not null and p_after is not null) then
    raise exception using errcode = '22023', message = 'withdrawal source input is invalid';
  end if;
  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'withdrawal source actor does not match the authenticated user';
  end if;
  select account.status into actor_status from public.user_accounts account
   where account.user_id = p_actor_user_id;
  if actor_status is null or actor_status <> 'active' then
    raise exception using errcode = '42501', message = 'withdrawal sources require an active account';
  end if;

  with source_rows as materialized (
    select account.id as source_ledger_account_id,
      account.wallet_id, account.membership_id,
      tenant.name as tenant_name, office.name as office_name,
      account.pocket_key, pocket.display_name as pocket_name,
      account.currency_code, currency.minor_unit_scale,
      coalesce(projection.balance, 0) as posted_balance,
      financial_ops.available_balance(account.id) as available_balance,
      row_number() over (order by account.id) as row_number
    from ledger.ledger_accounts account
    join public.wallets wallet on wallet.id = account.wallet_id
      and wallet.owner_user_id = p_actor_user_id
    join public.memberships membership on membership.id = account.membership_id
      and membership.tenant_id = account.tenant_id
      and membership.user_id = p_actor_user_id
    join public.tenants tenant on tenant.id = account.tenant_id
    join public.offices office on office.id = account.office_id
      and office.tenant_id = account.tenant_id
    join public.pocket_definitions pocket on pocket.pocket_key = account.pocket_key
    join ledger.currency_definitions currency on currency.currency_code = account.currency_code
    left join ledger.wallet_balance_projections projection on projection.ledger_account_id = account.id
    where account.account_class = 'member_value' and account.owner_user_id = p_actor_user_id
      and (p_after is null or account.id > p_after)
      and (p_source_ledger_account_id is null or account.id = p_source_ledger_account_id)
      -- Exact lookup proves ownership for command preflight, including retries
      -- after eligibility changes. The command rechecks mutation authority.
      and (p_source_ledger_account_id is not null or (
        membership.office_id = account.office_id and membership.status = 'active'
        and tenant.status = 'active' and office.status = 'active'
        and pocket.transfer_out_allowed and pocket.pocket_key <> 'debt'
      ))
    order by account.id limit p_limit + 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'source_ledger_account_id', source_ledger_account_id,
      'wallet_id', wallet_id, 'membership_id', membership_id,
      'tenant_name', tenant_name, 'office_name', office_name,
      'pocket_key', pocket_key, 'pocket_name', pocket_name,
      'currency_code', currency_code, 'minor_unit_scale', minor_unit_scale,
      'posted_balance', posted_balance::text,
      'reserved_balance', (posted_balance - available_balance)::text,
      'available_balance', available_balance::text
    ) order by source_ledger_account_id) filter (where row_number <= p_limit), '[]'::jsonb),
    case when count(*) > p_limit then (
      select source_ledger_account_id from source_rows where row_number = p_limit
    ) else null end into result_items, next_cursor from source_rows;
  return jsonb_build_object('items', result_items, 'nextCursor', next_cursor);
end;
$$;
revoke all on function read_api.member_withdrawal_sources(uuid, uuid, integer, uuid)
  from public, anon, authenticated, service_role;
grant execute on function read_api.member_withdrawal_sources(uuid, uuid, integer, uuid) to service_role;

-- Exact own target lookup avoids paginated history as a mutation ownership check.
create function read_api.member_withdrawal_target(p_actor_user_id uuid, p_withdrawal_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  result_target jsonb;
begin
  if p_actor_user_id is null or p_withdrawal_id is null then
    raise exception using errcode = '22023', message = 'withdrawal target input is invalid';
  end if;
  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'withdrawal target actor does not match the authenticated user';
  end if;
  if not exists (select 1 from public.user_accounts account
    where account.user_id = p_actor_user_id and account.status = 'active') then
    raise exception using errcode = '42501', message = 'withdrawal target requires an active account';
  end if;
  select jsonb_build_object('withdrawal_id', withdrawal.id, 'status', withdrawal.status)
    into result_target from financial_ops.withdrawal_requests withdrawal
    where withdrawal.id = p_withdrawal_id and withdrawal.owner_user_id = p_actor_user_id;
  if result_target is null then
    raise exception using errcode = '42501', message = 'withdrawal target is unavailable';
  end if;
  return result_target;
end;
$$;
revoke all on function read_api.member_withdrawal_target(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function read_api.member_withdrawal_target(uuid, uuid) to service_role;

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

  target_permission := case when p_actor_user_id = target_withdrawal.owner_user_id then 'initiate_own_withdrawal' else 'withdraw_on_behalf' end;
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
    'submit_withdrawal',
    p_requested_amount
  );

  perform financial_ops.enforce_authorization(authorization_decision);
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

  -- Both withdrawal and pocket-transfer reservations hold these funds.
  if financial_ops.available_balance(source_account.id) < p_requested_amount then
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
