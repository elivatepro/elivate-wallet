create schema read_api;

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
                        'posted_balance', sum(account_row.posted_balance),
                        'reserved_balance', sum(account_row.reserved_balance),
                        'pockets', jsonb_agg(jsonb_build_object(
                          'pocket_key', account_row.pocket_key,
                          'pocket_name', account_row.pocket_name,
                          'posted_balance', account_row.posted_balance,
                          'reserved_balance', account_row.reserved_balance
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
              'signed_amount', sum(posting.amount),
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
              'amount', withdrawal.requested_amount,
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

revoke all on schema read_api from public, anon, authenticated, service_role;
revoke all on all functions in schema read_api from public, anon, authenticated, service_role;
grant usage on schema read_api to service_role;
grant execute on function read_api.member_home(uuid) to service_role;

alter default privileges in schema read_api
  revoke execute on functions from public, anon, authenticated, service_role;
