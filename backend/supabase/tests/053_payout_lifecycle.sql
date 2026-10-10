-- Blueprint 05 — B6 test 4: primary, replace, deactivate, list, reveal, storage rules.
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(37);

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
-- Newest active membership of user n.
create function pg_temp.m(n int) returns uuid language sql stable as $$
  select id from org.memberships where user_id = pg_temp.u(n) and status = 'active'
  order by started_at desc, id limit 1
$$;
-- Stand-ins for what the Edge Function sends: ciphertext, HMAC fingerprint, last 4.
create function pg_temp.ct() returns text language sql volatile as
  $$ select encode(extensions.gen_random_bytes(38), 'base64') $$;
create function pg_temp.fp(p_bank text, p_number text) returns text language sql immutable as
  $$ select encode(extensions.digest(p_bank || ':' || p_number, 'sha256'), 'hex') $$;
create function pg_temp.prepare(n int, p_bank text, p_number text, p_key text, p_replaces uuid default null)
returns jsonb language sql volatile as $$
  select api.prepare_account_lookup(pg_temp.u(n), pg_temp.s(n), pg_temp.m(n), p_bank, pg_temp.ct(), 1,
    pg_temp.fp(p_bank, p_number), right(p_number, 4), p_replaces, p_key)
$$;
create function pg_temp.resolve(n int, p_lookup uuid, p_name text) returns jsonb language sql volatile as $$
  select api.record_account_lookup(pg_temp.u(n), pg_temp.s(n), pg_temp.m(n), p_lookup, 'resolved', p_name)
$$;
create function pg_temp.confirm(n int, p_lookup uuid, p_key text, p_reason text default null) returns jsonb
language sql volatile as $$
  select api.confirm_payout_account(pg_temp.u(n), pg_temp.s(n), pg_temp.m(n), p_lookup, p_reason, p_key)
$$;
-- Full add flow; returns the new payout account id.
create function pg_temp.add(n int, p_bank text, p_number text, p_name text default 'ADA OBI') returns uuid
language plpgsql volatile as $$
declare
  lookup uuid;
begin
  lookup := (pg_temp.prepare(n, p_bank, p_number, pg_temp.k())->>'lookupId')::uuid;
  perform pg_temp.resolve(n, lookup, p_name);
  return (pg_temp.confirm(n, lookup, pg_temp.k())->'payoutAccount'->>'payoutAccountId')::uuid;
end;
$$;

-- 1 President only · 2 Team Leader · 3, 4, 5 members · 9 Elivate admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from unnest(array[1, 2, 3, 4, 5, 9]) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from unnest(array[1, 2, 3, 4, 5, 9]) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from unnest(array[1, 2, 3, 4, 5, 9]) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(9), 'Test admin');
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('tenant'), 'Pilot', pg_temp.k());
end $$;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', null, array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(n), pg_temp.k())
  from unnest(array[3, 4, 5]) n;
end $$;
insert into payout.banks (provider, code, name, active) values
  ('paystack', '058', 'Guaranty Trust Bank', true),
  ('paystack', '044', 'Access Bank', true),
  ('paystack', '035A', 'ALAT by WEMA', true),
  ('paystack', '999', 'Closed Bank', false);

insert into ids select 'A1', pg_temp.add(3, '058', '0123456789');
insert into ids select 'A2', pg_temp.add(3, '044', '1111111111');
insert into ids select 'B1', pg_temp.add(4, '058', '2222222222');

select ok(
  (select usable_from = created_at + interval '24 hours' from payout.accounts where id = pg_temp.id('A2')),
  'a later account waits 24 hours (Q6)'
);

