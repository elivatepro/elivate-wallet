begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select no_plan();

insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
values (
  '00000000-0000-0000-0000-000000000501',
  'authenticated',
  'authenticated',
  'payout-account-owner@example.test',
  '{}'::jsonb,
  '{}'::jsonb
);

insert into public.user_accounts (user_id)
values ('00000000-0000-0000-0000-000000000501');

insert into public.tenants (id, name)
values ('10000000-0000-0000-0000-000000000501', 'Payout Account Tenant');

insert into public.offices (id, tenant_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000501',
  '10000000-0000-0000-0000-000000000501',
  'world_team',
  'Payout Account World Team'
);

insert into public.offices (
  id, tenant_id, parent_office_id, office_type, name
)
values (
  '20000000-0000-0000-0000-000000000502',
  '10000000-0000-0000-0000-000000000501',
  '20000000-0000-0000-0000-000000000501',
  'director',
  'Payout Account Director'
);

insert into public.offices (
  id, tenant_id, parent_office_id, office_type, name
)
values (
  '20000000-0000-0000-0000-000000000503',
  '10000000-0000-0000-0000-000000000501',
  '20000000-0000-0000-0000-000000000502',
  'team_leader',
  'Payout Account Team'
);

insert into public.memberships (
  id, tenant_id, user_id, office_id, role_key, is_primary
)
values (
  '30000000-0000-0000-0000-000000000501',
  '10000000-0000-0000-0000-000000000501',
  '00000000-0000-0000-0000-000000000501',
  '20000000-0000-0000-0000-000000000503',
  'member',
  true
);

insert into public.wallets (id, owner_user_id)
values (
  '60000000-0000-0000-0000-000000000501',
  '00000000-0000-0000-0000-000000000501'
);

insert into ledger.currency_definitions (currency_code, minor_unit_scale)
values ('NGN', 2);

with session_times as (
  select clock_timestamp() as verified_at
)
insert into authz.elevated_sessions (
  session_id, user_id, verified_at, valid_until, factor_method
)
select
  '70000000-0000-0000-0000-000000000501',
  '00000000-0000-0000-0000-000000000501',
  verified_at,
  verified_at + interval '5 minutes',
  'test_mfa'
from session_times;

-- A verified elevation is tied to a real Auth session.
insert into auth.sessions(id,user_id,aal,created_at,updated_at)
select session_id,user_id,'aal2',verified_at,verified_at from authz.elevated_sessions
on conflict (id) do nothing;

select is(
  (financial_ops.add_payout_account(
    '91000000-0000-0000-0000-000000000501',
    '00000000-0000-0000-0000-000000000501',
    '70000000-0000-0000-0000-000000000501',
    '10000000-0000-0000-0000-000000000501',
    '60000000-0000-0000-0000-000000000501',
    'NG', 'NGN', 'bank_transfer', '999', 'Test Bank',
    '0123456789', 'Payout Account Owner', true
  )).status,
  'active'::financial_ops.payout_account_status,
  'add creates an active payout-account record'
);

select is(
  (
    select count(*)
      from financial_ops.payout_accounts
     where wallet_id = '60000000-0000-0000-0000-000000000501'
       and is_primary
       and verification_status = 'pending'
  ),
  1::bigint,
  'new payout account can be selected as the primary destination before verification'
);

select is(
  (financial_ops.add_payout_account(
    '91000000-0000-0000-0000-000000000501',
    '00000000-0000-0000-0000-000000000501',
    '70000000-0000-0000-0000-000000000501',
    '10000000-0000-0000-0000-000000000501',
    '60000000-0000-0000-0000-000000000501',
    'NG', 'NGN', 'bank_transfer', '999', 'Test Bank',
    '0123456789', 'Payout Account Owner', true
  )).reused,
  true,
  'same add idempotency key reuses the original account'
);

select throws_ok(
  $$select financial_ops.add_payout_account(
    '91000000-0000-0000-0000-000000000501',
    '00000000-0000-0000-0000-000000000501',
    '70000000-0000-0000-0000-000000000501',
    '10000000-0000-0000-0000-000000000501',
    '60000000-0000-0000-0000-000000000501',
    'NG', 'NGN', 'bank_transfer', '999', 'Test Bank',
    'different-reference', 'Payout Account Owner', true
  )$$,
  '23505',
  'idempotency key already used with different payout-account data',
  'conflicting add replay is rejected'
);

