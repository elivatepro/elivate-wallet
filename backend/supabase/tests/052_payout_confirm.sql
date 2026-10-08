-- Blueprint 05 — B6 test 3: confirming a proof into a payout account.
begin;
create extension if not exists pgtap with schema extensions;
select plan(26);

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

-- A resolved proof for user 3.
insert into ids select 'L1', (pg_temp.prepare(3, '058', '0123456789', 'lookup-key-000001')->>'lookupId')::uuid;
select is(pg_temp.resolve(3, pg_temp.id('L1'), 'ADA OBI')->>'status', 'resolved', 'proof resolved');

update identity.session_pin_proofs set verified_at = now() - interval '6 minutes' where user_id = pg_temp.u(3);
select throws_ok(
  $$ select pg_temp.confirm(3, pg_temp.id('L1'), 'confirm-key-00001') $$,
  'P0001', 'step_up_required', 'confirming needs the PIN within 5 minutes'
);
update identity.session_pin_proofs set verified_at = now() where user_id = pg_temp.u(3);
select throws_ok(
  $$ select pg_temp.confirm(4, pg_temp.id('L1'), 'confirm-key-00001') $$,
  'P0001', 'not_found', 'another person''s proof is not found'
);
select throws_ok(
  $$ select pg_temp.confirm(3, pg_temp.id('L1'), 'confirm-key-00001', 'Because') $$,
  'P0001', 'validation_error', 'a reason belongs only to a replacement'
);

insert into ids select 'A1', (pg_temp.confirm(3, pg_temp.id('L1'), 'confirm-key-00001')->'payoutAccount'->>'payoutAccountId')::uuid;
select is(
  (select status::text || ':' || verification_status::text || ':' || verification_method::text || ':' || name_match::text || ':' || is_primary::text
   from payout.accounts where id = pg_temp.id('A1')),
  'active:verified:nuban_lookup:identity_pending:false',
  'confirmation creates a verified account, identity check pending, not primary'
);
select is(
  (select bank_name || ':' || account_name || ':' || account_last4 from payout.accounts where id = pg_temp.id('A1')),
  'Guaranty Trust Bank:ADA OBI:6789', 'bank name copied, provider name kept'
);
select ok(
  (select usable_from = created_at from payout.accounts where id = pg_temp.id('A1')),
  'a person''s first account is usable at once (Q6)'
);
select is(
  (select confirmed_payout_account_id from payout.account_lookups where id = pg_temp.id('L1')),
  pg_temp.id('A1'), 'the proof records what it confirmed'
);
select is(
  pg_temp.confirm(3, pg_temp.id('L1'), 'confirm-key-00001')->>'replayed',
  'true', 'same key replays the stored result'
);
select throws_ok(
  $$ select pg_temp.confirm(3, pg_temp.id('L1'), 'confirm-key-00002') $$,
  'P0001', 'conflict', 'a proof confirms once; another key can''t confirm it again'
);
select is((select count(*)::int from payout.accounts where owner_user_id = pg_temp.u(3)), 1, 'exactly one account');
select ok(
  not (pg_temp.confirm(3, pg_temp.id('L1'), 'confirm-key-00001')::text ~ '0123456789'),
  'the result never carries the full number'
);

-- Replay after expiry still returns the stored result.
set local session_replication_role = replica;
update payout.account_lookups set created_at = created_at - interval '1 hour', expires_at = expires_at - interval '1 hour'
where id = pg_temp.id('L1');
set local session_replication_role = origin;
select is(
  pg_temp.confirm(3, pg_temp.id('L1'), 'confirm-key-00001')->'payoutAccount'->>'payoutAccountId',
  pg_temp.id('A1')::text, 'same-key replay after proof expiry returns the stored result'
);

-- Expired at 15:01.
insert into ids select 'L2', (pg_temp.prepare(3, '044', '1111111111', 'lookup-key-000002')->>'lookupId')::uuid;
select is(pg_temp.resolve(3, pg_temp.id('L2'), 'ADA OBI')->>'status', 'resolved', 'second proof resolved');
set local session_replication_role = replica;
update payout.account_lookups set created_at = created_at - interval '15 minutes 1 second', expires_at = expires_at - interval '15 minutes 1 second'
where id = pg_temp.id('L2');
set local session_replication_role = origin;
select throws_ok(
  $$ select pg_temp.confirm(3, pg_temp.id('L2'), 'confirm-key-00003') $$,
  'P0001', 'payout_lookup_expired', 'an unconfirmed proof expires after 15 minutes'
);

