begin;

create extension if not exists pgtap with schema extensions;
select extensions.no_plan();

insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
values (
  '00000000-0000-0000-0000-000000000601',
  'authenticated',
  'authenticated',
  'member-home-owner@example.test',
  '{}'::jsonb,
  '{}'::jsonb
);

insert into public.user_accounts (user_id)
values ('00000000-0000-0000-0000-000000000601');

insert into public.tenants (id, name)
values ('10000000-0000-0000-0000-000000000601', 'Member Home Tenant');

insert into public.offices (id, tenant_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000601',
  '10000000-0000-0000-0000-000000000601',
  'world_team',
  'Member Home World Team'
);

insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000603',
  '10000000-0000-0000-0000-000000000601',
  '20000000-0000-0000-0000-000000000601',
  'director',
  'Member Home Director'
);

insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000602',
  '10000000-0000-0000-0000-000000000601',
  '20000000-0000-0000-0000-000000000603',
  'team_leader',
  'Member Home Office'
);

insert into public.memberships (id, tenant_id, user_id, office_id, role_key, is_primary)
values (
  '30000000-0000-0000-0000-000000000601',
  '10000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000601',
  '20000000-0000-0000-0000-000000000602',
  'member',
  true
);

insert into public.wallets (id, owner_user_id)
values (
  '60000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000601'
);

insert into public.pocket_definitions (pocket_key, display_name, sort_order)
values ('member_home_test', 'Member Home Test', 601);

insert into ledger.currency_definitions (currency_code, minor_unit_scale)
values ('NGN', 2);

insert into ledger.ledger_accounts (
  id, account_class, currency_code, wallet_id, tenant_id, office_id,
  membership_id, owner_user_id, pocket_key
)
values (
  '81000000-0000-0000-0000-000000000601',
  'member_value',
  'NGN',
  '60000000-0000-0000-0000-000000000601',
  '10000000-0000-0000-0000-000000000601',
  '20000000-0000-0000-0000-000000000602',
  '30000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000601',
  'member_home_test'
);

insert into ledger.ledger_accounts (id, account_class, currency_code, system_account_key)
values (
  '82000000-0000-0000-0000-000000000601',
  'system_counter',
  'NGN',
  'member_home_external'
);

insert into financial_ops.payout_accounts (
  id, wallet_id, owner_user_id, country_code, payout_currency, payout_rail,
  institution_code, institution_name, account_reference, account_holder_name,
  verification_status, verification_method, verified_at, is_primary, created_at
)
values (
  '70000000-0000-0000-0000-000000000601',
  '60000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000601',
  'NG', 'NGN', 'bank_transfer', 'TEST001', 'Member Home Bank',
  '0123456789', 'Member Home Owner', 'verified', 'manual_fixture',
  '2026-09-20 10:00:01+00', true, '2026-09-20 10:00:00+00'
);

select ledger.post_transaction(
  '90000000-0000-0000-0000-000000000601',
  extensions.digest('member-home-income', 'sha256'),
  'member_home_income',
  '30000000-0000-0000-0000-000000000601',
  '60000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000601',
  jsonb_build_array(jsonb_build_object(
    'currency_code', 'NGN',
    'postings', jsonb_build_array(
      jsonb_build_object(
        'ledger_account_id', '82000000-0000-0000-0000-000000000601',
        'amount', '-250.00'
      ),
      jsonb_build_object(
        'ledger_account_id', '81000000-0000-0000-0000-000000000601',
        'amount', '250.00'
      )
    )
  ))
);

insert into financial_ops.withdrawal_requests (
  id, tenant_id, office_id, membership_id, wallet_id, owner_user_id,
  source_ledger_account_id, source_currency_code, source_pocket_key,
  requested_amount, payout_account_id, initiated_by_user_id,
  status, created_at, updated_at
)
values (
  '71000000-0000-0000-0000-000000000601',
  '10000000-0000-0000-0000-000000000601',
  '20000000-0000-0000-0000-000000000602',
  '30000000-0000-0000-0000-000000000601',
  '60000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000601',
  '81000000-0000-0000-0000-000000000601',
  'NGN', 'member_home_test', 100,
  '70000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000601',
  'requested', '2026-09-20 11:00:00+00', '2026-09-20 11:00:00+00'
);

