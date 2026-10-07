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




select financial_ops.record_income(
 '91000000-0000-0000-0000-000000000501',
 '30000000-0000-0000-0000-000000000502','NGN',1000,
 jsonb_build_array(jsonb_build_object('storage_bucket_id','financial-evidence',
 'storage_object_path','transfer-test/receipt.png','original_filename','receipt.png',
 'mime_type','image/png','file_size_bytes','1024','sha256_hex',repeat('a',64),
 'observed_at',clock_timestamp()::text,'provider','manual')),
 '00000000-0000-0000-0000-000000000501'
);

create temporary table transfer_results (key text primary key,result financial_ops.financial_operation_result);
insert into transfer_results
select 'transfer-'||n,command_api.submit_pocket_transfer(
 ('92000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
 '00000000-0000-0000-0000-000000000502',null,null,
 '83000000-0000-0000-0000-000000000501','83000000-0000-0000-0000-000000000502',1
) from generate_series(1,57) n;

create temporary table transfer_pages(key text primary key,data jsonb);
insert into transfer_pages values('first',read_api.pocket_transfers(
 '00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503'));
insert into transfer_pages select 'second',read_api.pocket_transfers(
 '00000000-0000-0000-0000-000000000503','30000000-0000-0000-0000-000000000503',null,
 (data->'next_cursor'->>'created_at')::timestamptz,(data->'next_cursor'->>'transfer_id')::uuid)
 from transfer_pages where key='first';
select is(jsonb_array_length((select data from transfer_pages where key='first')->'items'),50,'first page contains fifty authorized transfers');
select is(jsonb_array_length((select data from transfer_pages where key='second')->'items'),7,'cursor reaches all remaining transfers');
select ok((select data->'next_cursor'='null'::jsonb from transfer_pages where key='second'),'last cursor is null');
select ok(not exists(select 1 from transfer_pages a,transfer_pages b,
 jsonb_array_elements(a.data->'items') first,jsonb_array_elements(b.data->'items') second
 where a.key='first' and b.key='second' and first->>'transfer_id'=second->>'transfer_id'),'transfer pages never duplicate rows');
select is(jsonb_array_length(read_api.pocket_transfers('00000000-0000-0000-0000-000000000502')->'items'),50,'owner can read own personal transfer queue');
select throws_ok($$select read_api.pocket_transfers('00000000-0000-0000-0000-000000000502','30000000-0000-0000-0000-000000000501')$$,
 '42501','transfer is outside your selected workspace','another actor membership never conveys selected scope');
select throws_ok($$select read_api.pocket_transfers('00000000-0000-0000-0000-000000000502','30000000-0000-0000-0000-000000000502')$$,
 '42501','transfer is outside your selected workspace','ordinary membership is not a leadership transfer workspace');
select throws_ok($$select read_api.pocket_transfers('00000000-0000-0000-0000-000000000502',null,'approved')$$,
 '22023','transfer query is invalid','approved is not a transfer terminal or intermediate state');
select throws_ok($$select read_api.pocket_transfers('00000000-0000-0000-0000-000000000502',null,null,clock_timestamp(),null)$$,
 '22023','transfer query is invalid','incomplete transfer cursor denied');

insert into transfer_pages values('choices',read_api.pocket_transfer_choices('00000000-0000-0000-0000-000000000502'));
select ok(not exists(select 1 from jsonb_array_elements((select data from transfer_pages where key='choices')->'items') item
 where item->>'source_ledger_account_id'='83000000-0000-0000-0000-000000000503'),'Debt never offered as source');
select ok(exists(select 1 from jsonb_array_elements((select data from transfer_pages where key='choices')->'items') item
 where item->>'source_ledger_account_id'='83000000-0000-0000-0000-000000000501'
 and (item->>'available_balance')::numeric=643),'choices include exact balance after all transfer reservations');
select ok(not exists(select 1 from jsonb_array_elements((select data from transfer_pages where key='choices')->'items') item,
 jsonb_array_elements(item->'destinations') destination
 where item->>'source_ledger_account_id'='83000000-0000-0000-0000-000000000501'
 and destination->>'destination_ledger_account_id'='83000000-0000-0000-0000-000000000504'),'source destinations never cross currency');
select ok(exists(select 1 from jsonb_array_elements((select data from transfer_pages where key='choices')->'items') item,
 jsonb_array_elements(item->'destinations') destination
 where destination->>'pocket_key'='debt' and (destination->>'maximum_amount')::numeric=0),'Debt at zero has zero receiving capacity');
select is(jsonb_array_length(read_api.pocket_transfer_choices('00000000-0000-0000-0000-000000000501',
 '30000000-0000-0000-0000-000000000501')->'items'),2,'authorized leader sees only target own-context source choices');

select ok((command_api.submit_pocket_transfer('92000000-0000-0000-0000-000000000001',
 '00000000-0000-0000-0000-000000000502',null,null,
 '83000000-0000-0000-0000-000000000501','83000000-0000-0000-0000-000000000502',1)).reused,'same-key request returns original durable result');
select throws_ok($$select command_api.submit_pocket_transfer('92000000-0000-0000-0000-000000000001',
 '00000000-0000-0000-0000-000000000502',null,null,
 '83000000-0000-0000-0000-000000000501','83000000-0000-0000-0000-000000000502',2)$$,
 '23505','transfer key already belongs to another command','changed amount cannot reuse key');
select throws_ok($$select command_api.submit_pocket_transfer('93000000-0000-0000-0000-000000000001',
 '00000000-0000-0000-0000-000000000501',null,null,
 '83000000-0000-0000-0000-000000000501','83000000-0000-0000-0000-000000000502',1)$$,
 '42501','personal transfers require your own Wallet','service wrapper cannot turn personal route into on-behalf transfer');

insert into transfer_results select 'approved',command_api.approve_pocket_transfer(
 '94000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000501',null,
 '30000000-0000-0000-0000-000000000501',(result).operation_id)
 from transfer_results where key='transfer-1';
select is((select (result).status from transfer_results where key='approved'),'completed','approval atomically returns completed');
select ok((command_api.approve_pocket_transfer('94000000-0000-0000-0000-000000000001',
 '00000000-0000-0000-0000-000000000501',null,'30000000-0000-0000-0000-000000000501',
 (select (result).operation_id from transfer_results where key='transfer-1'))).reused,'approval replay uses original key');
select ok(not (command_api.cancel_pocket_transfer('95000000-0000-0000-0000-000000000001',
 '00000000-0000-0000-0000-000000000502',null,null,
 (select (result).operation_id from transfer_results where key='transfer-2'),'Changed plan')).reused,'owner cancels requested transfer');
select ok((command_api.cancel_pocket_transfer('95000000-0000-0000-0000-000000000001',
 '00000000-0000-0000-0000-000000000502',null,null,
 (select (result).operation_id from transfer_results where key='transfer-2'),'Changed plan')).reused,'cancellation replays durable same result');
select throws_ok(format('select command_api.cancel_pocket_transfer(%L,%L,null,null,%L,%L)',
 '95000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000502',
 (select (result).operation_id from transfer_results where key='transfer-2'),'Different reason'),
 '23505','transfer key already belongs to another command','cancel same-key changed reason rejected');
update public.memberships set status='suspended' where id='30000000-0000-0000-0000-000000000501';
select throws_ok(format('select command_api.approve_pocket_transfer(%L,%L,null,%L,%L)',
 '94000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000501',
 '30000000-0000-0000-0000-000000000501',(select (result).operation_id from transfer_results where key='transfer-1')),
 '42501','transfer is outside your selected workspace','suspended selected membership denies committed replay');

-- The selected Office A remains the native boundary; individual surviving grants
-- extend only their named permission to sibling Office B.
insert into public.offices(id,tenant_id,parent_office_id,office_type,name)
values('20000000-0000-0000-0000-000000000504','10000000-0000-0000-0000-000000000501',
 '20000000-0000-0000-0000-000000000501','director','Selected sibling Office A');
insert into public.memberships(id,tenant_id,user_id,office_id,role_key,is_primary)
values('30000000-0000-0000-0000-000000000506','10000000-0000-0000-0000-000000000501',
 '00000000-0000-0000-0000-000000000504','20000000-0000-0000-0000-000000000504','director',false);
create function pg_temp.cross_queue(p_status text default null,p_search text default null)
returns jsonb language sql as $$
 select read_api.pocket_transfers('00000000-0000-0000-0000-000000000504',
  '30000000-0000-0000-0000-000000000506',p_status,null,null,null,p_search)
$$;
create function pg_temp.cross_choices() returns jsonb language sql as $$
 select read_api.pocket_transfer_choices('00000000-0000-0000-0000-000000000504',
  '30000000-0000-0000-0000-000000000506')
$$;
create function pg_temp.cross_approve() returns financial_ops.financial_operation_result language sql as $$
 select command_api.approve_pocket_transfer('96000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000504',null,'30000000-0000-0000-0000-000000000506',
  (select (result).operation_id from transfer_results where key='transfer-3'))
$$;
create function pg_temp.cross_submit() returns financial_ops.financial_operation_result language sql as $$
 select command_api.submit_pocket_transfer('96000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000504',null,'30000000-0000-0000-0000-000000000506',
  '83000000-0000-0000-0000-000000000501','83000000-0000-0000-0000-000000000502',1)
$$;
create function pg_temp.transfer_sqlstate(p_query text,p_expected text) returns boolean language plpgsql as $$
begin execute p_query; return false; exception when others then return sqlstate=p_expected; end;
$$;
select is((authz.authorize('00000000-0000-0000-0000-000000000504',null,'approve_pocket_transfer',
 '10000000-0000-0000-0000-000000000501','20000000-0000-0000-0000-000000000503',
 '30000000-0000-0000-0000-000000000502','00000000-0000-0000-0000-000000000502',
 '60000000-0000-0000-0000-000000000502','00000000-0000-0000-0000-000000000502')).source::text,
 'role_policy','other active membership has native Office B authority');
select is(jsonb_array_length(pg_temp.cross_queue()->'items'),0,'unrelated membership role authority cannot be borrowed into selected Office A');
select is(jsonb_array_length(pg_temp.cross_choices()->'items'),0,'selected Office A cannot borrow Office B source choices');
select ok(pg_temp.transfer_sqlstate('select pg_temp.cross_approve()','42501'),'outside native role-policy approval is denied');
insert into authz.access_assignments(id,tenant_id,subject_user_id,created_by_user_id,reason)
values('98000000-0000-0000-0000-000000000010','10000000-0000-0000-0000-000000000501',
 '00000000-0000-0000-0000-000000000504','00000000-0000-0000-0000-000000000503','Sibling transfer grant fixture');
insert into authz.access_rules(id,tenant_id,assignment_id,permission_key,effect,scope_type,scope_membership_id,starts_at)
values('98000000-0000-0000-0000-000000000011','10000000-0000-0000-0000-000000000501',
 '98000000-0000-0000-0000-000000000010','approve_pocket_transfer','allow','member',
 '30000000-0000-0000-0000-000000000502',clock_timestamp()-interval '2 hours');
update authz.tenant_role_permissions set allowed=false where tenant_id='10000000-0000-0000-0000-000000000501'
 and role_key='director' and permission_key in ('approve_pocket_transfer','transfer_between_pockets_on_behalf','view_scoped_financial_reports');
select is(jsonb_array_length(pg_temp.cross_queue()->'items'),50,'explicit sibling grant exposes authorized paginated queue');
select ok((pg_temp.cross_queue()->'items'->0->'capabilities'->>'approve')::boolean,'approval grant offers approval');
select is(pg_temp.cross_queue()->'items'->0->'capabilities'->>'cancel','false','approval grant does not offer initiation or cancellation');
select is(jsonb_array_length(pg_temp.cross_choices()->'items'),0,'approval-only grant never offers source choices');
select ok(pg_temp.transfer_sqlstate('select pg_temp.cross_submit()','42501'),'approval-only grant cannot initiate');
select is(jsonb_array_length(pg_temp.cross_queue(null,'nonexistent transfer filter')->'items'),0,'unmatched query returns empty authorized queue');
select is(pg_temp.cross_queue(null,'nonexistent transfer filter')->>'restricted','false','unfiltered authorized target distinguishes empty filter from permission loss');
select is((pg_temp.cross_approve()).status,'completed','explicit sibling grant permits authoritative approval');
select ok((pg_temp.cross_approve()).reused,'original actor key replays while sibling grant survives');
update authz.permission_catalog set step_up_mode='elevated' where permission_key='approve_pocket_transfer';
select ok(pg_temp.transfer_sqlstate('select pg_temp.cross_approve()','P0401'),'cross-office grant replay preserves fresh step-up requirement');
update authz.permission_catalog set step_up_mode='none' where permission_key='approve_pocket_transfer';
update authz.access_rules set expires_at=clock_timestamp()-interval '1 hour'
 where id='98000000-0000-0000-0000-000000000011';
select is(jsonb_array_length(pg_temp.cross_queue()->'items'),0,'expired cross-office grant removes all visible targets');
select ok(pg_temp.transfer_sqlstate('select pg_temp.cross_approve()','42501'),'expired cross-office grant cannot replay committed approval');
update authz.access_rules set expires_at=null where id='98000000-0000-0000-0000-000000000011';
insert into authz.access_rules(id,tenant_id,assignment_id,permission_key,effect,scope_type,scope_membership_id)
values('98000000-0000-0000-0000-000000000012','10000000-0000-0000-0000-000000000501',
 '98000000-0000-0000-0000-000000000010','approve_pocket_transfer','deny','member',
 '30000000-0000-0000-0000-000000000502');
select is(jsonb_array_length(pg_temp.cross_queue()->'items'),0,'matching deny overrides explicit cross-office allow');
select ok(pg_temp.transfer_sqlstate('select pg_temp.cross_approve()','42501'),'matching deny prevents cached approval recovery');
update authz.access_rules set revoked_at=clock_timestamp(),revoked_by_user_id='00000000-0000-0000-0000-000000000503'
 where id='98000000-0000-0000-0000-000000000012';
insert into authz.access_rules(id,tenant_id,assignment_id,permission_key,effect,scope_type,scope_office_id)
values('98000000-0000-0000-0000-000000000013','10000000-0000-0000-0000-000000000501',
 '98000000-0000-0000-0000-000000000010','transfer_between_pockets_on_behalf','allow','office_subtree',
 '20000000-0000-0000-0000-000000000502');
select is(jsonb_array_length(pg_temp.cross_choices()->'items'),2,'specific initiation grant exposes only eligible sibling sources');
select is(read_api.pocket_transfer_choices('00000000-0000-0000-0000-000000000504',
 '30000000-0000-0000-0000-000000000506',null,'83000000-0000-0000-0000-000000000599')->>'restricted',
 'false','empty source selector retains unfiltered cross-grant authority');
insert into transfer_results select 'cross-initiated',pg_temp.cross_submit();
select ok((pg_temp.cross_submit()).reused,'cross-office initiation replays same immutable result');
select is(read_api.pocket_transfers('00000000-0000-0000-0000-000000000504',
 '30000000-0000-0000-0000-000000000506',null,null,null,
 (select (result).operation_id from transfer_results where key='cross-initiated'))->'items'->0->'capabilities'->>'cancel',
 'true','initiating actor with current cross grant can cancel requested transfer');
update authz.access_rules set revoked_at=clock_timestamp(),revoked_by_user_id='00000000-0000-0000-0000-000000000503'
 where id='98000000-0000-0000-0000-000000000013';
select is(jsonb_array_length(pg_temp.cross_choices()->'items'),0,'revoked initiation grant removes source choices');
select ok(pg_temp.transfer_sqlstate('select pg_temp.cross_submit()','42501'),'revoked initiation grant prevents same-key cached recovery');
select ok(pg_temp.transfer_sqlstate(format('select command_api.cancel_pocket_transfer(%L,%L,null,%L,%L,%L)',
 '96000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000504',
 '30000000-0000-0000-0000-000000000506',(select (result).operation_id from transfer_results where key='cross-initiated'),
 'Changed plan'),'42501'),'original initiator needs current initiation permission to cancel');
select is(read_api.pocket_transfers('00000000-0000-0000-0000-000000000504',
 '30000000-0000-0000-0000-000000000506',null,null,null,
 (select (result).operation_id from transfer_results where key='cross-initiated'))->'items'->0->'capabilities'->>'cancel',
 'false','approval grant surviving initiation revocation never grants cancellation');
update public.memberships set status='suspended' where id='30000000-0000-0000-0000-000000000506';
select ok(pg_temp.transfer_sqlstate('select pg_temp.cross_approve()','42501'),'suspended selected workspace overrides surviving explicit grant');
select ok(pg_temp.transfer_sqlstate($query$select financial_ops.require_transfer_context(
 '00000000-0000-0000-0000-000000000504','30000000-0000-0000-0000-000000000504',
 '10000000-0000-0000-0000-000000000599','20000000-0000-0000-0000-000000000503',
 '00000000-0000-0000-0000-000000000502')$query$,'42501'),'cross grants never admit another target tenant');
select ok(pg_temp.transfer_sqlstate($query$select financial_ops.require_transfer_context(
 '00000000-0000-0000-0000-000000000504','30000000-0000-0000-0000-000000000504',
 '10000000-0000-0000-0000-000000000501','20000000-0000-0000-0000-000000000502',
 '00000000-0000-0000-0000-000000000504')$query$,'42501'),'selected leadership context never targets own Wallet');
update public.memberships set status='active' where id='30000000-0000-0000-0000-000000000506';
update authz.access_rules set revoked_at=clock_timestamp(),revoked_by_user_id='00000000-0000-0000-0000-000000000503'
 where id='98000000-0000-0000-0000-000000000011';
select is(jsonb_array_length(pg_temp.cross_queue()->'items'),0,'revocation removes final cross-office queue authority');
select is(pg_temp.cross_queue()->>'restricted','true','revoked grants distinguish restriction from empty work');
select ok(pg_temp.transfer_sqlstate('select pg_temp.cross_approve()','42501'),'revoked approval grant cannot return cached result');
update authz.tenant_role_permissions set allowed=true where tenant_id='10000000-0000-0000-0000-000000000501'
 and role_key='director' and permission_key in ('approve_pocket_transfer','transfer_between_pockets_on_behalf','view_scoped_financial_reports');

select ok(not has_function_privilege('anon','read_api.pocket_transfers(uuid,uuid,text,timestamptz,uuid,uuid,text)','EXECUTE'),'anonymous transfer read RPC denied');
select ok(not has_function_privilege('authenticated','read_api.pocket_transfer_choices(uuid,uuid,uuid,uuid)','EXECUTE'),'authenticated cannot invoke privileged choice RPC directly');
select ok(has_function_privilege('service_role','command_api.submit_pocket_transfer(uuid,uuid,uuid,uuid,uuid,uuid,numeric)','EXECUTE'),'service role has narrow submit wrapper');
select ok(not has_table_privilege('service_role','financial_ops.pocket_transfer_commands','SELECT'),'service role cannot directly read command cache');
select ok(not has_table_privilege('authenticated','financial_ops.pocket_transfer_commands','INSERT'),'authenticated cannot forge command results');
select throws_ok($$update financial_ops.pocket_transfer_commands set created_at=clock_timestamp()$$,
 '55000','transfer command results are immutable','durable results cannot be edited');

-- Read permission loss never leaks previously authorized queue contents.
update authz.tenant_role_permissions set allowed=false
 where tenant_id='10000000-0000-0000-0000-000000000501' and role_key='president_team_member'
 and permission_key in ('approve_pocket_transfer','transfer_between_pockets_on_behalf','view_scoped_financial_reports');
select is(jsonb_array_length(read_api.pocket_transfers('00000000-0000-0000-0000-000000000503',
 '30000000-0000-0000-0000-000000000503')->'items'),0,'revoked effective permissions hide all queue rows');
select is(read_api.pocket_transfers('00000000-0000-0000-0000-000000000503',
 '30000000-0000-0000-0000-000000000503')->>'restricted','true','permission loss distinguished from empty work');
select is(read_api.pocket_transfers('00000000-0000-0000-0000-000000000502')->'items'->0->'capabilities'->>'approve',
 'false','personal queue never offers self approval');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000502',true);
select throws_ok($$select read_api.pocket_transfers('00000000-0000-0000-0000-000000000503',
 '30000000-0000-0000-0000-000000000503')$$,'42501',
 'financial command actor does not match the authenticated user','authenticated identity cannot be overridden by privileged RPC argument');
select set_config('request.jwt.claim.sub','',true);
update public.user_accounts set status='suspended' where user_id='00000000-0000-0000-0000-000000000502';
select throws_ok($$select read_api.pocket_transfers('00000000-0000-0000-0000-000000000502')$$,
 '42501','transfers require an active account','suspended account cannot use personal transfer read');
select * from finish();
rollback;
