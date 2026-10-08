-- Blueprint 04 — B6 043: recording income (W-08), receipts, idempotency,
-- authorization, decision 22 and provenance.
begin;
create extension if not exists pgtap with schema extensions;
select plan(52);

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
-- Actor n's workspace (their leader membership, or President Team).
create function pg_temp.ws(n int) returns uuid language sql stable as $$
  select id from org.memberships where user_id = pg_temp.u(n) and status = 'active'
  order by (role = 'member'), started_at limit 1
$$;
create function pg_temp.receipt(n int, p_target uuid, p_key text, p_finalize boolean default true) returns uuid
language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_target, p_key, 'receipt.pdf',
    'application/pdf', 1000, repeat('b', 64))->>'evidenceId')::uuid;
  if p_finalize then
    perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 1000, repeat('b', 64), 'application/pdf');
  end if;
  return e;
end $$;
create function pg_temp.inc(n int, p_target uuid, p_amount text default '1000.00', p_key text default null,
  p_evidence uuid[] default null, p_currency text default 'NGN', p_date text default null) returns jsonb
language plpgsql as $$
declare
  key text := coalesce(p_key, pg_temp.k());
begin
  return api.record_income(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_target, p_currency, p_amount, 'Fiverr',
    coalesce(p_date, to_char(now() at time zone 'UTC', 'YYYY-MM-DD')), null, null, null, null,
    coalesce(p_evidence, array[pg_temp.receipt(n, p_target, key)]), key);
end $$;

-- 1 President · 2 World Team · 3 Director · 4 TL (T) · 5 TL (T2) · 6, 8 members (T) · 7 member (T2)
-- 9 other founder · 10 admin · 11 other TL · 12 other member
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 12) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 12) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 12) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
insert into ids
select 'other', (api.start_network(pg_temp.u(9), pg_temp.s(9), 'Abuja Network', 'ABJ', pg_temp.k())->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), 'Pilot', pg_temp.k());
  perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('other'), 'Pilot', pg_temp.k());
