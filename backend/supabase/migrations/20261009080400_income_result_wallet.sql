-- Blueprint 08 — B5: the income result also names the wallet it went into, so
-- the leader's result screen can open the transaction in that member's wallet
-- (managed activity detail). Field added only; stored results without it stay
-- valid (the client treats it as optional).

create or replace function finance.income_result(p_income_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'incomeId', i.id,
    'reference', i.reference,
    'status', 'posted',
    'transactionId', i.transaction_id,
    'membershipId', i.membership_id,
    'walletId', i.wallet_id,
    'currency', i.currency,
    'amount', ledger.money(i.amount, i.currency),
    'allocations', (
      select jsonb_agg(jsonb_build_object(
        'pocketId', a.pocket_id,
        'pocket', a.pocket_name,
        'basisPoints', a.basis_points,
        'amount', ledger.money(a.amount, i.currency)
      ) order by a.sort_order, a.pocket_id)
      from finance.income_allocations a where a.income_id = i.id
    )
  )
  from finance.income_records i
  where i.id = p_income_id;
$$;
