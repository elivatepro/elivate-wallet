begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select no_plan();

create temporary table payout_test_ids (
  key text primary key,
  id uuid not null
);

insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
values
  ('00000000-0000-0000-0000-000000000401', 'authenticated', 'authenticated', 'payout-approver@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000402', 'authenticated', 'authenticated', 'payout-owner@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000403', 'authenticated', 'authenticated', 'payout-president@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000404', 'authenticated', 'authenticated', 'payout-reviewer@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000405', 'authenticated', 'authenticated', 'payout-unassigned@example.test', '{}'::jsonb, '{}'::jsonb)
on conflict (id) do nothing;

insert into public.user_accounts (user_id)
values
  ('00000000-0000-0000-0000-000000000401'),
  ('00000000-0000-0000-0000-000000000402'),
  ('00000000-0000-0000-0000-000000000403'),
  ('00000000-0000-0000-0000-000000000404'),
  ('00000000-0000-0000-0000-000000000405');

insert into public.tenants (id, name)
values ('10000000-0000-0000-0000-000000000401', 'Payout Tenant');

insert into public.offices (id, tenant_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000401',
  '10000000-0000-0000-0000-000000000401',
  'world_team',
  'Payout World Team'
);

insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000402',
  '10000000-0000-0000-0000-000000000401',
  '20000000-0000-0000-0000-000000000401',
  'director',
  'Payout Director'
);

insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000403',
  '10000000-0000-0000-0000-000000000401',
  '20000000-0000-0000-0000-000000000402',
  'team_leader',
  'Payout Team'
);

insert into public.memberships (
  id, tenant_id, user_id, office_id, role_key, is_primary
)
values
  (
    '30000000-0000-0000-0000-000000000401',
    '10000000-0000-0000-0000-000000000401',
    '00000000-0000-0000-0000-000000000401',
    '20000000-0000-0000-0000-000000000403',
    'team_leader',
    true
  ),
  (
    '30000000-0000-0000-0000-000000000402',
    '10000000-0000-0000-0000-000000000401',
    '00000000-0000-0000-0000-000000000402',
    '20000000-0000-0000-0000-000000000403',
    'member',
    true
  ),
  (
    '30000000-0000-0000-0000-000000000403',
    '10000000-0000-0000-0000-000000000401',
    '00000000-0000-0000-0000-000000000403',
    null,
    'president_team_member',
    true
  ),
  (
    '30000000-0000-0000-0000-000000000404',
    '10000000-0000-0000-0000-000000000401',
    '00000000-0000-0000-0000-000000000404',
    '20000000-0000-0000-0000-000000000402',
    'director',
    true
  ),
  (
    '30000000-0000-0000-0000-000000000405',
    '10000000-0000-0000-0000-000000000401',
    '00000000-0000-0000-0000-000000000405',
    '20000000-0000-0000-0000-000000000401',
    'world_team_member',
    true
  );

select authz.seed_tenant_role_permissions(
  '10000000-0000-0000-0000-000000000401'
);

insert into public.wallets (id, owner_user_id)
values (
  '60000000-0000-0000-0000-000000000402',
  '00000000-0000-0000-0000-000000000402'
);

insert into public.pocket_definitions (
  pocket_key, display_name, sort_order
)
values ('payout_test', 'Payout Test', 500);

insert into ledger.currency_definitions (currency_code, minor_unit_scale)
values ('NGN', 2);

insert into ledger.ledger_accounts (
  id, account_class, currency_code, wallet_id, tenant_id, office_id,
  membership_id, owner_user_id, pocket_key
)
values (
  '83000000-0000-0000-0000-000000000401',
  'member_value',
  'NGN',
  '60000000-0000-0000-0000-000000000402',
  '10000000-0000-0000-0000-000000000401',
  '20000000-0000-0000-0000-000000000403',
  '30000000-0000-0000-0000-000000000402',
  '00000000-0000-0000-0000-000000000402',
  'payout_test'
);

