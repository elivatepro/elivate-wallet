create policy currency_definitions_private_deny
  on ledger.currency_definitions
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);

create policy ledger_accounts_private_deny
  on ledger.ledger_accounts
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);

create policy financial_transactions_private_deny
  on ledger.financial_transactions
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);

create policy journal_entries_private_deny
  on ledger.journal_entries
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);

create policy journal_postings_private_deny
  on ledger.journal_postings
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);

create policy wallet_balance_projections_private_deny
  on ledger.wallet_balance_projections
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);
