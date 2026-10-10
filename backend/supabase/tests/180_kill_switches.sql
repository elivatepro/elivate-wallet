-- Blueprint 18 — B6 180: kill switches (W-23). A stop refuses only NEW
-- operations, platform-wide or on one network; cancellations, rejections,
-- payouts of withdrawals approved before the stop, reviews and replays keep
-- working; reservations are untouched. Only platform admins change switches,
-- with a reason and the PIN, and every change is audited.
begin;
create extension if not exists pgtap with schema extensions;
select plan(40);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('18000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('28000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.uid(n int) returns text language sql stable as
  $$ select uid from identity.accounts where user_id = pg_temp.u(n) $$;
create function pg_temp.k() returns text language sql volatile as
  $$ select 'k' || md5(random()::text || clock_timestamp()::text) $$;
create temp table ids (name text primary key, id uuid not null);
create function pg_temp.id(p_name text) returns uuid language sql stable as
  $$ select id from ids where name = p_name $$;
create function pg_temp.m(n int, p_office uuid default null) returns uuid language sql stable as $$
  select id from org.memberships
  where user_id = pg_temp.u(n) and status = 'active' and office_id is not distinct from p_office
  order by started_at desc, id limit 1
$$;
create function pg_temp.ws(n int) returns uuid language sql stable as $$
  select id from org.memberships where user_id = pg_temp.u(n) and status = 'active'
  order by (role = 'member'), started_at limit 1
$$;
create function pg_temp.ct() returns text language sql volatile as
  $$ select encode(extensions.gen_random_bytes(38), 'base64') $$;
create function pg_temp.add_account(n int, p_bank text, p_number text, p_name text) returns uuid
language plpgsql volatile as $$
declare
  lookup uuid;
begin
  lookup := (api.prepare_account_lookup(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_bank, pg_temp.ct(), 1,
    encode(extensions.digest(p_bank || ':' || p_number, 'sha256'), 'hex'), right(p_number, 4), null, pg_temp.k())->>'lookupId')::uuid;
  perform api.record_account_lookup(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), lookup, 'resolved', p_name);
  return (api.confirm_payout_account(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), lookup, null, pg_temp.k())
    ->'payoutAccount'->>'payoutAccountId')::uuid;
end $$;
create function pg_temp.income_receipt(n int, p_target uuid, p_key text) returns uuid language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_target, p_key, 'r.pdf',
    'application/pdf', 1000, repeat('b', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 1000, repeat('b', 64), 'application/pdf');
  return e;
end $$;
create function pg_temp.income(p_source text, p_key text, p_receipt uuid default null) returns jsonb language sql volatile as $$
  select api.record_income(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(4, pg_temp.id('T')), 'NGN', '10000.00',
    p_source, to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null,
    array[coalesce(p_receipt, pg_temp.income_receipt(1, pg_temp.m(4, pg_temp.id('T')), p_key))], p_key)
$$;
create function pg_temp.pocket(p_name text) returns uuid language sql stable as
  $$ select id from ledger.pockets where tenant_id = pg_temp.id('tenant') and name = p_name $$;
create function pg_temp.acct(n int, p_name text) returns uuid language sql stable as $$
  select b.account_id from ledger.balances b where b.owner_user_id = pg_temp.u(n) and b.pocket_id = pg_temp.pocket(p_name)
    and b.currency = 'NGN'
$$;
create function pg_temp.wd(p_amount text, p_key text default null) returns jsonb language sql volatile as $$
  select api.request_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.acct(4, 'Point Value'), p_amount,
    pg_temp.id('A4'), coalesce(p_key, pg_temp.k()))
$$;
create function pg_temp.payout_receipt(n int, p_withdrawal uuid, p_key text) returns uuid language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_payout_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_withdrawal, p_key, 'pay.pdf',
    'application/pdf', 2000, repeat('c', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 2000, repeat('c', 64), 'application/pdf');
  return e;
end $$;
create function pg_temp.record(p_withdrawal uuid, p_amount text) returns jsonb language plpgsql as $$
declare
  key text := pg_temp.k();
begin
  return api.record_payout(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), p_withdrawal, p_amount, null,
    to_char(now() at time zone 'Africa/Lagos', 'YYYY-MM-DD'), '000014261005', null,
    pg_temp.payout_receipt(3, p_withdrawal, key), key);
end $$;
create function pg_temp.proof(n int, p_kind text, p_target uuid, p_key text) returns uuid language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_entry_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_kind, p_target, p_key,
    'proof.pdf', 'application/pdf', 3000, repeat('d', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 3000, repeat('d', 64), 'application/pdf');
  return e;
end $$;
create function pg_temp.adjust() returns jsonb language plpgsql as $$
declare
  key text := pg_temp.k();
