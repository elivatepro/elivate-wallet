create policy payout_accounts_private_deny
  on financial_ops.payout_accounts
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);

create policy withdrawal_requests_private_deny
  on financial_ops.withdrawal_requests
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);

create policy withdrawal_destination_snapshots_private_deny
  on financial_ops.withdrawal_destination_snapshots
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);

create policy funding_reservations_private_deny
  on financial_ops.funding_reservations
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);

create policy withdrawal_command_idempotency_private_deny
  on financial_ops.withdrawal_command_idempotency
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);

create index payout_accounts_wallet_id
  on financial_ops.payout_accounts (wallet_id);

create index funding_reservations_ledger_account_id
  on financial_ops.funding_reservations (ledger_account_id);