insert into ledger.ledger_accounts (
  id, account_class, currency_code, system_account_key
)
values
  (
    '84000000-0000-0000-0000-000000000401',
    'system_counter',
    'NGN',
    'payout_test_inflow'
  ),
  (
    '84000000-0000-0000-0000-000000000402',
    'system_counter',
    'NGN',
    'external_payout'
  ),
  (
    '84000000-0000-0000-0000-000000000403',
    'system_counter',
    'NGN',
    'provider_fee'
  );

select ledger.post_transaction(
  '90000000-0000-0000-0000-000000000401',
  extensions.digest('payout-opening-balance', 'sha256'),
  'payout_test_opening_balance',
  '30000000-0000-0000-0000-000000000402',
  '60000000-0000-0000-0000-000000000402',
  '00000000-0000-0000-0000-000000000405',
  jsonb_build_array(
    jsonb_build_object(
      'currency_code', 'NGN',
      'postings', jsonb_build_array(
        jsonb_build_object(
          'ledger_account_id', '84000000-0000-0000-0000-000000000401',
          'amount', '-1000.00'
        ),
        jsonb_build_object(
          'ledger_account_id', '83000000-0000-0000-0000-000000000401',
          'amount', '1000.00'
        )
      )
    )
  )
);

insert into financial_ops.payout_accounts (
  id, wallet_id, owner_user_id, country_code, payout_currency, payout_rail,
  institution_code, institution_name, account_reference, account_holder_name,
  verification_status, verification_method, verified_at, is_primary, created_at
)
values (
  '85000000-0000-0000-0000-000000000401',
  '60000000-0000-0000-0000-000000000402',
  '00000000-0000-0000-0000-000000000402',
  'NG',
  'NGN',
  'bank_transfer',
  '999',
  'Payout Test Bank',
  '0123456789',
  'Payout Owner',
  'verified',
  'manual_test_verification',
  statement_timestamp(),
  true,
  statement_timestamp()
);

select throws_ok(
  $$select authz.configure_financial_evidence_reviewer(
    '10000000-0000-0000-0000-000000000401',
    '30000000-0000-0000-0000-000000000404',
    true,
    '00000000-0000-0000-0000-000000000403'
  )$$,
  '42501',
  'financial evidence reviewer configuration requires fresh authorization',
  'President reviewer configuration requires five-minute step-up authorization'
);

insert into authz.elevated_sessions (
  session_id, user_id, verified_at, valid_until, factor_method
)
values (
  '91000000-0000-0000-0000-000000000401',
  '00000000-0000-0000-0000-000000000403',
  clock_timestamp(),
  clock_timestamp() + interval '4 minutes',
  'totp'
);

-- A verified elevation is tied to a real Auth session.
insert into auth.sessions(id,user_id,aal,created_at,updated_at)
select session_id,user_id,'aal2',verified_at,verified_at from authz.elevated_sessions
on conflict (id) do nothing;

select ok(
  authz.configure_financial_evidence_reviewer(
    '10000000-0000-0000-0000-000000000401',
    '30000000-0000-0000-0000-000000000404',
    true,
    '00000000-0000-0000-0000-000000000403',
    '91000000-0000-0000-0000-000000000401'
  ) is not null,
  'President can assign an active tenant member as financial evidence reviewer'
);

select ok(
  authz.configure_financial_evidence_reviewer(
    '10000000-0000-0000-0000-000000000401',
    '30000000-0000-0000-0000-000000000401',
    true,
    '00000000-0000-0000-0000-000000000403',
    '91000000-0000-0000-0000-000000000401'
  ) is not null,
  'President can assign the payout actor as reviewer without bypassing self-review rules'
);

insert into payout_test_ids (key, id)
select 'withdrawal_review', (
  financial_ops.submit_withdrawal(
    '92000000-0000-0000-0000-000000000401',
    '83000000-0000-0000-0000-000000000401',
    '85000000-0000-0000-0000-000000000401',
    200.00,
    '00000000-0000-0000-0000-000000000402'
  )
).withdrawal_id;

