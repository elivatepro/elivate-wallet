-- Blueprint 20 — B4 202: the hot-path foreign keys have indexes, and every
-- foreign key in the list is covered by an index that starts with its columns.
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(15);

select has_index('ledger', 'transactions', 'transactions_tenant_office_idx', array['tenant_id', 'office_id'],
  'ledger.transactions (tenant_id, office_id)');
select has_index('finance', 'entries', 'entries_tenant_office_idx', array['tenant_id', 'office_id'],
  'finance.entries (tenant_id, office_id)');
select has_index('finance', 'income_records', 'income_records_tenant_office_idx', array['tenant_id', 'office_id'],
  'finance.income_records (tenant_id, office_id)');
select has_index('finance', 'withdrawals', 'withdrawals_tenant_office_idx', array['tenant_id', 'office_id'],
  'finance.withdrawals (tenant_id, office_id)');
select has_index('finance', 'pocket_transfers', 'pocket_transfers_tenant_office_idx', array['tenant_id', 'office_id'],
  'finance.pocket_transfers (tenant_id, office_id)');
select has_index('org', 'memberships', 'memberships_tenant_office_idx', array['tenant_id', 'office_id'],
  'org.memberships (tenant_id, office_id)');
select has_index('org', 'offices', 'offices_tenant_parent_idx', array['tenant_id', 'parent_office_id'],
  'org.offices (tenant_id, parent_office_id)');
select has_index('exports', 'files', 'files_tenant_scope_office_idx', array['tenant_id', 'scope_office_id'],
  'exports.files (tenant_id, scope_office_id)');
select has_index('exports', 'files', 'files_wallet_idx', array['wallet_id'], 'exports.files (wallet_id)');
select has_index('exports', 'files', 'files_member_user_idx', array['member_user_id'], 'exports.files (member_user_id)');
select has_index('billing', 'owners', 'owners_user_idx', array['user_id'], 'billing.owners (user_id)');
select has_index('identity', 'nin_reviews', 'nin_reviews_membership_idx', array['membership_id'],
  'identity.nin_reviews (membership_id)');

-- Every foreign key of these tables on the listed columns has a leading index.
create function pg_temp.uncovered() returns setof text language sql stable as $$
  select c.conrelid::regclass::text || ' ' || c.conname
  from pg_constraint c
  where c.contype = 'f'
    and (c.conrelid::regclass::text, (select array_agg(a.attname::text order by k.ord)
           from unnest(c.conkey) with ordinality k(attnum, ord)
           join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum)) in (
      ('ledger.transactions', array['tenant_id', 'office_id']),
      ('finance.entries', array['tenant_id', 'office_id']),
      ('finance.income_records', array['tenant_id', 'office_id']),
      ('finance.withdrawals', array['tenant_id', 'office_id']),
      ('finance.pocket_transfers', array['tenant_id', 'office_id']),
      ('org.memberships', array['tenant_id', 'office_id']),
      ('org.offices', array['tenant_id', 'parent_office_id']),
      ('exports.files', array['tenant_id']),
      ('exports.files', array['tenant_id', 'scope_office_id']),
      ('exports.files', array['wallet_id']),
      ('exports.files', array['member_user_id']),
      ('billing.owners', array['user_id']),
      ('identity.nin_reviews', array['membership_id']))
    and not exists (
      select 1 from pg_index i
      where i.indrelid = c.conrelid
        and (i.indkey::int2[])[0:cardinality(c.conkey) - 1] @> c.conkey
        and (i.indkey::int2[])[0:cardinality(c.conkey) - 1] <@ c.conkey)
$$;
select is((select count(*)::int from pg_constraint c where c.contype = 'f'
  and c.conrelid::regclass::text in ('ledger.transactions', 'finance.entries', 'finance.income_records',
    'finance.withdrawals', 'finance.pocket_transfers', 'org.memberships', 'org.offices', 'exports.files',
    'billing.owners', 'identity.nin_reviews')
  and c.conname in ('transactions_tenant_id_office_id_fkey', 'entries_tenant_id_office_id_fkey',
    'income_records_tenant_id_office_id_fkey', 'withdrawals_tenant_id_office_id_fkey',
    'pocket_transfers_tenant_id_office_id_fkey', 'memberships_tenant_id_office_id_fkey',
    'offices_tenant_id_parent_office_id_fkey', 'files_tenant_id_fkey', 'files_tenant_id_scope_office_id_fkey',
    'files_wallet_id_fkey', 'files_member_user_id_fkey', 'owners_user_id_fkey', 'nin_reviews_membership_id_fkey')),
  13, 'the thirteen foreign keys exist as described');
select is_empty($$ select * from pg_temp.uncovered() $$, 'and each one has an index that starts with its columns');
select ok((select bool_and(i.indisvalid) from pg_index i
  where i.indexrelid::regclass::text in ('ledger.transactions_tenant_office_idx', 'finance.entries_tenant_office_idx',
    'finance.income_records_tenant_office_idx', 'finance.withdrawals_tenant_office_idx',
    'finance.pocket_transfers_tenant_office_idx', 'org.memberships_tenant_office_idx', 'org.offices_tenant_parent_idx',
    'exports.files_tenant_scope_office_idx', 'exports.files_wallet_idx', 'exports.files_member_user_idx',
    'billing.owners_user_idx', 'identity.nin_reviews_membership_idx')), 'all valid');

select * from finish();
rollback;
