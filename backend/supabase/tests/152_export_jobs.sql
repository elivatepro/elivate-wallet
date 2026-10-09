-- Blueprint 15 — B6 152: export jobs and downloads (W-18). Leases and
-- attempts; a file is ready only if every prepared row made it; revoked
-- permission between request and preparation fails clearly; downloads are
-- re-checked, expire, need the PIN for reports and are audited; M15 + bell
-- for big jobs only; privileges.
begin;
create extension if not exists pgtap with schema extensions;
select plan(42);

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
  return msg || ':' || coalesce(detail::jsonb->>'reason', '');
end $$;
create function pg_temp.month_from() returns text language sql stable as
  $$ select to_char(date_trunc('month', now() at time zone 'Africa/Lagos'), 'YYYY-MM-DD') $$;
create function pg_temp.month_to() returns text language sql stable as
  $$ select to_char(date_trunc('month', now() at time zone 'Africa/Lagos') + interval '1 month - 1 day', 'YYYY-MM-DD') $$;
create function pg_temp.statement(n int, p_format text default 'pdf') returns uuid language sql volatile as $$
  select (api.create_statement(pg_temp.u(n), pg_temp.s(n), null, 'NGN', 'month', pg_temp.month_from(),
    pg_temp.month_to(), p_format, pg_temp.k())->>'exportId')::uuid
$$;
create function pg_temp.report(n int) returns uuid language sql volatile as $$
  select (api.create_report(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), 'office_pdf', null, 'NGN', 'month',
    pg_temp.month_from(), pg_temp.month_to(), pg_temp.k())->>'exportId')::uuid
$$;
create function pg_temp.claim(p_worker text) returns uuid language sql volatile as
  $$ select (api.export_claim(p_worker)->'job'->>'exportId')::uuid $$;
create function pg_temp.finish(p_id uuid, p_worker text, p_rows int) returns jsonb language sql volatile as
  $$ select api.export_finalize(p_id, p_worker, p_rows, 1, 4096, repeat('e', 64), true) $$;
create function pg_temp.status(p_id uuid) returns text language sql stable as
  $$ select status from exports.files where id = p_id $$;

-- 1 President · 3 TL (T) · 4 member (T) · 6 another member (T) · 9 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 9) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 9) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 9) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(9), 'Test admin');
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin perform api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('tenant'), 'Pilot', pg_temp.k()); end $$;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', null,
  array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(4), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(6), pg_temp.k());
end $$;

-- ── Leases and attempts (6) ──
insert into ids select 'a', pg_temp.statement(4);
select is(pg_temp.claim('w1'), pg_temp.id('a'), 'the oldest waiting job is leased');
select is(pg_temp.claim('w2'), null, 'a leased job is not handed out twice');
select is(pg_temp.fails($$ select api.export_prepare(pg_temp.id('a'), 'w2') $$), 'conflict:lease_lost',
  'only the lease holder may work on it');
update exports.files set lease_expires_at = now() - interval '1 second' where id = pg_temp.id('a');
select is(pg_temp.claim('w2'), pg_temp.id('a'), 'an expired lease is taken over');
select is((select attempts from exports.files where id = pg_temp.id('a')), 2, 'as a second attempt');
update exports.files set lease_expires_at = now() - interval '1 second', attempts = 3 where id = pg_temp.id('a');
select pg_temp.claim('w3');
select is((select status || ':' || fail_reason from exports.files where id = pg_temp.id('a')), 'failed:attempts_exhausted',
  'after three attempts the file fails clearly');

-- ── Complete or fail (7) ──
insert into ids select 'b', pg_temp.statement(4);
select pg_temp.claim('w1');
select is((api.export_prepare(pg_temp.id('b'), 'w1')->>'status'), 'rendering', 'prepared');
select is((pg_temp.finish(pg_temp.id('b'), 'w1', 7)->>'status'), 'failed', 'a row count that does not match fails');
select ok((select status = 'failed' and fail_reason = 'incomplete' and sha256 is null from exports.files
  where id = pg_temp.id('b')), 'never ready, never a file');
select is((select count(*)::int from exports.rows where file_id = pg_temp.id('b')), 0, 'its rows are dropped');
select is((api.retry_export(pg_temp.u(4), pg_temp.s(4), pg_temp.id('b'))->>'status'), 'queued', 'Retry queues it again');
select pg_temp.claim('w1');
select api.export_prepare(pg_temp.id('b'), 'w1');
select is((api.export_fail(pg_temp.id('b'), 'w1', 'render_failed')->>'status'), 'failed', 'a render failure fails the file');
select is(pg_temp.fails($$ select api.retry_export(pg_temp.u(4), pg_temp.s(4), pg_temp.id('a') ) $$), 'no error',
  'any failed file can be retried');