insert into financial_ops.withdrawal_destination_snapshots (
  withdrawal_id, source_payout_account_id, institution_code, institution_name,
  account_reference, account_holder_name, payout_rail, payout_currency,
  country_code, verification_status, verification_method, snapshotted_at
)
values (
  '71000000-0000-0000-0000-000000000601',
  '70000000-0000-0000-0000-000000000601',
  'TEST001', 'Member Home Bank', '0123456789', 'Member Home Owner',
  'bank_transfer', 'NGN', 'NG', 'verified', 'manual_fixture',
  '2026-09-20 11:00:01+00'
);

-- Four journals in one posted transaction exercise equal created_at values with
-- independent UUID tie-breakers. Each amount makes a missing/repeated row visible.
select ledger.post_transaction(
  '90000000-0000-0000-0000-000000000602',
  extensions.digest('member-history-pagination', 'sha256'),
  'member_history_page',
  '30000000-0000-0000-0000-000000000601',
  '60000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000601',
  (select jsonb_agg(jsonb_build_object(
    'currency_code', 'NGN',
    'postings', jsonb_build_array(
      jsonb_build_object(
        'ledger_account_id', '82000000-0000-0000-0000-000000000601',
        'amount', -amount
      ),
      jsonb_build_object(
        'ledger_account_id', '81000000-0000-0000-0000-000000000601',
        'amount', amount
      )
    )
  )) from generate_series(1, 4) amount)
);

-- All five withdrawals have the same timestamp, so their UUID order alone must
-- keep every row reachable across page boundaries.
insert into financial_ops.withdrawal_requests (
  id, tenant_id, office_id, membership_id, wallet_id, owner_user_id,
  source_ledger_account_id, source_currency_code, source_pocket_key,
  requested_amount, payout_account_id, initiated_by_user_id,
  status, created_at, updated_at
)
select
  ('71000000-0000-0000-0000-' || lpad(sequence::text, 12, '0'))::uuid,
  tenant_id, office_id, membership_id, wallet_id, owner_user_id,
  source_ledger_account_id, source_currency_code, source_pocket_key,
  requested_amount, payout_account_id, initiated_by_user_id,
  status, created_at, updated_at
from financial_ops.withdrawal_requests
cross join generate_series(602, 605) sequence
where id = '71000000-0000-0000-0000-000000000601';

insert into financial_ops.withdrawal_destination_snapshots (
  withdrawal_id, source_payout_account_id, institution_code, institution_name,
  account_reference, account_holder_name, payout_rail, payout_currency,
  country_code, verification_status, verification_method, snapshotted_at
)
select
  ('71000000-0000-0000-0000-' || lpad(sequence::text, 12, '0'))::uuid,
  source_payout_account_id, institution_code, institution_name,
  account_reference, account_holder_name, payout_rail, payout_currency,
  country_code, verification_status, verification_method, snapshotted_at
from financial_ops.withdrawal_destination_snapshots
cross join generate_series(602, 605) sequence
where withdrawal_id = '71000000-0000-0000-0000-000000000601';

create temporary table pagination_cases (
  name text primary key,
  kind text not null,
  page_size integer not null,
  item_filter text,
  expected_count integer not null
);
insert into pagination_cases values
  ('activity page size one', 'activity', 1, null, 5),
  ('activity uneven final page', 'activity', 2, null, 5),
  ('activity exact full page', 'activity', 5, null, 5),
  ('activity filtered pages', 'activity', 2, 'member_history_page', 4),
  ('withdrawals page size one', 'withdrawals', 1, null, 5),
  ('withdrawals uneven final page', 'withdrawals', 2, null, 5),
  ('withdrawals exact full page', 'withdrawals', 5, 'requested', 5),
  ('withdrawals empty filter', 'withdrawals', 2, 'completed', 0);

create temporary table history_pages (name text, page_number integer, payload jsonb);
create temporary table history_expected (name text, items jsonb);
grant select on pagination_cases to service_role;
grant select, insert on history_pages, history_expected to service_role;

set local role service_role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000601', true);

insert into history_expected
select name, (case kind
  when 'activity' then read_api.member_activity(
    '00000000-0000-0000-0000-000000000601', null, null, 100, 'NGN', item_filter, 'member_home_test'
  )
  else read_api.member_withdrawals(
    '00000000-0000-0000-0000-000000000601', null, null, 100, item_filter
  ) end)->'items'