end $$;
insert into ids
select 'W', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'world_team', 'North', null, array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', pg_temp.id('W'), array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'), array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T2', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team B', pg_temp.id('D'), array[pg_temp.uid(5)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'O', (api.create_office(pg_temp.u(9), pg_temp.s(9), pg_temp.m(9), 'team_leader', 'Abuja Team', null, array[pg_temp.uid(11)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(6), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T2'), pg_temp.uid(7), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(8), pg_temp.k());
  perform api.add_membership(pg_temp.u(9), pg_temp.s(9), pg_temp.m(9), pg_temp.id('O'), pg_temp.uid(12), pg_temp.k());
end $$;
insert into ids values ('m6', pg_temp.m(6, pg_temp.id('T'))), ('m7', pg_temp.m(7, pg_temp.id('T2'))),
  ('m8', pg_temp.m(8, pg_temp.id('T'))), ('m12', pg_temp.m(12, pg_temp.id('O')));

-- ── Happy path (10) ──
create temp table first as select pg_temp.inc(4, pg_temp.id('m6'), '1000.03') as r;
select is((select r->>'status' from first), 'posted', 'income is posted at once');
select matches((select r->>'reference' from first), '^INC-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$', 'INC reference format (D-01)');
select is(
  (select array_agg(a->>'amount' order by n) from first, jsonb_array_elements(r->'allocations') with ordinality x (a, n)),
  array['400.01', '100.00', '150.01', '250.01', '100.00'], 'exact split with largest-remainder kobo'
);
select is(
  (select sum(posted) from ledger.balances where owner_user_id = pg_temp.u(6)), 1000.03::numeric,
  'member segments hold exactly the income'
);
select is(
  (select sum(p.amount) from ledger.postings p join ledger.accounts a on a.id = p.account_id
   where a.class = 'system' and a.tenant_id = pg_temp.id('tenant')), -1000.03::numeric,
  'the network inflow account mirrors it'
);
select is(
  (select status from evidence.files where attached_id = (select (r->>'incomeId')::uuid from first)), 'attached',
  'the receipt is attached'
);
select is((select count(*)::int from audit.tenant_events where action = 'income.recorded'), 1, 'one tenant audit row');
select lives_ok($$ set constraints all immediate $$, 'the ledger commit checks pass');
set constraints all deferred;

-- ── Authorization (12) ──
select throws_ok($$ select pg_temp.inc(6, pg_temp.id('m8')) $$, 'P0001', 'authorization_denied', 'members cannot record income');
select throws_ok($$ select pg_temp.inc(5, pg_temp.id('m6')) $$, 'P0001', 'authorization_denied', 'a sibling Team Leader cannot');
select is((pg_temp.inc(3, pg_temp.id('m6'))->>'status'), 'posted', 'the Director over the subtree can');
select is((pg_temp.inc(1, pg_temp.id('m7'))->>'status'), 'posted', 'the President can');
select throws_ok($$ select pg_temp.inc(4, pg_temp.id('m12')) $$, 'P0001', 'not_found', 'nothing across networks');
select throws_ok($$ select pg_temp.inc(4, pg_temp.m(4, pg_temp.id('T'))) $$, 'P0001', 'self_target_forbidden',
  'a leader cannot record income into their own wallet');
select throws_ok($$ select pg_temp.inc(1, pg_temp.m(1)) $$, 'P0001', 'target_not_eligible', 'President Team memberships have no wallet');
do $$ begin
  perform api.create_access_assignment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(3),
    jsonb_build_array(jsonb_build_object('permission', 'record_income', 'effect', 'deny', 'scopeType', 'member', 'scopeUid', pg_temp.uid(6))),
    'Related party', pg_temp.k());
  perform api.create_access_assignment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(5),
    jsonb_build_array(jsonb_build_object('permission', 'record_income', 'effect', 'allow', 'scopeType', 'office_subtree', 'scopeOfficeId', pg_temp.id('T'))),
    'Covering Team A', pg_temp.k());
end $$;
select throws_ok($$ select pg_temp.inc(3, pg_temp.id('m6')) $$, 'P0001', 'authorization_denied', 'an explicit deny beats the role');
select is((pg_temp.inc(5, pg_temp.id('m6'))->>'status'), 'posted', 'a sibling grant works');

-- ── Decision 22 ──
update identity.accounts set status = 'restricted' where user_id = pg_temp.u(7);
select is((pg_temp.inc(1, pg_temp.id('m7'))->>'status'), 'posted', 'a restricted account can receive income');
update identity.accounts set status = 'suspended' where user_id = pg_temp.u(7);
select throws_ok($$ select pg_temp.inc(1, pg_temp.id('m7')) $$, 'P0001', 'target_not_eligible', 'a suspended account cannot');
update identity.accounts set status = 'active' where user_id = pg_temp.u(7);
do $$ begin
  perform api.set_membership_status(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('m8'), 'suspended', 'Review', pg_temp.k());
end $$;
select throws_ok($$ select pg_temp.inc(4, pg_temp.id('m8')) $$, 'P0001', 'target_not_eligible', 'a suspended membership cannot');
do $$ begin
  perform api.end_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('m8'), 'Left', pg_temp.k());
end $$;
select throws_ok($$ select pg_temp.inc(4, pg_temp.id('m8')) $$, 'P0001', 'target_not_eligible', 'an ended membership cannot');

-- ── Validation (13) ──
select throws_ok($$ select pg_temp.inc(4, pg_temp.id('m6'), '0') $$, 'P0001', 'validation_error', 'zero is refused');
select throws_ok($$ select pg_temp.inc(4, pg_temp.id('m6'), '-5') $$, 'P0001', 'validation_error', 'negative is refused');
select throws_ok($$ select pg_temp.inc(4, pg_temp.id('m6'), '1.001') $$, 'P0001', 'validation_error', 'too many decimals');
select throws_ok($$ select pg_temp.inc(4, pg_temp.id('m6'), '10', null, null, 'EUR') $$, 'P0001', 'currency_not_supported', 'unsupported currency');
select throws_ok(
  $$ select pg_temp.inc(4, pg_temp.id('m6'), '10', null, null, 'NGN', to_char((now() at time zone 'UTC')::date + 2, 'YYYY-MM-DD')) $$,
  'P0001', 'validation_error', 'a date after tomorrow is refused'
);
select throws_ok($$ select pg_temp.inc(4, pg_temp.id('m6'), '10', null, array[]::uuid[]) $$, 'P0001', 'evidence_required', 'a receipt is required');
create temp table k1 as select pg_temp.k() as k;
select throws_ok(
  $$ select pg_temp.inc(4, pg_temp.id('m6'), '10', (select k from k1), array[pg_temp.receipt(1, pg_temp.id('m6'), (select k from k1))]) $$,
  'P0001', 'evidence_invalid', 'another person''s receipt is refused'
);
select throws_ok(
  $$ select pg_temp.inc(4, pg_temp.id('m6'), '10', null, array[pg_temp.receipt(4, pg_temp.id('m6'), pg_temp.k())]) $$,
  'P0001', 'evidence_invalid', 'a receipt bound to another attempt is refused'
);
select throws_ok(
  $$ select pg_temp.inc(4, pg_temp.id('m6'), '10', (select k from k1), array[pg_temp.receipt(4, pg_temp.id('m6'), (select k from k1), false)]) $$,
  'P0001', 'evidence_invalid', 'an unverified receipt is refused'
);
create temp table expired as select pg_temp.receipt(4, pg_temp.id('m6'), (select k from k1)) as e;
alter table evidence.files disable trigger files_guard;
update evidence.files set expires_at = now() - interval '1 minute' where id = (select e from expired);
alter table evidence.files enable trigger files_guard;
select throws_ok(
  $$ select pg_temp.inc(4, pg_temp.id('m6'), '10', (select k from k1), array[(select e from expired)]) $$,
  'P0001', 'evidence_invalid', 'an expired receipt is refused'
);
select throws_ok(
  $$ select pg_temp.inc(4, pg_temp.id('m6'), '10', null,
       array[(select id from evidence.files where attached_id = (select (r->>'incomeId')::uuid from first))]) $$,
  'P0001', 'evidence_invalid', 'a used receipt is refused'
);
select is(
  (select api.finalize_evidence_upload(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4),
     (api.create_evidence_upload(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('m6'), pg_temp.k(), 'r.png',
       'image/png', 10, repeat('c', 64))->>'evidenceId')::uuid, 10, repeat('d', 64), 'image/png')->>'status'),
  'cancelled', 'bytes that do not match the declared checksum cancel the receipt'
);
select is((select count(*)::int from finance.income_records), 5, 'failed attempts post nothing');