select financial_ops.approve_withdrawal(
  '92000000-0000-0000-0000-000000000402',
  (select id from payout_test_ids where key = 'withdrawal_review'),
  '00000000-0000-0000-0000-000000000401'
);

select throws_ok(
  format(
    $$select financial_ops.submit_payout_assertion(
      '93000000-0000-0000-0000-000000000400',
      %L::uuid,
      200.00,
      190.00,
      'NGN',
      'manual_bank',
      clock_timestamp(),
      '[]'::jsonb,
      '00000000-0000-0000-0000-000000000401',
      10.00
    )$$,
    (select id from payout_test_ids where key = 'withdrawal_review')
  ),
  '22023',
  'payout completion requires at least one evidence item',
  'manual payout completion cannot be submitted without evidence'
);

insert into payout_test_ids (key, id)
select 'assertion_review', (
  financial_ops.submit_payout_assertion(
    '93000000-0000-0000-0000-000000000401',
    (select id from payout_test_ids where key = 'withdrawal_review'),
    200.00,
    190.00,
    'NGN',
    'manual_bank',
    clock_timestamp(),
    jsonb_build_array(
      jsonb_build_object(
        'storage_bucket_id', 'financial-evidence',
        'storage_object_path', 'payout/review/original.png',
        'original_filename', 'original.png',
        'mime_type', 'image/png',
        'file_size_bytes', '2048',
        'sha256_hex', encode(extensions.digest('review-original', 'sha256'), 'hex'),
        'provider', 'manual_bank',
        'observed_at', clock_timestamp()::text,
        'provider_reference', 'REVIEW-001'
      )
    ),
    '00000000-0000-0000-0000-000000000401',
    10.00,
    'REVIEW-001'
  )
).payout_assertion_id;

select is(
  (
    financial_ops.submit_payout_assertion(
      '93000000-0000-0000-0000-000000000401',
      (select id from payout_test_ids where key = 'withdrawal_review'),
      200.00,
      190.00,
      'NGN',
      'manual_bank',
      (
        select revision.paid_at
          from financial_ops.payout_assertion_revisions revision
         where revision.payout_assertion_id = (
           select id from payout_test_ids where key = 'assertion_review'
         )
           and revision.revision_number = 1
      ),
      jsonb_build_array(
        jsonb_build_object(
          'storage_bucket_id', 'financial-evidence',
          'storage_object_path', 'payout/review/original.png',
          'original_filename', 'original.png',
          'mime_type', 'image/png',
          'file_size_bytes', '2048',
          'sha256_hex', encode(extensions.digest('review-original', 'sha256'), 'hex'),
          'provider', 'manual_bank',
          'observed_at', (
            select item.observed_at::text
              from evidence.financial_evidence item
              join financial_ops.payout_assertion_evidence link
                on link.evidence_id = item.id
              join financial_ops.payout_assertion_revisions revision
                on revision.id = link.payout_assertion_revision_id
             where revision.payout_assertion_id = (
               select id from payout_test_ids where key = 'assertion_review'
             )
             limit 1
          ),
          'provider_reference', 'REVIEW-001'
        )
      ),
      '00000000-0000-0000-0000-000000000401',
      10.00,
      'REVIEW-001'
    )
  ).reused,
  true,
  'payout assertion submission is idempotent'
);

select is(
  (
    financial_ops.record_payout_verification(
      '94000000-0000-0000-0000-000000000401',
      (select id from payout_test_ids where key = 'assertion_review'),
      jsonb_build_object('beneficiary_payout_amount', '180.00'),
      jsonb_build_array('beneficiary_amount_mismatch'),
      'payout-evidence-model',
      'v1'
    )
  ).payout_assertion_status,
  'correction_required'::financial_ops.payout_assertion_status,
  'first evidence mismatch creates one correction opportunity'
);

select throws_ok(
  format(
    $$select financial_ops.cancel_withdrawal(
      '92000000-0000-0000-0000-000000000403',
      %L::uuid,
      '00000000-0000-0000-0000-000000000401',
      'Evidence is unresolved'
    )$$,
    (select id from payout_test_ids where key = 'withdrawal_review')
  ),
  '55000',
  'withdrawal cannot be cancelled while payout evidence is unresolved',
  'an unresolved payout assertion keeps its reservation locked'
);