from pagination_cases;

insert into history_pages
with recursive pages as (
  select name, kind, page_size, item_filter, 1 as page_number,
    case kind
      when 'activity' then read_api.member_activity(
        '00000000-0000-0000-0000-000000000601', null, null, page_size, 'NGN', item_filter, 'member_home_test'
      )
      else read_api.member_withdrawals(
        '00000000-0000-0000-0000-000000000601', null, null, page_size, item_filter
      )
    end as payload
  from pagination_cases
  union all
  select name, kind, page_size, item_filter, page_number + 1,
    case kind
      when 'activity' then read_api.member_activity(
        '00000000-0000-0000-0000-000000000601',
        (payload->'next_cursor'->>'created_at')::timestamptz,
        (payload->'next_cursor'->>'entry_id')::uuid,
        page_size, 'NGN', item_filter, 'member_home_test'
      )
      else read_api.member_withdrawals(
        '00000000-0000-0000-0000-000000000601',
        (payload->'next_cursor'->>'created_at')::timestamptz,
        (payload->'next_cursor'->>'withdrawal_id')::uuid,
        page_size, item_filter
      )
    end
  from pages
  where payload->>'next_cursor' is not null
    and page_number < 10 -- Bound faulty cursors so a regression cannot hang CI.
)
select name, page_number, payload from pages;

select extensions.is(
  jsonb_array_length(expected.items), test.expected_count,
  test.name || ': fixture has the expected visible row count'
)
from pagination_cases test join history_expected expected using (name)
order by name;

select extensions.is(
  coalesce((select jsonb_agg(item.value order by page.page_number, item.ordinality)
    from history_pages page
    cross join lateral jsonb_array_elements(page.payload->'items') with ordinality item(value, ordinality)
    where page.name = test.name), '[]'::jsonb),
  expected.items,
  test.name || ': complete ordered traversal has no missing or duplicate rows'
)
from pagination_cases test join history_expected expected using (name)
order by name;

select extensions.is(
  (select count(*) from history_pages page where page.name = test.name),
  greatest(1, (test.expected_count + test.page_size - 1) / test.page_size)::bigint,
  test.name || ': only the expected number of pages is needed'
)
from pagination_cases test order by name;

select extensions.is(
  (select page.payload->>'next_cursor' from history_pages page
    where page.name = test.name order by page.page_number desc limit 1),
  null,
  test.name || ': final page has no next cursor'
)
from pagination_cases test order by name;

select extensions.throws_ok(
  $$select read_api.member_activity('00000000-0000-0000-0000-000000000602')$$,
  '42501', 'member activity actor does not match the authenticated user',
  'activity pagination retains the authenticated actor boundary'
);
select extensions.throws_ok(
  $$select read_api.member_withdrawals('00000000-0000-0000-0000-000000000602')$$,
  '42501', 'member withdrawals actor does not match the authenticated user',
  'withdrawal pagination retains the authenticated actor boundary'
);
select extensions.throws_ok(
  $$select read_api.member_activity('00000000-0000-0000-0000-000000000601', now(), null, 2)$$,
  '22023', 'member activity cursor is incomplete',
  'activity pagination rejects an incomplete cursor'
);
select extensions.throws_ok(
  $$select read_api.member_withdrawals('00000000-0000-0000-0000-000000000601', now(), null, 2)$$,
  '22023', 'member withdrawals cursor is incomplete',
  'withdrawal pagination rejects an incomplete cursor'
);

reset role;
update public.memberships set status = 'suspended'
where id = '30000000-0000-0000-0000-000000000601';
set local role service_role;
select extensions.throws_ok(
  $$select read_api.member_activity('00000000-0000-0000-0000-000000000601')$$,
  '42501', 'member activity requires an active Wallet membership',
  'activity pagination rechecks current membership authority'
);
select extensions.throws_ok(
  $$select read_api.member_withdrawals('00000000-0000-0000-0000-000000000601')$$,
  '42501', 'member withdrawals requires an active Wallet membership',
  'withdrawal pagination rechecks current membership authority'
);

select extensions.finish();
rollback;
