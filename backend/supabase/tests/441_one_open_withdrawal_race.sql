-- Blueprint 44 — 441: two sessions request a withdrawal for the same owner at
-- once while "One open withdrawal at a time" is on. The per-owner lock in
-- finance.lock_open_withdrawal makes the second wait for the first to commit,
-- so it then sees the first's request (440 covers the refusal itself). Uses
-- random ids and commits nothing; local stack credentials only.
begin;
create extension if not exists pgtap with schema extensions;
create extension if not exists dblink with schema extensions;
select plan(4);

create function pg_temp.conn() returns text language sql stable as $$
  select format('host=%s port=5432 dbname=postgres user=postgres password=postgres',
    coalesce(host(inet_server_addr()), '127.0.0.1'))
$$;

create temp table race (tenant uuid, owner uuid, other uuid);
insert into race values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid());

select extensions.dblink_connect('one', pg_temp.conn());
select extensions.dblink_connect('two', pg_temp.conn());
select extensions.dblink_connect('three', pg_temp.conn());
select extensions.dblink_exec('one', 'begin');
select extensions.dblink_exec('one', format(
  'do $x$ begin perform finance.lock_open_withdrawal(%L, %L); end $x$',
  (select tenant from race), (select owner from race)));
select extensions.dblink_send_query('two', format('select finance.lock_open_withdrawal(%L, %L)',
  (select tenant from race), (select owner from race)));
select extensions.dblink_send_query('three', format('select finance.lock_open_withdrawal(%L, %L)',
  (select tenant from race), (select other from race)));
select pg_sleep(0.5);
select is(extensions.dblink_is_busy('two'), 1, 'a second request for the same owner waits for the first');
select is(extensions.dblink_is_busy('three'), 0, 'another owner never waits');
select extensions.dblink_exec('one', 'commit');
select is((select count(*)::int from extensions.dblink_get_result('two') as r(x uuid)), 1,
  'the second goes on once the first commits');
select is((select count(*)::int from extensions.dblink_get_result('three') as r(x uuid)), 1,
  'and the other owner was answered at once');

select extensions.dblink_disconnect('one');
select extensions.dblink_disconnect('two');
select extensions.dblink_disconnect('three');
select * from finish();
rollback;
