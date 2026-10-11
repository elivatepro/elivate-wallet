-- Slice 28 (owner decision 2026-10-11): a leader no longer sees the invitation
-- they accepted in their Invitations list; everyone else still does, and the
-- leader still sees the invitations they send.
begin;
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(5);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.uid(n int) returns text language sql stable as
  $$ select uid from identity.accounts where user_id = pg_temp.u(n) $$;
create function pg_temp.k() returns text language sql volatile as
  $$ select 'k' || md5(random()::text || clock_timestamp()::text) $$;
create function pg_temp.dg(t text) returns text language sql immutable as
  $$ select encode(sha256(convert_to(t, 'UTF8')), 'hex') $$;
create function pg_temp.tid(t text) returns uuid language sql immutable as
  $$ select md5(t)::uuid $$;
create temp table ids (name text primary key, id uuid not null);
create function pg_temp.id(p_name text) returns uuid language sql stable as
  $$ select id from ids where name = p_name $$;
create function pg_temp.m(n int, p_office uuid default null) returns uuid language sql stable as $$
  select id from org.memberships
  where user_id = pg_temp.u(n) and status = 'active' and office_id is not distinct from p_office
  order by started_at desc, id limit 1
$$;
create function pg_temp.emails(n int, ws uuid) returns text[] language sql volatile as $$
  select coalesce(array_agg(e->>'email' order by e->>'email'), '{}')
  from jsonb_array_elements(api.list_invitations(pg_temp.u(n), pg_temp.s(n), ws)->'items') e
$$;

-- 1 President · 3 Director · 7 invited Team Leader of T (signs up later) · 10 admin.
insert into auth.users (id, email, aud, role, email_confirmed_at)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated', now()
from unnest(array[1, 3, 10]) n;
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from unnest(array[1, 3, 10]) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from unnest(array[1, 3, 10]) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(10), 'Test admin');

insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Synthetic Network', 'SYN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin perform api.activate_tenant(pg_temp.u(10), pg_temp.s(10), pg_temp.id('tenant'), 'Pilot network', pg_temp.k()); end $$;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', null, array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
insert into ids select 'T', (api.create_office_inviting_leader(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader',
  'Team A', pg_temp.id('D'), 'u7@example.test', pg_temp.tid('t7'), pg_temp.dg('t7'), pg_temp.k())->>'officeId')::uuid;

insert into auth.users (id, email, aud, role, email_confirmed_at)
values (pg_temp.u(7), 'u7@example.test', 'authenticated', 'authenticated', now());
insert into auth.sessions (id, user_id, created_at, updated_at) values (pg_temp.s(7), pg_temp.u(7), now(), now());
do $$ begin
  perform api.set_pin(pg_temp.u(7), pg_temp.s(7), repeat('a', 64));
  perform api.accept_invitation(pg_temp.u(7), pg_temp.s(7), pg_temp.dg('t7'), null, pg_temp.k());
end $$;

select is(pg_temp.emails(7, pg_temp.m(7, pg_temp.id('T'))), '{}'::text[],
  'the leader does not see the invitation they accepted');
select is(pg_temp.emails(3, pg_temp.m(3, pg_temp.id('D'))), array['u7@example.test'],
  'the director above still sees it');
select is(pg_temp.emails(1, pg_temp.m(1)), array['u7@example.test'],
  'the President Team still sees it');

do $$ begin
  perform api.create_invitation(pg_temp.u(7), pg_temp.s(7), pg_temp.m(7, pg_temp.id('T')), pg_temp.id('T'), 'member',
    'u8@example.test', pg_temp.tid('t8'), pg_temp.dg('t8'), null, pg_temp.k());
end $$;
select is(pg_temp.emails(7, pg_temp.m(7, pg_temp.id('T'))), array['u8@example.test'],
  'the leader sees the invitations they send');
select is(
  (select count(*)::int from jsonb_array_elements(
    api.list_invitations(pg_temp.u(7), pg_temp.s(7), pg_temp.m(7, pg_temp.id('T')), null, 'accepted')->'items')),
  0, 'the accepted filter leaves it out too');

select * from finish();
rollback;
