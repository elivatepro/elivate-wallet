-- Only the authenticated Edge transport may supply actor/session context.
-- Private financial operations remain unexposed and retain their own authorization.
create or replace function public.add_own_payout_account(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_country_code text,
  p_payout_currency text,
  p_payout_rail text,
  p_institution_code text,
  p_institution_name text,
  p_account_reference text,
  p_account_holder_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  membership public.memberships%rowtype;
  wallet_id uuid;
  decision authz.authorization_decision;
  command_result financial_ops.payout_account_command_result;
  verification financial_ops.payout_verification_status;
begin
  if p_idempotency_key is null or p_actor_user_id is null or p_membership_id is null
    or p_country_code is null or p_country_code !~ '^[A-Z]{2}$'
    or p_payout_currency is null or p_payout_currency !~ '^[A-Z]{3}$'
    or p_payout_rail is null or p_payout_rail !~ '^[a-z][a-z0-9_]{0,31}$'
    or p_institution_code is null or length(p_institution_code) > 64 or length(btrim(p_institution_code)) = 0
    or p_institution_name is null or length(p_institution_name) > 160 or length(btrim(p_institution_name)) = 0
    or p_account_reference is null or length(p_account_reference) > 128 or length(btrim(p_account_reference)) = 0
    or p_account_holder_name is null or length(p_account_holder_name) > 160 or length(btrim(p_account_holder_name)) = 0
    or p_institution_code ~ '[[:cntrl:]]' or p_institution_name ~ '[[:cntrl:]]'
    or p_account_reference ~ '[[:cntrl:]]' or p_account_holder_name ~ '[[:cntrl:]]' then
    raise exception using errcode = '22023', message = 'Payout account input is invalid';
  end if;
  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'Payout account actor mismatch';
  end if;

  -- The resource selector is untrusted. Resolve and hold active context before
  -- every invocation, including replay of a previously successful command.
  select m.* into membership
    from public.memberships m
    join public.user_accounts a on a.user_id = m.user_id and a.status = 'active'
    join public.tenants t on t.id = m.tenant_id and t.status = 'active'
    join public.offices o on o.id = m.office_id and o.tenant_id = m.tenant_id and o.status = 'active'
    where m.id = p_membership_id and m.user_id = p_actor_user_id
      and m.status = 'active' and m.role_key <> 'president_team_member'
    for share of m, a, t, o;
  if not found then
    raise exception using errcode = '42501', message = 'An active own-wallet membership is required';
  end if;
  select w.id into wallet_id from public.wallets w where w.owner_user_id = p_actor_user_id;
  if wallet_id is null then
    raise exception using errcode = '42501', message = 'An own wallet is required';
  end if;

  decision := authz.authorize(
    p_actor_user_id, p_session_id, 'manage_own_payout_accounts', membership.tenant_id,
    membership.office_id, membership.id, p_actor_user_id, wallet_id, p_actor_user_id,
    'manage_own_payout_accounts', null
  );
  if decision.decision = 'STEP_UP_REQUIRED' then
    raise exception using errcode = 'P0401', message = 'Recent authenticator verification is required';
  end if;
  if decision.decision is distinct from 'ALLOW' then
    raise exception using errcode = '42501', message = 'Payout account change is not authorized';
  end if;
  if not authz.is_elevated_session_valid(p_session_id,p_actor_user_id) then
    raise exception using errcode = 'P0401', message = 'Recent authenticator verification is required';
  end if;
  if not exists(select 1 from ledger.currency_definitions where currency_code = p_payout_currency) then
    raise exception using errcode = '22023', message = 'Payout currency is not configured';
  end if;

  command_result := financial_ops.add_payout_account(
    p_idempotency_key, p_actor_user_id, p_session_id, membership.tenant_id, wallet_id,
    p_country_code, p_payout_currency, p_payout_rail, p_institution_code,
    p_institution_name, p_account_reference, p_account_holder_name, false
  );
  select account.verification_status into verification from financial_ops.payout_accounts account
    where account.id = command_result.payout_account_id and account.owner_user_id = p_actor_user_id;
  return jsonb_build_object(
    'payout_account_id',command_result.payout_account_id,
    'status',command_result.status,
    'replayed',command_result.reused,
    'verification_status',verification
  );
end;
$$;
revoke all on function public.add_own_payout_account(uuid,uuid,uuid,uuid,text,text,text,text,text,text,text)
  from public,anon,authenticated,service_role;
grant execute on function public.add_own_payout_account(uuid,uuid,uuid,uuid,text,text,text,text,text,text,text)
  to service_role;
