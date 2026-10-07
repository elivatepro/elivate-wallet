-- Read-only President dashboard. Financial scope is independently resolved for
-- each stored provenance context; selected membership IDs are never authority.
create function read_api.leadership_overview(
  p_actor_user_id uuid,
  p_actor_membership_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor public.memberships%rowtype;
  report_decision authz.authorization_decision;
  member_counts jsonb;
  finances jsonb;
  snapshot_at timestamptz := statement_timestamp();
  month_start timestamptz := date_trunc('month', statement_timestamp() at time zone 'UTC') at time zone 'UTC';
begin
  perform financial_ops.require_command_actor(p_actor_user_id);
  select membership.* into actor
    from public.memberships membership
    join public.tenants tenant on tenant.id = membership.tenant_id and tenant.status = 'active'
    join public.user_accounts account on account.user_id = membership.user_id and account.status = 'active'
   where membership.id = p_actor_membership_id
     and membership.user_id = p_actor_user_id
     and membership.status = 'active'
     and membership.role_key = 'president_team_member';
  if actor.id is null then
    raise exception using errcode = '42501', message = 'active President workspace is required';
  end if;

  -- President membership visibility matches the existing public memberships
  -- RLS tenant boundary, including inactive ordinary-member memberships.
  select jsonb_build_object(
    'active', count(*) filter (where status = 'active'),
    'suspended', count(*) filter (where status = 'suspended'),
    'ended', count(*) filter (where status = 'ended')
  ) into member_counts from public.memberships
   where tenant_id = actor.tenant_id and role_key = 'member';

  report_decision := authz.authorize(p_actor_user_id, null,
    'view_scoped_financial_reports', actor.tenant_id);
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
  ), balances as materialized (
    select account.currency_code, coalesce(projection.balance, 0) as amount
      from ledger.ledger_accounts account
      join allowed on (allowed.tenant_id, allowed.office_id, allowed.membership_id, allowed.wallet_id, allowed.owner_user_id)
        = (account.tenant_id, account.office_id, account.membership_id, account.wallet_id, account.owner_user_id)
      left join ledger.wallet_balance_projections projection on projection.ledger_account_id = account.id
     where account.account_class = 'member_value'
  ), incomes as materialized (
    select income.*, transaction.posted_at from financial_ops.income_records income
      join allowed on (allowed.tenant_id, allowed.office_id, allowed.membership_id, allowed.wallet_id, allowed.owner_user_id)
        = (income.tenant_id, income.office_id, income.membership_id, income.wallet_id, income.owner_user_id)
      join ledger.financial_transactions transaction on transaction.id = income.financial_transaction_id
     where transaction.posted_at is not null
  ), withdrawals as materialized (
    select withdrawal.* from financial_ops.withdrawal_requests withdrawal
      join allowed on (allowed.tenant_id, allowed.office_id, allowed.membership_id, allowed.wallet_id, allowed.owner_user_id)
        = (withdrawal.tenant_id, withdrawal.office_id, withdrawal.membership_id, withdrawal.wallet_id, withdrawal.owner_user_id)
  ), currencies as (
    select currency_code from balances
    union select currency_code from incomes
    union select source_currency_code from withdrawals
  )
  select jsonb_build_object(
    'financial_access', report_decision.decision = 'ALLOW' or exists (select 1 from allowed),
    'currencies', coalesce((select jsonb_agg(jsonb_build_object(
      'currency_code', currency.currency_code, 'scale', definition.minor_unit_scale,
      'posted_balance', coalesce((select sum(amount) from balances where currency_code = currency.currency_code), 0)::text,
      'monthly_income', coalesce((select sum(gross_amount) from incomes where currency_code = currency.currency_code and posted_at >= month_start and posted_at <= snapshot_at), 0)::text,
      'requested_count', (select count(*) from withdrawals where source_currency_code = currency.currency_code and status = 'requested'),
      'requested_amount', coalesce((select sum(requested_amount) from withdrawals where source_currency_code = currency.currency_code and status = 'requested'), 0)::text,
      'approved_count', (select count(*) from withdrawals where source_currency_code = currency.currency_code and status = 'approved'),
      'approved_amount', coalesce((select sum(requested_amount) from withdrawals where source_currency_code = currency.currency_code and status = 'approved'), 0)::text
    ) order by currency.currency_code) from currencies currency
      join ledger.currency_definitions definition on definition.currency_code = currency.currency_code), '[]'::jsonb),
    'recent_income', coalesce((select jsonb_agg(jsonb_build_object(
      'id', recent.id, 'reference', recent.operation_reference,
      'currency_code', recent.currency_code, 'amount', recent.gross_amount::text,
      'created_at', recent.recorded_at
    ) order by recent.recorded_at desc, recent.id desc)
      from (select * from incomes order by recorded_at desc, id desc limit 5) recent), '[]'::jsonb),
    'recent_withdrawals', coalesce((select jsonb_agg(jsonb_build_object(
      'id', recent.id, 'reference', recent.withdrawal_reference,
      'currency_code', recent.source_currency_code, 'amount', recent.requested_amount::text,
      'status', recent.status, 'created_at', recent.created_at
    ) order by recent.created_at desc, recent.id desc)
      from (select * from withdrawals order by created_at desc, id desc limit 5) recent), '[]'::jsonb)
  ) into finances;
  return finances || jsonb_build_object('as_of', snapshot_at, 'period_start', month_start,
    'tenant_id', actor.tenant_id, 'members', member_counts);
end;
$$;
revoke all on function read_api.leadership_overview(uuid, uuid) from public, anon, authenticated;
grant execute on function read_api.leadership_overview(uuid, uuid) to service_role;
comment on function read_api.leadership_overview(uuid, uuid) is
  'President dashboard: exact per-currency aggregates and bounded activity after per-provenance report authorization; private JWT transport only.';
