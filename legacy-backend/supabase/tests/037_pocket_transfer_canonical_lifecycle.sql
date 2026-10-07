begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

create temporary table operation_test_ids (
  key text primary key,
  id uuid not null
);

insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
values
  ('00000000-0000-0000-0000-000000000501', 'authenticated', 'authenticated', 'operations-leader@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000502', 'authenticated', 'authenticated', 'operations-owner@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000503', 'authenticated', 'authenticated', 'operations-president@example.test', '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-0000-0000-000000000504', 'authenticated', 'authenticated', 'operations-reviewer@example.test', '{}'::jsonb, '{}'::jsonb)
on conflict (id) do nothing;

insert into public.user_accounts (user_id)
values
  ('00000000-0000-0000-0000-000000000501'),
  ('00000000-0000-0000-0000-000000000502'),
  ('00000000-0000-0000-0000-000000000503'),
  ('00000000-0000-0000-0000-000000000504');

insert into public.tenants (id, name)
values ('10000000-0000-0000-0000-000000000501', 'Financial Operations Tenant');

insert into public.offices (id, tenant_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000501',
  '10000000-0000-0000-0000-000000000501',
  'world_team',
  'Operations World Team'
);
insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000502',
  '10000000-0000-0000-0000-000000000501',
  '20000000-0000-0000-0000-000000000501',
  'director',
  'Operations Director'
);
insert into public.offices (id, tenant_id, parent_office_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000503',
  '10000000-0000-0000-0000-000000000501',
  '20000000-0000-0000-0000-000000000502',
  'team_leader',
  'Operations Team'
);

insert into public.memberships (
  id, tenant_id, user_id, office_id, role_key, is_primary
)
values
  ('30000000-0000-0000-0000-000000000501', '10000000-0000-0000-0000-000000000501', '00000000-0000-0000-0000-000000000501', '20000000-0000-0000-0000-000000000503', 'team_leader', true),
  ('30000000-0000-0000-0000-000000000502', '10000000-0000-0000-0000-000000000501', '00000000-0000-0000-0000-000000000502', '20000000-0000-0000-0000-000000000503', 'member', true),
  ('30000000-0000-0000-0000-000000000503', '10000000-0000-0000-0000-000000000501', '00000000-0000-0000-0000-000000000503', null, 'president_team_member', true),
  ('30000000-0000-0000-0000-000000000504', '10000000-0000-0000-0000-000000000501', '00000000-0000-0000-0000-000000000504', '20000000-0000-0000-0000-000000000502', 'director', true);

select authz.seed_tenant_role_permissions('10000000-0000-0000-0000-000000000501');

insert into public.wallets (id, owner_user_id)
values ('60000000-0000-0000-0000-000000000502', '00000000-0000-0000-0000-000000000502');

insert into public.pocket_definitions (pocket_key, display_name, sort_order)
values
  ('operations_main', 'Operations Main', 600),
  ('operations_savings', 'Operations Savings', 601);

insert into public.allocation_policy_versions (
  id, tenant_id, version_number, created_by_user_id
)
values (
  '61000000-0000-0000-0000-000000000501',
  '10000000-0000-0000-0000-000000000501',
  1,
  '00000000-0000-0000-0000-000000000503'
);
insert into public.allocation_policy_rules (
  tenant_id, policy_version_id, pocket_key, allocation_basis_points, remainder_rank
)
values
  ('10000000-0000-0000-0000-000000000501', '61000000-0000-0000-0000-000000000501', 'operations_main', 7000, 1),
  ('10000000-0000-0000-0000-000000000501', '61000000-0000-0000-0000-000000000501', 'operations_savings', 3000, 2);
update public.allocation_policy_versions
   set activated_at = clock_timestamp()
 where id = '61000000-0000-0000-0000-000000000501';
