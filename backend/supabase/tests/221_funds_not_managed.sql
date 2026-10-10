-- Blueprint 22 — B5 221: the "funds not managed" switch. Only the President
-- Team, with the PIN and a reason; directors only, never yourself; refused
-- while the wallet holds money in this network; audited, idempotent, inside
-- the network. Then: own-wallet permissions go, money targets and the ledger
-- refuse the membership, the setup turns light, and clearing restores it.
begin;
create extension if not exists pgtap with schema extensions;
select plan(38);

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
-- User n's active membership in an office (null: President Team).
create function pg_temp.m(n int, p_office uuid default null) returns uuid language sql stable as $$
  select id from org.memberships
  where user_id = pg_temp.u(n) and status = 'active' and office_id is not distinct from p_office
  order by started_at desc, id limit 1
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare
  msg text;
  det text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  return msg || coalesce(' ' || nullif(det, '{}'), '');
end $$;
-- The switch as President n in workspace w.
create function pg_temp.switch(n int, w uuid, p_target uuid, p_on boolean, p_key text,
  p_reason text default 'No money held for this director') returns jsonb language sql volatile as $$
  select api.set_funds_managed(pg_temp.u(n), pg_temp.s(n), w, p_target, p_on, p_reason, p_key)
$$;
create function pg_temp.switch_err(n int, w uuid, p_target uuid, p_on boolean,
  p_reason text default 'No money held for this director') returns text language sql volatile as $$
  select pg_temp.err(format('select api.set_funds_managed(%L, %L, %L, %L, %L, %L, %L)',
    pg_temp.u(n), pg_temp.s(n), w, p_target, p_on, p_reason, pg_temp.k()))
$$;
-- Income recorded by n in workspace w (default: the founder as President).
create function pg_temp.income(p_target uuid, p_amount text, n int default 1, w uuid default null) returns void
language plpgsql as $$
declare
  key text := pg_temp.k();
  ws uuid := coalesce(w, pg_temp.m(1));
  e uuid;
begin
  e := (api.create_evidence_upload(pg_temp.u(n), pg_temp.s(n), ws, p_target, key, 'r.pdf',
    'application/pdf', 1000, repeat('b', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), ws, e, 1000, repeat('b', 64),
    'application/pdf');
  perform api.record_income(pg_temp.u(n), pg_temp.s(n), ws, p_target, 'NGN', p_amount, 'Sales',
    to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null, array[e], key);
end $$;
create function pg_temp.caps(n int, w uuid) returns jsonb language sql stable as
  $$ select api.my_capabilities(pg_temp.u(n), pg_temp.s(n), w)->'permissions' $$;

-- 1 founder, President · 2 Team Leader · 3 member · 4 Director with money
-- 5 World Team · 6 second President, also a Director · 7 Director, no money
-- 8 admin · 10 President of another network
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 10) n;
insert into founders.approved (user_id, source) select pg_temp.u(n), 'existing' from unnest(array[1, 10]) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 10) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 10) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(8), 'Test admin');

-- Fixtures with the setup gate off; everyone is then set up (below).
set local identity.setup_gate = off;
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
insert into ids
select 'other', (api.start_network(pg_temp.u(10), pg_temp.s(10), 'Abuja Network', 'ABJ', pg_temp.k())->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(8), pg_temp.s(8), pg_temp.id('tenant'), 'Pilot', pg_temp.k());
  perform api.activate_tenant(pg_temp.u(8), pg_temp.s(8), pg_temp.id('other'), 'Pilot', pg_temp.k());
