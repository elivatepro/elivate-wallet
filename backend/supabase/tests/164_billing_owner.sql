-- Blueprint 16 — B6 164: the Billing Owner (W-19): one current owner with
-- history and audit, changed only with manage_subscription and a fresh PIN,
-- to an active member of the same network; a responsibility, not authority.
-- Billing is visible to manage_subscription holders and the owner only.
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(18);

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
create function pg_temp.ws(n int) returns uuid language sql stable as $$
  select id from org.memberships where user_id = pg_temp.u(n) and status = 'active'
  order by (role = 'member'), started_at limit 1
$$;
create function pg_temp.fails(p_sql text) returns text language plpgsql as $$
declare
  msg text;
  detail text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics msg = message_text, detail = pg_exception_detail;
  return msg || ':' || coalesce(case when detail like '{%' then detail::jsonb->>'reason' end, '');
end $$;
create function pg_temp.give(n int, p_target uuid) returns jsonb language sql volatile as $$
  select api.change_billing_owner(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_target, pg_temp.k())
$$;

-- 1 President (Cedar) · 2 leader · 3 member · 4 President (Pine) · 5 suspended member
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 5) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 5) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 5) n; end $$;
insert into ids select 'cedar', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Cedar Network', 'CDR', pg_temp.k(), null,
  'band_400', true)->>'tenantId')::uuid;
insert into ids select 'pine', (api.start_network(pg_temp.u(4), pg_temp.s(4), 'Pine Network', 'PIN', pg_temp.k(), null,
  'band_400', true)->>'tenantId')::uuid;
insert into ids select 'WT', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), 'world_team', 'World', null,
  array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('WT'), pg_temp.uid(3), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('WT'), pg_temp.uid(5), pg_temp.k());
  perform api.set_membership_status(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.ws(5), 'suspended', 'On leave',
    pg_temp.k());
end $$;

-- ── Who sees Billing (3) ──
select is((api.billing_overview(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1))->>'canManage')::boolean, true,
  'the President manages billing');
select is(pg_temp.fails($$ select api.billing_overview(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3)) $$),
  'authorization_denied:', 'a member without authority sees nothing');
select is(api.billing_overview(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1))->'owner'->>'uid', pg_temp.uid(1),
  'the founder is the first owner');

-- ── Changing the owner (9) ──
update identity.session_pin_proofs set verified_at = now() - interval '10 minutes' where user_id = pg_temp.u(1);
select is(pg_temp.fails($$ select pg_temp.give(1, pg_temp.ws(3)) $$), 'step_up_required:', 'it needs a fresh PIN');
update identity.session_pin_proofs set verified_at = now() where user_id = pg_temp.u(1);
select is(pg_temp.fails($$ select pg_temp.give(1, pg_temp.ws(4)) $$), 'not_found:', 'never someone from another network');
select is(pg_temp.fails($$ select pg_temp.give(1, (select id from org.memberships where user_id = pg_temp.u(5))) $$),
  'not_found:', 'never a suspended membership');
select is(pg_temp.give(1, pg_temp.ws(3))->'owner'->>'uid', pg_temp.uid(3), 'the President hands it to a member');
select is((select count(*)::int from billing.owners where tenant_id = pg_temp.id('cedar') and ended_at is null), 1,
  'one current owner');
select is((select count(*)::int from billing.owners where tenant_id = pg_temp.id('cedar')), 2, 'the history is kept');
select is((select count(*)::int from audit.tenant_events where tenant_id = pg_temp.id('cedar') and action = 'billing.owner_changed'),
  1, 'audited');
select is((select count(*)::int from notify.items where kind = 'billing.owner_assigned' and user_id = pg_temp.u(3)), 1,
  'B03 to the new owner');
select is(pg_temp.fails($$ select pg_temp.give(1, pg_temp.ws(3)) $$), 'conflict:already_owner', 'no change to the same person');

-- ── A responsibility, not authority (6) ──
select is((api.my_capabilities(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3))->>'billingOwner')::boolean, true,
  'the owner gets the Billing menu');
select is((api.billing_overview(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3))->>'canManage')::boolean, false,
  'the owner sees Billing without managing it');
select is(pg_temp.fails($$ select api.billing_checkout(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), 'band_400', 'year', 'test',
  pg_temp.k()) $$), 'no error', 'the owner can pay');
select is(pg_temp.fails($$ select pg_temp.give(3, pg_temp.ws(2)) $$), 'authorization_denied:', 'but cannot reassign it');
select is(pg_temp.fails($$ select api.billing_owner_candidates(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), null) $$),
  'authorization_denied:', 'or list candidates');
select is(pg_temp.fails($$ select api.record_income(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.ws(2), 'NGN', '1.00',
  'Fiverr', to_char(now(), 'YYYY-MM-DD'), null, null, null, null, array[]::uuid[], pg_temp.k()) $$),
  'authorization_denied:', 'and gains no money powers');

select * from finish();
rollback;
