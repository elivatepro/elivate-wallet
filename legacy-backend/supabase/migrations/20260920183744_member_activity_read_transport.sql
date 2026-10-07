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
          'signed_amount', activity_rows.signed_amount,
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
       where more.row_number = p_limit + 1
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