select is(
  (
    financial_ops.correct_payout_assertion(
      '93000000-0000-0000-0000-000000000402',
      (select id from payout_test_ids where key = 'assertion_review'),
      200.00,
      190.00,
      'NGN',
      'manual_bank',
      clock_timestamp(),
      jsonb_build_array(
        jsonb_build_object(
          'existing_evidence_id', (
            select link.evidence_id
              from financial_ops.payout_assertion_evidence link
              join financial_ops.payout_assertion_revisions revision
                on revision.id = link.payout_assertion_revision_id
             where revision.payout_assertion_id = (
               select id from payout_test_ids where key = 'assertion_review'
             )
               and revision.revision_number = 1
             limit 1
          )
        )
      ),
      '00000000-0000-0000-0000-000000000401',
      10.00,
      'REVIEW-001-CORRECTED'
    )
  ).payout_assertion_status,
  'submitted'::financial_ops.payout_assertion_status,
  'the payout actor can submit one corrected immutable revision'
);

select is(
  (
    financial_ops.record_payout_verification(
      '94000000-0000-0000-0000-000000000402',
      (select id from payout_test_ids where key = 'assertion_review'),
      jsonb_build_object('beneficiary_payout_amount', '185.00'),
      jsonb_build_array('beneficiary_amount_still_mismatched'),
      'payout-evidence-model',
      'v1'
    )
  ).payout_assertion_status,
  'needs_review'::financial_ops.payout_assertion_status,
  'a mismatch after the one correction escalates to manual review'
);

select ok(
  (
    select count(*) = 2
      from financial_ops.payout_assertion_revisions revision
     where revision.payout_assertion_id = (
       select id from payout_test_ids where key = 'assertion_review'
     )
  )
  and (
    select count(*) = 1
      from evidence.financial_evidence item
     where item.storage_object_path = 'payout/review/original.png'
  )
  and (
    select count(*) = 2
      from evidence.verification_attempts attempt
      join financial_ops.payout_assertion_revisions revision
        on revision.id = attempt.payout_assertion_revision_id
     where revision.payout_assertion_id = (
       select id from payout_test_ids where key = 'assertion_review'
     )
  ),
  'correction preserves original facts, evidence reuse, and verification history'
);

select throws_ok(
  format(
    $$select financial_ops.review_payout_assertion(
      '95000000-0000-0000-0000-000000000401',
      %L::uuid,
      'clear',
      'Unassigned actor attempts review',
      '00000000-0000-0000-0000-000000000405'
    )$$,
    (select id from payout_test_ids where key = 'assertion_review')
  ),
  '42501',
  'withdrawal command is not authorized',
  'an active tenant member without reviewer assignment cannot review evidence'
);

select throws_ok(
  format(
    $$select financial_ops.review_payout_assertion(
      '95000000-0000-0000-0000-000000000402',
      %L::uuid,
      'clear',
      'Payout actor attempts self-review',
      '00000000-0000-0000-0000-000000000401'
    )$$,
    (select id from payout_test_ids where key = 'assertion_review')
  ),
  '42501',
  'financial evidence reviewer cannot review their own payout operation',
  'reviewer assignment never permits payout-actor self-review'
);

select is(
  (
    financial_ops.review_payout_assertion(
      '95000000-0000-0000-0000-000000000403',
      (select id from payout_test_ids where key = 'assertion_review'),
      'clear',
      'Evidence supports the corrected payout facts',
      '00000000-0000-0000-0000-000000000404'
    )
  ).withdrawal_status,
  'completed'::financial_ops.withdrawal_status,
  'assigned independent reviewer clearance posts and completes the withdrawal'
);

select is(
  (
    financial_ops.review_payout_assertion(
      '95000000-0000-0000-0000-000000000403',
      (select id from payout_test_ids where key = 'assertion_review'),
      'clear',
      'Evidence supports the corrected payout facts',
      '00000000-0000-0000-0000-000000000404'
    )
  ).reused,
  true,
  'manual evidence-review completion is idempotent'
);

