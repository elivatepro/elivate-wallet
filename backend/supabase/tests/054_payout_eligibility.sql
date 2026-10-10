-- Blueprint 05 — B6 test 5: withdrawal eligibility, NIN re-check, snapshots.
begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

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

insert into ids select 'A1', pg_temp.add(3, '058', '0123456789', 'OBI ADA');
insert into ids select 'A2', pg_temp.add(3, '044', '1111111111', 'OBI ADA N');
insert into ids select 'A3', pg_temp.add(3, '035A', '2222222222', 'BOLA ADE');

-- Stand-in for the withdrawals slice's destination snapshot.
create temp table snapshot as
select id as source_payout_account_id, bank_code, bank_name, account_ciphertext, key_version,
  account_fingerprint, account_last4, account_name, verification_method, name_match, country_code, currency, rail
from payout.accounts where id = pg_temp.id('A1');

select is(
  (payout.eligible_destination(pg_temp.u(3), pg_temp.id('A1'))).id,
  pg_temp.id('A1'), 'the first account is usable at once, identity check pending (Q4-B)'
);
select throws_like(
  $$ select payout.eligible_destination(pg_temp.u(3), pg_temp.id('A2')) $$,
  'payout_account_unusable', 'a later account is cooling off (Q6)'
);
select throws_ok(
  $$ select payout.eligible_destination(pg_temp.u(4), pg_temp.id('A1')) $$,
  'P0001', 'not_found', 'only the owner''s accounts'
);

set local session_replication_role = replica;
update payout.accounts set usable_from = created_at where id in (pg_temp.id('A2'), pg_temp.id('A3'));
set local session_replication_role = origin;
select is(
  (payout.eligible_destination(pg_temp.u(3), pg_temp.id('A2'))).id,
  pg_temp.id('A2'), 'usable after 24 hours'
);

-- NIN lands: legal name Ada Ngozi Obi. A1 (OBI ADA) and A2 (OBI ADA N) match; A3 doesn't.
do $$ begin
  perform api.set_primary_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('A3'), pg_temp.k());
end $$;
create or replace function identity.legal_name(p_user_id uuid) returns jsonb
language sql stable set search_path = '' as $$
  select case when p_user_id = '10000000-0000-0000-0000-000000000003'::uuid
    then '{"given": "Ada", "middle": ["Ngozi"], "surname": "Obi"}'::jsonb end
$$;
select is(payout.recheck_name_match(pg_temp.u(3)), 3, 'every active account re-checked');
select is(
  (select array_agg(name_match::text order by account_name) from payout.accounts where owner_user_id = pg_temp.u(3)),
  array['mismatched', 'matched', 'matched'], 'two match, one fails'
);
select is(
  (select is_primary from payout.accounts where id = pg_temp.id('A3')),
  false, 'the failing account loses primary'
);
select is(
  (select count(*)::int from audit.security_events
   where action = 'payout_account.name_mismatch' and target_user_id = pg_temp.u(3)
     and safe_after->>'payoutAccountId' = pg_temp.id('A3')::text),
  1, 'the mismatch is audited'
);
select throws_like(
  $$ select payout.eligible_destination(pg_temp.u(3), pg_temp.id('A3')) $$,
  'payout_account_unusable', 'a mismatched account is unusable'
);
select is(payout.recheck_name_match(pg_temp.u(3)), 0, 're-checking again changes nothing');

-- Deactivation doesn't touch snapshots.
do $$ begin
  perform api.deactivate_payout_account(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3), pg_temp.id('A1'), 'Closed it', pg_temp.k());
end $$;
select throws_like(
  $$ select payout.eligible_destination(pg_temp.u(3), pg_temp.id('A1')) $$,
  'payout_account_unusable', 'a deactivated account is unusable'
);
select is(
  (select account_ciphertext || account_name || name_match::text from snapshot),
  (select account_ciphertext || 'OBI ADA' || 'identity_pending' from payout.accounts where id = pg_temp.id('A1')),
  'a snapshot copied before deactivation is unchanged'
);

-- Reasons in details.
create function pg_temp.reason(p_account uuid) returns text language plpgsql as $$
begin
  perform payout.eligible_destination(pg_temp.u(3), p_account);
  return 'usable';
exception when others then
  declare
    detail text;
  begin
    get stacked diagnostics detail = pg_exception_detail;
    return sqlerrm || ':' || coalesce(detail::jsonb->>'reason', '');
  end;
end;
$$;
select is(pg_temp.reason(pg_temp.id('A1')), 'payout_account_unusable:inactive', 'reason inactive');
select is(pg_temp.reason(pg_temp.id('A3')), 'payout_account_unusable:name_mismatch', 'reason name_mismatch');
set local session_replication_role = replica;
update payout.accounts set usable_from = now() + interval '1 hour' where id = pg_temp.id('A2');
set local session_replication_role = origin;
select is(pg_temp.reason(pg_temp.id('A2')), 'payout_account_unusable:cooling_off', 'reason cooling_off');

select * from finish();
rollback;