insert into public.tenant_active_allocation_policies (
  tenant_id, policy_version_id, activated_by_user_id
)
values (
  '10000000-0000-0000-0000-000000000501',
  '61000000-0000-0000-0000-000000000501',
  '00000000-0000-0000-0000-000000000503'
);

insert into ledger.currency_definitions (currency_code, minor_unit_scale)
values ('NGN', 2), ('USD', 2);

insert into ledger.ledger_accounts (
  id, account_class, currency_code, wallet_id, tenant_id, office_id,
  membership_id, owner_user_id, pocket_key
)
values
  ('83000000-0000-0000-0000-000000000501', 'member_value', 'NGN', '60000000-0000-0000-0000-000000000502', '10000000-0000-0000-0000-000000000501', '20000000-0000-0000-0000-000000000503', '30000000-0000-0000-0000-000000000502', '00000000-0000-0000-0000-000000000502', 'operations_main'),
  ('83000000-0000-0000-0000-000000000502', 'member_value', 'NGN', '60000000-0000-0000-0000-000000000502', '10000000-0000-0000-0000-000000000501', '20000000-0000-0000-0000-000000000503', '30000000-0000-0000-0000-000000000502', '00000000-0000-0000-0000-000000000502', 'operations_savings'),
  ('83000000-0000-0000-0000-000000000503', 'member_value', 'NGN', '60000000-0000-0000-0000-000000000502', '10000000-0000-0000-0000-000000000501', '20000000-0000-0000-0000-000000000503', '30000000-0000-0000-0000-000000000502', '00000000-0000-0000-0000-000000000502', 'debt'),
  ('83000000-0000-0000-0000-000000000504', 'member_value', 'USD', '60000000-0000-0000-0000-000000000502', '10000000-0000-0000-0000-000000000501', '20000000-0000-0000-0000-000000000503', '30000000-0000-0000-0000-000000000502', '00000000-0000-0000-0000-000000000502', 'operations_main');

insert into ledger.ledger_accounts (id, account_class, currency_code, system_account_key)
values
  ('84000000-0000-0000-0000-000000000501', 'system_counter', 'NGN', 'opening_balance'),
  ('84000000-0000-0000-0000-000000000502', 'system_counter', 'NGN', 'income_external'),
  ('84000000-0000-0000-0000-000000000503', 'system_counter', 'NGN', 'fx_clearing'),
  ('84000000-0000-0000-0000-000000000504', 'system_counter', 'USD', 'fx_clearing'),
  ('84000000-0000-0000-0000-000000000505', 'system_counter', 'NGN', 'administrative_adjustment'),
  ('84000000-0000-0000-0000-000000000506', 'system_counter', 'NGN', 'returned_funds_external'),
  ('84000000-0000-0000-0000-000000000507', 'system_counter', 'NGN', 'external_payout'),
  ('84000000-0000-0000-0000-000000000508', 'system_counter', 'NGN', 'provider_fee');

-- Rollback-only synthetic balances; no integration dispatch or live finance.
select ledger.post_transaction('94000000-0000-0000-0000-000000000601',extensions.digest('transfer-test-opening','sha256'),
 'synthetic_opening','30000000-0000-0000-0000-000000000502','60000000-0000-0000-0000-000000000502',
 '00000000-0000-0000-0000-000000000503',
 '[{"currency_code":"NGN","postings":[{"ledger_account_id":"83000000-0000-0000-0000-000000000501","amount":"1000"},
 {"ledger_account_id":"83000000-0000-0000-0000-000000000503","amount":"-50"},
 {"ledger_account_id":"84000000-0000-0000-0000-000000000501","amount":"-950"}]}]');
create function pg_temp.request_transfer(k integer,amount numeric default 10,actor uuid default '00000000-0000-0000-0000-000000000501',destination uuid default '83000000-0000-0000-0000-000000000502')
returns financial_ops.financial_operation_result language sql as $$
 select financial_ops.submit_pocket_transfer(('96000000-0000-0000-0000-'||lpad(k::text,12,'0'))::uuid,
 '83000000-0000-0000-0000-000000000501',destination,amount,actor); $$;