begin
  return api.submit_adjustment(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.m(4, pg_temp.id('T')), 'credit', 'NGN',
    '10.00', 'Goodwill credit from the network', null,
    array[pg_temp.proof(1, 'adjustment', pg_temp.m(4, pg_temp.id('T')), key)], key);
end $$;
-- Admin 9 changes a switch.
create function pg_temp.set(p_key text, p_tenant uuid, p_stopped boolean, p_idem text default null) returns jsonb
language sql volatile as $$
  select api.admin_set_switch(pg_temp.u(9), pg_temp.s(9), p_key, p_tenant, p_stopped, 'Bank partner outage',
    coalesce(p_idem, pg_temp.k()))
$$;
-- The error code and details.reason a statement fails with.
create function pg_temp.fails(p_sql text) returns text language plpgsql as $$
declare
  msg text;
  detail text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics msg = message_text, detail = pg_exception_detail;
  return msg || ':' || coalesce(detail::jsonb->>'reason', '');
end $$;

-- 1 President · 3 TL (T) · 4 member (T) · 8 other founder · 9 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'k' || n || '@example.test', 'authenticated', 'authenticated' from unnest(array[1, 3, 4, 8, 9]) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from unnest(array[1, 3, 4, 8, 9]) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from unnest(array[1, 3, 4, 8, 9]) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(9), 'Test admin');
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
insert into ids
select 'other', (api.start_network(pg_temp.u(8), pg_temp.s(8), 'Abuja Network', 'ABJ', pg_temp.k())->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('tenant'), 'Pilot', pg_temp.k());
  perform api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('other'), 'Pilot', pg_temp.k());
end $$;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', null, array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(4), pg_temp.k());
end $$;
insert into ids select 'e1', pg_temp.income_receipt(1, pg_temp.m(4, pg_temp.id('T')), 'k-income-0000000001');
select is((pg_temp.income('Fiverr', 'k-income-0000000001', pg_temp.id('e1'))->>'replayed')::boolean, false,
  'income before any stop');
insert into payout.banks (provider, code, name, active) values ('paystack', '058', 'Guaranty Trust Bank', true);
insert into ids select 'A4', pg_temp.add_account(4, '058', '0123456789', 'ADA OBI');
insert into ids select 'w1', (pg_temp.wd('1000.00', 'k-wd-000000000001')->>'withdrawalId')::uuid;
select is(api.approve_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w1'), pg_temp.k())->>'status',
  'approved', 'w1 approved before the stop');
insert into ids select 'w2', (pg_temp.wd('300.00')->>'withdrawalId')::uuid;
insert into ids select 'w3', (pg_temp.wd('200.00')->>'withdrawalId')::uuid;

-- ── Who may change a switch (7) ──
select is(jsonb_array_length(api.admin_switches(pg_temp.u(9), pg_temp.s(9))->'platform'), 8,
  'eight platform switches, all present');
select is((select count(*)::int from platform.kill_switches where tenant_id is null and stopped), 0, 'all running by default');
select is(pg_temp.fails($$ select api.admin_set_switch(pg_temp.u(1), pg_temp.s(1), 'withdrawals', null, true,
  'Not my call', pg_temp.k()) $$), 'authorization_denied:', 'a President cannot stop a switch');
select is(pg_temp.fails($$ select api.admin_switches(pg_temp.u(1), pg_temp.s(1)) $$), 'authorization_denied:',
  'nor read them');
select is(pg_temp.fails($$ select api.admin_set_switch(pg_temp.u(9), pg_temp.s(9), 'withdrawals', null, true, ' ',
  pg_temp.k()) $$), 'validation_error:', 'a reason is required');
select is(pg_temp.fails($$ select api.admin_set_switch(pg_temp.u(9), pg_temp.s(9), 'remittance', null, true,
  'Unknown switch', pg_temp.k()) $$), 'validation_error:', 'only the eight keys');
update identity.session_pin_proofs set verified_at = now() - interval '6 minutes' where session_id = pg_temp.s(9);
select is(pg_temp.fails($$ select pg_temp.set('withdrawals', null, true) $$), 'step_up_required:',
  'changing a switch needs a fresh PIN');
update identity.session_pin_proofs set verified_at = now() where session_id = pg_temp.s(9);

-- ── Withdrawals stopped platform-wide (10) ──
select is((pg_temp.set('withdrawals', null, true, 'k-switch-00000000001')->>'changed')::boolean, true,
  'withdrawals stopped');
select is((pg_temp.set('withdrawals', null, true, 'k-switch-00000000001')->>'replayed')::boolean, true,
  'same key replays');
select is(pg_temp.fails($$ select pg_temp.wd('50.00') $$), 'conflict:operation_paused', 'no new requests');
select is(pg_temp.fails($$ select api.approve_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w2'),
  pg_temp.k()) $$), 'conflict:operation_paused', 'no new approvals');
