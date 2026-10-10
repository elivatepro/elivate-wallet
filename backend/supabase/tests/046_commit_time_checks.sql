-- Fix 20261009040100: the ledger's deferred invariant checks fire at COMMIT,
-- outside the definer command, as the caller's role. Through the Edge
-- Functions that role is service_role, which has no usage on `ledger`. Each
-- test file here rolls back, so the commit is simulated: switch to
-- service_role and force the pending checks with SET CONSTRAINTS IMMEDIATE.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.k() returns text language sql volatile as
  $$ select 'k' || md5(random()::text || clock_timestamp()::text) $$;

-- 1 founder · 2 admin · 3 Team Leader · 4 member
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 4) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 4) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 4) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(2), 'Test admin');

create temp table t as
select (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid as tenant_id;
grant select on t to service_role;

-- Activation seeds the default split: one pending allocation_policies_complete check.
select lives_ok(
  $$ select api.activate_tenant(pg_temp.u(2), pg_temp.s(2), (select tenant_id from t), 'Pilot', pg_temp.k()) $$,
  'activation runs'
);
set local role service_role;
select lives_ok($$ set constraints all immediate $$, 'split check passes at commit as service_role');
reset role;
set constraints all deferred;

-- Income posts a transaction and journals: transactions_complete and journals_balanced.
do $$
declare
  president uuid := (select id from org.memberships where user_id = pg_temp.u(1) and status = 'active' limit 1);
  office uuid;
  target uuid;
  evidence uuid;
  key text := pg_temp.k();
begin
  office := (api.create_office(pg_temp.u(1), pg_temp.s(1), president, 'team_leader', 'Team A', null,
    array[(select uid from identity.accounts where user_id = pg_temp.u(3))], pg_temp.k())->>'officeId')::uuid;
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), president, office,
    (select uid from identity.accounts where user_id = pg_temp.u(4)), pg_temp.k());
  target := (select id from org.memberships where user_id = pg_temp.u(4) and office_id = office);
  evidence := (api.create_evidence_upload(pg_temp.u(1), pg_temp.s(1), president, target, key, 'receipt.pdf',
    'application/pdf', 1000, repeat('b', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(1), pg_temp.s(1), president, evidence, 1000, repeat('b', 64), 'application/pdf');
  perform api.record_income(pg_temp.u(1), pg_temp.s(1), president, target, 'NGN', '1000.00', 'Fiverr',
    to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null, array[evidence], key);
end $$;
select ok(
  exists (select 1 from ledger.journals j join ledger.transactions x on x.id = j.transaction_id
          where x.tenant_id = (select tenant_id from t)),
  'income posted a journal'
);
set local role service_role;
select lives_ok($$ set constraints all immediate $$, 'journal and transaction checks pass at commit as service_role');
reset role;

select ok(
  not has_function_privilege('service_role', 'ledger.check_journal_balanced()', 'execute')
  and not has_function_privilege('authenticated', 'ledger.check_policy_lines()', 'execute'),
  'the definer checks are not executable by API roles'
);

select * from finish();
rollback;