create function pg_temp.approve_transfer(t uuid,k integer,actor uuid default '00000000-0000-0000-0000-000000000501')
returns financial_ops.financial_operation_result language sql as $$
 select financial_ops.approve_pocket_transfer(('97000000-0000-0000-0000-'||lpad(k::text,12,'0'))::uuid,t,actor); $$;
create function pg_temp.assert_sqlstate(q text,expected text) returns boolean language plpgsql as $$
begin execute q; return false; exception when others then return sqlstate=expected; end; $$;

select is(enum_range(null::financial_ops.pocket_transfer_status)::text,'{requested,completed,rejected,cancelled}','terminal enum reconciled without approved intermediate');
select ok(not has_function_privilege('authenticated','financial_ops.submit_pocket_transfer(uuid,uuid,uuid,numeric,uuid,uuid)','EXECUTE')
 and not has_function_privilege('service_role','financial_ops.approve_pocket_transfer(uuid,uuid,uuid,uuid)','EXECUTE'),'private core never exposed directly to client or service role');
insert into operation_test_ids select 'leader',(pg_temp.request_transfer(1)).operation_id;
select is(financial_ops.available_balance('83000000-0000-0000-0000-000000000501'),990::numeric,'on-behalf request reserves exact source');
select is((select balance from ledger.wallet_balance_projections where ledger_account_id='83000000-0000-0000-0000-000000000501'),1000::numeric,'request has no ledger effect');
select is((pg_temp.approve_transfer((select id from operation_test_ids where key='leader'),1)).status,'completed','same scoped initiating leader holding approval may complete member transfer');
select is((select status::text from financial_ops.pocket_transfer_reservations where pocket_transfer_id=(select id from operation_test_ids where key='leader')),'consumed','atomic approval consumes reservation');
select is((select count(*) from ledger.journal_entries where financial_transaction_id=(select financial_transaction_id from financial_ops.pocket_transfer_requests where id=(select id from operation_test_ids where key='leader'))),1::bigint,'completion posts exactly one journal');
select is((select count(*) from ledger.journal_postings p join ledger.journal_entries e on e.id=p.journal_entry_id where e.financial_transaction_id=(select financial_transaction_id from financial_ops.pocket_transfer_requests where id=(select id from operation_test_ids where key='leader'))),2::bigint,'completion has two balanced pocket postings');
select ok((pg_temp.approve_transfer((select id from operation_test_ids where key='leader'),1)).reused,'same original actor and approval key recover completed result');
select ok(pg_temp.assert_sqlstate(format('select pg_temp.approve_transfer(%L::uuid,2)',(select id from operation_test_ids where key='leader')),'23505'),'different completed approval key rejected');
select ok(pg_temp.assert_sqlstate(format('select pg_temp.approve_transfer(%L::uuid,1,%L::uuid)',(select id from operation_test_ids where key='leader'),'00000000-0000-0000-0000-000000000504'),'23505'),'another currently authorized actor cannot replay original approval');
select is((select count(*) from ledger.financial_transactions where transaction_type='pocket_transfer'),1::bigint,'approval retries never duplicate financial posting');
select is((select balance from ledger.wallet_balance_projections where ledger_account_id='83000000-0000-0000-0000-000000000502'),10::numeric,'destination receives exact posted credit');
select ok(exists(select 1 from internal.outbox_events where event_type='pocket_transfer_completed' and aggregate_id=(select id from operation_test_ids where key='leader')),'completed state emits transactional outbox event');

-- Current actor authority is required even for a completed historical request.
update public.memberships set status='suspended' where id='30000000-0000-0000-0000-000000000501';
select ok(pg_temp.assert_sqlstate(format('select pg_temp.approve_transfer(%L::uuid,1)',(select id from operation_test_ids where key='leader')),'42501'),'suspended leader cannot replay completed approval');
select ok(pg_temp.assert_sqlstate('select pg_temp.request_transfer(1)','42501'),'suspended initiator cannot replay request');
update public.memberships set status='active' where id='30000000-0000-0000-0000-000000000501';

