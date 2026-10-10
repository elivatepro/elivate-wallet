-- Blueprint 11 — B7 112: the withdrawal, payout, review and pocket-move tables
-- stay private; their helpers are invoker with an empty search_path; the
-- worker functions are service-only.
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(5);

select ok(
  not exists (
    select 1 from unnest(array['withdrawals', 'payouts', 'payout_revisions', 'payout_checks',
      'payout_reviews', 'pocket_transfers']) t
    where has_table_privilege('anon', format('finance.%I', t), 'select')
       or has_table_privilege('authenticated', format('finance.%I', t), 'select')
       or has_table_privilege('authenticated', format('finance.%I', t), 'insert')
  ),
  'finance tables are not reachable by anon or authenticated'
);
select ok(
  (select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'finance' and c.relname in ('withdrawals', 'payouts', 'payout_revisions',
     'payout_checks', 'payout_reviews', 'pocket_transfers')),
  'row level security is on for every new table'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'finance' and p.prosecdef
      and p.proname in ('withdrawal_json', 'withdrawal_page', 'payout_json', 'complete_withdrawal',
        'transfer_json', 'transfer_page', 'trigger_payout_checker', 'take_receipt', 'add_revision')
  ),
  'finance helpers are not definer'
);
select ok(
  not exists (
    select 1 from unnest(array[
      'api.claim_payout_checks(text, integer)',
      'api.finish_payout_check(uuid, uuid, text, jsonb, text[], text, text)',
      'api.fail_payout_check(uuid, uuid, text)'
    ]) f
    where not has_function_privilege('service_role', f::regprocedure, 'execute')
       or has_function_privilege('anon', f::regprocedure, 'execute')
       or has_function_privilege('authenticated', f::regprocedure, 'execute')
  ),
  'the receipt-check worker functions are service-only'
);
select ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('api', 'finance')
      and p.proname ~ '(withdrawal|payout|pocket_transfer|transfer_|review_)'
      and not coalesce(p.proconfig @> array['search_path=""'], false)
  ),
  'every new function pins an empty search_path'
);

select * from finish();
rollback;
