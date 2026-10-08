-- Blueprint 06 — Welcome read: allowed before the PIN, own membership only.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;

insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 2) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 2) n;
do $$ begin perform api.set_pin(pg_temp.u(1), pg_temp.s(1), repeat('a', 64)); end $$;
create temp table t as
select (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', 'kkkkkkkkkkkkkkkkkkkk1')->>'membershipId')::uuid as m;
-- A membership for user 2 (no PIN yet), as an accepted invitation would create.
insert into org.memberships (tenant_id, office_id, user_id, role, status, is_primary, created_by)
select tenant_id, null, pg_temp.u(2), 'president_team_member', 'active', true, pg_temp.u(1)
from org.memberships where id = (select m from t);

select is(api.onboarding_workspace(pg_temp.u(2), pg_temp.s(2),
  (select id from org.memberships where user_id = pg_temp.u(2)))->>'tenantName', 'Lagos Network',
  'readable before the PIN exists');
select throws_ok($$ select api.onboarding_workspace(pg_temp.u(2), pg_temp.s(2), (select m from t)) $$,
  'P0001', 'workspace_invalid', 'someone else''s membership is refused');
update identity.session_pin_proofs set verified_at = now() - interval '1 day', last_activity_at = now() - interval '1 day'
where session_id = pg_temp.s(1);
select throws_ok($$ select api.onboarding_workspace(pg_temp.u(1), pg_temp.s(1), (select m from t)) $$,
  'P0001', 'pin_required', 'an idle session with a PIN must enter it');
select ok(not has_function_privilege('authenticated', 'api.onboarding_workspace(uuid, uuid, uuid)', 'execute'),
  'service_role only');

select * from finish();
rollback;
