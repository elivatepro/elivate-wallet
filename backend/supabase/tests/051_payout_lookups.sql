-- Blueprint 05 — B6 test 2: lookup proofs, gate, replay, limits.
begin;
create extension if not exists pgtap with schema extensions;
select plan(34);

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

-- ── Gate, workspace and authority ──
update identity.session_pin_proofs set verified_at = now() - interval '6 minutes' where user_id = pg_temp.u(3);
select throws_ok(
  $$ select pg_temp.prepare(3, '058', '0123456789', 'lookup-key-000001') $$,
  'P0001', 'step_up_required', 'a lookup needs the PIN within 5 minutes'
);
update identity.session_pin_proofs set verified_at = now() where user_id = pg_temp.u(3);
select throws_ok(
  $$ select pg_temp.prepare(1, '058', '0123456789', 'lookup-key-000001') $$,
  'P0001', 'authorization_denied', 'a President-only person has no payout accounts'
);
select throws_ok(
  $$ select api.prepare_account_lookup(pg_temp.u(3), pg_temp.s(3), pg_temp.m(4), '058', pg_temp.ct(), 1,
       pg_temp.fp('058', '0123456789'), '6789', null, 'lookup-key-000001') $$,
  'P0001', 'workspace_invalid', 'someone else''s membership is not a workspace'
);
update identity.accounts set status = 'restricted' where user_id = pg_temp.u(5);
select throws_ok(
  $$ select pg_temp.prepare(5, '058', '0123456789', 'lookup-key-000001') $$,
  'P0001', 'authorization_denied', 'restricted accounts cannot change payout accounts'
);
update identity.accounts set status = 'active' where user_id = pg_temp.u(5);

-- ── Input ──
select throws_ok(
  $$ select pg_temp.prepare(3, '999', '0123456789', 'lookup-key-000001') $$,
  'P0001', 'bank_unknown', 'an inactive bank is unknown'
);
select throws_ok(
  $$ select pg_temp.prepare(3, '123', '0123456789', 'lookup-key-000001') $$,
  'P0001', 'bank_unknown', 'a bank outside the list is unknown'
);
select throws_ok(
  $$ select pg_temp.prepare(3, '05 8', '0123456789', 'lookup-key-000001') $$,
  'P0001', 'validation_error', 'malformed bank code'
);
select throws_ok(
  $$ select api.prepare_account_lookup(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), '058', '0123456789', 1,
       pg_temp.fp('058', '0123456789'), '6789', null, 'lookup-key-000001') $$,
  'P0001', 'validation_error', 'plain digits are not accepted as ciphertext'
);
select throws_ok(
  $$ select api.prepare_account_lookup(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), '058', pg_temp.ct(), 1,
       'abc', '6789', null, 'lookup-key-000001') $$,
  'P0001', 'validation_error', 'fingerprint must be 64 hex'
);
select throws_ok(
  $$ select pg_temp.prepare(3, '058', '0123456789', 'short') $$,
  'P0001', 'validation_error', 'idempotency key format'
);

-- ── Proof and replay ──
insert into ids select 'L1', (pg_temp.prepare(3, '058', '0123456789', 'lookup-key-000001')->>'lookupId')::uuid;
select is(
  (select status::text || ':' || account_last4 || ':' || (expires_at - created_at)::text
   from payout.account_lookups where id = pg_temp.id('L1')),
  'pending:6789:00:15:00', 'a pending proof valid for 15 minutes, bound to the last 4'
);
select is(
  pg_temp.prepare(3, '058', '0123456789', 'lookup-key-000001')->>'lookupId',
  pg_temp.id('L1')::text, 'same key and data returns the same proof'
);
select is((select count(*)::int from payout.account_lookups where owner_user_id = pg_temp.u(3)), 1, 'no second row');
select throws_ok(
  $$ select pg_temp.prepare(3, '058', '0123456780', 'lookup-key-000001') $$,
  'P0001', 'idempotency_conflict', 'same key, different number'
);
select throws_ok(
  $$ select pg_temp.prepare(3, '044', '0123456789', 'lookup-key-000001') $$,
  'P0001', 'idempotency_conflict', 'same key, different bank'
);
select is(
  pg_temp.resolve(3, pg_temp.id('L1'), '  ADA   OBI ')->>'accountName',
  'ADA OBI', 'the provider name is stored trimmed'
);
select is(
  pg_temp.resolve(3, pg_temp.id('L1'), 'SOMEONE ELSE')->>'accountName',
  'ADA OBI', 'the first provider answer is final'
);
select is(
  (select name_match::text from payout.account_lookups where id = pg_temp.id('L1')),
  'identity_pending', 'no NIN yet: identity check pending'
);
select ok(
  not (pg_temp.prepare(3, '058', '0123456789', 'lookup-key-000001') ? 'accountNumber'),
  'the proof never returns a full number'
);
select throws_ok(
  $$ select api.record_account_lookup(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4), pg_temp.id('L1'), 'resolved', 'X Y') $$,
  'P0001', 'not_found', 'another person''s proof is not found'
);
insert into ids select 'L2', (pg_temp.prepare(3, '044', '1111111111', 'lookup-key-000002')->>'lookupId')::uuid;
select throws_ok(
  format($$ select api.record_account_lookup(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), %L, 'resolved', E'ADA\u0007OBI') $$, pg_temp.id('L2')),
  'P0001', 'validation_error', 'control characters in a provider name are rejected'
);
select is(
  api.record_account_lookup(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('L2'), 'not_found', null)->>'status',
  'not_found', 'provider said no such account'
);
select throws_ok(
  $$ update payout.account_lookups set bank_code = '044' where id = pg_temp.id('L1') $$,
  'P0001', 'invariant_violation', 'proof identity is immutable'
);
select throws_ok(
  $$ delete from payout.account_lookups where id = pg_temp.id('L1') $$,
  'P0001', 'invariant_violation', 'proofs are kept'
);

