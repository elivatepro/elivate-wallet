create or replace function read_api.member_withdrawals(
  p_actor_user_id uuid,
  p_before_created_at timestamptz default null,
  p_before_withdrawal_id uuid default null,
  p_limit integer default 50,
  p_status text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_status public.account_status;
  item_payload jsonb;
  next_cursor jsonb;
begin
  if p_actor_user_id is null then
    raise exception using errcode = '22023', message = 'member withdrawals actor is required';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'member withdrawals actor does not match the authenticated user';
  end if;

  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception using errcode = '22023', message = 'member withdrawals limit must be between 1 and 100';
  end if;

  if (p_before_created_at is null) <> (p_before_withdrawal_id is null) then
    raise exception using errcode = '22023', message = 'member withdrawals cursor is incomplete';
  end if;

  if p_status is not null and p_status not in ('requested', 'approved', 'completed', 'cancelled', 'rejected') then
    raise exception using errcode = '22023', message = 'member withdrawals status is invalid';
  end if;

  select account.status into actor_status
    from public.user_accounts account
   where account.user_id = p_actor_user_id;

  if actor_status is null or actor_status not in ('active', 'restricted', 'suspended') then
    raise exception using errcode = '42501', message = 'member withdrawals requires an eligible account';
  end if;

  if not exists (
    select 1
      from public.wallets wallet
      join public.memberships membership
        on membership.user_id = wallet.owner_user_id
       and membership.status = 'active'
      join public.tenants tenant
        on tenant.id = membership.tenant_id
       and tenant.status = 'active'
     where wallet.owner_user_id = p_actor_user_id
  ) then
    raise exception using errcode = '42501', message = 'member withdrawals requires an active Wallet membership';
  end if;

  with withdrawal_rows as materialized (
    select
      withdrawal.id as withdrawal_id,
      withdrawal.withdrawal_reference,
      withdrawal.source_currency_code,
      withdrawal.source_pocket_key,
      withdrawal.requested_amount,
      withdrawal.status,
      withdrawal.created_at,
      withdrawal.updated_at,
      withdrawal.approved_at,
      withdrawal.completed_at,
      withdrawal.rejected_at,
      withdrawal.cancelled_at,
      snapshot.institution_name,
      snapshot.payout_rail,
      snapshot.country_code,
      repeat('*', greatest(length(snapshot.account_reference) - 4, 0))
        || right(snapshot.account_reference, 4) as account_reference_masked,
      row_number() over (
        order by withdrawal.created_at desc, withdrawal.id desc
      ) as row_number
    from financial_ops.withdrawal_requests withdrawal
    join financial_ops.withdrawal_destination_snapshots snapshot
      on snapshot.withdrawal_id = withdrawal.id
   where withdrawal.owner_user_id = p_actor_user_id
     and (p_status is null or withdrawal.status::text = p_status)
     and (
       p_before_created_at is null
       or (withdrawal.created_at, withdrawal.id) < (p_before_created_at, p_before_withdrawal_id)
     )
   order by withdrawal.created_at desc, withdrawal.id desc
   limit p_limit + 1
  )
  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'withdrawal_id', withdrawal_rows.withdrawal_id,
          'reference', withdrawal_rows.withdrawal_reference,
          'currency_code', withdrawal_rows.source_currency_code,
          'pocket_key', withdrawal_rows.source_pocket_key,
          'requested_amount', withdrawal_rows.requested_amount,
          'status', withdrawal_rows.status,
          'created_at', withdrawal_rows.created_at,
          'updated_at', withdrawal_rows.updated_at,
          'approved_at', withdrawal_rows.approved_at,
          'completed_at', withdrawal_rows.completed_at,
          'rejected_at', withdrawal_rows.rejected_at,
          'cancelled_at', withdrawal_rows.cancelled_at,
          'destination', jsonb_build_object(
            'institution_name', withdrawal_rows.institution_name,
            'payout_rail', withdrawal_rows.payout_rail,
            'country_code', withdrawal_rows.country_code,
            'account_reference_masked', withdrawal_rows.account_reference_masked
          )
        ) order by withdrawal_rows.created_at desc, withdrawal_rows.withdrawal_id desc
      ) filter (where withdrawal_rows.row_number <= p_limit),
      '[]'::jsonb
    ),
    (
      select jsonb_build_object(
        'created_at', more.created_at,
        'withdrawal_id', more.withdrawal_id
      )
        from withdrawal_rows more
       where more.row_number = p_limit + 1
    )
    into item_payload, next_cursor
    from withdrawal_rows;

  return jsonb_build_object(
    'items', item_payload,
    'next_cursor', next_cursor
  );
end;
$$;

revoke all on function read_api.member_withdrawals(
  uuid, timestamptz, uuid, integer, text
) from public, anon, authenticated, service_role;
grant execute on function read_api.member_withdrawals(
  uuid, timestamptz, uuid, integer, text
) to service_role;