select ok(
  exists (
    select 1
      from financial_ops.withdrawal_requests withdrawal
      join financial_ops.funding_reservations reservation
        on reservation.withdrawal_id = withdrawal.id
      join financial_ops.payout_completion_assertions assertion
        on assertion.withdrawal_id = withdrawal.id
     where withdrawal.id = (
       select id from payout_test_ids where key = 'withdrawal_review'
     )
       and withdrawal.status = 'completed'
       and withdrawal.financial_transaction_id is not null
       and reservation.status = 'consumed'
       and assertion.status = 'posted'
       and assertion.accepted_via = 'manual_clear'
       and assertion.posted_financial_transaction_id
            = withdrawal.financial_transaction_id
  ),
  'manual clearance atomically links the posted transaction and consumes the reservation'
);

select is(
  (
    select projection.balance
      from ledger.wallet_balance_projections projection
     where projection.ledger_account_id = '83000000-0000-0000-0000-000000000401'
  ),
  800.00::numeric,
  'final withdrawal posting reduces the member balance by the authorized Wallet debit'
);

select ok(
  exists (
    select 1
      from ledger.financial_transactions transaction
      join ledger.journal_entries entry
        on entry.financial_transaction_id = transaction.id
      join ledger.journal_postings posting
        on posting.journal_entry_id = entry.id
      join ledger.ledger_accounts account
        on account.id = posting.ledger_account_id
     where transaction.id = (
       select withdrawal.financial_transaction_id
         from financial_ops.withdrawal_requests withdrawal
        where withdrawal.id = (
          select id from payout_test_ids where key = 'withdrawal_review'
        )
     )
     group by transaction.id
    having sum(posting.amount) = 0
       and count(*) = 3
       and bool_or(account.system_account_key = 'provider_fee' and posting.amount = 10.00)
  ),
  'provider fee is explicit in the balanced final withdrawal journal'
);

insert into payout_test_ids (key, id)
select 'withdrawal_match', (
  financial_ops.submit_withdrawal(
    '92000000-0000-0000-0000-000000000404',
    '83000000-0000-0000-0000-000000000401',
    '85000000-0000-0000-0000-000000000401',
    100.00,
    '00000000-0000-0000-0000-000000000402'
  )
).withdrawal_id;

select financial_ops.approve_withdrawal(
  '92000000-0000-0000-0000-000000000405',
  (select id from payout_test_ids where key = 'withdrawal_match'),
  '00000000-0000-0000-0000-000000000401'
);

insert into payout_test_ids (key, id)
select 'assertion_match', (
  financial_ops.submit_payout_assertion(
    '93000000-0000-0000-0000-000000000403',
    (select id from payout_test_ids where key = 'withdrawal_match'),
    100.00,
    100.00,
    'NGN',
    'manual_bank',
    clock_timestamp(),
    jsonb_build_array(
      jsonb_build_object(
        'storage_bucket_id', 'financial-evidence',
        'storage_object_path', 'payout/match/evidence.png',
        'original_filename', 'evidence.png',
        'mime_type', 'image/png',
        'file_size_bytes', '1024',
        'sha256_hex', encode(extensions.digest('match-evidence', 'sha256'), 'hex'),
        'provider', 'manual_bank',
        'observed_at', clock_timestamp()::text
      )
    ),
    '00000000-0000-0000-0000-000000000401'
  )
).payout_assertion_id;

select is(
  (
    financial_ops.record_payout_verification(
      '94000000-0000-0000-0000-000000000403',
      (select id from payout_test_ids where key = 'assertion_match'),
      jsonb_build_object(
        'wallet_debit_amount', '100.00',
        'beneficiary_payout_amount', '100.00',
        'payout_currency', 'NGN'
      ),
      '[]'::jsonb,
      'payout-evidence-model',
      'v1'
    )
  ).payout_assertion_status,
  'posted'::financial_ops.payout_assertion_status,
  'automated evidence match posts the payout without manual review'
);