-- Even a completed replay must satisfy current step-up and explicit deny precedence.
update authz.permission_catalog set step_up_mode='elevated' where permission_key='approve_pocket_transfer';
select ok(pg_temp.assert_sqlstate(format('select pg_temp.approve_transfer(%L::uuid,1)',(select id from operation_test_ids where key='leader')),'P0401'),'completed replay cannot bypass current required elevation');
update authz.permission_catalog set step_up_mode='none' where permission_key='approve_pocket_transfer';
insert into authz.access_assignments(id,tenant_id,subject_user_id,created_by_user_id,reason)
values('98000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000503','Transfer deny fixture');
insert into authz.access_rules(id,tenant_id,assignment_id,permission_key,effect,scope_type,scope_membership_id)
values('98000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000501','98000000-0000-0000-0000-000000000001','approve_pocket_transfer','deny','member','30000000-0000-0000-0000-000000000502');
select ok(pg_temp.assert_sqlstate(format('select pg_temp.approve_transfer(%L::uuid,1)',(select id from operation_test_ids where key='leader')),'42501'),'explicit deny overrides historical approval result');
update authz.access_rules set revoked_at=clock_timestamp(),revoked_by_user_id='00000000-0000-0000-0000-000000000503' where id='98000000-0000-0000-0000-000000000002';
update authz.tenant_role_permissions set allowed=false where tenant_id='10000000-0000-0000-0000-000000000501' and role_key='team_leader' and permission_key='approve_pocket_transfer';
insert into authz.access_rules(tenant_id,assignment_id,permission_key,effect,scope_type,scope_membership_id,starts_at,expires_at)
values('10000000-0000-0000-0000-000000000501','98000000-0000-0000-0000-000000000001','approve_pocket_transfer','allow','member','30000000-0000-0000-0000-000000000502',clock_timestamp()-interval '2 hours',clock_timestamp()-interval '1 hour');
select ok(pg_temp.assert_sqlstate(format('select pg_temp.approve_transfer(%L::uuid,1)',(select id from operation_test_ids where key='leader')),'42501'),'expired explicit grant cannot recover an old approval');
update authz.tenant_role_permissions set allowed=true where tenant_id='10000000-0000-0000-0000-000000000501' and role_key='team_leader' and permission_key='approve_pocket_transfer';

insert into operation_test_ids select 'owner',(pg_temp.request_transfer(2,10,'00000000-0000-0000-0000-000000000502')).operation_id;
select ok(pg_temp.assert_sqlstate(format('select pg_temp.approve_transfer(%L::uuid,3,%L::uuid)',(select id from operation_test_ids where key='owner'),'00000000-0000-0000-0000-000000000502'),'42501'),'Wallet owner cannot approve own transfer');
select is((select status::text from financial_ops.pocket_transfer_requests where id=(select id from operation_test_ids where key='owner')),'requested','self approval denial leaves requested transfer intact');
select is((financial_ops.reject_pocket_transfer((select id from operation_test_ids where key='owner'),'Insufficient operational approval','00000000-0000-0000-0000-000000000501')).status,'rejected','authorized leader rejects owner request');
select ok((financial_ops.reject_pocket_transfer((select id from operation_test_ids where key='owner'),'Insufficient operational approval','00000000-0000-0000-0000-000000000501')).reused,'same rejection decision idempotent');
select ok(pg_temp.assert_sqlstate(format('select financial_ops.reject_pocket_transfer(%L::uuid,%L,%L::uuid)',(select id from operation_test_ids where key='owner'),'Different reason','00000000-0000-0000-0000-000000000501'),'23505'),'rejected decision cannot be replayed with different reason');