-- ── Revoked between request and preparation (2) ──
insert into ids select 'r', pg_temp.report(3);
do $$ begin
  perform api.set_role_permission(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'export_scoped_reports', false,
    'Reports go through the director now', pg_temp.k());
end $$;
-- Skip the statement queued above (retry of 'a').
update exports.files set status = 'failed', fail_reason = 'render_failed' where id = pg_temp.id('a');
select is(pg_temp.claim('w1'), pg_temp.id('r'), 'the report is claimed');
select is((api.export_prepare(pg_temp.id('r'), 'w1')->>'failReason'), 'authorization_revoked',
  'permission removed after the request: the report fails, nothing is written');
do $$ begin
  perform api.set_role_permission(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'export_scoped_reports', true,
    'Back to the default', pg_temp.k());
end $$;

-- ── Ready, downloads and expiry (11) ──
insert into ids select 'c', pg_temp.statement(4);
select pg_temp.claim('w1');
select api.export_prepare(pg_temp.id('c'), 'w1');
select is((pg_temp.finish(pg_temp.id('c'), 'w1', 0)->>'status'), 'ready', 'all rows written: ready');
select is((api.export_file(pg_temp.u(4), pg_temp.s(4), pg_temp.id('c'))->>'status'), 'ready', 'the owner sees it ready');
select is((api.export_file(pg_temp.u(4), pg_temp.s(4), pg_temp.id('c'))->>'objectKey'), null,
  'the storage key never reaches the browser');
select throws_ok($$ select api.export_file(pg_temp.u(6), pg_temp.s(6), pg_temp.id('c')) $$, 'P0001', 'not_found',
  'nobody else sees it');
select throws_ok($$ select api.authorize_export_download(pg_temp.u(6), pg_temp.s(6), pg_temp.id('c')) $$, 'P0001',
  'not_found', 'nobody else downloads it');
create temp table dl as select api.authorize_export_download(pg_temp.u(4), pg_temp.s(4), pg_temp.id('c')) as d;
select is((select d->>'objectKey' from dl), 'exports/' || pg_temp.id('tenant') || '/' || pg_temp.id('c') || '/1.pdf',
  'the app server gets the server-built key of the attempt that made the file');
select is((select count(*)::int from audit.security_events where action = 'export.downloaded' and actor_user_id = pg_temp.u(4)),
  1, 'each download is audited');
select is((api.authorize_export_download(pg_temp.u(4), pg_temp.s(4), pg_temp.id('c'), 'preview')->>'contentType'),
  'image/png', 'a PDF statement has a preview');
update exports.files set expires_at = now() - interval '1 second' where id = pg_temp.id('c');
select is((api.export_file(pg_temp.u(4), pg_temp.s(4), pg_temp.id('c'))->>'status'), 'expired', 'after 7 days: expired');
select is(pg_temp.fails($$ select api.authorize_export_download(pg_temp.u(4), pg_temp.s(4), pg_temp.id('c')) $$),
  'conflict:export_expired', 'an expired file cannot be downloaded');
select is(pg_temp.fails($$ select api.authorize_export_download(pg_temp.u(4), pg_temp.s(4), pg_temp.id('b')) $$),
  'conflict:export_not_ready', 'a failed file cannot be downloaded');

-- ── Reports need the PIN (3) ──
insert into ids select 'r2', pg_temp.report(3);
select pg_temp.claim('w1');
select api.export_prepare(pg_temp.id('r2'), 'w1');
select pg_temp.finish(pg_temp.id('r2'), 'w1', (select row_count from exports.files where id = pg_temp.id('r2')));
update identity.session_pin_proofs set verified_at = now() - interval '10 minutes' where session_id = pg_temp.s(3);
select throws_ok($$ select api.authorize_export_download(pg_temp.u(3), pg_temp.s(3), pg_temp.id('r2')) $$, 'P0001',
  'step_up_required', 'a report download needs a fresh PIN');
update identity.session_pin_proofs set verified_at = now() where session_id = pg_temp.s(3);
select is((api.authorize_export_download(pg_temp.u(3), pg_temp.s(3), pg_temp.id('r2'))->>'contentType'), 'application/pdf',
  'with the PIN it is allowed');
select is((select count(*)::int from audit.tenant_events where action = 'export.downloaded'), 1,
  'and recorded in the network''s audit log');

