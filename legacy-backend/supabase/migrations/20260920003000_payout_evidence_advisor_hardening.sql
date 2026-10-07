create policy financial_evidence_reviewer_assignments_private_deny
  on authz.financial_evidence_reviewer_assignments
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);

create policy financial_evidence_private_deny
  on evidence.financial_evidence
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);

create policy verification_attempts_private_deny
  on evidence.verification_attempts
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);

create policy review_decisions_private_deny
  on evidence.review_decisions
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);

create policy payout_completion_assertions_private_deny
  on financial_ops.payout_completion_assertions
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);

create policy payout_assertion_revisions_private_deny
  on financial_ops.payout_assertion_revisions
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);

create policy payout_assertion_evidence_private_deny
  on financial_ops.payout_assertion_evidence
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);

create policy payout_command_idempotency_private_deny
  on financial_ops.payout_command_idempotency
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);

create policy outbox_events_private_deny
  on internal.outbox_events
  as restrictive
  for all
  to anon, authenticated, service_role
  using (false)
  with check (false);