insert into operation_test_ids select 'cancel-owner',(pg_temp.request_transfer(3)).operation_id;
select is((financial_ops.cancel_pocket_transfer((select id from operation_test_ids where key='cancel-owner'),'Owner changed their mind','00000000-0000-0000-0000-000000000502')).status,'cancelled','Wallet owner can cancel leadership initiated transfer');
select is((select status::text from financial_ops.pocket_transfer_reservations where pocket_transfer_id=(select id from operation_test_ids where key='cancel-owner')),'released','owner cancellation releases reservation');
select ok((financial_ops.cancel_pocket_transfer((select id from operation_test_ids where key='cancel-owner'),'Owner changed their mind','00000000-0000-0000-0000-000000000502')).reused,'same original cancellation decision idempotent');
insert into operation_test_ids select 'cancel-leader',(pg_temp.request_transfer(4)).operation_id;
select ok(pg_temp.assert_sqlstate(format('select financial_ops.cancel_pocket_transfer(%L::uuid,%L,%L::uuid)',(select id from operation_test_ids where key='cancel-leader'),'Not requester','00000000-0000-0000-0000-000000000504'),'42501'),'non-initiating leadership cannot cancel another actor request');
select is((financial_ops.cancel_pocket_transfer((select id from operation_test_ids where key='cancel-leader'),'Initiator cancelled','00000000-0000-0000-0000-000000000501')).status,'cancelled','initiating leader can cancel their on-behalf request');
update public.memberships set status='suspended' where id='30000000-0000-0000-0000-000000000502';
select ok(pg_temp.assert_sqlstate(format('select financial_ops.cancel_pocket_transfer(%L::uuid,%L,%L::uuid)',(select id from operation_test_ids where key='cancel-owner'),'Owner changed their mind','00000000-0000-0000-0000-000000000502'),'42501'),'suspended owner cannot replay cancellation');
update public.memberships set status='active' where id='30000000-0000-0000-0000-000000000502';
update public.memberships set status='suspended' where id='30000000-0000-0000-0000-000000000501';
select ok(pg_temp.assert_sqlstate(format('select financial_ops.reject_pocket_transfer(%L::uuid,%L,%L::uuid)',(select id from operation_test_ids where key='owner'),'Insufficient operational approval','00000000-0000-0000-0000-000000000501'),'42501'),'suspended rejector cannot replay terminal decision');
update public.memberships set status='active' where id='30000000-0000-0000-0000-000000000501';

-- Debt is repayable only to zero, and its live deficit is rechecked after account locks.
select ok(pg_temp.assert_sqlstate('select pg_temp.request_transfer(5,51,''00000000-0000-0000-0000-000000000501'',''83000000-0000-0000-0000-000000000503'')','23514'),'Debt overpayment fails at request with no reservation');
select ok(pg_temp.assert_sqlstate('select financial_ops.submit_pocket_transfer(''96000000-0000-0000-0000-000000000006'',''83000000-0000-0000-0000-000000000503'',''83000000-0000-0000-0000-000000000501'',1,''00000000-0000-0000-0000-000000000502'')','23514'),'Debt is never a source');
insert into operation_test_ids select 'debt-first',(pg_temp.request_transfer(7,40,'00000000-0000-0000-0000-000000000501','83000000-0000-0000-0000-000000000503')).operation_id;
insert into operation_test_ids select 'debt-competing',(pg_temp.request_transfer(8,40,'00000000-0000-0000-0000-000000000501','83000000-0000-0000-0000-000000000503')).operation_id;
select is((pg_temp.approve_transfer((select id from operation_test_ids where key='debt-first'),7)).status,'completed','first debt repayment posts');
select is((select balance from ledger.wallet_balance_projections where ledger_account_id='83000000-0000-0000-0000-000000000503'),(-10)::numeric,'Debt deficit decreases exactly');
select ok(pg_temp.assert_sqlstate(format('select pg_temp.approve_transfer(%L::uuid,8)',(select id from operation_test_ids where key='debt-competing')),'23514'),'other pending request cannot post stale larger deficit');
select is((select status::text from financial_ops.pocket_transfer_requests where id=(select id from operation_test_ids where key='debt-competing')),'requested','failed debt approval leaves request and reservation available for cancellation');
select is((select status::text from financial_ops.pocket_transfer_reservations where pocket_transfer_id=(select id from operation_test_ids where key='debt-competing')),'active','failed debt approval has no partial reservation effect');
select financial_ops.cancel_pocket_transfer((select id from operation_test_ids where key='debt-competing'),'Deficit changed','00000000-0000-0000-0000-000000000502');
insert into operation_test_ids select 'debt-zero',(pg_temp.request_transfer(9,10,'00000000-0000-0000-0000-000000000501','83000000-0000-0000-0000-000000000503')).operation_id;
select is((pg_temp.approve_transfer((select id from operation_test_ids where key='debt-zero'),9)).status,'completed','exact remaining deficit can be repaid');
select is((select balance from ledger.wallet_balance_projections where ledger_account_id='83000000-0000-0000-0000-000000000503'),0::numeric,'Debt repayment stops at zero');
select ok(pg_temp.assert_sqlstate('select pg_temp.request_transfer(10,1,''00000000-0000-0000-0000-000000000501'',''83000000-0000-0000-0000-000000000503'')','23514'),'Debt at zero cannot receive ordinary transfer');
select ok(pg_temp.assert_sqlstate('select pg_temp.request_transfer(11,1,''00000000-0000-0000-0000-000000000501'',''83000000-0000-0000-0000-000000000504'')','23514'),'cross currency is excluded');

