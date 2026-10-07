create or replace function financial_ops.require_command_actor(
  p_actor_user_id uuid
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if p_actor_user_id is null then
    raise exception using errcode = '22023', message = 'financial command actor is required';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using
      errcode = '42501',
      message = 'financial command actor does not match the authenticated user';
  end if;
end;
$$;

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
    ), 0::numeric)
    - coalesce((
      select sum(reservation.amount)
        from financial_ops.pocket_transfer_reservations reservation
       where reservation.ledger_account_id = p_ledger_account_id
         and reservation.status = 'active'
    ), 0::numeric);
$$;

create or replace function financial_ops.record_income(
  p_idempotency_key uuid,
  p_target_membership_id uuid,
  p_currency_code text,
  p_gross_amount numeric,
  p_evidence_items jsonb,
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
  existing_income financial_ops.income_records%rowtype;
  target_membership public.memberships%rowtype;
  target_wallet public.wallets%rowtype;
  active_policy_id uuid;
  system_account_id uuid;
  target_income_id uuid := extensions.gen_random_uuid();
  target_reference text := financial_ops.generate_operation_reference('INC');
  allocation_count integer;
  policy_rule_count integer;
  allocation_total numeric;
  journals jsonb;
  posting_result ledger.post_transaction_result;
  authorization_decision authz.authorization_decision;
begin
  if p_idempotency_key is null
     or p_target_membership_id is null
     or p_currency_code is null
     or p_evidence_items is null
     or jsonb_typeof(p_evidence_items) <> 'array'
     or jsonb_array_length(p_evidence_items) = 0 then
    raise exception using errcode = '22023', message = 'income command input is invalid';
  end if;

  perform financial_ops.require_command_actor(p_actor_user_id);
  perform financial_ops.assert_currency_amount(p_gross_amount, p_currency_code);

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'currency_code', p_currency_code,
      'evidence_items', p_evidence_items,
      'gross_amount', p_gross_amount::text,
      'target_membership_id', p_target_membership_id
    )::text,
    'sha256'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  select *
    into existing_income
    from financial_ops.income_records income
   where income.idempotency_key = p_idempotency_key;

  if found then
    if existing_income.request_fingerprint <> request_fingerprint then
      raise exception using
        errcode = '23505',
        message = 'idempotency key already used with different income data';
    end if;

    return (
      existing_income.id,
      existing_income.operation_reference,
      'posted',
      existing_income.financial_transaction_id,
      true
    )::financial_ops.financial_operation_result;
  end if;

  select *
    into target_membership
    from public.memberships membership
   where membership.id = p_target_membership_id
   for update;

  select wallet.*
    into target_wallet
    from public.wallets wallet
   where wallet.owner_user_id = target_membership.user_id;

  if target_membership.id is null
     or target_membership.status <> 'active'
     or target_membership.office_id is null
     or target_membership.role_key = 'president_team_member'
     or target_wallet.id is null then
    raise exception using
      errcode = '23514',
      message = 'income requires an active wallet-eligible target membership';
  end if;

  authorization_decision := authz.authorize(
    p_actor_user_id,
    p_session_id,
    'record_income',
    target_membership.tenant_id,
    target_membership.office_id,
    target_membership.id,
    target_membership.user_id,
    target_wallet.id,
    target_membership.user_id,
    'record_income',
    p_gross_amount
  );
  perform financial_ops.enforce_authorization(authorization_decision);

  select active.policy_version_id
    into active_policy_id
    from public.tenant_active_allocation_policies active
    join public.allocation_policy_versions policy
      on policy.tenant_id = active.tenant_id
     and policy.id = active.policy_version_id
     and policy.activated_at is not null
   where active.tenant_id = target_membership.tenant_id;

  if active_policy_id is null then
    raise exception using
      errcode = '23514',
      message = 'income requires an active tenant allocation policy';
  end if;

  select count(*)
    into policy_rule_count
    from public.allocation_policy_rules rule
   where rule.policy_version_id = active_policy_id;

  select count(*), coalesce(sum(allocation.allocated_amount), 0)
    into allocation_count, allocation_total
    from financial_ops.calculate_policy_allocations(
      active_policy_id,
      target_wallet.id,
      target_membership.id,
      p_currency_code,
      p_gross_amount,
      false
    ) allocation;

  if policy_rule_count = 0
     or allocation_count <> policy_rule_count
     or allocation_total <> p_gross_amount then
    raise exception using
      errcode = '23514',
      message = 'income allocation policy cannot be resolved to Wallet ledger accounts';
  end if;

  system_account_id := financial_ops.require_system_account(
    p_currency_code,
    'income_external'
  );

  select jsonb_build_array(
    jsonb_build_object(
      'currency_code', p_currency_code,
      'postings',
        jsonb_build_array(jsonb_build_object(
          'ledger_account_id', system_account_id,
          'amount', (-p_gross_amount)::text
        ))
        || coalesce(jsonb_agg(jsonb_build_object(
          'ledger_account_id', allocation.ledger_account_id,
          'amount', allocation.allocated_amount::text
        ) order by allocation.remainder_rank)
          filter (where allocation.allocated_amount > 0), '[]'::jsonb)
    )
  )
    into journals
    from financial_ops.calculate_policy_allocations(
      active_policy_id,
      target_wallet.id,
      target_membership.id,
      p_currency_code,
      p_gross_amount,
      false
    ) allocation;

  posting_result := ledger.post_transaction(
    p_idempotency_key,
    request_fingerprint,
    'income',
    target_membership.id,
    target_wallet.id,
    p_actor_user_id,
    journals,
    jsonb_build_object(
      'income_record_id', target_income_id,
      'allocation_policy_version_id', active_policy_id
    )
  );

  insert into financial_ops.income_records (
    id,
    operation_reference,
    idempotency_key,
    request_fingerprint,
    tenant_id,
    office_id,
    membership_id,
    wallet_id,
    owner_user_id,
    currency_code,
    gross_amount,
    allocation_policy_version_id,
    recorded_by_user_id,
    financial_transaction_id
  )
  values (
    target_income_id,
    target_reference,
    p_idempotency_key,
    request_fingerprint,
    target_membership.tenant_id,
    target_membership.office_id,
    target_membership.id,
    target_wallet.id,
    target_membership.user_id,
    p_currency_code,
    p_gross_amount,
    active_policy_id,
    p_actor_user_id,
    posting_result.transaction_id
  )
  returning * into existing_income;

  insert into financial_ops.income_allocations (
    income_record_id,
    ledger_account_id,
    pocket_key,
    allocation_basis_points,
    remainder_rank,
    allocated_amount
  )
  select
    existing_income.id,
    allocation.ledger_account_id,
    allocation.pocket_key,
    allocation.allocation_basis_points,
    allocation.remainder_rank,
    allocation.allocated_amount
  from financial_ops.calculate_policy_allocations(
    active_policy_id,
    target_wallet.id,
    target_membership.id,
    p_currency_code,
    p_gross_amount,
    false
  ) allocation;

  perform evidence.attach_financial_operation_evidence(
    target_membership.tenant_id,
    p_actor_user_id,
    'income',
    'income_record',
    existing_income.id,
    p_evidence_items
  );

  perform financial_ops.record_operation_authorization_audit(
    authorization_decision,
    p_session_id,
    'income_recorded',
    'income_record',
    existing_income.id,
    jsonb_build_object('financial_transaction_id', posting_result.transaction_id)
  );

  return (
    existing_income.id,
    existing_income.operation_reference,
    'posted',
    posting_result.transaction_id,
    false
  )::financial_ops.financial_operation_result;
end;
$$;

create or replace function financial_ops.assert_currency_amount(
  p_amount numeric,
  p_currency_code text
)
returns void
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  currency_scale smallint;
begin
  select currency.minor_unit_scale
    into currency_scale
    from ledger.currency_definitions currency
   where currency.currency_code = p_currency_code;

  if p_amount is null
     or p_amount <= 0
     or currency_scale is null
     or round(p_amount, currency_scale) <> p_amount then
    raise exception using
      errcode = '23514',
      message = 'financial amount must be positive and respect the currency minor-unit scale';
  end if;
end;
$$;

create or replace function financial_ops.require_system_account(
  p_currency_code text,
  p_system_account_key text
)
returns uuid
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  target_account_id uuid;
begin
  select account.id
    into target_account_id
    from ledger.ledger_accounts account
   where account.account_class = 'system_counter'
     and account.currency_code = p_currency_code
     and account.system_account_key = p_system_account_key;

  if target_account_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'required system ledger account is not configured';
  end if;

  return target_account_id;
end;
$$;

create or replace function financial_ops.record_operation_authorization_audit(
  p_decision authz.authorization_decision,
  p_session_id uuid,
  p_event_type text,
  p_target_type text,
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
    p_target_type,
    p_target_id,
    true,
    p_decision.source,
    p_decision.source_id,
    p_decision.reason_code,
    p_metadata
  );
$$;