select throws_ok(
  $$select financial_ops.set_primary_payout_account(
      '92000000-0000-0000-0000-000000000502',
      '00000000-0000-0000-0000-000000000501',
      '70000000-0000-0000-0000-000000000501',
      '10000000-0000-0000-0000-000000000501',
      (
        select id from financial_ops.payout_accounts
         where wallet_id = '60000000-0000-0000-0000-000000000501'
      )
    )$$,
  '23514',
  'only an active verified payout account may become primary',
  'unverified account promotion is blocked'
);

insert into financial_ops.payout_accounts (
  id, wallet_id, owner_user_id, country_code, payout_currency, payout_rail,
  institution_code, institution_name, account_reference, account_holder_name,
  verification_status, verification_method, verified_at, created_at
)
values (
  '85000000-0000-0000-0000-000000000501',
  '60000000-0000-0000-0000-000000000501',
  '00000000-0000-0000-0000-000000000501',
  'NG', 'NGN', 'bank_transfer', '999', 'Verified Bank',
  '0123456788', 'Payout Account Owner', 'verified', 'manual_test_verification',
  clock_timestamp(), clock_timestamp() - interval '1 second'
);

select is(
  (
    financial_ops.set_primary_payout_account(
      '92000000-0000-0000-0000-000000000503',
      '00000000-0000-0000-0000-000000000501',
      '70000000-0000-0000-0000-000000000501',
      '10000000-0000-0000-0000-000000000501',
      '85000000-0000-0000-0000-000000000501'
    )
  ).status,
  'active'::financial_ops.payout_account_status,
  'verified account can become primary'
);

select is(
  (
    financial_ops.deactivate_payout_account(
      '93000000-0000-0000-0000-000000000501',
      '00000000-0000-0000-0000-000000000501',
      '70000000-0000-0000-0000-000000000501',
      '10000000-0000-0000-0000-000000000501',
      '85000000-0000-0000-0000-000000000501'
    )
  ).status,
  'deactivated'::financial_ops.payout_account_status,
  'deactivation preserves the record and removes primary status'
);

select is(
  (
    financial_ops.replace_payout_account(
      '94000000-0000-0000-0000-000000000501',
      '00000000-0000-0000-0000-000000000501',
      '70000000-0000-0000-0000-000000000501',
      '10000000-0000-0000-0000-000000000501',
      (
        select id from financial_ops.payout_accounts
         where wallet_id = '60000000-0000-0000-0000-000000000501'
           and status = 'active'
         order by created_at
         limit 1
      ),
      'NG', 'NGN', 'bank_transfer', '999', 'Replacement Bank',
      '0123456787', 'Payout Account Owner', true
    )
  ).status,
  'active'::financial_ops.payout_account_status,
  'replacement creates a new active destination'
);

select is(
  (
    select count(*)
      from financial_ops.payout_accounts
     where status = 'replaced'
       and replaced_by_account_id is not null
  ),
  1::bigint,
  'replacement keeps the old payout account as historical evidence'
);

select throws_ok(
  $$select financial_ops.add_payout_account(
      '91000000-0000-0000-0000-000000000502',
      '00000000-0000-0000-0000-000000000501',
      null,
      '10000000-0000-0000-0000-000000000501',
      '60000000-0000-0000-0000-000000000501',
      'NG', 'NGN', 'bank_transfer', '999', 'Test Bank',
      '0123456788', 'Payout Account Owner', false
    )$$,
  '22023',
  'payout-account input is invalid',
  'missing elevated session is rejected before mutation'
);

select is(
  (
    select count(*)
      from authz.security_audit_events
     where tenant_id = '10000000-0000-0000-0000-000000000501'
       and event_type = 'payout_account_added'
  ),
  1::bigint,
  'payout-account add writes one security audit event'
);

select is(
  (
    select count(*)
      from internal.outbox_events
     where tenant_id = '10000000-0000-0000-0000-000000000501'
       and aggregate_type = 'payout_account'
       and event_type = 'payout_account_added'
  ),
  1::bigint,
  'payout-account add writes one post-commit outbox event'
);

set local role service_role;
select is((command_api.deactivate_payout_account('93000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501','70000000-0000-0000-0000-000000000501','10000000-0000-0000-0000-000000000501','85000000-0000-0000-0000-000000000501')).reused,true,'deactivated account can be retried by currently authorized owner');
reset role;
update authz.elevated_sessions set revoked_at=clock_timestamp() where session_id='70000000-0000-0000-0000-000000000501';
set local role service_role;
select throws_ok($$select command_api.deactivate_payout_account('93000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501','70000000-0000-0000-0000-000000000501','10000000-0000-0000-0000-000000000501','85000000-0000-0000-0000-000000000501')$$,'42501',null,'revoked elevation cannot replay payout deactivation');
reset role;

select * from finish();
rollback;