select is(
  (
    financial_ops.record_payout_verification(
      '94000000-0000-0000-0000-000000000403',
      (select id from payout_test_ids where key = 'assertion_match'),
      jsonb_build_object(
        'wallet_debit_amount', '100.00',
        'beneficiary_payout_amount', '100.00',
        'payout_currency', 'NGN'
      ),
      '[]'::jsonb,
      'payout-evidence-model',
      'v1'
    )
  ).reused,
  true,
  'automated verification result is idempotent'
);

select is(
  (
    select projection.balance
      from ledger.wallet_balance_projections projection
     where projection.ledger_account_id = '83000000-0000-0000-0000-000000000401'
  ),
  700.00::numeric,
  'automated completion posts exactly once'
);

insert into payout_test_ids (key, id)
select 'withdrawal_reject', (
  financial_ops.submit_withdrawal(
    '92000000-0000-0000-0000-000000000406',
    '83000000-0000-0000-0000-000000000401',
    '85000000-0000-0000-0000-000000000401',
    100.00,
    '00000000-0000-0000-0000-000000000402'
  )
).withdrawal_id;

select financial_ops.approve_withdrawal(
  '92000000-0000-0000-0000-000000000407',
  (select id from payout_test_ids where key = 'withdrawal_reject'),
  '00000000-0000-0000-0000-000000000401'
);

insert into payout_test_ids (key, id)
select 'assertion_reject', (
  financial_ops.submit_payout_assertion(
    '93000000-0000-0000-0000-000000000404',
    (select id from payout_test_ids where key = 'withdrawal_reject'),
    100.00,
    100.00,
    'NGN',
    'manual_bank',
    clock_timestamp(),
    jsonb_build_array(
      jsonb_build_object(
        'storage_bucket_id', 'financial-evidence',
        'storage_object_path', 'payout/reject/evidence.png',
        'original_filename', 'evidence.png',
        'mime_type', 'image/png',
        'file_size_bytes', '1024',
        'sha256_hex', encode(extensions.digest('reject-evidence', 'sha256'), 'hex'),
        'provider', 'manual_bank',
        'observed_at', clock_timestamp()::text
      )
    ),
    '00000000-0000-0000-0000-000000000401'
  )
).payout_assertion_id;

select financial_ops.record_payout_verification(
  '94000000-0000-0000-0000-000000000404',
  (select id from payout_test_ids where key = 'assertion_reject'),
  '{}'::jsonb,
  jsonb_build_array('reference_mismatch'),
  'payout-evidence-model'
);

select financial_ops.correct_payout_assertion(
  '93000000-0000-0000-0000-000000000405',
  (select id from payout_test_ids where key = 'assertion_reject'),
  100.00,
  100.00,
  'NGN',
  'manual_bank',
  clock_timestamp(),
  jsonb_build_array(
    jsonb_build_object(
      'existing_evidence_id', (
        select link.evidence_id
          from financial_ops.payout_assertion_evidence link
          join financial_ops.payout_assertion_revisions revision
            on revision.id = link.payout_assertion_revision_id
         where revision.payout_assertion_id = (
           select id from payout_test_ids where key = 'assertion_reject'
         )
           and revision.revision_number = 1
         limit 1
      )
    )
  ),
  '00000000-0000-0000-0000-000000000401'
);

select financial_ops.record_payout_verification(
  '94000000-0000-0000-0000-000000000405',
  (select id from payout_test_ids where key = 'assertion_reject'),
  '{}'::jsonb,
  jsonb_build_array('reference_still_mismatched'),
  'payout-evidence-model'
);

select is(
  (
    financial_ops.review_payout_assertion(
      '95000000-0000-0000-0000-000000000404',
      (select id from payout_test_ids where key = 'assertion_reject'),
      'reject',
      'Evidence does not substantiate the external payout',
      '00000000-0000-0000-0000-000000000404'
    )
  ).payout_assertion_status,
  'rejected'::financial_ops.payout_assertion_status,
  'reviewer rejection closes only the payout assertion'
);