-- Not found and pending proofs can't be confirmed.
insert into ids select 'L3', (pg_temp.prepare(3, '044', '2222222222', 'lookup-key-000003')->>'lookupId')::uuid;
select throws_ok(
  $$ select pg_temp.confirm(3, pg_temp.id('L3'), 'confirm-key-00004') $$,
  'P0001', 'conflict', 'a pending proof can''t be confirmed'
);
do $$ begin perform api.record_account_lookup(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('L3'), 'not_found', null); end $$;
select throws_ok(
  $$ select pg_temp.confirm(3, pg_temp.id('L3'), 'confirm-key-00005') $$,
  'P0001', 'account_not_found', 'a not-found proof can''t be confirmed'
);

-- Name mismatch once a legal name exists (stub replaced for this test).
create or replace function identity.legal_name(p_user_id uuid) returns jsonb
language sql stable set search_path = '' as $$
  select case when p_user_id = '10000000-0000-0000-0000-000000000004'::uuid
    then '{"given": "Bola", "middle": [], "surname": "Ade"}'::jsonb end
$$;
insert into ids select 'L4', (pg_temp.prepare(4, '058', '4444444444', 'lookup-key-000004')->>'lookupId')::uuid;
select is(pg_temp.resolve(4, pg_temp.id('L4'), 'ADA OBI')->>'nameMatch', 'mismatched', 'the lookup shows the mismatch');
select throws_ok(
  $$ select pg_temp.confirm(4, pg_temp.id('L4'), 'confirm-key-00006') $$,
  'P0001', 'payout_name_mismatch', 'a mismatched name blocks saving (Q2)'
);
insert into ids select 'L5', (pg_temp.prepare(4, '058', '5555555555', 'lookup-key-000005')->>'lookupId')::uuid;
select is(pg_temp.resolve(4, pg_temp.id('L5'), 'ADE BOLA')->>'nameMatch', 'matched', 'a matching name');
select is(
  pg_temp.confirm(4, pg_temp.id('L5'), 'confirm-key-00007')->'payoutAccount'->>'nameMatch',
  'matched', 'saved as matched'
);

-- Duplicate active account under a second proof.
insert into ids select 'L6', (pg_temp.prepare(5, '058', '6666666666', 'lookup-key-000006')->>'lookupId')::uuid;
insert into ids select 'L7', (pg_temp.prepare(5, '058', '6666666666', 'lookup-key-000007')->>'lookupId')::uuid;
do $$ begin
  perform pg_temp.resolve(5, pg_temp.id('L6'), 'ADA OBI');
  perform pg_temp.resolve(5, pg_temp.id('L7'), 'ADA OBI');
  perform pg_temp.confirm(5, pg_temp.id('L6'), 'confirm-key-00008');
end $$;
select throws_ok(
  $$ select pg_temp.confirm(5, pg_temp.id('L7'), 'confirm-key-00009') $$,
  'P0001', 'payout_account_exists', 'the same account can''t be saved twice by one person'
);
select lives_ok(
  $$ select pg_temp.add(2, '058', '6666666666') $$,
  'two people may save the same account (Q11)'
);
select ok(
  (select usable_from = created_at from payout.accounts where owner_user_id = pg_temp.u(2)),
  'the other person''s first account is usable at once too'
);

-- Losing the workspace or the network makes replays fail too (A-01).
update org.memberships set status = 'ended', ended_at = now(), is_primary = false where user_id = pg_temp.u(3);
select throws_ok(
  $$ select pg_temp.confirm(3, pg_temp.id('L1'), 'confirm-key-00001') $$,
  'P0001', 'workspace_invalid', 'replay after the membership ended is refused'
);
update org.tenants set status = 'suspended' where id = pg_temp.id('tenant');
select throws_ok(
  $$ select pg_temp.confirm(4, pg_temp.id('L5'), 'confirm-key-00007') $$,
  'P0001', 'network_not_active', 'replay in a suspended network is refused'
);

select * from finish();
rollback;
