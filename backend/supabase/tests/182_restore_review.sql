-- Blueprint 18 — B6 182: guided manual restore (owner answer Q7). Elivate
-- validates the archive (counts reconcile, or the request fails), reviews a
-- read-only comparison with live data (money and history always kept), and
-- moves the request by hand. In review only through a passing validation;
-- staged rows go when the request finishes.
begin;
create extension if not exists pgtap with schema extensions;
select plan(25);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('18200000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('28200000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
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
-- The archive's rows, as the ZIP holds them (captured from the worker steps).
create temp table archived (section text, data jsonb);
-- Worker stand-in: one complete backup that keeps a copy of its rows.
create function pg_temp.backup() returns uuid language plpgsql as $$
declare
  job jsonb := api.backup_claim('w1')->'job';
  id uuid := (job->>'backupId')::uuid;
  prep jsonb;
  files jsonb;
begin
  prep := api.backup_prepare(id, 'w1');
  insert into archived select r->>'section', r->'data'
  from jsonb_array_elements(api.backup_rows(id, 'w1', 0, 2000)->'rows') r;
  select jsonb_agg(jsonb_build_object('section', key, 'rows', value::int, 'sha256', repeat('d', 64))) into files
  from jsonb_each_text(prep->'counts');
  perform api.backup_finalize(id, 'w1', (prep->>'recordCount')::int, 1024, repeat('e', 64), files);
  return id;
end $$;
-- App server stand-in: streams the archive's rows, then reports.
create function pg_temp.validate(p_restore uuid, p_drop text default null) returns jsonb language plpgsql as $$
declare
  sec text;
  run uuid;
begin
  run := (api.admin_restore_source(pg_temp.u(9), pg_temp.s(9), p_restore)->>'runId')::uuid;
  for sec in select distinct section from archived loop
    perform api.admin_restore_rows(pg_temp.u(9), pg_temp.s(9), p_restore, run, sec,
      (select coalesce(jsonb_agg(data), '[]') from (select data from archived where section = sec
        offset case when sec = p_drop then 1 else 0 end) x));
  end loop;
  return api.admin_restore_validated(pg_temp.u(9), pg_temp.s(9), p_restore, run, true, null,
    jsonb_build_object('sections', (select jsonb_agg(jsonb_build_object('section', section, 'rows', n, 'sha256Ok', true))
      from (select section, count(*) n from archived group by section) c)));
end $$;

-- 1 President · 2 World Team leader · 9 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'r' || n || '@example.test', 'authenticated', 'authenticated' from unnest(array[1, 2, 9]) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from unnest(array[1, 2, 9]) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from unnest(array[1, 2, 9]) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(9), 'Test admin');
insert into ids select 'cedar', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Cedar Network', 'CDR', pg_temp.k())
  ->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('cedar'), 'Pilot', pg_temp.k());
end $$;
insert into ids select 'WT', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), 'world_team', 'World', null,
  array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
do $$ begin perform api.start_backup(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.k()); end $$;
insert into ids select 'b1', pg_temp.backup();
-- After the backup: a new office (added since) and a renamed one (changed).
insert into ids select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), 'director', 'Ikeja', pg_temp.id('WT'),
  array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
update org.offices set name = 'World Team' where id = pg_temp.id('WT');
insert into ids select 'r1', (api.request_restore(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('b1'),
  'Settings were changed by mistake', pg_temp.k())->'restore'->>'restoreId')::uuid;

-- ── Order of steps (5) ──
select is(pg_temp.fails($$ select api.admin_restore_source(pg_temp.u(9), pg_temp.s(9), pg_temp.id('r1')) $$),
  'conflict:invalid_transition', 'validation starts only once the request is validating');
select is(pg_temp.fails($$ select api.admin_restore_source(pg_temp.u(1), pg_temp.s(1), pg_temp.id('r1')) $$),
  'authorization_denied:', 'only Elivate validates');
select is(api.platform_advance_restore(pg_temp.u(9), pg_temp.s(9), pg_temp.id('r1'), 'validating', 'Archive checks',
  pg_temp.k())->'restore'->>'status', 'validating', 'Elivate starts validating');
select is(pg_temp.fails($$ select api.platform_advance_restore(pg_temp.u(9), pg_temp.s(9), pg_temp.id('r1'), 'in_review',
  'Skip the checks', pg_temp.k()) $$), 'validation_error:', 'in review only through a passing validation');
create temp table src as select api.admin_restore_source(pg_temp.u(9), pg_temp.s(9), pg_temp.id('r1')) as r;
select matches((select r->>'objectKey' from src), '^backups/[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9]+\.zip$',
  'the app server is told where the archive is');

