begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select no_plan();

insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
values
  ('00000000-0000-0000-0000-000000000201', 'authenticated', 'authenticated', 'ledger-actor@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000202', 'authenticated', 'authenticated', 'ledger-owner@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000203', 'authenticated', 'authenticated', 'ledger-outsider@example.test', '{}'::jsonb, '{}'::jsonb)
on conflict (id) do nothing;

insert into public.user_accounts (user_id)
values
  ('00000000-0000-0000-0000-000000000201'),
  ('00000000-0000-0000-0000-000000000202'),
  ('00000000-0000-0000-0000-000000000203');

insert into public.tenants (id, name)
values ('10000000-0000-0000-0000-000000000201', 'Ledger Tenant');

insert into public.offices (id, tenant_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000201',
  '10000000-0000-0000-0000-000000000201',
  'world_team',
  'Ledger World Team'
);

insert into public.offices (
  id, tenant_id, parent_office_id, office_type, name
)
values (
  '20000000-0000-0000-0000-000000000202',
  '10000000-0000-0000-0000-000000000201',
  '20000000-0000-0000-0000-000000000201',
  'director',
  'Ledger Director Office'
);

insert into public.offices (
  id, tenant_id, parent_office_id, office_type, name
)
values (
  '20000000-0000-0000-0000-000000000203',
  '10000000-0000-0000-0000-000000000201',
  '20000000-0000-0000-0000-000000000202',
  'team_leader',
  'Ledger Team Leader Office'
);

insert into public.memberships (
  id, tenant_id, user_id, office_id, role_key, is_primary
)
values (
  '30000000-0000-0000-0000-000000000202',
  '10000000-0000-0000-0000-000000000201',
  '00000000-0000-0000-0000-000000000202',
  '20000000-0000-0000-0000-000000000203',
  'member',
  true
);

insert into public.wallets (id, owner_user_id)
values (
  '60000000-0000-0000-0000-000000000202',
  '00000000-0000-0000-0000-000000000202'
);

insert into public.pocket_definitions (
  pocket_key, display_name, sort_order
)
values ('ledger_test', 'Ledger Test', 300);

insert into ledger.currency_definitions (currency_code, minor_unit_scale)
values ('NGN', 2), ('USD', 2);

insert into ledger.ledger_accounts (
  id, account_class, currency_code, wallet_id, tenant_id, office_id,
  membership_id, owner_user_id, pocket_key
)
values
  (
    '81000000-0000-0000-0000-000000000201',
    'member_value',
    'NGN',
    '60000000-0000-0000-0000-000000000202',
    '10000000-0000-0000-0000-000000000201',
    '20000000-0000-0000-0000-000000000203',
    '30000000-0000-0000-0000-000000000202',
    '00000000-0000-0000-0000-000000000202',
    'ledger_test'
  ),
  (
    '81000000-0000-0000-0000-000000000202',
    'member_value',
    'NGN',
    '60000000-0000-0000-0000-000000000202',
    '10000000-0000-0000-0000-000000000201',
    '20000000-0000-0000-0000-000000000203',
    '30000000-0000-0000-0000-000000000202',
    '00000000-0000-0000-0000-000000000202',
    'debt'
  ),
  (
    '81000000-0000-0000-0000-000000000203',
    'member_value',
    'USD',
    '60000000-0000-0000-0000-000000000202',
    '10000000-0000-0000-0000-000000000201',
    '20000000-0000-0000-0000-000000000203',
    '30000000-0000-0000-0000-000000000202',
    '00000000-0000-0000-0000-000000000202',
    'ledger_test'
  );

insert into ledger.ledger_accounts (
  id, account_class, currency_code, system_account_key
)
values
  ('82000000-0000-0000-0000-000000000201', 'system_counter', 'NGN', 'test_external_ngn'),
  ('82000000-0000-0000-0000-000000000202', 'system_counter', 'USD', 'test_external_usd');

select throws_ok(
  $$insert into ledger.ledger_accounts (
      account_class, currency_code, wallet_id, tenant_id, office_id,
      membership_id, owner_user_id, pocket_key
    ) values (
      'member_value',
      'NGN',
      '60000000-0000-0000-0000-000000000202',
      '10000000-0000-0000-0000-000000000201',
      '20000000-0000-0000-0000-000000000203',
      '30000000-0000-0000-0000-000000000202',
      '00000000-0000-0000-0000-000000000203',
      'ledger_test'
    )$$,
  '23514',
  'member-value ledger account context must match wallet ownership and membership provenance',
  'member-value ledger accounts derive owner and provenance from authoritative rows'
);