create or replace function financial_ops.calculate_policy_allocations(
  p_policy_version_id uuid,
  p_wallet_id uuid,
  p_membership_id uuid,
  p_currency_code text,
  p_total_amount numeric,
  p_cap_debt_at_zero boolean default false
)
returns table (
  ledger_account_id uuid,
  pocket_key text,
  allocation_basis_points integer,
  remainder_rank smallint,
  allocated_amount numeric
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  currency_scale smallint;
  unit_factor numeric;
  total_units numeric;
  debt_capacity_units numeric := 0;
begin
  select currency.minor_unit_scale
    into currency_scale
    from ledger.currency_definitions currency
   where currency.currency_code = p_currency_code;

  if currency_scale is null then
    raise exception using errcode = '23514', message = 'allocation currency is not configured';
  end if;

  perform financial_ops.assert_currency_amount(p_total_amount, p_currency_code);
  unit_factor := power(10::numeric, currency_scale);
  total_units := p_total_amount * unit_factor;

  if p_cap_debt_at_zero then
    select greatest(-coalesce(projection.balance, 0), 0) * unit_factor
      into debt_capacity_units
      from ledger.ledger_accounts account
      left join ledger.wallet_balance_projections projection
        on projection.ledger_account_id = account.id
     where account.wallet_id = p_wallet_id
       and account.membership_id = p_membership_id
       and account.currency_code = p_currency_code
       and account.pocket_key = 'debt';

    debt_capacity_units := coalesce(debt_capacity_units, 0);
  end if;

  return query
  with policy_rules as (
    select
      rule.pocket_key,
      rule.allocation_basis_points,
      rule.remainder_rank,
      floor(total_units * rule.allocation_basis_points / 10000)::numeric as base_units
    from public.allocation_policy_rules rule
    where rule.policy_version_id = p_policy_version_id
  ),
  initial as (
    select
      rule.*,
      rule.base_units
        + case
            when row_number() over (order by rule.remainder_rank)
              <= total_units - sum(rule.base_units) over ()
            then 1 else 0
          end as initial_units
    from policy_rules rule
  ),
  capped as (
    select
      initial.*,
      case
        when p_cap_debt_at_zero and initial.pocket_key = 'debt'
        then least(initial.initial_units, debt_capacity_units)
        else initial.initial_units
      end as capped_units
    from initial
  ),
  excess as (
    select coalesce(sum(initial_units - capped_units), 0)::numeric as units
    from capped
  ),
  non_debt as (
    select
      capped.*,
      sum(capped.allocation_basis_points)
        filter (where capped.pocket_key <> 'debt') over () as non_debt_bps
    from capped
  ),
  redistributed_base as (
    select
      non_debt.*,
      case
        when p_cap_debt_at_zero
          and non_debt.pocket_key <> 'debt'
          and non_debt.non_debt_bps > 0
        then floor(
          (select units from excess)
          * non_debt.allocation_basis_points
          / non_debt.non_debt_bps
        )
        else 0
      end as extra_base_units
    from non_debt
  ),
  redistributed as (
    select
      redistributed_base.*,
      extra_base_units
        + case
            when p_cap_debt_at_zero
             and redistributed_base.pocket_key <> 'debt'
             and row_number() over (
               partition by (redistributed_base.pocket_key <> 'debt')
               order by redistributed_base.remainder_rank
             ) <= (select units from excess)
               - sum(redistributed_base.extra_base_units)
                 filter (where redistributed_base.pocket_key <> 'debt') over ()
            then 1 else 0
          end as extra_units
    from redistributed_base
  )
  select
    account.id,
    redistributed.pocket_key,
    redistributed.allocation_basis_points,
    redistributed.remainder_rank,
    (redistributed.capped_units + redistributed.extra_units) / unit_factor
  from redistributed
  join ledger.ledger_accounts account
    on account.account_class = 'member_value'
   and account.wallet_id = p_wallet_id
   and account.membership_id = p_membership_id
   and account.currency_code = p_currency_code
   and account.pocket_key = redistributed.pocket_key
  order by redistributed.remainder_rank;
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

    return (
      existing_transfer.id,
      existing_transfer.operation_reference,
      existing_transfer.status::text,
      existing_transfer.financial_transaction_id,
      true
    )::financial_ops.financial_operation_result;
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
  perform financial_ops.enforce_authorization(authorization_decision);

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

  if target_transfer.status = 'approved' then
    return (
      target_transfer.id,
      target_transfer.operation_reference,
      target_transfer.status::text,
      target_transfer.financial_transaction_id,
      true
    )::financial_ops.financial_operation_result;
  end if;

  if target_transfer.status <> 'requested'
     or target_transfer.requested_by_user_id = p_actor_user_id then
    raise exception using
      errcode = '55000',
      message = 'pocket transfer requires a separate approver while requested';
  end if;

  select * into target_reservation
    from financial_ops.pocket_transfer_reservations reservation
   where reservation.pocket_transfer_id = target_transfer.id
   for update;

  select * into target_membership
    from public.memberships membership
   where membership.id = target_transfer.membership_id;

  if target_reservation.status <> 'active' or target_membership.status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'pocket transfer approval requires active reservation and membership';
  end if;

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
  perform financial_ops.enforce_authorization(authorization_decision);

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
     set status = 'approved',
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
  if target_transfer.status = 'rejected' then
    return (target_transfer.id, target_transfer.operation_reference,
      target_transfer.status::text, null, true)::financial_ops.financial_operation_result;
  end if;
  if target_transfer.status <> 'requested'
     or target_transfer.requested_by_user_id = p_actor_user_id then
    raise exception using errcode = '55000', message = 'pocket transfer cannot be rejected in its current state';
  end if;

  authorization_decision := authz.authorize(
    p_actor_user_id, p_session_id, 'approve_pocket_transfer',
    target_transfer.tenant_id, target_transfer.office_id,
    target_transfer.membership_id, target_transfer.owner_user_id,
    target_transfer.wallet_id, target_transfer.owner_user_id,
    'reject_pocket_transfer', target_transfer.amount
  );
  perform financial_ops.enforce_authorization(authorization_decision);

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
  if target_transfer.status = 'cancelled' then
    return (target_transfer.id, target_transfer.operation_reference,
      target_transfer.status::text, null, true)::financial_ops.financial_operation_result;
  end if;
  if target_transfer.status <> 'requested'
     or target_transfer.requested_by_user_id <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'only the requester may cancel a requested pocket transfer';
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
  perform financial_ops.enforce_authorization(authorization_decision);

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

create or replace function financial_ops.post_currency_conversion(
  p_currency_conversion_id uuid,
  p_resolution financial_ops.evidence_operation_resolution,
  p_posting_idempotency_key uuid,
  p_actor_user_id uuid
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_operation financial_ops.currency_conversions%rowtype;
  target_revision financial_ops.currency_conversion_revisions%rowtype;
  source_clearing_account_id uuid;
  destination_clearing_account_id uuid;
  request_fingerprint bytea;
  posting_result ledger.post_transaction_result;
begin
  select * into target_operation
    from financial_ops.currency_conversions operation
   where operation.id = p_currency_conversion_id
   for update;

  select * into target_revision
    from financial_ops.currency_conversion_revisions revision
   where revision.currency_conversion_id = target_operation.id
     and revision.revision_number = target_operation.current_revision_number;

  if target_operation.id is null
     or target_operation.status not in ('submitted', 'needs_review')
     or target_revision.id is null then
    raise exception using errcode = '55000', message = 'currency conversion is not ready to post';
  end if;

  perform account.id
    from ledger.ledger_accounts account
   where account.id in (
     target_operation.source_ledger_account_id,
     target_operation.destination_ledger_account_id
   )
   order by account.id
   for update;

  if financial_ops.available_balance(target_operation.source_ledger_account_id)
       < target_revision.source_amount then
    raise exception using errcode = '23514', message = 'currency conversion exceeds available funds';
  end if;

  source_clearing_account_id := financial_ops.require_system_account(
    target_revision.source_currency_code,
    'fx_clearing'
  );
  destination_clearing_account_id := financial_ops.require_system_account(
    target_revision.destination_currency_code,
    'fx_clearing'
  );

  request_fingerprint := extensions.digest(
    jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'currency_conversion_id', target_operation.id,
      'destination_amount', target_revision.destination_amount::text,
      'resolution', p_resolution,
      'revision_number', target_revision.revision_number,
      'source_amount', target_revision.source_amount::text
    )::text,
    'sha256'
  );

  posting_result := ledger.post_transaction(
    p_posting_idempotency_key,
    request_fingerprint,
    'currency_conversion',
    target_operation.membership_id,
    target_operation.wallet_id,
    p_actor_user_id,
    jsonb_build_array(
      jsonb_build_object(
        'currency_code', target_revision.source_currency_code,
        'postings', jsonb_build_array(
          jsonb_build_object(
            'ledger_account_id', target_operation.source_ledger_account_id,
            'amount', (-target_revision.source_amount)::text
          ),
          jsonb_build_object(
            'ledger_account_id', source_clearing_account_id,
            'amount', target_revision.source_amount::text
          )
        )
      ),
      jsonb_build_object(
        'currency_code', target_revision.destination_currency_code,
        'postings', jsonb_build_array(
          jsonb_build_object(
            'ledger_account_id', destination_clearing_account_id,
            'amount', (-target_revision.destination_amount)::text
          ),
          jsonb_build_object(
            'ledger_account_id', target_operation.destination_ledger_account_id,
            'amount', target_revision.destination_amount::text
          )
        )
      )
    ),
    jsonb_build_object(
      'currency_conversion_id', target_operation.id,
      'effective_rate', target_revision.effective_rate,
      'provider', target_revision.provider,
      'provider_fee_amount', target_revision.provider_fee_amount,
      'provider_fee_currency', target_revision.provider_fee_currency,
      'provider_rate', target_revision.provider_rate,
      'resolution', p_resolution,
      'revision_number', target_revision.revision_number,
      'withdrawal_id', target_operation.withdrawal_id
    )
  );

  perform set_config('financial_ops.evidence_operation_transition', target_operation.id::text, true);
  update financial_ops.currency_conversions
     set status = 'posted',
         accepted_via = p_resolution,
         accepted_at = clock_timestamp(),
         posted_financial_transaction_id = posting_result.transaction_id,
         version = version + 1,
         updated_at = clock_timestamp()
   where id = target_operation.id;
  perform set_config('financial_ops.evidence_operation_transition', '', true);

  return posting_result.transaction_id;
end;
$$;

create or replace function financial_ops.submit_currency_conversion(
  p_idempotency_key uuid,
  p_source_ledger_account_id uuid,
  p_destination_ledger_account_id uuid,
  p_source_amount numeric,
  p_destination_amount numeric,
  p_effective_rate numeric,
  p_provider text,
  p_converted_at timestamptz,
  p_evidence_items jsonb,
  p_actor_user_id uuid,
  p_provider_rate numeric default null,
  p_provider_fee_amount numeric default 0,
  p_provider_fee_currency text default null,
  p_provider_reference text default null,
  p_withdrawal_id uuid default null,
  p_notes text default null,
  p_session_id uuid default null
)
returns financial_ops.financial_operation_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_operation financial_ops.currency_conversions%rowtype;
  source_account ledger.ledger_accounts%rowtype;
  destination_account ledger.ledger_accounts%rowtype;
  target_membership public.memberships%rowtype;
  target_revision financial_ops.currency_conversion_revisions%rowtype;
  authorization_decision authz.authorization_decision;
begin
  if p_idempotency_key is null
     or p_source_ledger_account_id is null
     or p_destination_ledger_account_id is null
     or p_effective_rate is null or p_effective_rate <= 0
     or coalesce(length(btrim(p_provider)), 0) = 0
     or p_converted_at is null
     or p_evidence_items is null
     or jsonb_typeof(p_evidence_items) <> 'array'
     or jsonb_array_length(p_evidence_items) = 0
     or p_provider_fee_amount < 0
     or (p_provider_fee_amount = 0 and p_provider_fee_currency is not null)
     or (p_provider_fee_amount > 0 and p_provider_fee_currency is null) then
    raise exception using errcode = '22023', message = 'currency conversion input is invalid';
  end if;
  perform financial_ops.require_command_actor(p_actor_user_id);

  request_fingerprint := extensions.digest(jsonb_build_object(
    'actor_user_id', p_actor_user_id,
    'converted_at', p_converted_at,
    'destination_amount', p_destination_amount::text,
    'destination_ledger_account_id', p_destination_ledger_account_id,
    'effective_rate', p_effective_rate::text,
    'evidence_items', p_evidence_items,
    'notes', nullif(btrim(p_notes), ''),
    'provider', btrim(p_provider),
    'provider_fee_amount', p_provider_fee_amount::text,
    'provider_fee_currency', p_provider_fee_currency,
    'provider_rate', p_provider_rate::text,
    'provider_reference', nullif(btrim(p_provider_reference), ''),
    'source_amount', p_source_amount::text,
    'source_ledger_account_id', p_source_ledger_account_id,
    'withdrawal_id', p_withdrawal_id
  )::text, 'sha256');

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_idempotency_key::text, 0));
  select * into existing_operation
    from financial_ops.currency_conversions operation
   where operation.idempotency_key = p_idempotency_key;
  if found then
    if existing_operation.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '23505', message = 'idempotency key already used with different conversion data';
    end if;
    return (existing_operation.id, existing_operation.operation_reference,
      existing_operation.status::text, existing_operation.posted_financial_transaction_id,
      true)::financial_ops.financial_operation_result;
  end if;

  perform account.id from ledger.ledger_accounts account
   where account.id in (p_source_ledger_account_id, p_destination_ledger_account_id)
   order by account.id for update;
  select * into source_account from ledger.ledger_accounts where id = p_source_ledger_account_id;
  select * into destination_account from ledger.ledger_accounts where id = p_destination_ledger_account_id;

  if source_account.id is null or destination_account.id is null
     or source_account.account_class <> 'member_value'
     or destination_account.account_class <> 'member_value'
     or source_account.wallet_id <> destination_account.wallet_id
     or source_account.tenant_id <> destination_account.tenant_id
     or source_account.office_id <> destination_account.office_id
     or source_account.membership_id <> destination_account.membership_id
     or source_account.owner_user_id <> destination_account.owner_user_id
     or source_account.pocket_key <> destination_account.pocket_key
     or source_account.currency_code = destination_account.currency_code then
    raise exception using errcode = '23514', message = 'conversion accounts must share one Wallet pocket and use different currencies';
  end if;

  select * into target_membership from public.memberships where id = source_account.membership_id;
  if target_membership.status <> 'active' then
    raise exception using errcode = '23514', message = 'currency conversion requires an active target membership';
  end if;
  perform financial_ops.assert_currency_amount(p_source_amount, source_account.currency_code);
  perform financial_ops.assert_currency_amount(p_destination_amount, destination_account.currency_code);
  if p_provider_fee_amount > 0 then
    perform financial_ops.assert_currency_amount(p_provider_fee_amount, p_provider_fee_currency);
  end if;
  if financial_ops.available_balance(source_account.id) < p_source_amount then
    raise exception using errcode = '23514', message = 'currency conversion exceeds available funds';
  end if;

  if p_withdrawal_id is not null and not exists (
    select 1 from financial_ops.withdrawal_requests withdrawal
     where withdrawal.id = p_withdrawal_id
       and withdrawal.wallet_id = source_account.wallet_id
       and withdrawal.tenant_id = source_account.tenant_id
  ) then
    raise exception using errcode = '23514', message = 'linked withdrawal does not match the conversion Wallet context';
  end if;

  authorization_decision := authz.authorize(
    p_actor_user_id, p_session_id, 'perform_currency_conversion',
    source_account.tenant_id, source_account.office_id, source_account.membership_id,
    source_account.owner_user_id, source_account.wallet_id, source_account.owner_user_id,
    'submit_currency_conversion', p_source_amount
  );
  perform financial_ops.enforce_authorization(authorization_decision);

  insert into financial_ops.currency_conversions (
    idempotency_key, request_fingerprint, tenant_id, office_id, membership_id,
    wallet_id, owner_user_id, source_ledger_account_id, destination_ledger_account_id,
    withdrawal_id, submitted_by_user_id
  ) values (
    p_idempotency_key, request_fingerprint, source_account.tenant_id,
    source_account.office_id, source_account.membership_id, source_account.wallet_id,
    source_account.owner_user_id, source_account.id, destination_account.id,
    p_withdrawal_id, p_actor_user_id
  ) returning * into existing_operation;

  insert into financial_ops.currency_conversion_revisions (
    currency_conversion_id, revision_number, source_amount, destination_amount,
    source_currency_code, destination_currency_code, provider_rate, effective_rate,
    provider_fee_amount, provider_fee_currency, provider, provider_reference,
    converted_at, notes, submitted_by_user_id
  ) values (
    existing_operation.id, 1, p_source_amount, p_destination_amount,
    source_account.currency_code, destination_account.currency_code,
    p_provider_rate, p_effective_rate, p_provider_fee_amount, p_provider_fee_currency,
    btrim(p_provider), nullif(btrim(p_provider_reference), ''), p_converted_at,
    nullif(btrim(p_notes), ''), p_actor_user_id
  ) returning * into target_revision;

  perform evidence.attach_financial_operation_evidence(
    source_account.tenant_id, p_actor_user_id, 'currency_conversion',
    'currency_conversion_revision', target_revision.id, p_evidence_items
  );
  perform financial_ops.record_operation_authorization_audit(
    authorization_decision, p_session_id, 'currency_conversion_submitted',
    'currency_conversion', existing_operation.id,
    jsonb_build_object('revision_number', 1)
  );
  return (existing_operation.id, existing_operation.operation_reference,
    existing_operation.status::text, null, false)::financial_ops.financial_operation_result;