end $$;
insert into ids
select 'W', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'world_team', 'World', null,
  array[pg_temp.uid(5)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Directors', pg_temp.id('W'),
  array[pg_temp.uid(4), pg_temp.uid(7)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'),
  array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(3), pg_temp.k());
  perform api.add_president(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(6), 'Co-president', pg_temp.k());
  perform api.add_office_leader(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('D'), pg_temp.uid(6),
    'Also a director', pg_temp.k());
end $$;
insert into ids select 'd4', pg_temp.m(4, pg_temp.id('D'));
insert into ids select 'd6', pg_temp.m(6, pg_temp.id('D'));
insert into ids select 'd7', pg_temp.m(7, pg_temp.id('D'));
insert into ids select 'p6', pg_temp.m(6);
select pg_temp.income(pg_temp.id('d4'), '2500.00');

-- Everyone finishes their setup, so the switch alone is under test.
insert into identity.nin_records (user_id, nin_fingerprint, nin_last4, given_name, surname, phone, method, verified_at)
select pg_temp.u(n), repeat(to_hex(n), 64), lpad(n::text, 4, '0'), 'Person', 'Number' || n,
  '+23480300000' || lpad(n::text, 2, '0'), 'provider', now()
from generate_series(1, 10) n;
update identity.profiles
set rank = 'Director', first_name = 'Person', last_name = 'Number', phone = '+23480300000' || right(user_id::text, 2), phone_source = 'nin',
    photo_key = 'photos/' || user_id::text || '/' || gen_random_uuid()::text || '.png', photo_updated_at = now()
where user_id in (select pg_temp.u(n) from generate_series(1, 10) n);
insert into payout.banks (provider, code, name, active) values ('paystack', '058', 'Guaranty Trust Bank', true);
do $$
declare
  n int;
  w uuid;
  lookup uuid;
begin
  foreach n in array array[2, 3, 4, 5, 6, 7] loop
    w := (identity.setup_state(pg_temp.u(n))->>'walletMembershipId')::uuid;
    lookup := (api.prepare_account_lookup(pg_temp.u(n), pg_temp.s(n), w, '058',
      encode(extensions.gen_random_bytes(38), 'base64'), 1, repeat(to_hex(n + 1), 64), '678' || n, null,
      pg_temp.k())->>'lookupId')::uuid;
    perform api.record_account_lookup(pg_temp.u(n), pg_temp.s(n), w, lookup, 'resolved', 'PERSON NUMBER' || n);
    perform api.confirm_payout_account(pg_temp.u(n), pg_temp.s(n), w, lookup, null, pg_temp.k());
  end loop;
end $$;
set local identity.setup_gate = on;
select is((select count(*)::int from generate_series(1, 10) n
           where identity.setup_state(pg_temp.u(n))->>'next' is not null), 0, 'fixture: everyone is set up');

-- ── Who may switch (6) ──
select is(pg_temp.switch_err(4, pg_temp.id('d4'), pg_temp.id('d7'), true), 'authorization_denied',
  'a Director may not');
select is(pg_temp.switch_err(5, pg_temp.m(5, pg_temp.id('W')), pg_temp.id('d7'), true), 'authorization_denied',
  'a World Team member may not');
select is(pg_temp.switch_err(2, pg_temp.m(2, pg_temp.id('T')), pg_temp.id('d7'), true), 'authorization_denied',
  'a Team Leader may not');
select is(pg_temp.switch_err(10, pg_temp.m(10), pg_temp.id('d7'), true), 'not_found',
  'another network''s President finds nothing');
select is(pg_temp.switch_err(6, pg_temp.id('p6'), pg_temp.id('d6'), true), 'self_target_forbidden',
  'a President cannot switch their own director membership');
update identity.session_pin_proofs set verified_at = now() - interval '10 minutes' where session_id = pg_temp.s(1);
select is(pg_temp.switch_err(1, pg_temp.m(1), pg_temp.id('d7'), true), 'step_up_required', 'the PIN is required');
update identity.session_pin_proofs set verified_at = now() where session_id = pg_temp.s(1);

-- ── What may be switched (4) ──
select is(pg_temp.switch_err(1, pg_temp.m(1), pg_temp.id('d7'), true, 'no'), 'validation_error {"field": "reason"}',
  'a reason is required');
select is(pg_temp.switch_err(1, pg_temp.m(1), pg_temp.m(3, pg_temp.id('T')), true),
  'conflict {"reason": "not_a_director"}', 'a member is not a director');
select is(pg_temp.switch_err(1, pg_temp.m(1), pg_temp.m(5, pg_temp.id('W')), true),
  'conflict {"reason": "not_a_director"}', 'nor is World Team');
select is(pg_temp.switch_err(1, pg_temp.m(1), pg_temp.id('d4'), true), 'conflict {"reason": "wallet_not_empty"}',
  'refused while the wallet holds money');

-- ── Setting it (8) ──
create temp table first_call as
select pg_temp.switch(1, pg_temp.m(1), pg_temp.id('d7'), true, 'switch-key-0000001') as res;
select is((select res from first_call),
  jsonb_build_object('membershipId', pg_temp.id('d7'), 'fundsNotManaged', true, 'changed', true,
    'replayed', false), 'set');
select ok(org.funds_not_managed(pg_temp.id('d7')), 'the membership is marked');
select is((select count(*)::int from audit.tenant_events
           where action = 'membership.funds_not_managed' and target_id = pg_temp.id('d7')::text
             and reason = 'No money held for this director' and actor_user_id = pg_temp.u(1)
             and tenant_id = pg_temp.id('tenant')), 1, 'audited with the reason');
select is(pg_temp.switch(1, pg_temp.m(1), pg_temp.id('d7'), true, 'switch-key-0000001'),
  (select res || '{"replayed": true}' from first_call), 'the same key replays the result');
select is((select count(*)::int from audit.tenant_events where action = 'membership.funds_not_managed'), 1,
  'without a second audit row');
select is(pg_temp.err($$ select pg_temp.switch(1, pg_temp.m(1), pg_temp.id('d7'), false, 'switch-key-0000001') $$),
  'idempotency_conflict', 'the same key with another request is refused');
select is(pg_temp.switch(1, pg_temp.m(1), pg_temp.id('d7'), true, pg_temp.k())->'changed', 'false'::jsonb,
  'already set: nothing changes');
select is((select count(*)::int from org.funds_exemptions where membership_id = pg_temp.id('d7')), 1,
  'one row per period');

-- ── What it changes (10) ──
select ok(not (pg_temp.caps(7, pg_temp.id('d7')) ?| array['view_own_wallet', 'view_own_financials',
  'export_own_statement', 'initiate_own_withdrawal', 'manage_own_payout_accounts', 'transfer_between_own_pockets']),
  'no own-wallet permission in that workspace');
select ok(pg_temp.caps(7, pg_temp.id('d7')) ?& array['record_income', 'approve_withdrawal', 'manage_members'],
  'every director authority stays');
select ok(pg_temp.caps(4, pg_temp.id('d4')) ? 'initiate_own_withdrawal', 'another director keeps theirs');
select is(pg_temp.err(format('select pg_temp.income(%L, %L, 7, %L)', pg_temp.m(3, pg_temp.id('T')), '75.00',
  pg_temp.id('d7'))), 'no error', 'and still records income for their team');
select is(identity.setup_state(pg_temp.u(7))->>'level', 'light', 'the setup turns light');
select is(pg_temp.err($$ select pg_temp.income(pg_temp.id('d7'), '10.00') $$), 'target_not_eligible',
  'income is refused');
select ok(not exists (
  select 1 from jsonb_array_elements(api.income_targets(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1))->'items') i
  where i->>'membershipId' = pg_temp.id('d7')::text), 'and the member search leaves them out');