-- Same global Wallet does not permit moving value across membership/office provenance.
insert into public.memberships(id,tenant_id,user_id,office_id,role_key,is_primary)
values('30000000-0000-0000-0000-000000000505','10000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000502','20000000-0000-0000-0000-000000000502','director',false);
insert into ledger.ledger_accounts(id,account_class,currency_code,wallet_id,tenant_id,office_id,membership_id,owner_user_id,pocket_key)
values('83000000-0000-0000-0000-000000000505','member_value','NGN','60000000-0000-0000-0000-000000000502','10000000-0000-0000-0000-000000000501','20000000-0000-0000-0000-000000000502','30000000-0000-0000-0000-000000000505','00000000-0000-0000-0000-000000000502','operations_savings');
select ok(pg_temp.assert_sqlstate('select pg_temp.request_transfer(16,1,''00000000-0000-0000-0000-000000000501'',''83000000-0000-0000-0000-000000000505'')','23514'),'same Wallet but different membership and office cannot transfer');

-- Multiple open requests are allowed, but their source reservations serialize against overdraw.
insert into operation_test_ids select 'large-first',(pg_temp.request_transfer(12,600)).operation_id;
insert into operation_test_ids select 'large-second',(pg_temp.request_transfer(13,300)).operation_id;
select ok(pg_temp.assert_sqlstate('select pg_temp.request_transfer(14,41)','23514'),'combined pending source reservations prevent overspend');
select is((select count(*) from financial_ops.pocket_transfer_requests where status='requested'),2::bigint,'multiple sufficiently funded open transfers allowed');
select is(financial_ops.available_balance('83000000-0000-0000-0000-000000000501'),40::numeric,'availability subtracts every pending source reservation');
select ok(pg_temp.assert_sqlstate(format('update financial_ops.pocket_transfer_requests set status=''completed'' where id=%L::uuid',(select id from operation_test_ids where key='large-first')),'55000'),'direct lifecycle write remains prohibited');
select ok(pg_temp.assert_sqlstate(format('select pg_temp.approve_transfer(%L::uuid,15)',(select id from operation_test_ids where key='cancel-owner')),'55000'),'cancelled request cannot later post');
select is((select count(*) from ledger.financial_transactions where transaction_type='pocket_transfer'),3::bigint,'denials and cancellations never add a financial transaction');
select * from finish();
rollback;