end;
$$;

create or replace function financial_ops.correct_currency_conversion(
  p_correction_idempotency_key uuid,
  p_currency_conversion_id uuid,
  p_source_amount numeric,
  p_destination_amount numeric,
  p_effective_rate numeric,
  p_provider text,
  p_converted_at timestamptz,
  p_evidence_items jsonb,
  p_actor_user_id uuid,
  p_provider_rate numeric default null,
  p_provider_fee_amount numeric default 0,
  p_provider_fee_currency text default null,
  p_provider_reference text default null,
  p_notes text default null,
  p_session_id uuid default null
)
returns financial_ops.financial_operation_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_operation financial_ops.currency_conversions%rowtype;
  source_account ledger.ledger_accounts%rowtype;
  destination_account ledger.ledger_accounts%rowtype;
  target_revision financial_ops.currency_conversion_revisions%rowtype;
  authorization_decision authz.authorization_decision;
begin
  if p_correction_idempotency_key is null or p_currency_conversion_id is null
     or p_effective_rate is null or p_effective_rate <= 0
     or coalesce(length(btrim(p_provider)), 0) = 0 or p_converted_at is null
     or p_evidence_items is null or jsonb_typeof(p_evidence_items) <> 'array'
     or jsonb_array_length(p_evidence_items) = 0
     or p_provider_fee_amount < 0
     or (p_provider_fee_amount = 0 and p_provider_fee_currency is not null)
     or (p_provider_fee_amount > 0 and p_provider_fee_currency is null) then
    raise exception using errcode = '22023', message = 'currency conversion correction input is invalid';
  end if;
  perform financial_ops.require_command_actor(p_actor_user_id);

  select operation.* into target_operation
    from financial_ops.currency_conversions operation
    left join financial_ops.currency_conversion_revisions revision
      on revision.currency_conversion_id = operation.id
     and revision.correction_idempotency_key = p_correction_idempotency_key
   where operation.id = p_currency_conversion_id
   for update of operation;

  select * into target_revision
    from financial_ops.currency_conversion_revisions revision
   where revision.currency_conversion_id = p_currency_conversion_id
     and revision.correction_idempotency_key = p_correction_idempotency_key;
  if target_revision.id is not null then
    return (target_operation.id, target_operation.operation_reference,
      target_operation.status::text, target_operation.posted_financial_transaction_id,
      true)::financial_ops.financial_operation_result;
  end if;

  if target_operation.id is null or target_operation.status <> 'correction_required'
     or target_operation.current_revision_number <> 1
     or target_operation.submitted_by_user_id <> p_actor_user_id then
    raise exception using errcode = '55000', message = 'currency conversion does not allow another correction';
  end if;

  select * into source_account from ledger.ledger_accounts where id = target_operation.source_ledger_account_id;
  select * into destination_account from ledger.ledger_accounts where id = target_operation.destination_ledger_account_id;
  perform financial_ops.assert_currency_amount(p_source_amount, source_account.currency_code);
  perform financial_ops.assert_currency_amount(p_destination_amount, destination_account.currency_code);
  if p_provider_fee_amount > 0 then
    perform financial_ops.assert_currency_amount(p_provider_fee_amount, p_provider_fee_currency);
  end if;

  authorization_decision := authz.authorize(
    p_actor_user_id, p_session_id, 'perform_currency_conversion',
    target_operation.tenant_id, target_operation.office_id, target_operation.membership_id,
    target_operation.owner_user_id, target_operation.wallet_id, target_operation.owner_user_id,
    'correct_currency_conversion', p_source_amount
  );
  perform financial_ops.enforce_authorization(authorization_decision);

  insert into financial_ops.currency_conversion_revisions (
    currency_conversion_id, revision_number, correction_idempotency_key,
    source_amount, destination_amount, source_currency_code, destination_currency_code,
    provider_rate, effective_rate, provider_fee_amount, provider_fee_currency,
    provider, provider_reference, converted_at, notes, submitted_by_user_id
  ) values (
    target_operation.id, 2, p_correction_idempotency_key,
    p_source_amount, p_destination_amount, source_account.currency_code,
    destination_account.currency_code, p_provider_rate, p_effective_rate,
    p_provider_fee_amount, p_provider_fee_currency, btrim(p_provider),
    nullif(btrim(p_provider_reference), ''), p_converted_at,
    nullif(btrim(p_notes), ''), p_actor_user_id
  ) returning * into target_revision;

  perform evidence.attach_financial_operation_evidence(
    target_operation.tenant_id, p_actor_user_id, 'currency_conversion',
    'currency_conversion_revision', target_revision.id, p_evidence_items
  );
  perform set_config('financial_ops.evidence_operation_transition', target_operation.id::text, true);
  update financial_ops.currency_conversions
     set status = 'submitted', current_revision_number = 2,
         version = version + 1, updated_at = clock_timestamp()
   where id = target_operation.id
  returning * into target_operation;
  perform set_config('financial_ops.evidence_operation_transition', '', true);

  perform financial_ops.record_operation_authorization_audit(
    authorization_decision, p_session_id, 'currency_conversion_corrected',
    'currency_conversion', target_operation.id, jsonb_build_object('revision_number', 2)
  );
  return (target_operation.id, target_operation.operation_reference,
    target_operation.status::text, null, false)::financial_ops.financial_operation_result;
end;
$$;

create or replace function financial_ops.record_currency_conversion_verification(
  p_verification_request_id uuid,
  p_currency_conversion_id uuid,
  p_extracted_facts jsonb,
  p_mismatch_reasons jsonb,
  p_verifier_name text,
  p_verifier_version text default null
)
returns financial_ops.financial_operation_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_attempt evidence.financial_operation_verification_attempts%rowtype;
  target_operation financial_ops.currency_conversions%rowtype;
  target_revision financial_ops.currency_conversion_revisions%rowtype;
  verification_outcome evidence.verification_outcome;
  transaction_id uuid;