select is((pg_temp.wd('1000.00', 'k-wd-000000000001')->>'replayed')::boolean, true,
  'a committed request still replays (unknown-outcome recovery)');
select is(api.reject_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w2'), 'Not this week',
  pg_temp.k())->>'status', 'rejected', 'rejections still work and release the hold');
select is(api.cancel_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('w3'), 'Changed my mind',
  pg_temp.k())->>'status', 'cancelled', 'cancellations still work');
select ok((select r.id is not null from finance.withdrawals w join ledger.reservations r on r.id = w.reservation_id
  where w.id = pg_temp.id('w1')), 'the approved withdrawal keeps its reservation');
select is((pg_temp.record(pg_temp.id('w1'), '1000.00')->>'replayed')::boolean, false,
  'a withdrawal approved before the stop is still paid out');
select is((select count(*)::int from audit.security_events where action = 'kill_switch.stopped'
  and safe_after->>'key' = 'withdrawals'), 1, 'the stop is audited once');

-- ── Starting again (2) ──
select is((pg_temp.set('withdrawals', null, false)->>'changed')::boolean, true, 'withdrawals started again');
insert into ids select 'w4', (pg_temp.wd('100.00')->>'withdrawalId')::uuid;
select ok(pg_temp.id('w4') is not null, 'new requests are accepted again');

-- ── One network only (7) ──
select is((pg_temp.set('payouts', pg_temp.id('tenant'), true)->>'changed')::boolean, true,
  'payout recording stopped on one network');
select is(api.approve_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w4'), pg_temp.k())->>'status',
  'approved', 'approvals are a different switch');
select is(pg_temp.fails($$ select pg_temp.record(pg_temp.id('w4'), '100.00') $$), 'conflict:operation_paused',
  'no new payout records on that network');
select ok(not platform.is_stopped('payouts', pg_temp.id('other')), 'other networks are unaffected');
select is(api.stopped_operations(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4))->'stopped', '["payouts"]'::jsonb,
  'members of that network see what is stopped');
select is(api.stopped_operations(pg_temp.u(8), pg_temp.s(8), pg_temp.ws(8))->'stopped', '[]'::jsonb,
  'members elsewhere see nothing stopped');
select is((select count(*)::int from audit.tenant_events where tenant_id = pg_temp.id('tenant')
  and action = 'operations.paused_by_elivate'), 1, 'the President''s audit log shows "paused by Elivate"');

-- ── Every other switch (9) ──
do $$ begin
  perform pg_temp.set(k, null, true) from unnest(array['income', 'transfers', 'adjustments', 'reversals', 'conversion',
    'returned_funds']) k;
end $$;
select is(pg_temp.fails($$ select pg_temp.income('Upwork', 'k-income-0000000002') $$), 'conflict:operation_paused',
  'no new income');
select is((pg_temp.income('Fiverr', 'k-income-0000000001', pg_temp.id('e1'))->>'replayed')::boolean, true,
  'recorded income still replays');
select is(pg_temp.fails($$ select api.request_pocket_transfer(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4),
  pg_temp.acct(4, 'Point Value'), pg_temp.pocket('Savings'), '10.00', pg_temp.k()) $$), 'conflict:operation_paused',
  'no new pocket moves');
select is(pg_temp.fails($$ select pg_temp.adjust() $$), 'conflict:operation_paused', 'no new adjustments');
select is(pg_temp.fails($$ insert into finance.reversals (tenant_id) values (pg_temp.id('tenant')) $$),
  'conflict:operation_paused', 'no new reversals');
select is(pg_temp.fails($$ insert into finance.entries (id, kind, tenant_id) values (gen_random_uuid(), 'conversion',
  pg_temp.id('tenant')) $$), 'conflict:operation_paused', 'no new conversions');
select is(pg_temp.fails($$ insert into finance.entries (id, kind, tenant_id) values (gen_random_uuid(), 'returned_funds',
  pg_temp.id('tenant')) $$), 'conflict:operation_paused', 'no new returned funds');
select is(jsonb_array_length(api.stopped_operations(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4))->'stopped'), 7,
  'seven operations stopped for that network');
select is((select count(*)::int from platform.kill_switch_changes), 9, 'every change kept in the history');

-- ── History is append-only (2) ──
select is(pg_temp.fails($$ update platform.kill_switch_changes set reason = 'edited' $$), 'invariant_violation:',
  'switch history cannot be edited');
select is(pg_temp.fails($$ delete from platform.kill_switch_changes $$), 'invariant_violation:',
  'or deleted');

-- ── Not exposed to clients (1) ──
select ok(not has_function_privilege('authenticated', 'api.admin_set_switch(uuid, uuid, text, uuid, boolean, text, text, text)',
  'execute'), 'clients cannot call the command directly');

select * from finish();
rollback;
