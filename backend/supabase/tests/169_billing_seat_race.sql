-- Blueprint 16 — B6 169: two sessions race for the last seat. The fixture is
-- committed through dblink (separate sessions cannot see this transaction)
-- with random ids and synthetic emails, so it never collides with other
-- files; the local stack is reset before every full run. Runs last. The
-- connection uses the local stack's default credentials (never a hosted DB).
begin;
create extension if not exists pgtap with schema extensions;
create extension if not exists dblink with schema extensions;
select plan(5);

-- The test session's own server address over the Docker network, where the
-- server asks for the password (loopback is trusted, which dblink refuses).
create function pg_temp.conn() returns text language sql stable as $$
  select format('host=%s port=5432 dbname=postgres user=postgres password=postgres',
    coalesce(host(inet_server_addr()), '127.0.0.1'))
$$;

create temp table race (tenant uuid, founder uuid, a uuid, b uuid);
insert into race values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid());

select extensions.dblink_connect('setup', pg_temp.conn());
select extensions.dblink_exec('setup', format($sql$
  insert into auth.users (id, email, aud, role)
  select x.id, 'race-' || x.id::text || '@race.test', 'authenticated', 'authenticated'
  from (values (%1$L::uuid), (%2$L::uuid), (%3$L::uuid)) x(id);
  insert into org.tenants (id, name, short_name, status, created_by, activated_at, activated_by, activation_source)
  values (%4$L, 'Race Network', 'RACE', 'active', %1$L, now(), %1$L, 'trial');
  insert into billing.subscriptions (tenant_id, status, kind, plan_id, period_start, period_end)
  values (%4$L, 'trial', 'trial', (billing.plan('band_400')).id, now(), now() + interval '7 days');
  with people as (
    insert into auth.users (id, email, aud, role)
    select gen_random_uuid(), 'race-' || %4$L || '-' || n || '@race.test', 'authenticated', 'authenticated'
    from generate_series(1, 399) n
    returning id
  )
  insert into org.memberships (tenant_id, office_id, user_id, role, is_primary, created_by)
  select %4$L, null, id, 'president_team_member', true, %1$L from people;
$sql$, (select founder from race), (select a from race), (select b from race), (select tenant from race)));

select is((select billing.seats_used(tenant) from race), 399, 'one seat left');

select extensions.dblink_connect('one', pg_temp.conn());
select extensions.dblink_connect('two', pg_temp.conn());
select extensions.dblink_exec('one', 'begin');
select extensions.dblink_exec('one', format(
  'do $x$ begin perform org.create_membership(%L, null, %L, ''president_team_member'', %L); end $x$',
  (select tenant from race), (select a from race), (select founder from race)));
select extensions.dblink_send_query('two', format(
  'select org.create_membership(%L, null, %L, ''president_team_member'', %L)',
  (select tenant from race), (select b from race), (select founder from race)));
select pg_sleep(0.5);
select is(extensions.dblink_is_busy('two'), 1, 'the second session waits for the first');
select extensions.dblink_exec('one', 'commit');
select is((select count(*)::int from extensions.dblink_get_result('two', false) as r(x text)), 0,
  'the second session gets no membership');
select matches(extensions.dblink_error_message('two'), 'conflict', 'it is refused once the first commits');
select is((select billing.seats_used(tenant) from race), 400, 'exactly the cap, never more');

select extensions.dblink_disconnect('one');
select extensions.dblink_disconnect('two');
select extensions.dblink_disconnect('setup');

select * from finish();
rollback;