begin
  if p_verification_request_id is null or p_currency_conversion_id is null
     or p_extracted_facts is null or jsonb_typeof(p_extracted_facts) <> 'object'
     or p_mismatch_reasons is null or jsonb_typeof(p_mismatch_reasons) <> 'array'
     or coalesce(length(btrim(p_verifier_name)), 0) = 0 then
    raise exception using errcode = '22023', message = 'currency conversion verification input is invalid';
  end if;
  request_fingerprint := extensions.digest(jsonb_build_object(
    'currency_conversion_id', p_currency_conversion_id,
    'extracted_facts', p_extracted_facts,
    'mismatch_reasons', p_mismatch_reasons,
    'verifier_name', btrim(p_verifier_name),
    'verifier_version', nullif(btrim(p_verifier_version), '')
  )::text, 'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_verification_request_id::text, 0));

  select * into existing_attempt
    from evidence.financial_operation_verification_attempts attempt
   where attempt.verification_request_id = p_verification_request_id;
  select * into target_operation from financial_ops.currency_conversions where id = p_currency_conversion_id;
  if existing_attempt.id is not null then
    if existing_attempt.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '23505', message = 'verification request already used with different conversion data';
    end if;
    return (target_operation.id, target_operation.operation_reference,
      target_operation.status::text, target_operation.posted_financial_transaction_id,
      true)::financial_ops.financial_operation_result;
  end if;

  select * into target_operation
    from financial_ops.currency_conversions where id = p_currency_conversion_id for update;
  select * into target_revision from financial_ops.currency_conversion_revisions
   where currency_conversion_id = target_operation.id
     and revision_number = target_operation.current_revision_number;
  if target_operation.id is null or target_operation.status <> 'submitted' then
    raise exception using errcode = '55000', message = 'currency conversion is not awaiting verification';
  end if;

  verification_outcome := case when jsonb_array_length(p_mismatch_reasons) = 0
    then 'match'::evidence.verification_outcome else 'mismatch'::evidence.verification_outcome end;
  insert into evidence.financial_operation_verification_attempts (
    verification_request_id, request_fingerprint, currency_conversion_revision_id,
    outcome, extracted_facts, mismatch_reasons, verifier_name, verifier_version
  ) values (
    p_verification_request_id, request_fingerprint, target_revision.id,
    verification_outcome, p_extracted_facts, p_mismatch_reasons,
    btrim(p_verifier_name), nullif(btrim(p_verifier_version), '')
  );

  if verification_outcome = 'match' then
    transaction_id := financial_ops.post_currency_conversion(
      target_operation.id, 'automated_match', p_verification_request_id,
      target_operation.submitted_by_user_id
    );
  else
    perform set_config('financial_ops.evidence_operation_transition', target_operation.id::text, true);
    update financial_ops.currency_conversions
       set status = case when current_revision_number = 1
         then 'correction_required'::financial_ops.evidence_operation_status
         else 'needs_review'::financial_ops.evidence_operation_status end,
           version = version + 1, updated_at = clock_timestamp()
     where id = target_operation.id
    returning * into target_operation;
    perform set_config('financial_ops.evidence_operation_transition', '', true);
  end if;

  select * into target_operation from financial_ops.currency_conversions where id = p_currency_conversion_id;
  return (target_operation.id, target_operation.operation_reference,
    target_operation.status::text, transaction_id, false)::financial_ops.financial_operation_result;
end;
$$;

create or replace function financial_ops.review_currency_conversion(
  p_idempotency_key uuid,
  p_currency_conversion_id uuid,
  p_decision evidence.review_decision,
  p_review_note text,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.financial_operation_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_operation financial_ops.currency_conversions%rowtype;
  existing_decision evidence.financial_operation_review_decisions%rowtype;
  reviewer_assignment_id uuid;
  authorization_decision authz.authorization_decision;
  transaction_id uuid;
begin
  if p_idempotency_key is null or p_currency_conversion_id is null
     or p_decision is null or coalesce(length(btrim(p_review_note)), 0) = 0 then
    raise exception using errcode = '22023', message = 'currency conversion review input is invalid';
  end if;
  perform financial_ops.require_command_actor(p_actor_user_id);
  select * into target_operation from financial_ops.currency_conversions
   where id = p_currency_conversion_id for update;
  select * into existing_decision from evidence.financial_operation_review_decisions
   where currency_conversion_id = p_currency_conversion_id;
  if existing_decision.id is not null then
    if existing_decision.reviewer_user_id <> p_actor_user_id
       or existing_decision.decision <> p_decision
       or existing_decision.review_note <> btrim(p_review_note) then
      raise exception using errcode = '23505', message = 'currency conversion already has a different review decision';
    end if;
    return (target_operation.id, target_operation.operation_reference,
      target_operation.status::text, target_operation.posted_financial_transaction_id,
      true)::financial_ops.financial_operation_result;
  end if;
  if target_operation.id is null or target_operation.status <> 'needs_review' then
    raise exception using errcode = '55000', message = 'currency conversion is not awaiting manual review';
  end if;

  authorization_decision := authz.authorize_financial_evidence_review(
    p_actor_user_id, p_session_id, target_operation.tenant_id,
    target_operation.office_id, target_operation.membership_id,
    target_operation.owner_user_id, target_operation.wallet_id,
    'review_currency_conversion'
  );
  perform financial_ops.enforce_authorization(authorization_decision);
  reviewer_assignment_id := authorization_decision.source_id;

  insert into evidence.financial_operation_review_decisions (
    currency_conversion_id, reviewer_assignment_id, reviewer_user_id,
    decision, review_note
  ) values (
    target_operation.id, reviewer_assignment_id, p_actor_user_id,
    p_decision, btrim(p_review_note)
  );

  if p_decision = 'clear' then
    transaction_id := financial_ops.post_currency_conversion(
      target_operation.id, 'manual_clear', p_idempotency_key, p_actor_user_id
    );
  else
    perform set_config('financial_ops.evidence_operation_transition', target_operation.id::text, true);
    update financial_ops.currency_conversions
       set status = 'rejected', version = version + 1, updated_at = clock_timestamp()
     where id = target_operation.id;
    perform set_config('financial_ops.evidence_operation_transition', '', true);
  end if;

  perform financial_ops.record_operation_authorization_audit(
    authorization_decision, p_session_id, 'currency_conversion_reviewed',
    'currency_conversion', target_operation.id,
    jsonb_build_object('decision', p_decision)
  );
  select * into target_operation from financial_ops.currency_conversions where id = p_currency_conversion_id;
  return (target_operation.id, target_operation.operation_reference,
    target_operation.status::text, transaction_id, false)::financial_ops.financial_operation_result;
end;
$$;

create or replace function financial_ops.configure_adjustment_evidence_requirement(
  p_tenant_id uuid,
  p_evidence_required boolean,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.tenant_financial_settings
language plpgsql
security invoker
set search_path = ''
as $$
declare
  authorization_decision authz.authorization_decision;
  target_settings financial_ops.tenant_financial_settings%rowtype;
begin
  if p_tenant_id is null or p_evidence_required is null then
    raise exception using errcode = '22023', message = 'adjustment evidence setting input is invalid';
  end if;
  perform financial_ops.require_command_actor(p_actor_user_id);
  authorization_decision := authz.authorize(
    p_actor_user_id, p_session_id, 'configure_adjustment_evidence_requirement',
    p_tenant_id, null, null, null, null, null,
    'configure_adjustment_evidence_requirement', null
  );
  perform financial_ops.enforce_authorization(authorization_decision);

  insert into financial_ops.tenant_financial_settings (
    tenant_id, adjustment_evidence_required, updated_by_user_id
  ) values (p_tenant_id, p_evidence_required, p_actor_user_id)
  on conflict (tenant_id) do update
    set adjustment_evidence_required = excluded.adjustment_evidence_required,
        version = financial_ops.tenant_financial_settings.version + 1,
        updated_by_user_id = excluded.updated_by_user_id,
        updated_at = clock_timestamp()
  returning * into target_settings;

  perform financial_ops.record_operation_authorization_audit(
    authorization_decision, p_session_id, 'adjustment_evidence_requirement_configured',
    'tenant', p_tenant_id,
    jsonb_build_object('adjustment_evidence_required', p_evidence_required)
  );
  return target_settings;
end;
$$;

create or replace function financial_ops.post_administrative_adjustment(
  p_administrative_adjustment_id uuid,
  p_resolution financial_ops.evidence_operation_resolution,
  p_posting_idempotency_key uuid,
  p_actor_user_id uuid
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_operation financial_ops.administrative_adjustments%rowtype;
  system_account_id uuid;
  journals jsonb;
  request_fingerprint bytea;
  posting_result ledger.post_transaction_result;
  insufficient_line boolean;
begin
  select * into target_operation
    from financial_ops.administrative_adjustments operation
   where operation.id = p_administrative_adjustment_id
   for update;
  if target_operation.id is null
     or target_operation.status not in ('submitted', 'needs_review') then
    raise exception using errcode = '55000', message = 'administrative adjustment is not ready to post';
  end if;

  perform account.id
    from ledger.ledger_accounts account
    join financial_ops.administrative_adjustment_lines line
      on line.ledger_account_id = account.id
   where line.administrative_adjustment_id = target_operation.id
   order by account.id
   for update of account;

  if target_operation.direction = 'debit' then
    select exists (
      select 1
        from financial_ops.administrative_adjustment_lines line
        join ledger.ledger_accounts account on account.id = line.ledger_account_id
       where line.administrative_adjustment_id = target_operation.id
         and account.pocket_key <> 'debt'
         and financial_ops.available_balance(account.id) < line.amount
    ) into insufficient_line;
    if insufficient_line then
      raise exception using errcode = '23514', message = 'administrative debit exceeds available pocket funds';
    end if;
  end if;

  system_account_id := financial_ops.require_system_account(
    target_operation.currency_code,
    'administrative_adjustment'
  );

  select jsonb_build_array(jsonb_build_object(
    'currency_code', target_operation.currency_code,
    'postings',
      coalesce(jsonb_agg(jsonb_build_object(
        'ledger_account_id', line.ledger_account_id,
        'amount', (case when target_operation.direction = 'credit'
          then line.amount else -line.amount end)::text
      ) order by line.remainder_rank) filter (where line.amount > 0), '[]'::jsonb)
      || jsonb_build_array(jsonb_build_object(
        'ledger_account_id', system_account_id,
        'amount', (case when target_operation.direction = 'credit'
          then -target_operation.amount else target_operation.amount end)::text
      ))
  )) into journals
  from financial_ops.administrative_adjustment_lines line
  where line.administrative_adjustment_id = target_operation.id;

  request_fingerprint := extensions.digest(jsonb_build_object(
    'actor_user_id', p_actor_user_id,
    'administrative_adjustment_id', target_operation.id,
    'amount', target_operation.amount::text,
    'direction', target_operation.direction,
    'resolution', p_resolution
  )::text, 'sha256');

  posting_result := ledger.post_transaction(
    p_posting_idempotency_key, request_fingerprint, 'administrative_adjustment',
    target_operation.membership_id, target_operation.wallet_id, p_actor_user_id,
    journals,
    jsonb_build_object(
      'administrative_adjustment_id', target_operation.id,
      'allocation_policy_version_id', target_operation.allocation_policy_version_id,
      'reason', target_operation.reason,
      'resolution', p_resolution
    )
  );

  perform set_config('financial_ops.evidence_operation_transition', target_operation.id::text, true);
  update financial_ops.administrative_adjustments
     set status = 'posted', accepted_via = p_resolution,
         accepted_at = clock_timestamp(),
         posted_financial_transaction_id = posting_result.transaction_id,
         version = version + 1, updated_at = clock_timestamp()
   where id = target_operation.id;
  perform set_config('financial_ops.evidence_operation_transition', '', true);
  return posting_result.transaction_id;
end;
$$;

create or replace function financial_ops.submit_administrative_adjustment(
  p_idempotency_key uuid,
  p_target_membership_id uuid,
  p_currency_code text,
  p_direction financial_ops.adjustment_direction,
  p_amount numeric,
  p_reason text,
  p_evidence_items jsonb,
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
  existing_operation financial_ops.administrative_adjustments%rowtype;
  target_membership public.memberships%rowtype;
  target_wallet public.wallets%rowtype;
  active_policy_id uuid;
  evidence_required boolean;
  target_revision financial_ops.administrative_adjustment_revisions%rowtype;
  authorization_decision authz.authorization_decision;
  policy_rule_count integer;
  allocation_count integer;
  allocation_total numeric;
  insufficient_line boolean;
  transaction_id uuid;
begin
  if p_idempotency_key is null or p_target_membership_id is null
     or p_currency_code is null or p_direction is null
     or coalesce(length(btrim(p_reason)), 0) = 0
     or p_evidence_items is null or jsonb_typeof(p_evidence_items) <> 'array' then
    raise exception using errcode = '22023', message = 'administrative adjustment input is invalid';
  end if;
  perform financial_ops.require_command_actor(p_actor_user_id);
  perform financial_ops.assert_currency_amount(p_amount, p_currency_code);

  request_fingerprint := extensions.digest(jsonb_build_object(
    'actor_user_id', p_actor_user_id, 'amount', p_amount::text,
    'currency_code', p_currency_code, 'direction', p_direction,
    'evidence_items', p_evidence_items, 'reason', btrim(p_reason),
    'target_membership_id', p_target_membership_id
  )::text, 'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_idempotency_key::text, 0));
  select * into existing_operation from financial_ops.administrative_adjustments
   where idempotency_key = p_idempotency_key;
  if found then
    if existing_operation.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '23505', message = 'idempotency key already used with different adjustment data';
    end if;
    return (existing_operation.id, existing_operation.operation_reference,
      existing_operation.status::text, existing_operation.posted_financial_transaction_id,
      true)::financial_ops.financial_operation_result;
  end if;

  select * into target_membership from public.memberships
   where id = p_target_membership_id for update;
  select * into target_wallet from public.wallets
   where owner_user_id = target_membership.user_id;
  if target_membership.id is null or target_membership.status <> 'active'
     or target_membership.office_id is null or target_membership.role_key = 'president_team_member'
     or target_wallet.id is null or target_membership.user_id = p_actor_user_id then
    raise exception using errcode = '23514', message = 'administrative adjustment requires another active Wallet holder';
  end if;

  authorization_decision := authz.authorize(
    p_actor_user_id, p_session_id, 'manual_credit_debit_adjustment',
    target_membership.tenant_id, target_membership.office_id, target_membership.id,
    target_membership.user_id, target_wallet.id, target_membership.user_id,
    'submit_administrative_adjustment', p_amount
  );
  perform financial_ops.enforce_authorization(authorization_decision);

  select active.policy_version_id into active_policy_id
    from public.tenant_active_allocation_policies active
    join public.allocation_policy_versions policy
      on policy.tenant_id = active.tenant_id and policy.id = active.policy_version_id
     and policy.activated_at is not null
   where active.tenant_id = target_membership.tenant_id;
  if active_policy_id is null then
    raise exception using errcode = '23514', message = 'adjustment requires an active allocation policy';
  end if;

  select coalesce(settings.adjustment_evidence_required, true)
    into evidence_required
    from (select 1) seed
    left join financial_ops.tenant_financial_settings settings
      on settings.tenant_id = target_membership.tenant_id;
  if evidence_required and jsonb_array_length(p_evidence_items) = 0 then
    raise exception using errcode = '23514', message = 'tenant settings require adjustment evidence';
  end if;

  select count(*) into policy_rule_count from public.allocation_policy_rules
   where policy_version_id = active_policy_id;
  select count(*), coalesce(sum(allocation.allocated_amount), 0)
    into allocation_count, allocation_total
    from financial_ops.calculate_policy_allocations(
      active_policy_id, target_wallet.id, target_membership.id, p_currency_code,
      p_amount, p_direction = 'credit'
    ) allocation;
  if policy_rule_count = 0 or allocation_count <> policy_rule_count
     or allocation_total <> p_amount then
    raise exception using errcode = '23514', message = 'adjustment allocation cannot be resolved to Wallet accounts';
  end if;

  if p_direction = 'debit' then
    select exists (
      select 1 from financial_ops.calculate_policy_allocations(
        active_policy_id, target_wallet.id, target_membership.id,
        p_currency_code, p_amount, false
      ) allocation
      join ledger.ledger_accounts account on account.id = allocation.ledger_account_id
      where account.pocket_key <> 'debt'
        and financial_ops.available_balance(account.id) < allocation.allocated_amount
    ) into insufficient_line;
    if insufficient_line then
      raise exception using errcode = '23514', message = 'administrative debit exceeds available pocket funds';
    end if;
  end if;

  insert into financial_ops.administrative_adjustments (
    idempotency_key, request_fingerprint, tenant_id, office_id, membership_id,
    wallet_id, owner_user_id, currency_code, direction, amount, reason,
    allocation_policy_version_id, evidence_required, submitted_by_user_id
  ) values (
    p_idempotency_key, request_fingerprint, target_membership.tenant_id,
    target_membership.office_id, target_membership.id, target_wallet.id,
    target_membership.user_id, p_currency_code, p_direction, p_amount,
    btrim(p_reason), active_policy_id, evidence_required, p_actor_user_id
  ) returning * into existing_operation;
  insert into financial_ops.administrative_adjustment_revisions (
    administrative_adjustment_id, revision_number, submitted_by_user_id
  ) values (existing_operation.id, 1, p_actor_user_id)
  returning * into target_revision;
  insert into financial_ops.administrative_adjustment_lines (
    administrative_adjustment_id, ledger_account_id, pocket_key,
    allocation_basis_points, remainder_rank, amount
  ) select existing_operation.id, allocation.ledger_account_id, allocation.pocket_key,
      allocation.allocation_basis_points, allocation.remainder_rank, allocation.allocated_amount
    from financial_ops.calculate_policy_allocations(
      active_policy_id, target_wallet.id, target_membership.id, p_currency_code,
      p_amount, p_direction = 'credit'
    ) allocation;

  if evidence_required then
    perform evidence.attach_financial_operation_evidence(
      target_membership.tenant_id, p_actor_user_id, 'administrative_adjustment',
      'administrative_adjustment_revision', target_revision.id, p_evidence_items
    );
  else
    transaction_id := financial_ops.post_administrative_adjustment(
      existing_operation.id, 'automated_match', p_idempotency_key, p_actor_user_id
    );
  end if;

  perform financial_ops.record_operation_authorization_audit(
    authorization_decision, p_session_id, 'administrative_adjustment_submitted',
    'administrative_adjustment', existing_operation.id,
    jsonb_build_object('evidence_required', evidence_required)
  );
  select * into existing_operation from financial_ops.administrative_adjustments
   where id = existing_operation.id;
  return (existing_operation.id, existing_operation.operation_reference,
    existing_operation.status::text, transaction_id, false)::financial_ops.financial_operation_result;
end;
$$;

create or replace function financial_ops.correct_administrative_adjustment(
  p_correction_idempotency_key uuid,
  p_administrative_adjustment_id uuid,
  p_evidence_items jsonb,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.financial_operation_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_operation financial_ops.administrative_adjustments%rowtype;
  target_revision financial_ops.administrative_adjustment_revisions%rowtype;
  authorization_decision authz.authorization_decision;
begin
  if p_correction_idempotency_key is null or p_administrative_adjustment_id is null
     or p_evidence_items is null or jsonb_typeof(p_evidence_items) <> 'array'
     or jsonb_array_length(p_evidence_items) = 0 then
    raise exception using errcode = '22023', message = 'adjustment correction input is invalid';
  end if;
  perform financial_ops.require_command_actor(p_actor_user_id);
  select * into target_operation from financial_ops.administrative_adjustments
   where id = p_administrative_adjustment_id for update;
  select * into target_revision from financial_ops.administrative_adjustment_revisions
   where administrative_adjustment_id = p_administrative_adjustment_id
     and correction_idempotency_key = p_correction_idempotency_key;
  if target_revision.id is not null then
    return (target_operation.id, target_operation.operation_reference,
      target_operation.status::text, target_operation.posted_financial_transaction_id,
      true)::financial_ops.financial_operation_result;
  end if;
  if target_operation.id is null or target_operation.status <> 'correction_required'
     or target_operation.current_revision_number <> 1
     or target_operation.submitted_by_user_id <> p_actor_user_id then
    raise exception using errcode = '55000', message = 'adjustment does not allow another correction';
  end if;

  authorization_decision := authz.authorize(
    p_actor_user_id, p_session_id, 'manual_credit_debit_adjustment',
    target_operation.tenant_id, target_operation.office_id,
    target_operation.membership_id, target_operation.owner_user_id,
    target_operation.wallet_id, target_operation.owner_user_id,
    'correct_administrative_adjustment', target_operation.amount
  );
  perform financial_ops.enforce_authorization(authorization_decision);

  insert into financial_ops.administrative_adjustment_revisions (
    administrative_adjustment_id, revision_number, correction_idempotency_key,
    submitted_by_user_id
  ) values (target_operation.id, 2, p_correction_idempotency_key, p_actor_user_id)
  returning * into target_revision;
  perform evidence.attach_financial_operation_evidence(
    target_operation.tenant_id, p_actor_user_id, 'administrative_adjustment',
    'administrative_adjustment_revision', target_revision.id, p_evidence_items
  );
  perform set_config('financial_ops.evidence_operation_transition', target_operation.id::text, true);
  update financial_ops.administrative_adjustments
     set status = 'submitted', current_revision_number = 2,
         version = version + 1, updated_at = clock_timestamp()
   where id = target_operation.id
  returning * into target_operation;
  perform set_config('financial_ops.evidence_operation_transition', '', true);
  perform financial_ops.record_operation_authorization_audit(
    authorization_decision, p_session_id, 'administrative_adjustment_corrected',
    'administrative_adjustment', target_operation.id,
    jsonb_build_object('revision_number', 2)
  );
  return (target_operation.id, target_operation.operation_reference,
    target_operation.status::text, null, false)::financial_ops.financial_operation_result;
end;
$$;

create or replace function financial_ops.record_administrative_adjustment_verification(
  p_verification_request_id uuid,
  p_administrative_adjustment_id uuid,
  p_extracted_facts jsonb,
  p_mismatch_reasons jsonb,
  p_verifier_name text,
  p_verifier_version text default null
)
returns financial_ops.financial_operation_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_attempt evidence.financial_operation_verification_attempts%rowtype;
  target_operation financial_ops.administrative_adjustments%rowtype;
  target_revision financial_ops.administrative_adjustment_revisions%rowtype;
  verification_outcome evidence.verification_outcome;
  transaction_id uuid;
begin
  if p_verification_request_id is null or p_administrative_adjustment_id is null
     or p_extracted_facts is null or jsonb_typeof(p_extracted_facts) <> 'object'
     or p_mismatch_reasons is null or jsonb_typeof(p_mismatch_reasons) <> 'array'
     or coalesce(length(btrim(p_verifier_name)), 0) = 0 then
    raise exception using errcode = '22023', message = 'adjustment verification input is invalid';
  end if;
  request_fingerprint := extensions.digest(jsonb_build_object(
    'administrative_adjustment_id', p_administrative_adjustment_id,
    'extracted_facts', p_extracted_facts, 'mismatch_reasons', p_mismatch_reasons,
    'verifier_name', btrim(p_verifier_name),
    'verifier_version', nullif(btrim(p_verifier_version), '')
  )::text, 'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_verification_request_id::text, 0));
  select * into existing_attempt from evidence.financial_operation_verification_attempts
   where verification_request_id = p_verification_request_id;
  select * into target_operation from financial_ops.administrative_adjustments
   where id = p_administrative_adjustment_id;
  if existing_attempt.id is not null then
    if existing_attempt.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '23505', message = 'verification request already used with different adjustment data';
    end if;
    return (target_operation.id, target_operation.operation_reference,
      target_operation.status::text, target_operation.posted_financial_transaction_id,
      true)::financial_ops.financial_operation_result;
  end if;

  select * into target_operation from financial_ops.administrative_adjustments
   where id = p_administrative_adjustment_id for update;
  select * into target_revision from financial_ops.administrative_adjustment_revisions
   where administrative_adjustment_id = target_operation.id
     and revision_number = target_operation.current_revision_number;
  if target_operation.id is null or target_operation.status <> 'submitted'
     or not target_operation.evidence_required then
    raise exception using errcode = '55000', message = 'adjustment is not awaiting verification';
  end if;
  verification_outcome := case when jsonb_array_length(p_mismatch_reasons) = 0
    then 'match'::evidence.verification_outcome else 'mismatch'::evidence.verification_outcome end;
  insert into evidence.financial_operation_verification_attempts (
    verification_request_id, request_fingerprint, administrative_adjustment_revision_id,
    outcome, extracted_facts, mismatch_reasons, verifier_name, verifier_version
  ) values (
    p_verification_request_id, request_fingerprint, target_revision.id,
    verification_outcome, p_extracted_facts, p_mismatch_reasons,
    btrim(p_verifier_name), nullif(btrim(p_verifier_version), '')
  );
  if verification_outcome = 'match' then
    transaction_id := financial_ops.post_administrative_adjustment(
      target_operation.id, 'automated_match', p_verification_request_id,
      target_operation.submitted_by_user_id
    );
  else
    perform set_config('financial_ops.evidence_operation_transition', target_operation.id::text, true);
    update financial_ops.administrative_adjustments
       set status = case when current_revision_number = 1
         then 'correction_required'::financial_ops.evidence_operation_status
         else 'needs_review'::financial_ops.evidence_operation_status end,
           version = version + 1, updated_at = clock_timestamp()
     where id = target_operation.id returning * into target_operation;
    perform set_config('financial_ops.evidence_operation_transition', '', true);
  end if;
  select * into target_operation from financial_ops.administrative_adjustments
   where id = p_administrative_adjustment_id;
  return (target_operation.id, target_operation.operation_reference,
    target_operation.status::text, transaction_id, false)::financial_ops.financial_operation_result;
end;
$$;

create or replace function financial_ops.review_administrative_adjustment(
  p_idempotency_key uuid,
  p_administrative_adjustment_id uuid,
  p_decision evidence.review_decision,
  p_review_note text,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.financial_operation_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_operation financial_ops.administrative_adjustments%rowtype;
  existing_decision evidence.financial_operation_review_decisions%rowtype;
  reviewer_assignment_id uuid;
  authorization_decision authz.authorization_decision;
  transaction_id uuid;
begin
  if p_idempotency_key is null or p_administrative_adjustment_id is null
     or p_decision is null or coalesce(length(btrim(p_review_note)), 0) = 0 then
    raise exception using errcode = '22023', message = 'adjustment review input is invalid';
  end if;
  perform financial_ops.require_command_actor(p_actor_user_id);
  select * into target_operation from financial_ops.administrative_adjustments
   where id = p_administrative_adjustment_id for update;
  select * into existing_decision from evidence.financial_operation_review_decisions
   where administrative_adjustment_id = p_administrative_adjustment_id;
  if existing_decision.id is not null then
    if existing_decision.reviewer_user_id <> p_actor_user_id
       or existing_decision.decision <> p_decision
       or existing_decision.review_note <> btrim(p_review_note) then
      raise exception using errcode = '23505', message = 'adjustment already has a different review decision';
    end if;
    return (target_operation.id, target_operation.operation_reference,
      target_operation.status::text, target_operation.posted_financial_transaction_id,
      true)::financial_ops.financial_operation_result;
  end if;
  if target_operation.id is null or target_operation.status <> 'needs_review' then
    raise exception using errcode = '55000', message = 'adjustment is not awaiting manual review';
  end if;
  authorization_decision := authz.authorize_financial_evidence_review(
    p_actor_user_id, p_session_id, target_operation.tenant_id,
    target_operation.office_id, target_operation.membership_id,
    target_operation.owner_user_id, target_operation.wallet_id,
    'review_administrative_adjustment'
  );
  perform financial_ops.enforce_authorization(authorization_decision);
  reviewer_assignment_id := authorization_decision.source_id;
  insert into evidence.financial_operation_review_decisions (
    administrative_adjustment_id, reviewer_assignment_id, reviewer_user_id,
    decision, review_note
  ) values (
    target_operation.id, reviewer_assignment_id, p_actor_user_id,
    p_decision, btrim(p_review_note)
  );
  if p_decision = 'clear' then
    transaction_id := financial_ops.post_administrative_adjustment(
      target_operation.id, 'manual_clear', p_idempotency_key, p_actor_user_id
    );
  else
    perform set_config('financial_ops.evidence_operation_transition', target_operation.id::text, true);
    update financial_ops.administrative_adjustments
       set status = 'rejected', version = version + 1, updated_at = clock_timestamp()
     where id = target_operation.id;
    perform set_config('financial_ops.evidence_operation_transition', '', true);
  end if;
  perform financial_ops.record_operation_authorization_audit(
    authorization_decision, p_session_id, 'administrative_adjustment_reviewed',
    'administrative_adjustment', target_operation.id,
    jsonb_build_object('decision', p_decision)
  );
  select * into target_operation from financial_ops.administrative_adjustments
   where id = p_administrative_adjustment_id;
  return (target_operation.id, target_operation.operation_reference,
    target_operation.status::text, transaction_id, false)::financial_ops.financial_operation_result;
end;
$$;

create or replace function financial_ops.post_returned_fund(
  p_returned_fund_id uuid,
  p_resolution financial_ops.evidence_operation_resolution,
  p_posting_idempotency_key uuid,
  p_actor_user_id uuid
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_operation financial_ops.returned_funds%rowtype;
  system_account_id uuid;
  request_fingerprint bytea;
  posting_result ledger.post_transaction_result;
begin
  select * into target_operation from financial_ops.returned_funds
   where id = p_returned_fund_id for update;
  if target_operation.id is null
     or target_operation.status not in ('submitted', 'needs_review') then
    raise exception using errcode = '55000', message = 'returned funds are not ready to post';
  end if;
  system_account_id := financial_ops.require_system_account(
    target_operation.currency_code, 'returned_funds_external'
  );
  request_fingerprint := extensions.digest(jsonb_build_object(
    'actor_user_id', p_actor_user_id, 'amount', target_operation.amount::text,
    'resolution', p_resolution, 'returned_fund_id', target_operation.id
  )::text, 'sha256');
  posting_result := ledger.post_transaction(
    p_posting_idempotency_key, request_fingerprint, 'returned_funds',
    target_operation.membership_id, target_operation.wallet_id, p_actor_user_id,
    jsonb_build_array(jsonb_build_object(
      'currency_code', target_operation.currency_code,
      'postings', jsonb_build_array(
        jsonb_build_object('ledger_account_id', system_account_id,
          'amount', (-target_operation.amount)::text),
        jsonb_build_object('ledger_account_id', target_operation.destination_ledger_account_id,
          'amount', target_operation.amount::text)
      )
    )),
    jsonb_build_object(
      'resolution', p_resolution, 'returned_fund_id', target_operation.id,
      'withdrawal_id', target_operation.withdrawal_id
    )
  );
  perform set_config('financial_ops.evidence_operation_transition', target_operation.id::text, true);
  update financial_ops.returned_funds
     set status = 'posted', accepted_via = p_resolution,
         accepted_at = clock_timestamp(),
         posted_financial_transaction_id = posting_result.transaction_id,
         version = version + 1, updated_at = clock_timestamp()
   where id = target_operation.id;
  perform set_config('financial_ops.evidence_operation_transition', '', true);
  return posting_result.transaction_id;
end;
$$;

create or replace function financial_ops.submit_returned_fund(
  p_idempotency_key uuid,
  p_withdrawal_id uuid,
  p_amount numeric,
  p_provider text,
  p_returned_at timestamptz,
  p_evidence_items jsonb,
  p_actor_user_id uuid,
  p_provider_reference text default null,
  p_notes text default null,
  p_session_id uuid default null
)
returns financial_ops.financial_operation_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_operation financial_ops.returned_funds%rowtype;
  target_withdrawal financial_ops.withdrawal_requests%rowtype;
  target_revision financial_ops.returned_fund_revisions%rowtype;
  final_wallet_debit numeric;
  committed_returns numeric;
  authorization_decision authz.authorization_decision;
begin
  if p_idempotency_key is null or p_withdrawal_id is null
     or coalesce(length(btrim(p_provider)), 0) = 0 or p_returned_at is null
     or p_evidence_items is null or jsonb_typeof(p_evidence_items) <> 'array'
     or jsonb_array_length(p_evidence_items) = 0 then
    raise exception using errcode = '22023', message = 'returned funds input is invalid';
  end if;
  perform financial_ops.require_command_actor(p_actor_user_id);
  request_fingerprint := extensions.digest(jsonb_build_object(
    'actor_user_id', p_actor_user_id, 'amount', p_amount::text,
    'evidence_items', p_evidence_items, 'notes', nullif(btrim(p_notes), ''),
    'provider', btrim(p_provider),
    'provider_reference', nullif(btrim(p_provider_reference), ''),
    'returned_at', p_returned_at, 'withdrawal_id', p_withdrawal_id
  )::text, 'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_idempotency_key::text, 0));
  select * into existing_operation from financial_ops.returned_funds
   where idempotency_key = p_idempotency_key;
  if found then
    if existing_operation.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '23505', message = 'idempotency key already used with different returned-fund data';
    end if;
    return (existing_operation.id, existing_operation.operation_reference,
      existing_operation.status::text, existing_operation.posted_financial_transaction_id,
      true)::financial_ops.financial_operation_result;
  end if;

  select * into target_withdrawal from financial_ops.withdrawal_requests
   where id = p_withdrawal_id for update;
  if target_withdrawal.id is null or target_withdrawal.status <> 'completed' then
    raise exception using errcode = '23514', message = 'returned funds require a completed withdrawal';
  end if;
  perform financial_ops.assert_currency_amount(p_amount, target_withdrawal.source_currency_code);

  select revision.wallet_debit_amount into final_wallet_debit
    from financial_ops.payout_completion_assertions assertion
    join financial_ops.payout_assertion_revisions revision
      on revision.payout_assertion_id = assertion.id
     and revision.revision_number = assertion.current_revision_number
   where assertion.withdrawal_id = target_withdrawal.id
     and assertion.status = 'posted'
   order by assertion.assertion_number desc limit 1;
  select coalesce(sum(returned.amount), 0) into committed_returns
    from financial_ops.returned_funds returned
   where returned.withdrawal_id = target_withdrawal.id
     and returned.status <> 'rejected';
  if final_wallet_debit is null or committed_returns + p_amount > final_wallet_debit then
    raise exception using errcode = '23514', message = 'cumulative returned funds exceed the final Wallet debit';
  end if;

  authorization_decision := authz.authorize(
    p_actor_user_id, p_session_id, 'record_returned_funds',
    target_withdrawal.tenant_id, target_withdrawal.office_id,
    target_withdrawal.membership_id, target_withdrawal.owner_user_id,
    target_withdrawal.wallet_id, target_withdrawal.owner_user_id,
    'submit_returned_fund', p_amount
  );
  perform financial_ops.enforce_authorization(authorization_decision);

  insert into financial_ops.returned_funds (
    idempotency_key, request_fingerprint, withdrawal_id, tenant_id, office_id,
    membership_id, wallet_id, owner_user_id, destination_ledger_account_id,
    currency_code, amount, submitted_by_user_id
  ) values (
    p_idempotency_key, request_fingerprint, target_withdrawal.id,
    target_withdrawal.tenant_id, target_withdrawal.office_id,
    target_withdrawal.membership_id, target_withdrawal.wallet_id,
    target_withdrawal.owner_user_id, target_withdrawal.source_ledger_account_id,
    target_withdrawal.source_currency_code, p_amount, p_actor_user_id
  ) returning * into existing_operation;
  insert into financial_ops.returned_fund_revisions (
    returned_fund_id, revision_number, provider, provider_reference,
    returned_at, notes, submitted_by_user_id
  ) values (
    existing_operation.id, 1, btrim(p_provider),
    nullif(btrim(p_provider_reference), ''), p_returned_at,
    nullif(btrim(p_notes), ''), p_actor_user_id
  ) returning * into target_revision;
  perform evidence.attach_financial_operation_evidence(
    target_withdrawal.tenant_id, p_actor_user_id, 'returned_funds',
    'returned_fund_revision', target_revision.id, p_evidence_items
  );
  perform financial_ops.record_operation_authorization_audit(
    authorization_decision, p_session_id, 'returned_fund_submitted',
    'returned_fund', existing_operation.id,
    jsonb_build_object('withdrawal_id', target_withdrawal.id)
  );
  return (existing_operation.id, existing_operation.operation_reference,
    existing_operation.status::text, null, false)::financial_ops.financial_operation_result;
end;
$$;

create or replace function financial_ops.correct_returned_fund(
  p_correction_idempotency_key uuid,
  p_returned_fund_id uuid,
  p_provider text,
  p_returned_at timestamptz,
  p_evidence_items jsonb,
  p_actor_user_id uuid,
  p_provider_reference text default null,
  p_notes text default null,
  p_session_id uuid default null
)
returns financial_ops.financial_operation_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_operation financial_ops.returned_funds%rowtype;
  target_revision financial_ops.returned_fund_revisions%rowtype;
  authorization_decision authz.authorization_decision;
begin
  if p_correction_idempotency_key is null or p_returned_fund_id is null
     or coalesce(length(btrim(p_provider)), 0) = 0 or p_returned_at is null
     or p_evidence_items is null or jsonb_typeof(p_evidence_items) <> 'array'
     or jsonb_array_length(p_evidence_items) = 0 then
    raise exception using errcode = '22023', message = 'returned-fund correction input is invalid';
  end if;
  perform financial_ops.require_command_actor(p_actor_user_id);
  select * into target_operation from financial_ops.returned_funds
   where id = p_returned_fund_id for update;
  select * into target_revision from financial_ops.returned_fund_revisions
   where returned_fund_id = p_returned_fund_id
     and correction_idempotency_key = p_correction_idempotency_key;
  if target_revision.id is not null then
    return (target_operation.id, target_operation.operation_reference,
      target_operation.status::text, target_operation.posted_financial_transaction_id,
      true)::financial_ops.financial_operation_result;
  end if;
  if target_operation.id is null or target_operation.status <> 'correction_required'
     or target_operation.current_revision_number <> 1
     or target_operation.submitted_by_user_id <> p_actor_user_id then
    raise exception using errcode = '55000', message = 'returned fund does not allow another correction';
  end if;
  authorization_decision := authz.authorize(
    p_actor_user_id, p_session_id, 'record_returned_funds',
    target_operation.tenant_id, target_operation.office_id, target_operation.membership_id,
    target_operation.owner_user_id, target_operation.wallet_id, target_operation.owner_user_id,
    'correct_returned_fund', target_operation.amount
  );
  perform financial_ops.enforce_authorization(authorization_decision);
  insert into financial_ops.returned_fund_revisions (
    returned_fund_id, revision_number, correction_idempotency_key,
    provider, provider_reference, returned_at, notes, submitted_by_user_id
  ) values (
    target_operation.id, 2, p_correction_idempotency_key, btrim(p_provider),
    nullif(btrim(p_provider_reference), ''), p_returned_at,
    nullif(btrim(p_notes), ''), p_actor_user_id
  ) returning * into target_revision;
  perform evidence.attach_financial_operation_evidence(
    target_operation.tenant_id, p_actor_user_id, 'returned_funds',
    'returned_fund_revision', target_revision.id, p_evidence_items
  );
  perform set_config('financial_ops.evidence_operation_transition', target_operation.id::text, true);
  update financial_ops.returned_funds
     set status = 'submitted', current_revision_number = 2,
         version = version + 1, updated_at = clock_timestamp()
   where id = target_operation.id returning * into target_operation;
  perform set_config('financial_ops.evidence_operation_transition', '', true);
  perform financial_ops.record_operation_authorization_audit(
    authorization_decision, p_session_id, 'returned_fund_corrected',
    'returned_fund', target_operation.id, jsonb_build_object('revision_number', 2)
  );
  return (target_operation.id, target_operation.operation_reference,
    target_operation.status::text, null, false)::financial_ops.financial_operation_result;
end;
$$;

create or replace function financial_ops.record_returned_fund_verification(
  p_verification_request_id uuid,
  p_returned_fund_id uuid,
  p_extracted_facts jsonb,
  p_mismatch_reasons jsonb,
  p_verifier_name text,
  p_verifier_version text default null
)
returns financial_ops.financial_operation_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_attempt evidence.financial_operation_verification_attempts%rowtype;
  target_operation financial_ops.returned_funds%rowtype;
  target_revision financial_ops.returned_fund_revisions%rowtype;
  verification_outcome evidence.verification_outcome;
  transaction_id uuid;
begin
  if p_verification_request_id is null or p_returned_fund_id is null
     or p_extracted_facts is null or jsonb_typeof(p_extracted_facts) <> 'object'
     or p_mismatch_reasons is null or jsonb_typeof(p_mismatch_reasons) <> 'array'
     or coalesce(length(btrim(p_verifier_name)), 0) = 0 then
    raise exception using errcode = '22023', message = 'returned-fund verification input is invalid';
  end if;
  request_fingerprint := extensions.digest(jsonb_build_object(
    'returned_fund_id', p_returned_fund_id, 'extracted_facts', p_extracted_facts,
    'mismatch_reasons', p_mismatch_reasons, 'verifier_name', btrim(p_verifier_name),
    'verifier_version', nullif(btrim(p_verifier_version), '')
  )::text, 'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_verification_request_id::text, 0));
  select * into existing_attempt from evidence.financial_operation_verification_attempts
   where verification_request_id = p_verification_request_id;
  select * into target_operation from financial_ops.returned_funds where id = p_returned_fund_id;
  if existing_attempt.id is not null then
    if existing_attempt.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '23505', message = 'verification request already used with different returned-fund data';
    end if;
    return (target_operation.id, target_operation.operation_reference,
      target_operation.status::text, target_operation.posted_financial_transaction_id,
      true)::financial_ops.financial_operation_result;
  end if;
  select * into target_operation from financial_ops.returned_funds
   where id = p_returned_fund_id for update;
  select * into target_revision from financial_ops.returned_fund_revisions
   where returned_fund_id = target_operation.id
     and revision_number = target_operation.current_revision_number;
  if target_operation.id is null or target_operation.status <> 'submitted' then
    raise exception using errcode = '55000', message = 'returned fund is not awaiting verification';
  end if;
  verification_outcome := case when jsonb_array_length(p_mismatch_reasons) = 0
    then 'match'::evidence.verification_outcome else 'mismatch'::evidence.verification_outcome end;
  insert into evidence.financial_operation_verification_attempts (
    verification_request_id, request_fingerprint, returned_fund_revision_id,
    outcome, extracted_facts, mismatch_reasons, verifier_name, verifier_version
  ) values (
    p_verification_request_id, request_fingerprint, target_revision.id,
    verification_outcome, p_extracted_facts, p_mismatch_reasons,
    btrim(p_verifier_name), nullif(btrim(p_verifier_version), '')
  );
  if verification_outcome = 'match' then
    transaction_id := financial_ops.post_returned_fund(
      target_operation.id, 'automated_match', p_verification_request_id,
      target_operation.submitted_by_user_id
    );
  else
    perform set_config('financial_ops.evidence_operation_transition', target_operation.id::text, true);
    update financial_ops.returned_funds
       set status = case when current_revision_number = 1
         then 'correction_required'::financial_ops.evidence_operation_status
         else 'needs_review'::financial_ops.evidence_operation_status end,
           version = version + 1, updated_at = clock_timestamp()
     where id = target_operation.id returning * into target_operation;
    perform set_config('financial_ops.evidence_operation_transition', '', true);
  end if;
  select * into target_operation from financial_ops.returned_funds where id = p_returned_fund_id;
  return (target_operation.id, target_operation.operation_reference,
    target_operation.status::text, transaction_id, false)::financial_ops.financial_operation_result;
end;
$$;

create or replace function financial_ops.review_returned_fund(
  p_idempotency_key uuid,
  p_returned_fund_id uuid,
  p_decision evidence.review_decision,
  p_review_note text,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.financial_operation_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_operation financial_ops.returned_funds%rowtype;
  existing_decision evidence.financial_operation_review_decisions%rowtype;
  reviewer_assignment_id uuid;
  authorization_decision authz.authorization_decision;
  transaction_id uuid;
begin
  if p_idempotency_key is null or p_returned_fund_id is null
     or p_decision is null or coalesce(length(btrim(p_review_note)), 0) = 0 then
    raise exception using errcode = '22023', message = 'returned-fund review input is invalid';
  end if;
  perform financial_ops.require_command_actor(p_actor_user_id);
  select * into target_operation from financial_ops.returned_funds
   where id = p_returned_fund_id for update;
  select * into existing_decision from evidence.financial_operation_review_decisions
   where returned_fund_id = p_returned_fund_id;
  if existing_decision.id is not null then
    if existing_decision.reviewer_user_id <> p_actor_user_id
       or existing_decision.decision <> p_decision
       or existing_decision.review_note <> btrim(p_review_note) then
      raise exception using errcode = '23505', message = 'returned fund already has a different review decision';
    end if;
    return (target_operation.id, target_operation.operation_reference,
      target_operation.status::text, target_operation.posted_financial_transaction_id,
      true)::financial_ops.financial_operation_result;
  end if;
  if target_operation.id is null or target_operation.status <> 'needs_review' then
    raise exception using errcode = '55000', message = 'returned fund is not awaiting manual review';
  end if;
  authorization_decision := authz.authorize_financial_evidence_review(
    p_actor_user_id, p_session_id, target_operation.tenant_id,
    target_operation.office_id, target_operation.membership_id,
    target_operation.owner_user_id, target_operation.wallet_id,
    'review_returned_fund'
  );
  perform financial_ops.enforce_authorization(authorization_decision);
  reviewer_assignment_id := authorization_decision.source_id;
  insert into evidence.financial_operation_review_decisions (
    returned_fund_id, reviewer_assignment_id, reviewer_user_id, decision, review_note
  ) values (
    target_operation.id, reviewer_assignment_id, p_actor_user_id,
    p_decision, btrim(p_review_note)
  );
  if p_decision = 'clear' then
    transaction_id := financial_ops.post_returned_fund(
      target_operation.id, 'manual_clear', p_idempotency_key, p_actor_user_id
    );
  else
    perform set_config('financial_ops.evidence_operation_transition', target_operation.id::text, true);
    update financial_ops.returned_funds
       set status = 'rejected', version = version + 1, updated_at = clock_timestamp()
     where id = target_operation.id;
    perform set_config('financial_ops.evidence_operation_transition', '', true);
  end if;
  perform financial_ops.record_operation_authorization_audit(
    authorization_decision, p_session_id, 'returned_fund_reviewed',
    'returned_fund', target_operation.id, jsonb_build_object('decision', p_decision)
  );
  select * into target_operation from financial_ops.returned_funds where id = p_returned_fund_id;
  return (target_operation.id, target_operation.operation_reference,
    target_operation.status::text, transaction_id, false)::financial_ops.financial_operation_result;
end;
$$;

create or replace function financial_ops.reverse_financial_transaction(
  p_idempotency_key uuid,
  p_original_financial_transaction_id uuid,
  p_reason text,
  p_actor_user_id uuid,
  p_session_id uuid
)
returns financial_ops.financial_operation_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_reversal financial_ops.financial_reversals%rowtype;
  target_transaction ledger.financial_transactions%rowtype;
  prior_reversal financial_ops.financial_reversals%rowtype;
  target_reversal_id uuid := extensions.gen_random_uuid();
  target_reference text := financial_ops.generate_operation_reference('REV');
  authorization_decision authz.authorization_decision;
  journals jsonb;
  posting_result ledger.post_transaction_result;
  insufficient_account boolean;
begin
  if p_idempotency_key is null or p_original_financial_transaction_id is null
     or coalesce(length(btrim(p_reason)), 0) = 0 or p_session_id is null then
    raise exception using errcode = '22023', message = 'transaction reversal input is invalid';
  end if;
  perform financial_ops.require_command_actor(p_actor_user_id);
  request_fingerprint := extensions.digest(jsonb_build_object(
    'actor_user_id', p_actor_user_id,
    'original_financial_transaction_id', p_original_financial_transaction_id,
    'reason', btrim(p_reason)
  )::text, 'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_idempotency_key::text, 0));
  select * into existing_reversal from financial_ops.financial_reversals
   where idempotency_key = p_idempotency_key;
  if found then
    if existing_reversal.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '23505', message = 'idempotency key already used with different reversal data';
    end if;
    return (existing_reversal.id, existing_reversal.operation_reference, 'posted',
      existing_reversal.reversal_financial_transaction_id,
      true)::financial_ops.financial_operation_result;
  end if;

  select * into target_transaction from ledger.financial_transactions
   where id = p_original_financial_transaction_id for update;
  if target_transaction.id is null or target_transaction.posted_at is null then
    raise exception using errcode = 'P0002', message = 'posted financial transaction was not found';
  end if;
  select * into prior_reversal from financial_ops.financial_reversals
   where reversal_financial_transaction_id = target_transaction.id;
  if prior_reversal.id is null and exists (
    select 1 from financial_ops.financial_reversals reversal
     where reversal.original_financial_transaction_id = target_transaction.id
       and reversal.reinstates_reversal_id is null
  ) then
    raise exception using errcode = '55000', message = 'financial transaction already has a direct reversal';
  end if;
  if prior_reversal.id is not null and exists (
    select 1 from financial_ops.financial_reversals reversal
     where reversal.reinstates_reversal_id = prior_reversal.id
  ) then
    raise exception using errcode = '55000', message = 'financial reversal has already been reinstated';
  end if;

  authorization_decision := authz.authorize(
    p_actor_user_id, p_session_id, 'reverse_transaction',
    target_transaction.tenant_id, target_transaction.office_id,
    target_transaction.membership_id, target_transaction.owner_user_id,
    target_transaction.wallet_id, target_transaction.owner_user_id,
    'reverse_financial_transaction', null
  );
  perform financial_ops.enforce_authorization(authorization_decision);
  if not authz.consume_action_confirmation(
    p_session_id, p_actor_user_id, 'reverse_financial_transaction',
    'financial_transaction', target_transaction.id
  ) then
    raise exception using errcode = '42501', message = 'transaction reversal requires a one-time action confirmation';
  end if;

  perform account.id
    from ledger.journal_entries entry
    join ledger.journal_postings posting on posting.journal_entry_id = entry.id
    join ledger.ledger_accounts account on account.id = posting.ledger_account_id
   where entry.financial_transaction_id = target_transaction.id
   order by account.id
   for update of account;

  select exists (
    select 1
      from (
        select account.id, account.pocket_key, sum(-posting.amount) as reversal_amount
          from ledger.journal_entries entry
          join ledger.journal_postings posting on posting.journal_entry_id = entry.id
          join ledger.ledger_accounts account on account.id = posting.ledger_account_id
         where entry.financial_transaction_id = target_transaction.id
           and account.account_class = 'member_value'
         group by account.id, account.pocket_key
      ) effect
     where effect.reversal_amount < 0
       and effect.pocket_key <> 'debt'
       and financial_ops.available_balance(effect.id) < -effect.reversal_amount
  ) into insufficient_account;
  if insufficient_account then
    raise exception using errcode = '23514', message = 'transaction reversal would violate available pocket funds';
  end if;

  select jsonb_agg(jsonb_build_object(
    'currency_code', source_journal.currency_code,
    'postings', source_journal.postings
  ) order by source_journal.entry_number)
    into journals
    from (
      select entry.entry_number, entry.currency_code,
        jsonb_agg(jsonb_build_object(
          'ledger_account_id', posting.ledger_account_id,
          'amount', (-posting.amount)::text
        ) order by posting.line_number) as postings
      from ledger.journal_entries entry
      join ledger.journal_postings posting on posting.journal_entry_id = entry.id
      where entry.financial_transaction_id = target_transaction.id
      group by entry.id, entry.entry_number, entry.currency_code
    ) source_journal;

  posting_result := ledger.post_transaction(
    p_idempotency_key, request_fingerprint,
    case when prior_reversal.id is null then 'transaction_reversal' else 'transaction_reinstatement' end,
    target_transaction.membership_id, target_transaction.wallet_id,
    p_actor_user_id, journals,
    jsonb_build_object(
      'financial_reversal_id', target_reversal_id,
      'original_financial_transaction_id', target_transaction.id,
      'reason', btrim(p_reason),
      'reinstates_reversal_id', prior_reversal.id
    )
  );

  insert into financial_ops.financial_reversals (
    id, operation_reference, idempotency_key, request_fingerprint,
    tenant_id, original_financial_transaction_id,
    reversal_financial_transaction_id, reinstates_reversal_id,
    reason, reversed_by_user_id
  ) values (
    target_reversal_id, target_reference, p_idempotency_key, request_fingerprint,
    target_transaction.tenant_id, target_transaction.id,
    posting_result.transaction_id, prior_reversal.id,
    btrim(p_reason), p_actor_user_id
  ) returning * into existing_reversal;

  perform financial_ops.record_operation_authorization_audit(
    authorization_decision, p_session_id,
    case when prior_reversal.id is null then 'financial_transaction_reversed'
      else 'financial_transaction_reinstated' end,
    'financial_transaction', target_transaction.id,
    jsonb_build_object(
      'financial_reversal_id', existing_reversal.id,
      'reversal_financial_transaction_id', posting_result.transaction_id
    )
  );
  return (existing_reversal.id, existing_reversal.operation_reference, 'posted',
    posting_result.transaction_id, false)::financial_ops.financial_operation_result;
end;
$$;
