-- Blueprint 05: wallet link and owner alerts through the outbox.
begin;
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

-- ── Wallet link ──
insert into ids select 'A1', pg_temp.add(3, '058', '0123456789');
select is(
  (select wallet_id from payout.accounts where id = pg_temp.id('A1')),
  ledger.wallet_for(pg_temp.u(3)), 'the account carries the owner''s wallet'
);
select ok(
  not exists (select 1 from payout.account_lookups where wallet_id is distinct from ledger.wallet_for(owner_user_id)),
  'every proof carries its owner''s wallet'
);
select throws_ok(
  $$ update payout.accounts set wallet_id = ledger.wallet_for(pg_temp.u(4)) where id = pg_temp.id('A1') $$,
  'P0001', 'invariant_violation', 'the wallet never changes'
);
select throws_ok(
  format($$ insert into payout.account_lookups (owner_user_id, workspace_membership_id, lookup_key, provider, bank_code,
       account_ciphertext, key_version, account_fingerprint, account_last4, created_at, expires_at, wallet_id)
     values (%L, %L, 'lookup-key-999999', 'paystack', '058', %L, 1, %L, '6789', now(), now() + interval '15 minutes', %L) $$,
    pg_temp.u(3), pg_temp.m(3), pg_temp.ct(), pg_temp.fp('058', '0123456789'), ledger.wallet_for(pg_temp.u(4))),
  'P0001', 'invariant_violation', 'a proof can''t point at someone else''s wallet'
);
select throws_ok(
  $$ select pg_temp.prepare(1, '058', '0123456789', 'lookup-key-000009') $$,
  'P0001', 'authorization_denied', 'a President-only person (no wallet) has no payout accounts'
);

-- ── Alerts ──
insert into ids select 'A2', pg_temp.add(3, '044', '1111111111');
do $$ begin
  perform api.set_primary_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('A1'), pg_temp.k());
end $$;
insert into ids select 'L3', (pg_temp.prepare(3, '035A', '2222222222', 'lookup-key-000003', pg_temp.id('A1'))->>'lookupId')::uuid;
do $$ begin perform pg_temp.resolve(3, pg_temp.id('L3'), 'ADA OBI'); end $$;
insert into ids select 'A3', (pg_temp.confirm(3, pg_temp.id('L3'), 'replace-key-00001', 'Moved banks')->'payoutAccount'->>'payoutAccountId')::uuid;
do $$ begin
  perform api.deactivate_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('A2'), 'Closed it', pg_temp.k());
end $$;
create or replace function identity.legal_name(p_user_id uuid) returns jsonb
language sql stable set search_path = '' as $$
  select case when p_user_id = '10000000-0000-0000-0000-000000000003'::uuid
    then '{"given": "Bola", "middle": [], "surname": "Ade"}'::jsonb end
$$;
select is(payout.recheck_name_match(pg_temp.u(3)), 1, 'the NIN re-check fails the active account');

select is(
  (select array_agg(params->>'action' order by params->>'action')
   from outbox.events where template = 'payout_account.alert'),
  array['added', 'added', 'deactivated', 'name_mismatch', 'primary_changed', 'replaced'],
  'one alert per change, none for lookups'
);
select ok(
  (select bool_and(recipient_user_id = pg_temp.u(3) and recipient_email is null and tenant_id is null
     and aggregate_type = 'payout_account' and template_version = 1)
   from outbox.events where template = 'payout_account.alert'),
  'alerts go to the owner''s account, not an address, and belong to no network'
);
select ok(
  (select bool_and((select array_agg(k order by k) from jsonb_object_keys(params) k) = array['action', 'at', 'bankName'])
   from outbox.events where template = 'payout_account.alert'),
  'params are exactly action, bankName and at'
);
select is(
  (select params->>'bankName' from outbox.events
   where template = 'payout_account.alert' and params->>'action' = 'replaced'),
  'ALAT by WEMA', 'the bank name is the new account''s bank'
);
select ok(
  not exists (
    select 1 from outbox.events
    where template = 'payout_account.alert'
      and ((params - 'at')::text ~ '[0-9]{4}' or params::text like '%ADA%')
  ),
  'no account digits (not even the last 4) or names in any alert'
);
select ok(
  not exists (
    select 1 from outbox.events e
    where regexp_replace(e.params::text, '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z', '', 'g') ~ '[0-9]{10}'
  ),
  'no 10-digit run in any outbox payload'
);
select is(
  (select count(distinct dedupe_key)::int from outbox.events where template = 'payout_account.alert'),
  6, 'each alert has its own dedupe key'
);
select is(
  (select count(*)::int from outbox.deliveries d join outbox.events e on e.id = d.event_id
   where e.template = 'payout_account.alert' and d.status = 'pending'),
  6, 'each alert is queued for delivery'
);

select * from finish();
rollback;
