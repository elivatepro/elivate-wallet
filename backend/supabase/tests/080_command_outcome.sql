-- Blueprint 08 — B6 080: unknown-outcome recovery (F-03, W-00).
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(14);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.uid(n int) returns text language sql stable as
  $$ select uid from identity.accounts where user_id = pg_temp.u(n) $$;
create function pg_temp.k() returns text language sql volatile as
  $$ select 'k' || md5(random()::text || clock_timestamp()::text) $$;
create temp table ids (name text primary key, id uuid, key text);
create function pg_temp.id(p_name text) returns uuid language sql stable as
  $$ select id from ids where name = p_name $$;
create function pg_temp.key(p_name text) returns text language sql stable as
  $$ select key from ids where name = p_name $$;
create function pg_temp.ws(n int) returns uuid language sql stable as $$
  select id from org.memberships where user_id = pg_temp.u(n) and status = 'active'
  order by (role = 'member'), started_at limit 1
$$;
create function pg_temp.outcome(n int, p_key text, p_command text default null) returns jsonb language sql volatile as
  $$ select api.command_outcome(pg_temp.u(n), pg_temp.s(n), p_key, p_command) $$;

-- 1 President · 4 Team Leader · 6 member · 10 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from unnest(array[1, 4, 6, 10]) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from unnest(array[1, 4, 6, 10]) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from unnest(array[1, 4, 6, 10]) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');
insert into ids (name, key) values ('start', pg_temp.k());
update ids set id = (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.key('start'))->>'tenantId')::uuid
where name = 'start';
do $$ begin
  perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('start'), 'Pilot', pg_temp.k());
end $$;
insert into ids (name, id)
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), 'team_leader', 'Team A', null,
  array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('T'), pg_temp.uid(6), pg_temp.k());
end $$;
insert into ids (name, id) select 'm6', pg_temp.ws(6);

-- One income by the Team Leader, keeping its key and result.
create temp table posted (key text, result jsonb);
do $$
declare
  key text := pg_temp.k();
  e uuid;
begin
  e := (api.create_evidence_upload(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('m6'), key, 'receipt.pdf',
    'application/pdf', 1000, repeat('b', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), e, 1000, repeat('b', 64), 'application/pdf');
  insert into posted values (key, api.record_income(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('m6'), 'NGN',
    '1000.00', 'Fiverr', to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null, array[e], key));
end $$;

select is((select result->>'walletId' from posted)::uuid, ledger.wallet_for(pg_temp.u(6)),
  'the income result names the wallet it went into');
select is(pg_temp.outcome(4, 'never-sent-key-0001')->>'status', 'not_found', 'an unknown key has no outcome');
select is(pg_temp.outcome(4, (select key from posted))->>'status', 'committed', 'a posted income is committed');
select is(pg_temp.outcome(4, (select key from posted))->>'command', 'record_income', 'and names its command');
select is(pg_temp.outcome(4, (select key from posted))->>'reference', (select result->>'reference' from posted),
  'with its public reference');
select ok(not (pg_temp.outcome(4, (select key from posted)) ? 'result'), 'but never the protected result itself');
select is(pg_temp.outcome(4, (select key from posted), 'record_income')->>'status', 'committed',
  'the expected command matches');
select throws_ok(
  format($$ select pg_temp.outcome(4, %L, 'set_allocation') $$, (select key from posted)),
  'P0001', 'idempotency_conflict', 'a different command under the same key is a conflict'
);
select is(pg_temp.outcome(6, (select key from posted))->>'status', 'not_found',
  'keys belong to their actor: nobody else learns about the attempt');
select is(pg_temp.outcome(1, pg_temp.key('start'))->>'status', 'committed', 'works for any stored command');
select ok(pg_temp.outcome(1, pg_temp.key('start'))->'reference' = 'null'::jsonb,
  'reference is null when the result has none');

-- An income attempt cancelled under its key (W-08 recovery).
create temp table cancelled_key as select pg_temp.k() as key;
do $$ begin
  perform api.cancel_income_attempt(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('m6'), 'Timed out, not sent',
    (select key from cancelled_key));
end $$;
select is(pg_temp.outcome(4, (select key from cancelled_key))->>'status', 'cancelled', 'a cancelled income attempt');

select throws_ok($$ select pg_temp.outcome(4, 'short') $$, 'P0001', 'validation_error', 'malformed key rejected');
select throws_ok(
  $$ select api.command_outcome(pg_temp.u(4), pg_temp.s(6), 'never-sent-key-0001') $$,
  'P0001', null, 'another person''s session is refused'
);

select * from finish();
rollback;
