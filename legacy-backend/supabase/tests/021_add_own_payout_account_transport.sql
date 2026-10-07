begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(43);

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


-- Additional users distinguish another owner, a President, and a member with no Wallet.
insert into auth.users(id,email) values
 ('00000000-0000-0000-0000-000000000502','other-payout-owner@example.test'),
 ('00000000-0000-0000-0000-000000000503','payout-president@example.test'),
 ('00000000-0000-0000-0000-000000000504','payout-no-wallet@example.test');
insert into public.user_accounts(user_id) values
 ('00000000-0000-0000-0000-000000000502'),
 ('00000000-0000-0000-0000-000000000503'),
 ('00000000-0000-0000-0000-000000000504');
insert into public.memberships(id,tenant_id,user_id,office_id,role_key) values
 ('30000000-0000-0000-0000-000000000502','10000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000502','20000000-0000-0000-0000-000000000503','member'),
 ('30000000-0000-0000-0000-000000000503','10000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000503',null,'president_team_member'),
 ('30000000-0000-0000-0000-000000000504','10000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000504','20000000-0000-0000-0000-000000000503','member');
select set_config('request.jwt.claim.sub','',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);

-- Invoker helper only assembles test input; it grants no production authority.
create function pg_temp.add_account(patch jsonb default '{}') returns jsonb
language sql security invoker as $$
 with input as (select jsonb_build_object(
 'key','91000000-0000-0000-0000-000000000501',
 'actor','00000000-0000-0000-0000-000000000501',
 'session','70000000-0000-0000-0000-000000000501',
 'membership','30000000-0000-0000-0000-000000000501',
 'country','NG','currency','NGN','rail','bank_transfer','code','999',
 'institution','Test Bank','reference','0123456789','holder','Payout Owner'
 ) || patch as body)
 select public.add_own_payout_account(
 (body->>'key')::uuid,(body->>'actor')::uuid,(body->>'session')::uuid,(body->>'membership')::uuid,
 body->>'country',body->>'currency',body->>'rail',body->>'code',body->>'institution',body->>'reference',body->>'holder'
 ) from input;
$$;

select is(has_function_privilege('anon','public.add_own_payout_account(uuid,uuid,uuid,uuid,text,text,text,text,text,text,text)','EXECUTE'),false,'anon has only intended transport access');

select is(has_function_privilege('authenticated','public.add_own_payout_account(uuid,uuid,uuid,uuid,text,text,text,text,text,text,text)','EXECUTE'),false,'authenticated has only intended transport access');

select is(has_function_privilege('service_role','public.add_own_payout_account(uuid,uuid,uuid,uuid,text,text,text,text,text,text,text)','EXECUTE'),true,'service_role has only intended transport access');

select is(has_function_privilege('anon','financial_ops.add_payout_account(uuid,uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,boolean)','EXECUTE'),false,'anon cannot execute private add directly');

select is(has_table_privilege('anon','financial_ops.payout_accounts','INSERT'),false,'anon has no private payout INSERT grant');

select is(has_function_privilege('authenticated','financial_ops.add_payout_account(uuid,uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,boolean)','EXECUTE'),false,'authenticated cannot execute private add directly');

select is(has_table_privilege('authenticated','financial_ops.payout_accounts','INSERT'),false,'authenticated has no private payout INSERT grant');

select is(has_function_privilege('service_role','financial_ops.add_payout_account(uuid,uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,boolean)','EXECUTE'),false,'service_role cannot execute private add directly');

select is(has_table_privilege('service_role','financial_ops.payout_accounts','INSERT'),false,'service_role has no private payout INSERT grant');

set local role anon;

select throws_ok($q$select pg_temp.add_account('{}')$q$,'42501',null,'anon cannot invoke wrapper');
reset role;

set local role authenticated;

select throws_ok($q$select pg_temp.add_account('{}')$q$,'42501',null,'authenticated cannot invoke wrapper');
reset role;
set local role service_role;

select throws_ok($q$select pg_temp.add_account('{"membership":"30000000-0000-0000-0000-000000000502"}'::jsonb)$q$,'42501',null,'another owner membership is rejected');

select throws_ok($q$select pg_temp.add_account('{"membership":"30000000-0000-0000-0000-000000000599"}'::jsonb)$q$,'42501',null,'nonexistent membership is rejected');

select throws_ok($q$select pg_temp.add_account('{"membership":"30000000-0000-0000-0000-000000000503","actor":"00000000-0000-0000-0000-000000000503"}'::jsonb)$q$,'42501',null,'President cannot add a personal payout account');

select throws_ok($q$select pg_temp.add_account('{"membership":"30000000-0000-0000-0000-000000000504","actor":"00000000-0000-0000-0000-000000000504"}'::jsonb)$q$,'42501',null,'member without a wallet is rejected');

select throws_ok($q$select pg_temp.add_account('{"session":null}'::jsonb)$q$,'P0401',null,'missing step-up has its own stable error');

select throws_ok($q$select pg_temp.add_account('{"session":"70000000-0000-0000-0000-000000000599"}'::jsonb)$q$,'P0401',null,'unknown step-up session is rejected');