-- ── Primary ──
update identity.session_pin_proofs set verified_at = now() - interval '6 minutes' where user_id = pg_temp.u(3);
select throws_ok(
  $$ select api.set_primary_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('A1'), pg_temp.k()) $$,
  'P0001', 'step_up_required', 'primary change needs the PIN'
);
update identity.session_pin_proofs set verified_at = now() where user_id = pg_temp.u(3);
select is(
  api.set_primary_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('A1'), 'primary-key-00001')->>'changed',
  'true', 'first primary set'
);
select is(
  api.set_primary_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('A2'), 'primary-key-00002')->'payoutAccount'->>'isPrimary',
  'true', 'primary moves'
);
select is(
  (select array_agg(id order by id) from payout.accounts where owner_user_id = pg_temp.u(3) and is_primary),
  array[pg_temp.id('A2')], 'one primary per currency and rail'
);
select is(
  api.set_primary_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('A2'), 'primary-key-00003')->>'changed',
  'false', 'already primary: no change'
);
select throws_ok(
  $$ select api.set_primary_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('B1'), pg_temp.k()) $$,
  'P0001', 'not_found', 'no command touches another owner''s account'
);
select throws_ok(
  $$ update payout.accounts set is_primary = true where id = pg_temp.id('A1') $$,
  '23505', null, 'the database itself allows only one primary'
);

-- ── Replace (two calls) ──
insert into ids select 'L3', (pg_temp.prepare(3, '035A', '3333333333', 'lookup-key-000003', pg_temp.id('A2'))->>'lookupId')::uuid;
do $$ begin perform pg_temp.resolve(3, pg_temp.id('L3'), 'ADA OBI'); end $$;
select throws_ok(
  $$ select pg_temp.confirm(3, pg_temp.id('L3'), 'replace-key-00001') $$,
  'P0001', 'validation_error', 'a replacement needs a reason'
);
select throws_ok(
  $$ select pg_temp.confirm(3, pg_temp.id('L3'), 'replace-key-00001', 'ab') $$,
  'P0001', 'validation_error', 'reason is 3–500 characters'
);
insert into ids select 'A3', (pg_temp.confirm(3, pg_temp.id('L3'), 'replace-key-00001', 'Moved banks')->'payoutAccount'->>'payoutAccountId')::uuid;
select is(
  (select status::text || ':' || is_primary::text || ':' || replaced_by_id::text from payout.accounts where id = pg_temp.id('A2')),
  'replaced:false:' || pg_temp.id('A3')::text, 'the old account is kept as replaced'
);
select is(
  (select is_primary::text || ':' || replaces_id::text || ':' || verification_status::text from payout.accounts where id = pg_temp.id('A3')),
  'true:' || pg_temp.id('A2')::text || ':verified', 'primary carried to the verified replacement'
);
select ok(
  (select usable_from = created_at + interval '24 hours' from payout.accounts where id = pg_temp.id('A3')),
  'a replacement waits 24 hours'
);
select is(
  (select reason from audit.security_events where action = 'payout_account.replaced' and actor_user_id = pg_temp.u(3)),
  'Moved banks', 'replacement audited with its reason'
);
select throws_ok(
  $$ select pg_temp.prepare(3, '058', '4444444444', pg_temp.k(), pg_temp.id('A2')) $$,
  'P0001', 'conflict', 'a replaced account can''t be replaced again'
);
select throws_ok(
  $$ select pg_temp.prepare(3, '058', '4444444444', pg_temp.k(), pg_temp.id('B1')) $$,
  'P0001', 'not_found', 'can''t replace another person''s account'
);

-- ── Deactivate ──
select throws_ok(
  $$ select api.deactivate_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('A3'), null, pg_temp.k()) $$,
  'P0001', 'validation_error', 'deactivation needs a reason (Q8)'
);
select is(
  api.deactivate_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('A3'), 'Closed it', 'deact-key-000001')->'payoutAccount'->>'status',
  'deactivated', 'deactivated'
);
select is(
  (select is_primary::text || ':' || deactivated_reason from payout.accounts where id = pg_temp.id('A3')),
  'false:Closed it', 'primary cleared, reason kept'
);
select is(
  (select count(*)::int from payout.accounts where owner_user_id = pg_temp.u(3) and is_primary),
  0, 'no automatic new primary'
);
select is(
  api.deactivate_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('A3'), 'Closed it', 'deact-key-000001')->>'replayed',
  'true', 'same key replays'
);
select throws_ok(
  $$ select api.deactivate_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('A3'), 'Again', pg_temp.k()) $$,
  'P0001', 'conflict', 'already deactivated'
);
select throws_ok(
  $$ select api.set_primary_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('A3'), pg_temp.k()) $$,
  'P0001', 'conflict', 'a deactivated account can''t be primary'
);
select throws_ok(
  $$ select api.deactivate_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('B1'), 'Not mine', pg_temp.k()) $$,
  'P0001', 'not_found', 'can''t deactivate another person''s account'
);