select is(
  (
    ledger.post_transaction(
      '90000000-0000-0000-0000-000000000201',
      extensions.digest('ledger-income-1', 'sha256'),
      'test_income',
      '30000000-0000-0000-0000-000000000202',
      '60000000-0000-0000-0000-000000000202',
      '00000000-0000-0000-0000-000000000201',
      jsonb_build_array(
        jsonb_build_object(
          'currency_code', 'NGN',
          'postings', jsonb_build_array(
            jsonb_build_object(
              'ledger_account_id', '82000000-0000-0000-0000-000000000201',
              'amount', '-100.00'
            ),
            jsonb_build_object(
              'ledger_account_id', '81000000-0000-0000-0000-000000000201',
              'amount', '100.00'
            )
          )
        )
      )
    )
  ).reused,
  false,
  'first trusted posting creates new immutable financial history'
);

select is(
  (
    select balance
      from ledger.wallet_balance_projections
     where ledger_account_id = '81000000-0000-0000-0000-000000000201'
  ),
  100.000000000000000000::numeric,
  'member-value projection is updated from posted history'
);

select is(
  (
    select sum(jp.amount)
      from ledger.journal_postings jp
      join ledger.journal_entries je on je.id = jp.journal_entry_id
      join ledger.financial_transactions ft on ft.id = je.financial_transaction_id
     where ft.idempotency_key = '90000000-0000-0000-0000-000000000201'
  ),
  0.000000000000000000::numeric,
  'single-currency journal postings balance exactly to zero'
);

select ok(
  exists (
    select 1
      from ledger.financial_transactions ft
     where ft.idempotency_key = '90000000-0000-0000-0000-000000000201'
       and ft.transaction_reference ~ '^FT-[A-F0-9]{16}$'
       and ft.posted_at is not null
       and ft.tenant_id = '10000000-0000-0000-0000-000000000201'
       and ft.office_id = '20000000-0000-0000-0000-000000000203'
       and ft.membership_id = '30000000-0000-0000-0000-000000000202'
       and ft.wallet_id = '60000000-0000-0000-0000-000000000202'
       and ft.owner_user_id = '00000000-0000-0000-0000-000000000202'
  ),
  'financial transaction keeps a human reference and immutable provenance'
);

select is(
  (
    ledger.post_transaction(
      '90000000-0000-0000-0000-000000000201',
      extensions.digest('ledger-income-1', 'sha256'),
      'test_income',
      '30000000-0000-0000-0000-000000000202',
      '60000000-0000-0000-0000-000000000202',
      '00000000-0000-0000-0000-000000000201',
      jsonb_build_array(
        jsonb_build_object(
          'currency_code', 'NGN',
          'postings', jsonb_build_array(
            jsonb_build_object(
              'ledger_account_id', '82000000-0000-0000-0000-000000000201',
              'amount', '-100.00'
            ),
            jsonb_build_object(
              'ledger_account_id', '81000000-0000-0000-0000-000000000201',
              'amount', '100.00'
            )
          )
        )
      )
    )
  ).reused,
  true,
  'same idempotency key and fingerprint reuses the original result'
);

select is(
  (
    select count(*)
      from ledger.financial_transactions
     where idempotency_key = '90000000-0000-0000-0000-000000000201'
  ),
  1::bigint,
  'idempotent retry creates no duplicate financial transaction'
);

select throws_ok(
  $$select ledger.post_transaction(
      '90000000-0000-0000-0000-000000000201',
      extensions.digest('different-command', 'sha256'),
      'test_income',
      '30000000-0000-0000-0000-000000000202',
      '60000000-0000-0000-0000-000000000202',
      '00000000-0000-0000-0000-000000000201',
      jsonb_build_array(
        jsonb_build_object(
          'currency_code', 'NGN',
          'postings', jsonb_build_array(
            jsonb_build_object(
              'ledger_account_id', '82000000-0000-0000-0000-000000000201',
              'amount', '-100.00'
            ),
            jsonb_build_object(
              'ledger_account_id', '81000000-0000-0000-0000-000000000201',
              'amount', '100.00'
            )
          )
        )
      )
    )$$,
  '23505',
  'idempotency key already used with different command data',
  'conflicting idempotency-key reuse is rejected'
);

select throws_ok(
  $$select ledger.post_transaction(
      '90000000-0000-0000-0000-000000000202',
      extensions.digest('unbalanced-command', 'sha256'),
      'test_unbalanced',
      '30000000-0000-0000-0000-000000000202',
      '60000000-0000-0000-0000-000000000202',
      '00000000-0000-0000-0000-000000000201',
      jsonb_build_array(
        jsonb_build_object(
          'currency_code', 'NGN',
          'postings', jsonb_build_array(
            jsonb_build_object(
              'ledger_account_id', '82000000-0000-0000-0000-000000000201',
              'amount', '-10.00'
            ),
            jsonb_build_object(
              'ledger_account_id', '81000000-0000-0000-0000-000000000201',
              'amount', '9.00'
            )
          )
        )
      )
    )$$,
  '23514',
  'journal entry must contain at least two postings that balance to zero',
  'unbalanced journals cannot be posted'
);

