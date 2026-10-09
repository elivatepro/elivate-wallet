-- Blueprint 09 follow-up: Record income member search across the whole
-- network (api.income_targets p_query). Same scope and eligibility as before.
begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

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
create function pg_temp.m(n int) returns uuid language sql stable as $$
  select id from org.memberships where user_id = pg_temp.u(n) and status = 'active'
  order by (role = 'member'), started_at limit 1
$$;
-- UIDs of actor n's targets for a query (null query = everyone in scope).
create function pg_temp.found(n int, q text, p_limit int default null, p_cursor text default null) returns text[]
language sql as $$
  select coalesce(array_agg(i->'person'->>'uid' order by i->'person'->>'uid'), '{}')
  from jsonb_array_elements(api.income_targets(pg_temp.u(n), pg_temp.s(n), pg_temp.m(n), null, p_cursor, p_limit, q)->'items') i
$$;
create function pg_temp.uids(variadic ns int[]) returns text[] language sql stable as
  $$ select array_agg(pg_temp.uid(n) order by pg_temp.uid(n)) from unnest(ns) n $$;

-- 1 President · 4 TL (Team A) · 5 TL (Team B) · 6, 8 members (Team A) · 7 member (Team B)
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 10) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 10) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 10) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), 'Pilot', pg_temp.k()); end $$;
insert into ids
select 'A', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team Alpha', null, array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'B', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team Bravo', null, array[pg_temp.uid(5)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('A'), pg_temp.uid(6), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('A'), pg_temp.uid(8), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('B'), pg_temp.uid(7), pg_temp.k());
end $$;
insert into identity.profiles (user_id, first_name, last_name, display_name) values
  (pg_temp.u(6), 'Adaeze', 'Nwosu', null),
  (pg_temp.u(7), 'Adaobi', 'Eze', null),
  (pg_temp.u(8), 'Tunde', 'Bello', '100%_Tunde')
on conflict (user_id) do update
  set first_name = excluded.first_name, last_name = excluded.last_name, display_name = excluded.display_name;

select is(pg_temp.found(1, null), pg_temp.uids(4, 5, 6, 7, 8), 'no query: every eligible member in scope');
select is(pg_temp.found(1, 'ada'), pg_temp.uids(6, 7), 'name search is case-insensitive and network-wide');
select is(pg_temp.found(1, 'adaeze nwosu'), pg_temp.uids(6), 'first and last name together');
select is(pg_temp.found(1, pg_temp.uid(7)), pg_temp.uids(7), 'by UID');
select is(pg_temp.found(1, 'bravo'), pg_temp.uids(5, 7), 'by office name');
select is(pg_temp.found(1, '100%_'), pg_temp.uids(8), 'wildcards are matched literally');
select is(pg_temp.found(1, '_'), pg_temp.uids(8), 'an underscore is not a wildcard');
select is(pg_temp.found(4, 'ada'), pg_temp.uids(6), 'a Team Leader only finds members in their scope');
select is(
  pg_temp.found(1, 'ada', 1, api.income_targets(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), null, null, 1, 'ada')->>'nextCursor'),
  (select array_agg(x) from unnest(pg_temp.uids(6, 7)) x
   where x <> (api.income_targets(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), null, null, 1, 'ada')->'items'->0->'person'->>'uid')),
  'the cursor pages through the filtered results'
);
select throws_ok(
  $$ select api.income_targets(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), null, null, null, '   ') $$,
  'P0001', 'validation_error', 'a blank query is refused'
);
select throws_ok(
  format($$ select api.income_targets(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), null, null, null, %L) $$, repeat('a', 101)),
  'P0001', 'validation_error', 'a query over 100 characters is refused'
);

select * from finish();
rollback;
