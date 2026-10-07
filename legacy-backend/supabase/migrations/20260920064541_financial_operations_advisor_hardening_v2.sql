create policy financial_operation_evidence_private_deny
  on evidence.financial_operation_evidence
  as restrictive for all to anon, authenticated, service_role
  using (false) with check (false);
create policy financial_operation_review_decisions_private_deny
  on evidence.financial_operation_review_decisions
  as restrictive for all to anon, authenticated, service_role
  using (false) with check (false);
create policy financial_operation_verification_attempts_private_deny
  on evidence.financial_operation_verification_attempts
  as restrictive for all to anon, authenticated, service_role
  using (false) with check (false);

create policy administrative_adjustment_lines_private_deny
  on financial_ops.administrative_adjustment_lines
  as restrictive for all to anon, authenticated, service_role
  using (false) with check (false);
create policy administrative_adjustment_revisions_private_deny
  on financial_ops.administrative_adjustment_revisions
  as restrictive for all to anon, authenticated, service_role
  using (false) with check (false);
create policy administrative_adjustments_private_deny
  on financial_ops.administrative_adjustments
  as restrictive for all to anon, authenticated, service_role
  using (false) with check (false);
create policy currency_conversion_revisions_private_deny
  on financial_ops.currency_conversion_revisions
  as restrictive for all to anon, authenticated, service_role
  using (false) with check (false);
create policy currency_conversions_private_deny
  on financial_ops.currency_conversions
  as restrictive for all to anon, authenticated, service_role
  using (false) with check (false);
create policy financial_reversals_private_deny
  on financial_ops.financial_reversals
  as restrictive for all to anon, authenticated, service_role
  using (false) with check (false);
create policy income_allocations_private_deny
  on financial_ops.income_allocations
  as restrictive for all to anon, authenticated, service_role
  using (false) with check (false);
create policy income_records_private_deny
  on financial_ops.income_records
  as restrictive for all to anon, authenticated, service_role
  using (false) with check (false);
create policy pocket_transfer_requests_private_deny
  on financial_ops.pocket_transfer_requests
  as restrictive for all to anon, authenticated, service_role
  using (false) with check (false);
create policy pocket_transfer_reservations_private_deny
  on financial_ops.pocket_transfer_reservations
  as restrictive for all to anon, authenticated, service_role
  using (false) with check (false);
create policy returned_fund_revisions_private_deny
  on financial_ops.returned_fund_revisions
  as restrictive for all to anon, authenticated, service_role
  using (false) with check (false);
create policy returned_funds_private_deny
  on financial_ops.returned_funds
  as restrictive for all to anon, authenticated, service_role
  using (false) with check (false);
create policy tenant_financial_settings_private_deny
  on financial_ops.tenant_financial_settings
  as restrictive for all to anon, authenticated, service_role
  using (false) with check (false);

create index financial_evidence_reviewers_user_id
  on authz.financial_evidence_reviewer_assignments (reviewer_user_id);
create index administrative_adjustment_lines_pocket_key
  on financial_ops.administrative_adjustment_lines (pocket_key);
create index administrative_adjustments_currency_code
  on financial_ops.administrative_adjustments (currency_code);
create index administrative_adjustments_owner_user_id
  on financial_ops.administrative_adjustments (owner_user_id);
create index administrative_adjustments_tenant_policy
  on financial_ops.administrative_adjustments (tenant_id, allocation_policy_version_id);
create index administrative_adjustments_tenant_membership
  on financial_ops.administrative_adjustments (tenant_id, membership_id);
create index administrative_adjustments_tenant_office
  on financial_ops.administrative_adjustments (tenant_id, office_id);
create index currency_conversions_owner_user_id
  on financial_ops.currency_conversions (owner_user_id);
create index currency_conversions_tenant_membership
  on financial_ops.currency_conversions (tenant_id, membership_id);
create index currency_conversions_tenant_office
  on financial_ops.currency_conversions (tenant_id, office_id);
create index income_allocations_pocket_key
  on financial_ops.income_allocations (pocket_key);
create index income_records_currency_code
  on financial_ops.income_records (currency_code);
create index income_records_owner_user_id
  on financial_ops.income_records (owner_user_id);
create index income_records_tenant_policy
  on financial_ops.income_records (tenant_id, allocation_policy_version_id);
create index income_records_tenant_membership
  on financial_ops.income_records (tenant_id, membership_id);
create index income_records_tenant_office
  on financial_ops.income_records (tenant_id, office_id);
create index pocket_transfer_requests_currency_code
  on financial_ops.pocket_transfer_requests (currency_code);
create index pocket_transfer_requests_owner_user_id
  on financial_ops.pocket_transfer_requests (owner_user_id);
create index pocket_transfer_requests_tenant_membership
  on financial_ops.pocket_transfer_requests (tenant_id, membership_id);
create index pocket_transfer_requests_tenant_office
  on financial_ops.pocket_transfer_requests (tenant_id, office_id);
create index returned_funds_currency_code
  on financial_ops.returned_funds (currency_code);
create index returned_funds_owner_user_id
  on financial_ops.returned_funds (owner_user_id);
create index returned_funds_tenant_membership
  on financial_ops.returned_funds (tenant_id, membership_id);
create index returned_funds_tenant_office
  on financial_ops.returned_funds (tenant_id, office_id);
create index returned_funds_wallet_id
  on financial_ops.returned_funds (wallet_id);