select throws_ok(
  $$select ledger.post_transaction(
      '90000000-0000-0000-0000-000000000203',
      extensions.digest('cross-currency-command', 'sha256'),
      'test_cross_currency',
      '30000000-0000-0000-0000-000000000202',
      '60000000-0000-0000-0000-000000000202',
      '00000000-0000-0000-0000-000000000201',
      jsonb_build_array(
        jsonb_build_object(
          'currency_code', 'NGN',
          'postings', jsonb_build_array(
            jsonb_build_object(
              'ledger_account_id', '82000000-0000-0000-0000-000000000201',
              'amount', '-10.00'
            ),
            jsonb_build_object(
              'ledger_account_id', '81000000-0000-0000-0000-000000000203',
              'amount', '10.00'
            )
          )
        )
      )
    )$$,
  '23514',
  'journal posting account currency must match journal currency',
  'cross-currency postings cannot be balanced inside one journal'
);

select throws_ok(
  $$select ledger.post_transaction(
      '90000000-0000-0000-0000-000000000204',
      extensions.digest('currency-scale-command', 'sha256'),
      'test_currency_scale',
      '30000000-0000-0000-0000-000000000202',
      '60000000-0000-0000-0000-000000000202',
      '00000000-0000-0000-0000-000000000201',
      jsonb_build_array(
        jsonb_build_object(
          'currency_code', 'NGN',
          'postings', jsonb_build_array(
            jsonb_build_object(
              'ledger_account_id', '82000000-0000-0000-0000-000000000201',
              'amount', '-0.001'
            ),
            jsonb_build_object(
              'ledger_account_id', '81000000-0000-0000-0000-000000000201',
              'amount', '0.001'
            )
          )
        )
      )
    )$$,
  '22003',
  'posting amount exceeds the currency minor-unit scale',
  'posting precision cannot exceed the configured currency scale'
);

select throws_ok(
  $$select ledger.post_transaction(
      '90000000-0000-0000-0000-000000000205',
      extensions.digest('ordinary-negative-command', 'sha256'),
      'test_ordinary_negative',
      '30000000-0000-0000-0000-000000000202',
      '60000000-0000-0000-0000-000000000202',
      '00000000-0000-0000-0000-000000000201',
      jsonb_build_array(
        jsonb_build_object(
          'currency_code', 'NGN',
          'postings', jsonb_build_array(
            jsonb_build_object(
              'ledger_account_id', '81000000-0000-0000-0000-000000000201',
              'amount', '-101.00'
            ),
            jsonb_build_object(
              'ledger_account_id', '82000000-0000-0000-0000-000000000201',
              'amount', '101.00'
            )
          )
        )
      )
    )$$,
  '23514',
  'ordinary pocket balance cannot become negative',
  'ordinary pocket projection cannot become negative'
);

select is(
  (
    select balance
      from ledger.wallet_balance_projections
     where ledger_account_id = '81000000-0000-0000-0000-000000000201'
  ),
  100.000000000000000000::numeric,
  'failed posting rolls back its projection change'
);

select is(
  (
    ledger.post_transaction(
      '90000000-0000-0000-0000-000000000206',
      extensions.digest('debt-negative-command', 'sha256'),
      'test_debt_negative',
      '30000000-0000-0000-0000-000000000202',
      '60000000-0000-0000-0000-000000000202',
      '00000000-0000-0000-0000-000000000201',
      jsonb_build_array(
        jsonb_build_object(
          'currency_code', 'NGN',
          'postings', jsonb_build_array(
            jsonb_build_object(
              'ledger_account_id', '81000000-0000-0000-0000-000000000202',
              'amount', '-25.00'
            ),
            jsonb_build_object(
              'ledger_account_id', '82000000-0000-0000-0000-000000000201',
              'amount', '25.00'
            )
          )
        )
      )
    )
  ).reused,
  false,
  'Debt is the only pocket that may post to a negative projection'
);

select is(
  (
    select balance
      from ledger.wallet_balance_projections
     where ledger_account_id = '81000000-0000-0000-0000-000000000202'
  ),
  -25.000000000000000000::numeric,
  'Debt projection preserves its exact negative amount'
);

