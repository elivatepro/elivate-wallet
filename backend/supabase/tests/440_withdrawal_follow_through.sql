-- Blueprint 44 — 440: withdrawal follow-through (owner decisions 2026-10-17).
-- D2 the "Withdrawal requested" push kind; D3 the "One open withdrawal at a
-- time" team setting (off by default, revisions, restore, enforcement for the
-- member and a leader on behalf, conflict details, the up-front read); D1
-- open withdrawals in the owner's own Activity and Home only (posted reads,
-- month totals and statement figures unchanged); the single read's scope.
-- The two-session race is 441.
begin;
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(44);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
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
    encode(extensions.digest(p_bank || ':' || p_number, 'sha256'), 'hex'), right(p_number, 4), null,
    pg_temp.k())->>'lookupId')::uuid;
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
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 1000, repeat('b', 64),
    'application/pdf');
  return e;
end $$;
create function pg_temp.seg(n int) returns uuid language sql stable as $$
  select b.account_id from ledger.balances b join ledger.pockets p on p.id = b.pocket_id
  where b.owner_user_id = pg_temp.u(n) and p.name = 'Point Value' and b.currency = 'NGN'
$$;
create function pg_temp.wd(n int, p_amount text, p_reason text, p_key text default null) returns jsonb
language sql volatile as $$
  select api.request_withdrawal(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), pg_temp.seg(4), p_amount,
    pg_temp.id('A4'), p_reason, coalesce(p_key, pg_temp.k()))
$$;
-- The error code and details.field a statement fails with.
create function pg_temp.fails(p_sql text) returns text language plpgsql as $$
declare
  msg text;
  detail text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics msg = message_text, detail = pg_exception_detail;
  return msg || ':' || coalesce(detail::jsonb->>'field', '');
end $$;
create function pg_temp.payout_receipt(n int, p_withdrawal uuid, p_key text) returns uuid language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_payout_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_withdrawal, p_key, 'pay.pdf',
    'application/pdf', 2000, repeat('c', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 2000, repeat('c', 64),
    'application/pdf');
  return e;
end $$;

-- 1 President · 2 Director (D) · 3 TL (T) · 4 member (T) · 9 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from unnest(array[1, 2, 3, 4, 9]) n;
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from unnest(array[1, 2, 3, 4, 9]) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from unnest(array[1, 2, 3, 4, 9]) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(9), 'Test admin');
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('tenant'), 'Pilot', pg_temp.k());
end $$;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', null,
  array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'),
  array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(4), pg_temp.k());
  perform api.record_income(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(4, pg_temp.id('T')), 'NGN', '10000.00',
    'Fiverr', to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null,
    array[pg_temp.income_receipt(1, pg_temp.m(4, pg_temp.id('T')), 'k-income-0000000001')], 'k-income-0000000001');
end $$;
insert into payout.banks (provider, code, name, active) values ('paystack', '058', 'Guaranty Trust Bank', true);
insert into ids select 'A4', pg_temp.add_account(4, '058', '0123456789', 'ADA OBI');


-- The error's code and details for a statement.
create function pg_temp.err(p_sql text) returns jsonb language plpgsql as $$
declare
  msg text;
  detail text;
begin
  execute p_sql;
  return jsonb_build_object('code', 'no error');
exception when others then
  get stacked diagnostics msg = message_text, detail = pg_exception_detail;
  return jsonb_build_object('code', msg) || coalesce(case when detail like '{%' then detail::jsonb end, '{}');
end $$;
create function pg_temp.save(p_rev int, p_fields jsonb) returns jsonb language sql volatile as $$
  select api.update_team_settings(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), p_rev, p_fields, pg_temp.k())
$$;
create function pg_temp.rev() returns int language sql stable as
  $$ select revision from org.tenant_settings where tenant_id = pg_temp.id('tenant') $$;
create function pg_temp.act(n int, p_cursor text default null, p_direction text default null,
  p_status text default null, p_query text default null) returns jsonb language sql stable as $$
  select api.my_activity(pg_temp.u(n), pg_temp.s(n), null, null, null, p_direction, null, null, null, p_cursor,
    null, p_query, p_status, null, pg_temp.ws(n))
$$;

-- ── D2: the push kind (2) ──
select ok(exists (select 1 from notify.push_kinds where key = 'money.withdrawal_submitted'),
  '"Withdrawal requested" pushes');
