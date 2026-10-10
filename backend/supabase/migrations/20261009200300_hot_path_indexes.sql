-- Blueprint 20 — B4: indexes for foreign keys on hot paths that had none
-- (performance advisor, confirmed against pg_constraint on a fresh replay).
-- Without them every office/tenant check on these tables, and every delete
-- or key change on the referenced row, scans the table. Additive only. Plain
-- CREATE INDEX (no CONCURRENTLY): the dev tables are small, and the CLI runs
-- a migration file as one batch, where CONCURRENTLY is refused.

-- Composite (tenant_id, office_id) → org.offices (tenant_id, id).
create index if not exists transactions_tenant_office_idx on ledger.transactions (tenant_id, office_id);
create index if not exists entries_tenant_office_idx on finance.entries (tenant_id, office_id);
create index if not exists income_records_tenant_office_idx on finance.income_records (tenant_id, office_id);
create index if not exists withdrawals_tenant_office_idx on finance.withdrawals (tenant_id, office_id);
create index if not exists pocket_transfers_tenant_office_idx on finance.pocket_transfers (tenant_id, office_id);
create index if not exists memberships_tenant_office_idx on org.memberships (tenant_id, office_id);

-- org.offices (tenant_id, parent_office_id) → org.offices (tenant_id, id).
create index if not exists offices_tenant_parent_idx on org.offices (tenant_id, parent_office_id);

-- exports.files: tenant_id and (tenant_id, scope_office_id) share one index;
-- the wallet and the member each get their own.
create index if not exists files_tenant_scope_office_idx on exports.files (tenant_id, scope_office_id);
create index if not exists files_wallet_idx on exports.files (wallet_id);
create index if not exists files_member_user_idx on exports.files (member_user_id);

-- billing.owners.user_id (my_capabilities' billing-owner check).
create index if not exists owners_user_idx on billing.owners (user_id);

-- identity.nin_reviews.membership_id.
create index if not exists nin_reviews_membership_idx on identity.nin_reviews (membership_id);