select is(
  (
    ledger.post_transaction(
      '90000000-0000-0000-0000-000000000207',
      extensions.digest('multi-currency-command', 'sha256'),
      'test_multi_currency',
      '30000000-0000-0000-0000-000000000202',
      '60000000-0000-0000-0000-000000000202',
      '00000000-0000-0000-0000-000000000201',
      jsonb_build_array(
        jsonb_build_object(
          'currency_code', 'NGN',
          'postings', jsonb_build_array(
            jsonb_build_object(
              'ledger_account_id', '81000000-0000-0000-0000-000000000201',
              'amount', '-5.00'
            ),
            jsonb_build_object(
              'ledger_account_id', '82000000-0000-0000-0000-000000000201',
              'amount', '5.00'
            )
          )
        ),
        jsonb_build_object(
          'currency_code', 'USD',
          'postings', jsonb_build_array(
            jsonb_build_object(
              'ledger_account_id', '82000000-0000-0000-0000-000000000202',
              'amount', '-2.50'
            ),
            jsonb_build_object(
              'ledger_account_id', '81000000-0000-0000-0000-000000000203',
              'amount', '2.50'
            )
          )
        )
      )
    )
  ).reused,
  false,
  'one financial transaction can group multiple balanced single-currency journals'
);

update public.memberships
   set status = 'suspended'
 where id = '30000000-0000-0000-0000-000000000202';

select throws_ok(
  $$select ledger.post_transaction(
      '90000000-0000-0000-0000-000000000208',
      extensions.digest('suspended-membership-command', 'sha256'),
      'test_suspended_membership',
      '30000000-0000-0000-0000-000000000202',
      '60000000-0000-0000-0000-000000000202',
      '00000000-0000-0000-0000-000000000201',
      jsonb_build_array(
        jsonb_build_object(
          'currency_code', 'NGN',
          'postings', jsonb_build_array(
            jsonb_build_object(
              'ledger_account_id', '82000000-0000-0000-0000-000000000201',
              'amount', '-1.00'
            ),
            jsonb_build_object(
              'ledger_account_id', '81000000-0000-0000-0000-000000000201',
              'amount', '1.00'
            )
          )
        )
      )
    )$$,
  '23514',
  'financial transaction posting requires active actor and organizational context',
  'suspended membership cannot contribute authority to a new posting'
);

update public.memberships
   set status = 'active'
 where id = '30000000-0000-0000-0000-000000000202';

select throws_ok(
  $$update ledger.financial_transactions
       set metadata = '{"tampered":true}'::jsonb
     where idempotency_key = '90000000-0000-0000-0000-000000000201'$$,
  '55000',
  'posted financial transactions are immutable',
  'posted financial transaction history cannot be edited'
);

select throws_ok(
  $$update ledger.journal_postings
       set amount = amount + 1
     where id = (select min(id) from ledger.journal_postings)$$,
  '55000',
  'ledger.journal_postings is immutable',
  'journal postings cannot be edited'
);

select throws_ok(
  $$delete from ledger.journal_entries
     where id = (select id from ledger.journal_entries order by created_at, id limit 1)$$,
  '55000',
  'ledger.journal_entries is immutable',
  'journal entries cannot be deleted'
);

select throws_ok(
  $$update ledger.wallet_balance_projections
       set balance = 999
     where ledger_account_id = '81000000-0000-0000-0000-000000000201'$$,
  '55000',
  'balance projections may only be changed by trusted ledger posting',
  'projection balances cannot be edited directly'
);

select ok(
  not has_schema_privilege('authenticated', 'ledger', 'usage'),
  'authenticated role has no usage on the private ledger schema'
);

select ok(
  not has_table_privilege(
    'service_role',
    'ledger.financial_transactions',
    'select'
  ),
  'service role has no direct ledger table access'
);

select ok(
  not has_function_privilege(
    'service_role',
    'ledger.post_transaction(uuid,bytea,text,uuid,uuid,uuid,jsonb,jsonb)',
    'execute'
  ),
  'service role cannot bypass authorization through the private posting primitive'
);

select is(
  (
    select count(*)
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'ledger'
       and c.relkind = 'r'
       and c.relrowsecurity
       and c.relforcerowsecurity
  ),
  6::bigint,
  'every private ledger table has RLS enabled and forced'
);

select is(
  (
    select count(*)
      from pg_policy p
      join pg_class c on c.oid = p.polrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'ledger'
       and not p.polpermissive
       and pg_get_expr(p.polqual, p.polrelid) = 'false'
       and pg_get_expr(p.polwithcheck, p.polrelid) = 'false'
  ),
  6::bigint,
  'every private ledger table has an explicit restrictive deny policy'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000202', true);

select throws_ok(
  $$select count(*) from ledger.financial_transactions$$,
  '42501',
  null,
  'authenticated clients cannot read private ledger history directly'
);

select throws_ok(
  $$select ledger.post_transaction(
      '90000000-0000-0000-0000-000000000209',
      decode(repeat('00', 32), 'hex'),
      'client_attempt',
      '30000000-0000-0000-0000-000000000202',
      '60000000-0000-0000-0000-000000000202',
      '00000000-0000-0000-0000-000000000202',
      '[]'::jsonb
    )$$,
  '42501',
  null,
  'authenticated clients cannot execute the private posting primitive'
);

reset role;

select finish();
rollback;