select throws_ok($$ delete from notify.push_kinds where key = 'money.withdrawal_submitted' $$, 'P0001',
  'invariant_violation', 'push kinds stay immutable');

-- ── D3: default off (3) ──
select is((select one_open_withdrawal from org.tenant_settings where tenant_id = pg_temp.id('tenant')), false,
  'the rule is off by default');
select is((api.team_settings(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1))->'settings'->>'oneOpenWithdrawal'), 'false',
  'the settings read says so');
select is((api.withdrawal_sources(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4))->'openWithdrawal'), 'null'::jsonb,
  'New withdrawal is not blocked');

-- ── Off: several open requests are allowed (2) ──
create temp table w1 as select pg_temp.wd(4, '1000.00', 'School fees', 'k-wd-4400000000001') as r;
insert into ids select 'w1', (r->>'withdrawalId')::uuid from w1;
create temp table w2 as select pg_temp.wd(4, '500.00', 'Rent share') as r;
insert into ids select 'w2', (r->>'withdrawalId')::uuid from w2;
-- One transaction: both share now(). Place the first a minute earlier so "newest" is defined.
set local session_replication_role = replica;
update finance.withdrawals set created_at = created_at - interval '1 minute' where id = pg_temp.id('w1');
set local session_replication_role = origin;
select is((select count(*)::int from finance.withdrawals where status = 'requested'), 2,
  'with the rule off a second open request is placed');
select is((api.withdrawal_sources(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4))->'openWithdrawal'), 'null'::jsonb,
  'and nothing blocks a third');

-- ── D1: Activity and Home (11) ──
select is(jsonb_array_length(pg_temp.act(4)->'pending'), 2, 'Activity lists both open withdrawals as pending');
select is(pg_temp.act(4)->>'pendingMore', 'false', 'and says there are no others');
select is(pg_temp.act(4)->'pending'->0->>'withdrawalId', pg_temp.id('w2')::text, 'newest first');
select is(pg_temp.act(4)->'pending'->0->>'amount', '500.00', 'the amount on hold, never signed');
select is(pg_temp.act(4)->'pending'->0->>'title', 'Guaranty Trust Bank •• 6789', 'titled by bank and last four');
select is(pg_temp.act(4)->'pending'->0->>'status', 'requested', 'with its stage');
select is(jsonb_array_length(pg_temp.act(4, null, 'in')->'pending'), 0, 'Money in shows no withdrawal');
select is(jsonb_array_length(pg_temp.act(4, null, null, 'posted')->'pending'), 0,
  'a ledger status filter shows none');
select is(jsonb_array_length(pg_temp.act(4, null, null, null, 'Guaranty')->'pending'), 2, 'search finds the bank');
select is((select count(*)::int from jsonb_array_elements(pg_temp.act(4)->'items') i
    where i.value->>'type' = 'withdrawal'), 0, 'posted activity has no withdrawal row until it completes');
select is((api.home_view(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4))->'pending'->1->>'withdrawalId'),
  pg_temp.id('w1')::text, 'Home carries them too');

-- ── D1: only the owner, never totals or statements (4) ──
select is(jsonb_array_length(api.my_activity(pg_temp.u(3), pg_temp.s(3), null, null, null, null, null, null, null,
  null, null, null, null, null, pg_temp.ws(3))->'pending'), 0, 'another person never sees them');
select ok(not (ledger.activity((select wallet_id from finance.withdrawals where id = pg_temp.id('w1')),
  pg_temp.id('tenant'), null, null, null, null, null, null, null, null, 10) ? 'pending'),
  'the shared activity read (managed wallets) is unchanged');
select is((pg_temp.act(4)->'months'->0->'currencies'->0->>'out'), '0.00', 'month totals count no hold as money out');
select is((select count(*)::int from exports.lines(array[pg_temp.seg(4)], now() - interval '1 day',
  now() + interval '1 day')), 1, 'statement figures still see only the posted income');

-- ── D3: switching it on (6) ──
select is((pg_temp.save(pg_temp.rev(), '{"oneOpenWithdrawal": true}')->'settings'->>'oneOpenWithdrawal'), 'true',
  'the President switches it on');
select is((select one_open_withdrawal from org.tenant_setting_revisions where tenant_id = pg_temp.id('tenant')
    and revision = pg_temp.rev()), true, 'the revision keeps it');
