-- Blueprint 04 — B6 041: wallet creation (D-01) through the membership hook
-- (org.create_membership → org.on_membership_created → ledger.ensure_wallet),
-- invitation acceptance, and the backfill.
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
create function pg_temp.m(n int, p_office uuid default null) returns uuid language sql stable as $$
  select id from org.memberships
  where user_id = pg_temp.u(n) and status = 'active' and office_id is not distinct from p_office
  order by started_at desc, id limit 1
$$;

-- 1 founder (President only) · 4 Team Leader in two networks · 6 member · 7 invitee
-- 8 pre-hook member · 9 other founder · 10 admin
insert into auth.users (id, email, aud, role, email_confirmed_at)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated', now() from generate_series(1, 10) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 10) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 10) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
insert into ids
select 'other', (api.start_network(pg_temp.u(9), pg_temp.s(9), 'Abuja Network', 'ABJ', pg_temp.k())->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), 'Pilot', pg_temp.k());
  perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('other'), 'Pilot', pg_temp.k());
end $$;

-- ── President-only accounts ──
select is(ledger.wallet_for(pg_temp.u(1)), null, 'starting a network creates no wallet for the founder');
select throws_ok($$ select ledger.require_wallet(pg_temp.u(1)) $$, 'P0001', 'no_wallet', 'require_wallet explains the missing wallet');
select is(ledger.ensure_wallet(pg_temp.u(1)), null, 'ensure_wallet creates nothing for a President-only account');

-- ── Through org.create_membership ──
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', null, array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
select isnt(ledger.wallet_for(pg_temp.u(4)), null, 'a leader named when an office is created gets a wallet');
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(6), pg_temp.k());
end $$;
select isnt(ledger.wallet_for(pg_temp.u(6)), null, 'adding a member creates their wallet');
select is(ledger.ensure_wallet(pg_temp.u(6)), ledger.wallet_for(pg_temp.u(6)), 'ensure_wallet is idempotent');
insert into ids
select 'O', (api.create_office(pg_temp.u(9), pg_temp.s(9), pg_temp.m(9), 'team_leader', 'Abuja Team', null, array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
select is((select count(*)::int from ledger.wallets where owner_user_id = pg_temp.u(4)), 1,
  'a second membership in another network creates no second wallet');

-- ── Invitation acceptance (Blueprint 03) ──
do $$ begin
  perform api.create_invitation(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.id('T'), 'member',
    'u7@example.test', gen_random_uuid(), encode(sha256('t7'::bytea), 'hex'), null, pg_temp.k());
end $$;
select is(ledger.wallet_for(pg_temp.u(7)), null, 'an invitation alone creates no wallet');
do $$ begin
  perform api.accept_invitation(pg_temp.u(7), pg_temp.s(7), encode(sha256('t7'::bytea), 'hex'), null, pg_temp.k());
end $$;
select isnt(ledger.wallet_for(pg_temp.u(7)), null, 'accepting an invitation creates the wallet');

-- A President who is also added as a member gets a wallet.
do $$ begin
  perform api.add_membership(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T')), pg_temp.id('T'), pg_temp.uid(1), pg_temp.k());
end $$;
select isnt(ledger.wallet_for(pg_temp.u(1)), null, 'a President who becomes a member gets a wallet');

-- ── Backfill: only memberships created before the hook existed ──
select is(ledger.backfill_wallets(), 0, 'the hook leaves nothing to backfill');
insert into org.memberships (tenant_id, office_id, user_id, role, created_by)
values (pg_temp.id('tenant'), pg_temp.id('T'), pg_temp.u(8), 'member', pg_temp.u(1));
select is(ledger.backfill_wallets(), 1, 'backfill creates the wallet of a membership that bypassed the hook, once');

-- ── Wallets outlive memberships (W-05) ──
do $$ begin
  perform api.end_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(6, pg_temp.id('T')), 'Left the team', pg_temp.k());
end $$;
select isnt(ledger.wallet_for(pg_temp.u(6)), null, 'ending every membership keeps the wallet');
select throws_ok($$ delete from ledger.wallets where owner_user_id = pg_temp.u(6) $$, 'P0001', 'invariant_violation',
  'wallets cannot be deleted');

select * from finish();
rollback;