-- ── Notifications: big jobs only (4) ──
select is((select count(*)::int from notify.items where kind like 'export.%'), 0, 'small jobs send nothing');
create or replace function exports.notify_threshold() returns int
language sql immutable set search_path = '' as $$ select -1 $$;
insert into ids select 'big', pg_temp.statement(4);
select pg_temp.claim('w1');
select api.export_prepare(pg_temp.id('big'), 'w1');
select pg_temp.finish(pg_temp.id('big'), 'w1', 0);
select is((select kind || ':' || coalesce(tenant_id::text, 'personal') from notify.items where subject_id = pg_temp.id('big')),
  'export.statement_ready:personal', 'a big statement leaves a personal bell item');
select is((select e.template from outbox.events e join notify.items i on i.email_event_id = e.id
  where i.subject_id = pg_temp.id('big')), 'money.statement_ready', 'and sends M15');
select ok((select not (e.params ? 'amount') and not (e.params ? 'objectKey') and e.params->>'path' = '/app/statements'
  from outbox.events e join notify.items i on i.email_event_id = e.id where i.subject_id = pg_temp.id('big')),
  'M15 carries no amounts or file location, only the app page');

-- ── A later deny reaches saved reports; retry notices stay distinct; picker (5) ──
do $$
declare
  e uuid;
begin
  e := (api.create_evidence_upload(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(4, pg_temp.id('T')),
    'k-income-jobs-000001', 'r.pdf', 'application/pdf', 1000, repeat('b', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), e, 1000, repeat('b', 64),
    'application/pdf');
  perform api.record_income(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(4, pg_temp.id('T')), 'NGN', '1000.00',
    'Jobs income', to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null, array[e],
    'k-income-jobs-000001');
  set local session_replication_role = replica;
  update ledger.transactions set posted_at = posted_at - interval '1 minute'
  where id = (select transaction_id from finance.income_records where source = 'Jobs income');
  set local session_replication_role = origin;
end $$;
insert into ids select 'r3', pg_temp.report(3);
select pg_temp.claim('w1');
select api.export_prepare(pg_temp.id('r3'), 'w1');
select pg_temp.finish(pg_temp.id('r3'), 'w1', (select row_count from exports.files where id = pg_temp.id('r3')));
update identity.session_pin_proofs set verified_at = now() where session_id = pg_temp.s(3);
select is((api.authorize_export_download(pg_temp.u(3), pg_temp.s(3), pg_temp.id('r3'))->>'contentType'), 'application/pdf',
  'the saved report downloads while everything in it is visible');
do $$ begin
  perform api.create_access_assignment(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(3),
    jsonb_build_array(jsonb_build_object('permission', 'export_scoped_reports', 'effect', 'deny',
      'scopeType', 'member', 'scopeUid', pg_temp.uid(4))), 'Not this member', pg_temp.k());
end $$;
select throws_ok($$ select api.authorize_export_download(pg_temp.u(3), pg_temp.s(3), pg_temp.id('r3')) $$, 'P0001',
  'authorization_denied', 'after a deny on one member in it, the saved report no longer downloads');
update exports.files set status = 'failed', fail_reason = 'render_failed', notify = true where id = pg_temp.id('a');
select exports.notify(f, 'failed') from exports.files f where f.id = pg_temp.id('a');
select api.retry_export(pg_temp.u(4), pg_temp.s(4), pg_temp.id('a'));
select exports.finish_failed(pg_temp.id('a'), 'render_failed');
select is((select count(*)::int from notify.items where subject_id = pg_temp.id('a') and kind = 'export.failed'), 1,
  'not yet: a retry is quiet until it fails again as a big job');
update exports.files set notify = true where id = pg_temp.id('a');
select exports.finish_failed(pg_temp.id('a'), 'render_failed');
select is((select count(*)::int from notify.items where subject_id = pg_temp.id('a') and kind = 'export.failed'), 2,
  'a retried big job that fails again leaves a new notice');
select is((select jsonb_array_length(api.report_members(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.uid(4))->'items')),
  1, 'the member picker finds people in the export scope by UID');
select is((select row_count from exports.files where id = pg_temp.id('r3')), 1, 'the saved report held that member');

-- ── Privileges (3) ──
select ok(not has_schema_privilege('authenticated', 'exports', 'usage'), 'the exports schema is private');
select ok(not has_function_privilege('authenticated', 'api.export_claim(text)', 'execute'),
  'browsers cannot drive the Worker steps');
select ok(not has_function_privilege('anon', 'api.authorize_export_download(uuid,uuid,uuid,text,text)', 'execute'),
  'nor authorize downloads');

select * from finish();
rollback;