-- ── Idempotency and cancellation (14) ──
create temp table k2 as select pg_temp.k() as k, null::uuid as e;
update k2 set e = pg_temp.receipt(4, pg_temp.id('m6'), k);
create temp table second as select pg_temp.inc(4, pg_temp.id('m6'), '50.00', (select k from k2), array[(select e from k2)]) as r;
select is(
  (pg_temp.inc(4, pg_temp.id('m6'), '50.00', (select k from k2), array[(select e from k2)])->>'replayed'), 'true',
  'the same request replays'
);
select is((select count(*)::int from finance.income_records where idempotency_key = (select k from k2)), 1, 'it posted once');
select throws_ok(
  $$ select pg_temp.inc(4, pg_temp.id('m6'), '51.00', (select k from k2), array[(select e from k2)]) $$,
  'P0001', 'idempotency_conflict', 'same key, different request'
);
select is(
  (api.cancel_income_attempt(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('m6'), 'Connection lost', (select k from k2))->>'reference'),
  (select r->>'reference' from second), 'cancelling a posted attempt returns the posted income'
);
create temp table k3 as select pg_temp.k() as k, null::uuid as e;
update k3 set e = pg_temp.receipt(4, pg_temp.id('m6'), k);
select throws_ok(
  $$ select api.cancel_income_attempt(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('m6'), '', (select k from k3)) $$,
  'P0001', 'validation_error', 'cancelling needs a reason'
);
select is(
  (api.cancel_income_attempt(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('m6'), 'Connection lost', (select k from k3))->>'status'),
  'cancelled', 'an attempt that never posted is cancelled'
);
select throws_ok(
  $$ select pg_temp.inc(4, pg_temp.id('m6'), '50.00', (select k from k3), array[(select e from k3)]) $$,
  'P0001', 'attempt_cancelled', 'a cancelled attempt cannot post later'
);
do $$ begin
  perform api.set_role_permission(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'record_income', false, 'Directors only', pg_temp.k());
