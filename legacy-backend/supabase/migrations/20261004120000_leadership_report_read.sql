-- Leadership reporting derives every row's scope from stored financial provenance.
create function read_api.leadership_report(
  p_actor_user_id uuid,
  p_actor_membership_id uuid,
  p_from date,
  p_to date,
  p_currency_code text default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor public.memberships%rowtype;
  result jsonb;
begin
  perform financial_ops.require_command_actor(p_actor_user_id);
  if p_from is null or p_to is null or p_from > p_to
     or p_currency_code is not null and p_currency_code !~ '^[A-Z]{3}$' then
    raise exception using errcode = '22023', message = 'report query is invalid';
  end if;

  select membership.* into actor from public.memberships membership
    join public.user_accounts account on account.user_id = membership.user_id and account.status = 'active'
    join public.tenants tenant on tenant.id = membership.tenant_id and tenant.status = 'active'
    left join public.offices office on office.id = membership.office_id and office.tenant_id = membership.tenant_id
   where membership.id = p_actor_membership_id and membership.user_id = p_actor_user_id
     and membership.status = 'active'
     and membership.role_key in ('team_leader','director','world_team_member','president_team_member')
     and (membership.office_id is null or office.status = 'active');
  if actor.id is null then
    raise exception using errcode = '42501', message = 'active leadership workspace is required';
  end if;

  with contexts as materialized (
    select tenant_id, office_id, membership_id, wallet_id, owner_user_id
      from ledger.ledger_accounts where tenant_id = actor.tenant_id and account_class = 'member_value'
    union
    select tenant_id, office_id, membership_id, wallet_id, owner_user_id
      from financial_ops.income_records where tenant_id = actor.tenant_id
    union
    select tenant_id, office_id, membership_id, wallet_id, owner_user_id
      from financial_ops.withdrawal_requests where tenant_id = actor.tenant_id
  ), allowed as materialized (
    select context.* from contexts context
     where (authz.authorize(p_actor_user_id, null, 'view_scoped_financial_reports',
       context.tenant_id, context.office_id, context.membership_id, context.owner_user_id,
       context.wallet_id, context.owner_user_id)).decision = 'ALLOW'
  ), currencies as materialized (
    select account.currency_code from ledger.ledger_accounts account join allowed using
      (tenant_id, office_id, membership_id, wallet_id, owner_user_id)
     where account.account_class = 'member_value'
    union select income.currency_code from financial_ops.income_records income join allowed using
      (tenant_id, office_id, membership_id, wallet_id, owner_user_id)
    union select withdrawal.source_currency_code from financial_ops.withdrawal_requests withdrawal join allowed using
      (tenant_id, office_id, membership_id, wallet_id, owner_user_id)
  ), incomes as materialized (
    select income.* from financial_ops.income_records income
      join allowed using (tenant_id, office_id, membership_id, wallet_id, owner_user_id)
      join ledger.financial_transactions transaction on transaction.id = income.financial_transaction_id
     where transaction.posted_at >= p_from::timestamp at time zone 'UTC'
       and transaction.posted_at < (p_to + 1)::timestamp at time zone 'UTC'
       and (p_currency_code is null or income.currency_code = p_currency_code)
  ), withdrawals as materialized (
    select withdrawal.* from financial_ops.withdrawal_requests withdrawal
      join allowed using (tenant_id, office_id, membership_id, wallet_id, owner_user_id)
     where withdrawal.created_at >= p_from::timestamp at time zone 'UTC'
       and withdrawal.created_at < (p_to + 1)::timestamp at time zone 'UTC'
       and (p_currency_code is null or withdrawal.source_currency_code = p_currency_code)
  ), balances as materialized (
    select account.membership_id, account.office_id, account.currency_code,
      coalesce(projection.balance, 0) amount
      from ledger.ledger_accounts account
      join allowed using (tenant_id, office_id, membership_id, wallet_id, owner_user_id)
      left join ledger.wallet_balance_projections projection on projection.ledger_account_id = account.id
     where account.account_class = 'member_value'
       and (p_currency_code is null or account.currency_code = p_currency_code)
  ), dimensions as materialized (
    select membership.id membership_id, membership.office_id,
      coalesce(nullif(profile.display_name,''), account.public_uid) display_name
      from public.memberships membership
      join public.user_accounts account on account.user_id = membership.user_id
      left join public.user_profiles profile on profile.user_id = membership.user_id
     where membership.tenant_id = actor.tenant_id
       and exists (select 1 from allowed where allowed.membership_id = membership.id)
  ), report_currencies as materialized (
    select currency_code from currencies where p_currency_code is null or currency_code = p_currency_code
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'currency_code', p_currency_code,
    'currencies', coalesce((select jsonb_agg(currency_code order by currency_code) from currencies), '[]'::jsonb),
    'totals', coalesce((select jsonb_agg(jsonb_build_object(
      'currency_code', currency.currency_code,
      'income_total', coalesce((select sum(gross_amount) from incomes where currency_code=currency.currency_code),0)::text,
      'withdrawal_requested_total', coalesce((select sum(requested_amount) from withdrawals where source_currency_code=currency.currency_code and status='requested'),0)::text,
      'withdrawal_approved_total', coalesce((select sum(requested_amount) from withdrawals where source_currency_code=currency.currency_code and status in ('approved','completed')),0)::text,
      'net_flow', (coalesce((select sum(gross_amount) from incomes where currency_code=currency.currency_code),0)
        - coalesce((select sum(requested_amount) from withdrawals where source_currency_code=currency.currency_code and status in ('approved','completed')),0))::text,
      'posted_balance', coalesce((select sum(amount) from balances where currency_code=currency.currency_code),0)::text
    ) order by currency.currency_code) from report_currencies currency), '[]'::jsonb),
    'offices', coalesce((select jsonb_agg(jsonb_build_object(
      'office_id', office.id, 'office_name', office.name, 'currency_code', currency.currency_code,
      'income_total', coalesce((select sum(gross_amount) from incomes where office_id=office.id and currency_code=currency.currency_code),0)::text,
      'withdrawal_requested_total', coalesce((select sum(requested_amount) from withdrawals where office_id=office.id and source_currency_code=currency.currency_code and status='requested'),0)::text,
      'withdrawal_approved_total', coalesce((select sum(requested_amount) from withdrawals where office_id=office.id and source_currency_code=currency.currency_code and status in ('approved','completed')),0)::text,
      'net_flow', (coalesce((select sum(gross_amount) from incomes where office_id=office.id and currency_code=currency.currency_code),0)-coalesce((select sum(requested_amount) from withdrawals where office_id=office.id and source_currency_code=currency.currency_code and status in ('approved','completed')),0))::text,
      'member_count', (select count(distinct membership_id) from dimensions where office_id=office.id)
    ) order by office.name, currency.currency_code) from public.offices office cross join report_currencies currency
      where office.tenant_id=actor.tenant_id and exists(select 1 from dimensions where office_id=office.id)), '[]'::jsonb),
    'members', coalesce((select jsonb_agg(jsonb_build_object(
      'membership_id', member.membership_id, 'display_name', member.display_name,
      'office_id', member.office_id, 'currency_code', currency.currency_code,
      'income_total', coalesce((select sum(gross_amount) from incomes where membership_id=member.membership_id and currency_code=currency.currency_code),0)::text,
      'withdrawal_total', coalesce((select sum(requested_amount) from withdrawals where membership_id=member.membership_id and source_currency_code=currency.currency_code and status in ('approved','completed')),0)::text,
      'posted_balance', coalesce((select sum(amount) from balances where membership_id=member.membership_id and currency_code=currency.currency_code),0)::text
    ) order by member.display_name, member.membership_id, currency.currency_code) from dimensions member cross join report_currencies currency), '[]'::jsonb)
  ) into result;
  if p_currency_code is not null and not (result->'currencies' ? p_currency_code) then
    raise exception using errcode = '22023', message = 'report currency is unavailable';
  end if;
  return result;
end;
$$;
revoke all on function read_api.leadership_report(uuid,uuid,date,date,text) from public,anon,authenticated;
grant execute on function read_api.leadership_report(uuid,uuid,date,date,text) to service_role;
comment on function read_api.leadership_report(uuid,uuid,date,date,text) is
  'Exact leadership financial report after per-provenance authorization; private JWT transport only.';