-- Expired before an answer: terminal.
insert into ids select 'L3', (pg_temp.prepare(3, '044', '2222222222', 'lookup-key-000003')->>'lookupId')::uuid;
set local session_replication_role = replica;
update payout.account_lookups set created_at = created_at - interval '16 minutes', expires_at = expires_at - interval '16 minutes'
where id = pg_temp.id('L3');
set local session_replication_role = origin;
select throws_ok(
  $$ select pg_temp.resolve(3, pg_temp.id('L3'), 'ADA OBI') $$,
  'P0001', 'payout_lookup_expired', 'an expired proof can''t be answered'
);
select throws_ok(
  $$ select pg_temp.prepare(3, '044', '2222222222', 'lookup-key-000003') $$,
  'P0001', 'payout_lookup_expired', 'retrying an expired unanswered proof fails'
);

-- ── Audit ──
select is(
  (select count(*)::int from audit.security_events where action = 'payout_account.lookup' and actor_user_id = pg_temp.u(3)),
  2, 'each recorded answer is audited once'
);
select ok(
  not exists (
    select 1 from audit.security_events
    where action like 'payout_account.%'
      and (safe_after::text like '%ADA%'
        or regexp_replace(safe_after::text, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '', 'g') ~ '[0-9]{10}')
  ),
  'lookup audit holds no names or numbers'
);

-- ── Limits (Q9) ──
-- user 4: 10 lookups in the hour, then refused.
do $$ begin
  perform pg_temp.prepare(4, '058', lpad(n::text, 10, '0'), 'limit-key-' || lpad(n::text, 8, '0')) from generate_series(1, 10) n;
end $$;
select throws_ok(
  $$ select pg_temp.prepare(4, '058', '9999999999', 'limit-key-00000011') $$,
  'P0001', 'rate_limited', 'the 11th lookup in an hour is refused'
);
select ok(
  (select (pg_temp.prepare(4, '058', lpad('1', 10, '0'), 'limit-key-00000001')->>'lookupId') is not null),
  'replaying an existing key is not a new lookup'
);
set local session_replication_role = replica;
update payout.account_lookups set created_at = created_at - interval '2 hours', expires_at = expires_at - interval '2 hours'
where owner_user_id = pg_temp.u(4);
set local session_replication_role = origin;
do $$ begin
  perform pg_temp.prepare(4, '058', lpad(n::text, 10, '0'), 'limit-key-' || lpad(n::text, 8, '0')) from generate_series(11, 20) n;
end $$;
set local session_replication_role = replica;
update payout.account_lookups set created_at = created_at - interval '2 hours', expires_at = expires_at - interval '2 hours'
where owner_user_id = pg_temp.u(4) and created_at > now() - interval '1 hour';
set local session_replication_role = origin;
do $$ begin
  perform pg_temp.prepare(4, '058', lpad(n::text, 10, '0'), 'limit-key-' || lpad(n::text, 8, '0')) from generate_series(21, 30) n;
end $$;
set local session_replication_role = replica;
update payout.account_lookups set created_at = created_at - interval '2 hours', expires_at = expires_at - interval '2 hours'
where owner_user_id = pg_temp.u(4) and created_at > now() - interval '1 hour';
set local session_replication_role = origin;
select throws_ok(
  $$ select pg_temp.prepare(4, '058', '9999999999', 'limit-key-00000031') $$,
  'P0001', 'rate_limited', 'the 31st lookup in a day is refused'
);

-- Active account cap (5).
do $$ begin
  perform pg_temp.add(2, '058', lpad(n::text, 10, '7'), 'ADA OBI') from generate_series(1, 5) n;
end $$;
select throws_ok(
  $$ select pg_temp.prepare(2, '044', '3333333333', pg_temp.k()) $$,
  'P0001', 'conflict', 'a sixth active account is refused'
);
select throws_ok(
  $$ select pg_temp.prepare(2, '058', '7777777771', pg_temp.k()) $$,
  'P0001', 'payout_account_exists', 'an active account can''t be looked up again'
);
select lives_ok(
  format($$ select pg_temp.prepare(2, '044', '3333333333', pg_temp.k(), %L) $$,
    (select id from payout.accounts where owner_user_id = pg_temp.u(2) order by created_at, id limit 1)),
  'a replacement lookup is allowed at the cap'
);

select * from finish();
rollback;
