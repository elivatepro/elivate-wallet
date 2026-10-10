-- Blueprint 16 — B6 161: seats (D-10). Distinct people count once;
-- suspended people and the President count; an invitation alone and an
-- ended membership don't. At the cap new people and new invitations are
-- refused; B04 goes out once at 90%; the check holds a per-tenant advisory
-- lock (the two-session race is 169_).
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(17);

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
create function pg_temp.seats() returns int language sql stable as
  $$ select billing.seats_used(pg_temp.id('t')) $$;
create function pg_temp.add(n int, p_office text) returns jsonb language sql volatile as
  $$ select api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id(p_office), pg_temp.uid(n), pg_temp.k()) $$;
create function pg_temp.invite(p_email text, p_tok text) returns jsonb language sql volatile as $$
  select api.create_invitation(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('WT'), 'member', p_email,
    md5(p_tok)::uuid, encode(sha256(convert_to(p_tok, 'UTF8')), 'hex'), null, pg_temp.k())
$$;
-- Synthetic seat filler: direct memberships for generated people (fixture only).
create function pg_temp.fill(p_to int) returns void language plpgsql as $$
declare
  need int := p_to - pg_temp.seats();
  base int := coalesce((select max(substr(email, 2, 5)::int) from auth.users where email like 'f%@fill.test'), 10000);
begin
  if need <= 0 then return; end if;
  insert into auth.users (id, email, aud, role)
  select gen_random_uuid(), 'f' || (base + n) || '@fill.test', 'authenticated', 'authenticated'
  from generate_series(1, need) n;
  insert into org.memberships (tenant_id, office_id, user_id, role, is_primary, created_by)
  select pg_temp.id('t'), pg_temp.id('WT'), u.id, 'member', true, pg_temp.u(1)
  from auth.users u
  where u.email like 'f%@fill.test' and substr(u.email, 2, 5)::int > base;
end $$;

-- 1 founder · 2 leader · 3 member (later suspended) · 4 member (ends) · 5 invited only · 6–9 newcomers
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 9) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 9) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 9) n; end $$;
insert into ids select 't', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Cedar Network', 'CDR', pg_temp.k(), null,
  'band_400', true)->>'tenantId')::uuid;
insert into ids select 'WT', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'world_team', 'World',
  null, array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja',
  pg_temp.id('WT'), array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;

-- ── Counting (7) ──
select is(pg_temp.seats(), 2, 'the President counts (no wallet); the leader of two offices counts once');
select lives_ok($$ select pg_temp.add(3, 'WT') $$, 'a member joins');
select lives_ok($$ select pg_temp.add(4, 'WT') $$, 'another member joins');
select is(pg_temp.seats(), 4, 'a second membership of the same person counts once');
do $$ begin
  perform api.set_membership_status(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(3, pg_temp.id('WT')),
    'suspended', 'On leave', pg_temp.k());
  perform api.end_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(4, pg_temp.id('WT')), 'Left', pg_temp.k());
end $$;
select is(pg_temp.seats(), 3, 'a suspended person still counts; an ended membership does not');
select lives_ok($$ select pg_temp.invite('u5@example.test', 'tok-5') $$, 'an invitation is sent');
select is(pg_temp.seats(), 3, 'an invitation alone takes no seat');

-- ── B04 at 90% (3) ──
select pg_temp.fill(358);
select lives_ok($$ select pg_temp.add(6, 'WT') $$, 'the 359th person joins');
select is((select count(*)::int from notify.items where kind = 'billing.seats_almost_full' and user_id = pg_temp.u(1)), 0,
  'no warning below 90%');
select pg_temp.add(7, 'WT');
select is((select count(*)::int from notify.items where kind = 'billing.seats_almost_full' and user_id = pg_temp.u(1)), 1,
  'B04 when the 360th of 400 seats is taken');

-- ── The cap (6) ──
select pg_temp.fill(400);
select is(pg_temp.seats(), 400, 'the network is full');
select is(pg_temp.fails($$ select pg_temp.add(8, 'WT') $$), 'conflict:seat_limit_reached', 'a new person is refused');
select lives_ok($$ select pg_temp.add(3, 'D') $$, 'an already counted person may take another membership');
select is(pg_temp.fails($$ select pg_temp.invite('u9@example.test', 'tok-9') $$), 'conflict:seat_limit_reached',
  'new invitations are refused at the cap');
select lives_ok($$ select api.create_invitation(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('D'), 'member',
  'u2@example.test', md5('tok-2')::uuid, encode(sha256(convert_to('tok-2', 'UTF8')), 'hex'), null, pg_temp.k()) $$,
  'an invitation to an already counted person is allowed');
select is((select count(*)::int from notify.items where kind = 'billing.seats_almost_full' and user_id = pg_temp.u(1)), 1,
  'B04 only once per period');

-- ── Serialization (1) ──
select ok(exists (
  select 1 from pg_locks
  where locktype = 'advisory' and pid = pg_backend_pid() and granted
    and classid::bigint = ((hashtextextended('billing.seats:' || pg_temp.id('t')::text, 0) >> 32) & 4294967295)
    and objid::bigint = (hashtextextended('billing.seats:' || pg_temp.id('t')::text, 0) & 4294967295)
), 'the seat check holds the per-tenant advisory lock until commit');

select * from finish();
rollback;
