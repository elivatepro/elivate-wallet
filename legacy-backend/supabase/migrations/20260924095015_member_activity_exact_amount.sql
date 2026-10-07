-- Preserve numeric(38,18) precision across JSON parsers and statement exports.
-- JSON numbers can round before the frontend has a chance to format them.

create or replace function read_api.member_activity(
  p_actor_user_id uuid,
  p_before_created_at timestamptz default null,
  p_before_entry_id uuid default null,
  p_limit integer default 50,
  p_currency_code text default null,
  p_transaction_type text default null,
  p_pocket_key text default null
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
    raise exception using errcode = '22023', message = 'member activity actor is required';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'member activity actor does not match the authenticated user';
  end if;

  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception using errcode = '22023', message = 'member activity limit must be between 1 and 100';
  end if;

  if (p_before_created_at is null) <> (p_before_entry_id is null) then
    raise exception using errcode = '22023', message = 'member activity cursor is incomplete';
  end if;

  if p_currency_code is not null and p_currency_code !~ '^[A-Z]{3}$' then
    raise exception using errcode = '22023', message = 'member activity currency is invalid';
  end if;

  if p_transaction_type is not null and p_transaction_type !~ '^[a-z][a-z0-9_]*$' then
    raise exception using errcode = '22023', message = 'member activity transaction type is invalid';
  end if;

  if p_pocket_key is not null and p_pocket_key !~ '^[a-z][a-z0-9_]*$' then
    raise exception using errcode = '22023', message = 'member activity pocket is invalid';
  end if;

  select account.status into actor_status
    from public.user_accounts account
   where account.user_id = p_actor_user_id;

  if actor_status is null or actor_status not in ('active', 'restricted', 'suspended') then
    raise exception using errcode = '42501', message = 'member activity requires an eligible account';
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
    raise exception using errcode = '42501', message = 'member activity requires an active Wallet membership';
  end if;

  with activity_rows as materialized (
    select
      transaction.id as transaction_id,
      transaction.transaction_reference,
      transaction.transaction_type,
      entry.id as entry_id,
      entry.currency_code,
      sum(posting.amount) as signed_amount,
      case when count(distinct account.pocket_key) = 1 then min(account.pocket_key) end as pocket_key,
      transaction.created_at,
      transaction.posted_at,
      row_number() over (
        order by transaction.created_at desc, entry.id desc
      ) as row_number
    from ledger.financial_transactions transaction
    join ledger.journal_entries entry
      on entry.financial_transaction_id = transaction.id
    join ledger.journal_postings posting
      on posting.journal_entry_id = entry.id
    join ledger.ledger_accounts account
      on account.id = posting.ledger_account_id
     and account.owner_user_id = p_actor_user_id
     and account.account_class = 'member_value'
   where transaction.posted_at is not null
     and (p_currency_code is null or entry.currency_code = p_currency_code)
     and (p_transaction_type is null or transaction.transaction_type = p_transaction_type)
     and (p_pocket_key is null or account.pocket_key = p_pocket_key)
     and (
       p_before_created_at is null
       or (transaction.created_at, entry.id) < (p_before_created_at, p_before_entry_id)
     )
   group by transaction.id, entry.id, entry.currency_code
   order by transaction.created_at desc, entry.id desc
   limit p_limit + 1
  )
  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'transaction_id', activity_rows.transaction_id,
          'reference', activity_rows.transaction_reference,
          'type', activity_rows.transaction_type,
          'currency_code', activity_rows.currency_code,
          'signed_amount', activity_rows.signed_amount::text,
          'state', 'completed',
          'pocket_key', activity_rows.pocket_key,
          'created_at', activity_rows.created_at,
          'posted_at', activity_rows.posted_at
        ) order by activity_rows.created_at desc, activity_rows.entry_id desc
      ) filter (where activity_rows.row_number <= p_limit),
      '[]'::jsonb
    ),
    (
      select jsonb_build_object(
        'created_at', more.created_at,
        'entry_id', more.entry_id
      )
        from activity_rows more
       -- The next request uses strict <, so anchor it to the last returned
       -- row. The excluded lookahead only determines whether more rows exist.
       where more.row_number = p_limit
         and exists (select 1 from activity_rows lookahead where lookahead.row_number = p_limit + 1)
    )
    into item_payload, next_cursor
    from activity_rows;

  return jsonb_build_object(
    'items', item_payload,
    'next_cursor', next_cursor
  );
end;
$$;

revoke all on function read_api.member_activity(
  uuid, timestamptz, uuid, integer, text, text, text
) from public, anon, authenticated, service_role;
grant execute on function read_api.member_activity(
  uuid, timestamptz, uuid, integer, text, text, text
) to service_role;