select throws_ok($q$select pg_temp.add_account('{"currency":"ZZZ"}'::jsonb)$q$,'22023',null,'unconfigured currency is rejected without seeding');

select throws_ok($q$select pg_temp.add_account('{"country":"ng"}'::jsonb)$q$,'22023',null,'invalid country code is rejected');

select throws_ok($q$select pg_temp.add_account('{"reference":null}'::jsonb)$q$,'22023',null,'null payout reference is rejected');

select throws_ok($q$select pg_temp.add_account('{"reference":"line\nbreak"}'::jsonb)$q$,'22023',null,'control characters are rejected');

select throws_ok($q$select pg_temp.add_account(jsonb_build_object('holder',repeat('x',161)))$q$,'22023',null,'oversized account holder is rejected');

select is(pg_temp.add_account()->>'status','active','authorized own-wallet save succeeds through service-only wrapper');

select is(pg_temp.add_account()->>'replayed','true','same command retries return existing result');

select is(pg_temp.add_account()->>'verification_status','pending','save does not invent verification');

select throws_ok($q$select pg_temp.add_account('{"reference":"9876543210"}'::jsonb)$q$,'23505',null,'changed details with same key are rejected');
reset role;

select is((select count(*) from financial_ops.payout_accounts where owner_user_id='00000000-0000-0000-0000-000000000501'),1::bigint,'retries create only one account');

select is((select is_primary from financial_ops.payout_accounts where owner_user_id='00000000-0000-0000-0000-000000000501'),false,'pending account is not made primary');

select is((select count(*) from authz.security_audit_events where event_type='payout_account_added' and actor_user_id='00000000-0000-0000-0000-000000000501'),1::bigint,'one security audit event survives retries');

select is((select count(*) from internal.outbox_events where event_type='payout_account_added' and tenant_id='10000000-0000-0000-0000-000000000501'),1::bigint,'one notification outbox event survives retries');

select ok(not exists(select 1 from internal.outbox_events where event_type='payout_account_added' and payload::text like '%0123456789%'),'notification payload does not reveal bank reference');

select ok(not exists(select 1 from authz.security_audit_events where event_type='payout_account_added' and metadata::text like '%0123456789%'),'audit metadata does not reveal bank reference');
set local role service_role;

select is(read_api.member_payout_accounts('00000000-0000-0000-0000-000000000501')->'items'->0->>'account_reference_masked','******6789','member read returns masked destination');

select is(read_api.member_payout_accounts('00000000-0000-0000-0000-000000000501')->'items'->0->>'verification_status','pending','member read truthfully shows pending verification');
select ok(read_api.member_payout_accounts('00000000-0000-0000-0000-000000000501')->'supported_currencies' @> '[{"currency_code":"NGN","minor_unit_scale":2}]'::jsonb,'configured currency is exposed without fabricated catalogue entries');
select is(read_api.member_payout_accounts('00000000-0000-0000-0000-000000000501')->'items'->0->>'account_reference',null::text,'member read never includes the full account reference');

reset role;
update public.user_accounts set status='suspended' where user_id='00000000-0000-0000-0000-000000000501';
set local role service_role;

select throws_ok($q$select pg_temp.add_account('{}')$q$,'42501',null,'inactive account blocks even successful-command replay');
reset role;
update public.user_accounts set status='active' where user_id='00000000-0000-0000-0000-000000000501';
update public.memberships set status='suspended' where id='30000000-0000-0000-0000-000000000501';
set local role service_role;

select throws_ok($q$select pg_temp.add_account('{}')$q$,'42501',null,'inactive membership blocks even successful-command replay');
reset role;
update public.memberships set status='active' where id='30000000-0000-0000-0000-000000000501';
update public.tenants set status='suspended' where id='10000000-0000-0000-0000-000000000501';
set local role service_role;

select throws_ok($q$select pg_temp.add_account('{}')$q$,'42501',null,'inactive tenant blocks even successful-command replay');
reset role;
update public.tenants set status='active' where id='10000000-0000-0000-0000-000000000501';
update public.offices set status='closed' where id='20000000-0000-0000-0000-000000000503';
set local role service_role;

select throws_ok($q$select pg_temp.add_account('{}')$q$,'42501',null,'inactive office blocks even successful-command replay');
reset role;
update public.offices set status='active' where id='20000000-0000-0000-0000-000000000503';
update authz.elevated_sessions set revoked_at=clock_timestamp() where session_id='70000000-0000-0000-0000-000000000501';
set local role service_role;

select throws_ok($q$select pg_temp.add_account('{}')$q$,'P0401',null,'revoked elevation blocks successful-command replay');
reset role;
update authz.elevated_sessions set revoked_at=null where session_id='70000000-0000-0000-0000-000000000501';
-- Trusted transport supplies the verified actor; a mismatched JWT is still rejected.
select set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000502","role":"service_role"}',true);
set local role service_role;
select throws_ok($q$select pg_temp.add_account('{}')$q$,'42501',null,'JWT actor mismatch is rejected before replay');
reset role;

select is((select count(*) from financial_ops.payout_accounts where owner_user_id='00000000-0000-0000-0000-000000000501'),1::bigint,'rejected replays preserve existing payout history');

select * from finish();
rollback;
