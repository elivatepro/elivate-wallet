-- Fix (found by the join e2e, 2026-10-08): the ledger's deferred invariant
-- checks fire at COMMIT, after the SECURITY DEFINER api.* command has
-- returned, so they ran as the caller's role (service_role through PostgREST).
-- That role has no usage on the private `ledger` schema, so every command that
-- writes a journal, a transaction or an allocation version failed at commit
-- with "permission denied for schema ledger" (seen as internal_error):
-- activating a network, recording income, saving a split, payouts.
-- pgTAP did not see it because each test file rolls back instead of committing.
--
-- The checks now run as their owner. A function that returns `trigger` cannot
-- be called directly (Postgres refuses it outside a trigger), so this adds no
-- entry point; 045 allows exactly these three and nothing else.

alter function ledger.check_journal_balanced() security definer;
alter function ledger.check_transaction_complete() security definer;
alter function ledger.check_policy_lines() security definer;

revoke all on function ledger.check_journal_balanced() from public, anon, authenticated, service_role;
revoke all on function ledger.check_transaction_complete() from public, anon, authenticated, service_role;
revoke all on function ledger.check_policy_lines() from public, anon, authenticated, service_role;