create or replace function read_api.member_home(
  p_actor_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_status public.account_status;
begin
  if p_actor_user_id is null then
    raise exception using errcode = '22023', message = 'member home actor is required';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'member home actor does not match the authenticated user';
  end if;

  select account.status into actor_status
    from public.user_accounts account
   where account.user_id = p_actor_user_id;

  if actor_status is null or actor_status not in ('active', 'restricted', 'suspended') then
    raise exception using errcode = '42501', message = 'member home requires an eligible account';
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
    raise exception using errcode = '42501', message = 'member home requires an active Wallet membership';
  end if;

  return jsonb_build_object(
    'wallets', coalesce((
      select jsonb_agg(wallet_payload order by wallet_id)
        from (
          select
            wallet.id as wallet_id,
            jsonb_build_object(
              'wallet_id', wallet.id,
              'currencies', coalesce((
                select jsonb_agg(currency_payload order by currency_code)
                  from (
                    select
                      account_row.currency_code,
                      jsonb_build_object(
                        'currency_code', account_row.currency_code,
                        'posted_balance', sum(account_row.posted_balance)::text,
                        'reserved_balance', sum(account_row.reserved_balance)::text,
                        'pockets', jsonb_agg(jsonb_build_object(
                          'pocket_key', account_row.pocket_key,
                          'pocket_name', account_row.pocket_name,
                          'posted_balance', account_row.posted_balance::text,
                          'reserved_balance', account_row.reserved_balance::text
                        ) order by account_row.sort_order)
                      ) as currency_payload
                    from (
                    select
                      account.id,
                      account.currency_code,
                      account.pocket_key,
                      pocket.display_name as pocket_name,
                      pocket.sort_order,
                      coalesce(projection.balance, 0) as posted_balance,
                      coalesce((select sum(reservation.amount)
                        from financial_ops.funding_reservations reservation
                       where reservation.ledger_account_id = account.id
                         and reservation.status = 'active'), 0)
                      + coalesce((select sum(reservation.amount)
                        from financial_ops.pocket_transfer_reservations reservation
                       where reservation.ledger_account_id = account.id
                         and reservation.status = 'active'), 0) as reserved_balance
                    from ledger.ledger_accounts account
                    join public.pocket_definitions pocket on pocket.pocket_key = account.pocket_key
                    left join ledger.wallet_balance_projections projection on projection.ledger_account_id = account.id
                   where account.account_class = 'member_value'
                     and account.wallet_id = wallet.id
                    ) account_row
                   group by account_row.currency_code
                  ) currency_row
              ), '[]'::jsonb)
            ) as wallet_payload
            from public.wallets wallet
           where wallet.owner_user_id = p_actor_user_id
        ) wallet_row
    ), '[]'::jsonb),
    'recent_activity', coalesce((
      select jsonb_agg(activity_payload order by created_at desc)
        from (
          select
            transaction.created_at,
            jsonb_build_object(
              'transaction_id', transaction.id,
              'reference', transaction.transaction_reference,
              'type', transaction.transaction_type,
              'currency_code', entry.currency_code,
              'signed_amount', sum(posting.amount)::text,
              'created_at', transaction.created_at,
              'posted_at', transaction.posted_at
            ) as activity_payload
          from ledger.financial_transactions transaction
          join ledger.journal_entries entry on entry.financial_transaction_id = transaction.id
          join ledger.journal_postings posting on posting.journal_entry_id = entry.id
          join ledger.ledger_accounts account
            on account.id = posting.ledger_account_id
           and account.owner_user_id = p_actor_user_id
           and account.account_class = 'member_value'
         group by transaction.id, entry.id, entry.currency_code
         order by transaction.created_at desc
         limit 20
        ) activity_row
    ), '[]'::jsonb),
    'recent_withdrawals', coalesce((
      select jsonb_agg(withdrawal_payload order by created_at desc)
        from (
          select
            withdrawal.created_at,
            jsonb_build_object(
              'withdrawal_id', withdrawal.id,
              'reference', withdrawal.withdrawal_reference,
              'currency_code', withdrawal.source_currency_code,
              'amount', withdrawal.requested_amount::text,
              'status', withdrawal.status,
              'created_at', withdrawal.created_at,
              'updated_at', withdrawal.updated_at
            ) as withdrawal_payload
          from financial_ops.withdrawal_requests withdrawal
         where withdrawal.owner_user_id = p_actor_user_id
         order by withdrawal.created_at desc
         limit 10
        ) withdrawal_row
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function read_api.member_home(uuid) from public, anon, authenticated, service_role;
grant execute on function read_api.member_home(uuid) to service_role;

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
          'requested_amount', withdrawal_rows.requested_amount::text,
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
       -- The next request uses strict <, so anchor it to the last returned
       -- row. The excluded lookahead only determines whether more rows exist.
       where more.row_number = p_limit
         and exists (select 1 from withdrawal_rows lookahead where lookahead.row_number = p_limit + 1)
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