select is(pg_temp.err(format($q$
  select ledger.post('income', refs.issue('INC'), %L, %L, %L, jsonb_build_array(jsonb_build_object(
    'currency', 'NGN', 'postings', jsonb_build_array(
      jsonb_build_object('accountId', ledger.segment_account(ledger.wallet_for(%L), %L, 'NGN',
        (select id from ledger.pockets where tenant_id = %L and kind = 'ordinary' order by sort_order limit 1)),
        'amount', '5'),
      jsonb_build_object('accountId', ledger.system_account(%L, 'NGN', 'external_inflow'), 'amount', '-5')))))
  $q$, pg_temp.id('d7'), pg_temp.u(1), pg_temp.k(), pg_temp.u(7), pg_temp.id('d7'), pg_temp.id('tenant'),
  pg_temp.id('tenant'))), 'conflict {"reason": "funds_not_managed"}', 'the ledger refuses a posting');
select is(pg_temp.err(format($q$
  insert into ledger.reservations (account_id, amount, purpose, source_type, source_id, actor_user_id)
  values (ledger.segment_account(ledger.wallet_for(%L), %L, 'NGN',
    (select id from ledger.pockets where tenant_id = %L and kind = 'ordinary' order by sort_order limit 1)),
    1, 'withdrawal', 'test', gen_random_uuid(), %L)
  $q$, pg_temp.u(7), pg_temp.id('d7'), pg_temp.id('tenant'), pg_temp.u(1))),
  'conflict {"reason": "funds_not_managed"}', 'and a hold');