end $$;
select throws_ok(
  $$ select pg_temp.inc(4, pg_temp.id('m6'), '50.00', (select k from k2), array[(select e from k2)]) $$,
  'P0001', 'authorization_denied', 'a replay after losing the permission is denied'
);
do $$ begin
  perform api.set_role_permission(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'record_income', true, 'Restore', pg_temp.k());
end $$;

-- ── Step-up and restricted actors (16) ──
update identity.session_pin_proofs set verified_at = now() - interval '10 minutes' where user_id = pg_temp.u(4);
select throws_ok($$ select pg_temp.inc(4, pg_temp.id('m6')) $$, 'P0001', 'step_up_required', 'recording income needs the PIN');
update identity.session_pin_proofs set verified_at = now() where user_id = pg_temp.u(4);
update identity.accounts set status = 'restricted' where user_id = pg_temp.u(4);
select throws_ok($$ select pg_temp.inc(4, pg_temp.id('m6')) $$, 'P0001', 'authorization_denied', 'restricted accounts cannot record income');
update identity.accounts set status = 'active' where user_id = pg_temp.u(4);

-- ── Split changes affect future income only (15) ──
do $$ begin
  perform api.set_allocation(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 1,
    (select jsonb_agg(jsonb_build_object('pocketId', l.pocket_id, 'name', l.name, 'basisPoints', case when l.sort_order = 1 then 10000 else 0 end) order by l.sort_order)
     from ledger.allocation_policy_lines l join ledger.active_allocation_policies a on a.policy_id = l.policy_id
     where a.tenant_id = pg_temp.id('tenant')),
    'All to Point Value', pg_temp.k());
end $$;
select is(
  (select array_agg(a->>'amount' order by n) from jsonb_array_elements(pg_temp.inc(4, pg_temp.id('m6'), '10.00')->'allocations') with ordinality x (a, n)),
  array['10.00', '0.00', '0.00', '0.00', '0.00'], 'new income follows the new split'
);
select is(
  (select array_agg(basis_points order by sort_order) from finance.income_allocations where income_id = (select (r->>'incomeId')::uuid from first)),
  array[4000, 1000, 1500, 2500, 1000], 'posted income keeps the split it was posted with'
);

-- No active split → allocation_policy_missing (simulated for the other network).
alter table ledger.active_allocation_policies disable trigger active_allocation_policies_no_delete;
delete from ledger.active_allocation_policies where tenant_id = pg_temp.id('other');
alter table ledger.active_allocation_policies enable trigger active_allocation_policies_no_delete;
select throws_ok($$ select pg_temp.inc(11, pg_temp.id('m12')) $$, 'P0001', 'allocation_policy_missing', 'no split, no income');

-- ── Provenance (17) ──
do $$ begin
  perform api.move_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('m6'), pg_temp.id('T2'), 'Team change', pg_temp.k());
end $$;
select is((pg_temp.inc(5, pg_temp.m(6, pg_temp.id('T2')))->>'membershipId')::uuid, pg_temp.m(6, pg_temp.id('T2')),
  'new income lands on the new membership');
select ok(
  (select sum(posted) from ledger.balances where office_id = pg_temp.id('T') and owner_user_id = pg_temp.u(6)) > 0
  and (select count(*) from finance.income_records where membership_id = pg_temp.id('m6')) >= 3,
  'old income stays with the old membership and office'
);

-- ── Targets (W-08 step 1) ──
select is(
  (select array_agg(i->'person'->>'uid' order by i->'person'->>'uid')
   from jsonb_array_elements(api.income_targets(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4))->'items') i),
  null::text[], 'Team A has no eligible member left for its leader'
);
select ok(
  exists (select 1 from jsonb_array_elements(api.income_targets(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1))->'items') i
          where i->'person'->>'uid' = pg_temp.uid(6))
  and not exists (select 1 from jsonb_array_elements(api.income_targets(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1))->'items') i
          where i->'person'->>'uid' in (pg_temp.uid(1), pg_temp.uid(8))),
  'targets are the eligible members in scope, never oneself'
);

select is((select count(*)::int from ledger.verify_balances()), 0, 'projection still matches the ledger');

select * from finish();
rollback;