select ok(
  exists (
    select 1
      from financial_ops.withdrawal_requests withdrawal
      join financial_ops.funding_reservations reservation
        on reservation.withdrawal_id = withdrawal.id
     where withdrawal.id = (
       select id from payout_test_ids where key = 'withdrawal_reject'
     )
       and withdrawal.status = 'approved'
       and withdrawal.financial_transaction_id is null
       and reservation.status = 'active'
  ),
  'reviewer rejection preserves the approved funded withdrawal with no ledger effect'
);

select is(
  (
    financial_ops.cancel_withdrawal(
      '92000000-0000-0000-0000-000000000408',
      (select id from payout_test_ids where key = 'withdrawal_reject'),
      '00000000-0000-0000-0000-000000000401',
      'External payout confirmed not to have occurred'
    )
  ).status,
  'cancelled'::financial_ops.withdrawal_status,
  'approved withdrawal may be explicitly cancelled after assertion rejection'
);

select is(
  financial_ops.available_balance(
    '83000000-0000-0000-0000-000000000401'
  ),
  700.00::numeric,
  'rejected evidence and explicit cancellation release the reservation without changing posted balance'
);

select ok(
  exists (
    select 1
      from internal.outbox_events event
     where event.event_type = 'financial_evidence_review_required'
  )
  and exists (
    select 1
      from internal.outbox_events event
     where event.event_type = 'withdrawal_completed'
  ),
  'review escalation and financial completion create transactional outbox events'
);

select throws_ok(
  format(
    $$update evidence.financial_evidence
         set notes = 'rewritten'
       where id = %L::uuid$$,
    (
      select link.evidence_id
        from financial_ops.payout_assertion_evidence link
        join financial_ops.payout_assertion_revisions revision
          on revision.id = link.payout_assertion_revision_id
       where revision.payout_assertion_id = (
         select id from payout_test_ids where key = 'assertion_review'
       )
       limit 1
    )
  ),
  '55000',
  'evidence.financial_evidence is append-only',
  'submitted financial evidence cannot be rewritten'
);

select ok(
  not has_schema_privilege('authenticated', 'evidence', 'usage')
  and not has_schema_privilege('authenticated', 'internal', 'usage'),
  'authenticated clients cannot access evidence or outbox schemas'
);

select ok(
  not has_table_privilege(
    'service_role',
    'evidence.financial_evidence',
    'select'
  )
  and not has_table_privilege(
    'service_role',
    'internal.outbox_events',
    'select'
  ),
  'service role has no direct evidence or outbox table access'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'financial_ops.submit_payout_assertion(uuid,uuid,numeric,numeric,text,text,timestamptz,jsonb,uuid,numeric,text,text,uuid)',
    'execute'
  )
  and not has_function_privilege(
    'service_role',
    'financial_ops.review_payout_assertion(uuid,uuid,evidence.review_decision,text,uuid,uuid)',
    'execute'
  ),
  'payout and review commands are not directly client-accessible'
);

select is(
  (
    select count(*)
      from pg_class relation
      join pg_namespace namespace on namespace.oid = relation.relnamespace
     where namespace.nspname in ('evidence', 'internal')
       and relation.relkind = 'r'
       and relation.relrowsecurity
       and relation.relforcerowsecurity
  ),
  (
    select count(*)
      from pg_class relation
      join pg_namespace namespace on namespace.oid = relation.relnamespace
     where namespace.nspname in ('evidence', 'internal')
       and relation.relkind = 'r'
  ),
  'every evidence and outbox table has RLS enabled and forced'
);

select ok(
  exists (
    select 1
      from authz.security_audit_events event
     where event.event_type = 'payout_evidence_cleared'
       and event.permission_key = 'review_financial_evidence'
  )
  and exists (
    select 1
      from authz.security_audit_events event
     where event.event_type = 'withdrawal_completed'
       and event.permission_key = 'approve_withdrawal'
  ),
  'review and completion decisions are append-only security audit events'
);

select finish();
rollback;