select is(pg_temp.err(format($q$
  insert into finance.entries (id, reference, kind, tenant_id, office_id, membership_id, wallet_id, owner_user_id,
    currency, amount, direction, reason, submitted_by, idempotency_key)
  values (gen_random_uuid(), refs.issue('ADJ'), 'adjustment', %L, %L, %L, ledger.wallet_for(%L), %L, 'NGN', 5,
    'credit', 'Late bonus', %L, %L)
  $q$, pg_temp.id('tenant'), pg_temp.id('D'), pg_temp.id('d7'), pg_temp.u(7), pg_temp.u(7), pg_temp.u(1), pg_temp.k())),
  'conflict {"reason": "funds_not_managed"}', 'and an entry waiting for review');
select is((api.member_detail(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('d7'))
  - array['person', 'emailMasked', 'office', 'officeLeaders', 'memberships', 'history', 'startedAt', 'walletId',
          'membershipId', 'role', 'status', 'isPrimary', 'endedAt', 'isSelf'])
  #- '{actions,suspend}' #- '{actions,move}' #- '{actions,end}' #- '{actions,changeRole}',
  jsonb_build_object('fundsNotManaged', true, 'fundsBlocked', null, 'actions', jsonb_build_object('funds', true)),
  'the member page shows the switch');

-- ── Reads (3) ──
select is((api.member_detail(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('d4'))->>'fundsBlocked'),
  'wallet_not_empty', 'a director with money shows why it cannot be switched');
select is((api.member_detail(pg_temp.u(5), pg_temp.s(5), pg_temp.m(5, pg_temp.id('W')), pg_temp.id('d7'))
  ->'actions'->'funds'), 'false'::jsonb, 'only the President Team sees the action');
select is((select w->'fundsNotManaged' from jsonb_array_elements(api.my_workspaces(pg_temp.u(7), pg_temp.s(7))) w
           where w->>'membershipId' = pg_temp.id('d7')::text), 'true'::jsonb, 'the workspace list says so');

-- ── Clearing it (5) ──
select is(pg_temp.switch(6, pg_temp.id('p6'), pg_temp.id('d7'), false, pg_temp.k(), 'Wallet back on')->'changed',
  'true'::jsonb, 'another President clears it');
select ok(not org.funds_not_managed(pg_temp.id('d7')), 'the membership is managed again');
select is((select count(*)::int from audit.tenant_events
           where action = 'membership.funds_managed' and target_id = pg_temp.id('d7')::text
             and reason = 'Wallet back on'), 1, 'audited');
select ok(pg_temp.caps(7, pg_temp.id('d7')) ? 'initiate_own_withdrawal', 'own-wallet permissions return');
select is(pg_temp.err($$ select pg_temp.income(pg_temp.id('d7'), '10.00') $$), 'no error', 'income posts again');

select * from finish();
rollback;