-- ── Mismatched accounts can't be primary ──
set local session_replication_role = replica;
update payout.accounts set name_match = 'mismatched' where id = pg_temp.id('A1');
set local session_replication_role = origin;
select throws_ok(
  $$ select api.set_primary_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('A1'), pg_temp.k()) $$,
  'P0001', 'conflict', 'a mismatched account can''t be primary'
);

-- ── Storage rules ──
select throws_ok(
  $$ delete from payout.accounts where id = pg_temp.id('A1') $$,
  'P0001', 'invariant_violation', 'accounts are never deleted'
);
select throws_ok(
  $$ update payout.accounts set account_last4 = '0000' where id = pg_temp.id('A1') $$,
  'P0001', 'invariant_violation', 'number columns are immutable'
);
select throws_ok(
  $$ update payout.accounts set owner_user_id = pg_temp.u(4) where id = pg_temp.id('A1') $$,
  'P0001', 'invariant_violation', 'ownership is immutable'
);
select throws_ok(
  $$ update payout.accounts set status = 'active', deactivated_at = null, deactivated_reason = null where id = pg_temp.id('A3') $$,
  'P0001', 'invariant_violation', 'a deactivated account stays deactivated'
);

-- ── List and reveal ──
select is(
  (select string_agg(i->>'status', ',' order by n) from jsonb_array_elements(
     api.list_payout_accounts(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3))->'items') with ordinality as x (i, n)
   where n = 1) || ':' ||
  jsonb_array_length(api.list_payout_accounts(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3))->'items'),
  'active:3', 'own accounts, active first, history kept'
);
select ok(
  (select bool_and(i->>'accountNumberMasked' ~ '^•••• [0-9]{4}$' and not (i ? 'accountCiphertext'))
   from jsonb_array_elements(api.list_payout_accounts(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3))->'items') i),
  'numbers are masked and ciphertext never listed'
);
select is(
  jsonb_array_length(api.list_payout_accounts(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4))->'items'),
  1, 'each person sees only their own accounts'
);
update identity.session_pin_proofs set verified_at = now() - interval '6 minutes' where user_id = pg_temp.u(3);
select throws_ok(
  $$ select api.reveal_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('A1')) $$,
  'P0001', 'step_up_required', 'reveal needs the PIN'
);
update identity.session_pin_proofs set verified_at = now() where user_id = pg_temp.u(3);
select is(
  api.reveal_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('A1'))->>'ciphertext',
  (select account_ciphertext from payout.accounts where id = pg_temp.id('A1')), 'reveal hands the ciphertext to Edge'
);
select is(
  (select count(*)::int from audit.security_events where action = 'payout_account.revealed' and actor_user_id = pg_temp.u(3)),
  1, 'every reveal is audited'
);
select throws_ok(
  $$ select api.reveal_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('B1')) $$,
  'P0001', 'not_found', 'no reveal of another person''s account'
);
select is(
  (select array_agg(distinct action order by action) from audit.security_events where actor_user_id = pg_temp.u(3) and action like 'payout_account.%'),
  array['payout_account.added', 'payout_account.deactivated', 'payout_account.lookup', 'payout_account.primary_changed',
        'payout_account.replaced', 'payout_account.revealed'],
  'every change is audited'
);

select * from finish();
rollback;
