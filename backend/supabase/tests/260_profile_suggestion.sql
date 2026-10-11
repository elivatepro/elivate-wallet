-- Owner feedback 2026-10-11: the profile read suggests the founder
-- application's name and rank until the profile has its own.
begin;
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(6);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.suggested(n int) returns jsonb language sql volatile as
  $$ select api.my_profile(pg_temp.u(n), pg_temp.s(n))->'suggested' $$;

insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 3) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 3) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 3) n; end $$;

-- Synthetic approved applications for founders 1 and 3; 2 is an existing founder.
with apps as (
  insert into founders.applications (full_name, email, phone, team_name, rank, status, decided_at, decided_by,
    decision_reason)
  values ('Ada  Lovelace Byron', 'u1@example.test', '+2348030000001', 'Team One', 'ruby_director_5', 'approved',
      now(), pg_temp.u(2), 'Synthetic approval'),
    ('Grace', 'u3@example.test', '+2348030000003', 'Team Three', 'diamond_director', 'approved',
      now(), pg_temp.u(2), 'Synthetic approval')
  returning id, email
)
insert into founders.approved (user_id, source, application_id)
select u.id, 'application', apps.id from apps join auth.users u on u.email = apps.email;
insert into founders.approved (user_id, source) values (pg_temp.u(2), 'existing');

select is(pg_temp.suggested(1), '{"firstName": "Ada", "lastName": "Lovelace Byron", "rank": "Ruby Director 5"}',
  'name split and rank mapped from the application');
select is(pg_temp.suggested(2), 'null'::jsonb, 'no application, no suggestion');
select is(pg_temp.suggested(3), '{"firstName": "Grace", "rank": "Diamond Director"}', 'a one-word name has no last name');

update identity.profiles set rank = 'Director' where user_id = pg_temp.u(1);
select is(pg_temp.suggested(1), '{"firstName": "Ada", "lastName": "Lovelace Byron"}',
  'the profile''s own rank wins');
update identity.profiles set first_name = 'A', last_name = 'B' where user_id = pg_temp.u(1);
select is(pg_temp.suggested(1), 'null'::jsonb, 'nothing left to suggest');
select is(api.my_profile(pg_temp.u(1), pg_temp.s(1))->>'firstName', 'A', 'stored names are untouched');

select * from finish();
rollback;
