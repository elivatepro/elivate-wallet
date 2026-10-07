create or replace function read_api.member_payout_accounts(
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
    raise exception using errcode = '22023', message = 'member payout accounts actor is required';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'member payout accounts actor does not match the authenticated user';
  end if;

  select account.status into actor_status
    from public.user_accounts account
   where account.user_id = p_actor_user_id;

  if actor_status is null or actor_status not in ('active', 'restricted', 'suspended') then
    raise exception using errcode = '42501', message = 'member payout accounts requires an eligible account';
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
    raise exception using errcode = '42501', message = 'member payout accounts requires an active Wallet membership';
  end if;

  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'payout_account_id', account.id,
          'country_code', account.country_code,
          'payout_currency', account.payout_currency,
          'payout_rail', account.payout_rail,
          'institution_code', account.institution_code,
          'institution_name', account.institution_name,
          'account_reference_masked', repeat('*', greatest(length(account.account_reference) - 4, 0))
            || right(account.account_reference, 4),
          'account_holder_name', account.account_holder_name,
          'verification_status', account.verification_status,
          'is_primary', account.is_primary,
          'status', account.status,
          'created_at', account.created_at
        ) order by account.is_primary desc, account.created_at desc, account.id desc
      )
        from financial_ops.payout_accounts account
       where account.owner_user_id = p_actor_user_id
         and account.status = 'active'
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function read_api.member_payout_accounts(uuid)
  from public, anon, authenticated, service_role;
grant execute on function read_api.member_payout_accounts(uuid) to service_role;