select is((select changed from org.tenant_setting_revisions where tenant_id = pg_temp.id('tenant')
    and revision = pg_temp.rev()), array['oneOpenWithdrawal'], 'and names the change');
select is((select safe_after from audit.tenant_events where action = 'settings.updated' order by id desc limit 1),
  '{"oneOpenWithdrawal": true}'::jsonb, 'the audit log shows it');
select is((pg_temp.err($$ select pg_temp.save(pg_temp.rev(), '{"oneOpenWithdrawal": "yes"}') $$)->>'field'),
  'oneOpenWithdrawal', 'only true or false');
select is((pg_temp.err($$ select api.update_team_settings(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.rev(),
  '{"oneOpenWithdrawal": false}', pg_temp.k()) $$)->>'code'), 'authorization_denied',
  'a member cannot change it');

-- ── D3: enforcement (8) ──
select is((pg_temp.err($$ select pg_temp.wd(4, '100.00', 'Another one') $$)->>'code'), 'conflict',
  'with the rule on a second request is refused');
select is((pg_temp.err($$ select pg_temp.wd(4, '100.00', 'Another one') $$)->>'reason'), 'open_withdrawal_exists',
  'with its reason');
select is((pg_temp.err($$ select pg_temp.wd(4, '100.00', 'Another one') $$)->>'withdrawalId'),
  pg_temp.id('w2')::text, 'and the open withdrawal to view');
select is((pg_temp.err($$ select pg_temp.wd(1, '100.00', 'Placed on behalf') $$)->>'reason'),
  'open_withdrawal_exists', 'a leader placing it on behalf is refused too');
select is((pg_temp.wd(4, '1000.00', 'School fees', 'k-wd-4400000000001')->>'replayed')::boolean, true,
  'a replay of an accepted request still answers');
select is((api.withdrawal_sources(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4))->'openWithdrawal'->>'withdrawalId'),
  pg_temp.id('w2')::text, 'New withdrawal says so up front');
do $$ begin
  perform api.cancel_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('w1'), null, pg_temp.k());
  perform api.cancel_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('w2'), null, pg_temp.k());
end $$;
select is((pg_temp.wd(4, '200.00', 'Now it is the only one')->>'status'), 'requested',
  'once nothing is open a request goes through');
select is((pg_temp.err($$ select pg_temp.wd(4, '100.00', 'Another one') $$)->>'reason'), 'open_withdrawal_exists',
  'and the next one waits again');

-- ── Closed withdrawals leave Activity (1) ──
select is((select count(*)::int from jsonb_array_elements(pg_temp.act(4)->'pending') p
    where p.value->>'withdrawalId' in (pg_temp.id('w1')::text, pg_temp.id('w2')::text)), 0,
  'cancelled requests are not pending');

-- ── Restore and backups (4) ──
select is((api.restore_team_settings_revision(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.rev(),
  pg_temp.rev() - 1, pg_temp.k())->'settings'->>'oneOpenWithdrawal'), 'false', 'restoring an older revision turns it off');
select is((select changed from org.tenant_setting_revisions where tenant_id = pg_temp.id('tenant')
    and revision = pg_temp.rev()), array['oneOpenWithdrawal'], 'the restore names it');
select is((select count(*)::int from backups.snapshot(pg_temp.id('tenant')) s
    where s.section = 'settings_revisions' and s.data ? 'one_open_withdrawal'), 1,
  'a backup marks only the revision with the rule on');
select ok(not exists (select 1 from backups.snapshot(pg_temp.id('tenant')) s
    where s.section = 'settings_revisions' and s.data->>'revision' = '1' and s.data ? 'one_open_withdrawal'),
  'older revisions back up exactly as before');

-- ── The single read and privileges (3) ──
select is((pg_temp.err(format($$ select api.my_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), %L) $$,
  pg_temp.id('w1')))->>'code'), 'not_found', 'someone else''s withdrawal is not found');
select ok(not has_function_privilege('authenticated',
  'ledger.open_withdrawals(uuid, uuid, uuid, text, uuid, text, text, text, text, text, text, text, int)', 'execute'),
  'the pending read is private');
select ok(not has_function_privilege('authenticated', 'finance.lock_open_withdrawal(uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'api.request_withdrawal(uuid, uuid, uuid, uuid, text, uuid, text, text, text)',
  'execute'), 'the lock and the command are not callable by clients');

select * from finish();
rollback;