-- ── One run at a time (3) ──
create temp table src2 as select api.admin_restore_source(pg_temp.u(9), pg_temp.s(9), pg_temp.id('r1')) as r;
select is(pg_temp.fails(format($$ select api.admin_restore_rows(pg_temp.u(9), pg_temp.s(9), pg_temp.id('r1'), %L, 'offices',
  '[{}]'::jsonb) $$, (select r->>'runId' from src))), 'conflict:run_superseded', 'an older run can no longer stage rows');
select is(pg_temp.fails(format($$ select api.admin_restore_validated(pg_temp.u(9), pg_temp.s(9), pg_temp.id('r1'), %L, true,
  null, '{"sections":[]}'::jsonb) $$, (select r->>'runId' from src))), 'conflict:run_superseded',
  'nor finish the validation');
select is(pg_temp.fails($$ select api.admin_restore_rows(pg_temp.u(9), pg_temp.s(9), pg_temp.id('r1'), null, 'offices',
  '[{}]'::jsonb) $$), 'conflict:run_superseded', 'a run id is required');

-- ── A failing validation (3) ──
select is(pg_temp.validate(pg_temp.id('r1'), 'offices')->'restore'->>'status', 'failed',
  'a missing row fails the request');
select is((select fail_reason from backups.restore_checks where restore_id = pg_temp.id('r1')), 'row_count_mismatch',
  'with a safe reason');
select is((select count(*)::int from backups.restore_rows where restore_id = pg_temp.id('r1')), 0,
  'and no staged rows are kept');

-- ── A passing validation (6) ──
insert into ids select 'r2', (api.request_restore(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('b1'),
  'Offices were renamed by mistake', pg_temp.k())->'restore'->>'restoreId')::uuid;
do $$ begin
  perform api.platform_advance_restore(pg_temp.u(9), pg_temp.s(9), pg_temp.id('r2'), 'validating', 'Archive checks', pg_temp.k());
end $$;
select is(pg_temp.validate(pg_temp.id('r2'))->'restore'->>'status', 'in_review', 'a reconciled archive goes to review');
create temp table d as select api.admin_restore(pg_temp.u(9), pg_temp.s(9), pg_temp.id('r2')) as r;
create temp table offices_diff as
select x from d, jsonb_array_elements(r->'differences') x where x->>'section' = 'offices';
select is((select (x->>'added')::int from offices_diff), 1, 'the office added since is counted');
select is((select (x->>'changed')::int from offices_diff), 1, 'the renamed office is counted as changed');
select is((select x->>'onRestore' from offices_diff), 'manual', 'offices are fixed by hand');
select is((select x->>'onRestore' from d, jsonb_array_elements(r->'differences') x where x->>'section' = 'audit'),
  'kept', 'history is always kept');
select is((select (r->'validation'->>'ok')::boolean from d), true, 'the validation result is shown');

-- ── By hand, then done (5) ──
select is(api.platform_advance_restore(pg_temp.u(9), pg_temp.s(9), pg_temp.id('r2'), 'restoring', 'Fixing offices by hand',
  pg_temp.k())->'restore'->>'status', 'restoring', 'restoring is an operator step');
select ok((select jsonb_array_length(api.admin_restore(pg_temp.u(9), pg_temp.s(9), pg_temp.id('r2'))->'differences'))
  > 0, 'the comparison stays visible while restoring');
select is(api.platform_advance_restore(pg_temp.u(9), pg_temp.s(9), pg_temp.id('r2'), 'completed',
  'Restored two offices by hand', pg_temp.k())->'restore'->>'status', 'completed', 'completed with notes');
select is((select count(*)::int from backups.restore_rows where restore_id = pg_temp.id('r2')), 0,
  'staged rows are removed once finished');
select is((select string_agg(to_status, ',' order by id) from backups.restore_events where request_id = pg_temp.id('r2')),
  'requested,validating,in_review,restoring,completed', 'every step is recorded');

-- ── Reads (3) ──
select is(pg_temp.fails($$ select api.admin_restore(pg_temp.u(1), pg_temp.s(1), pg_temp.id('r2')) $$),
  'authorization_denied:', 'the review is for Elivate only');
select is(jsonb_array_length(api.admin_restores(pg_temp.u(9), pg_temp.s(9))), 2, 'both requests are listed');
select is(pg_temp.fails($$ select api.admin_restore_rows(pg_temp.u(9), pg_temp.s(9), pg_temp.id('r2'), gen_random_uuid(), 'offices',
  '[{}]'::jsonb) $$), 'conflict:invalid_transition', 'rows are accepted only while validating');

select * from finish();
rollback;
