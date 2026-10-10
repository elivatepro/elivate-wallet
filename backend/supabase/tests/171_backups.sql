-- Blueprint 17 — B6 171: the Team Backup Vault (W-24): who backs up and
-- downloads, one backup at a time, the worker steps (complete or fail), what
-- an archive leaves out, the PIN and audit on download, 90-day expiry, and
-- restore requests (one open, cancel window, Elivate-only transitions, T04).
begin;
create extension if not exists pgtap with schema extensions;
select plan(49);

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
-- Worker stand-in: one complete run. Returns the prepare result.
create function pg_temp.run(p_finish boolean default true, p_drop int default 0) returns jsonb
language plpgsql as $$
declare
  job jsonb := api.backup_claim('w1')->'job';
  prep jsonb;
  files jsonb;
begin
  prep := api.backup_prepare((job->>'backupId')::uuid, 'w1');
  if prep->>'status' <> 'building' or not p_finish then
    return prep;
  end if;
  select jsonb_agg(jsonb_build_object('section', key, 'rows', value::int - case when p_drop > 0 and key = 'people'
    then p_drop else 0 end, 'sha256', repeat('d', 64))) into files
  from jsonb_each_text(prep->'counts');
  return prep || jsonb_build_object('finalize', api.backup_finalize((job->>'backupId')::uuid, 'w1',
    (prep->>'recordCount')::int, 1024, repeat('e', 64), files));
end $$;

-- 1 President · 2 World Team leader · 3 member · 4 President (Pine) · 9 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 9) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 9) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 9) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(9), 'Test admin');
insert into ids select 'cedar', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Cedar Network', 'CDR', pg_temp.k())
  ->>'tenantId')::uuid;
insert into ids select 'pine', (api.start_network(pg_temp.u(4), pg_temp.s(4), 'Pine Network', 'PIN', pg_temp.k())
  ->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('cedar'), 'Pilot', pg_temp.k());
  perform api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('pine'), 'Pilot', pg_temp.k());
end $$;
insert into ids select 'WT', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), 'world_team', 'World', null,
  array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('WT'), pg_temp.uid(3), pg_temp.k());
end $$;
-- Synthetic secrets that must never reach an archive.
insert into identity.nin_records (user_id, nin_fingerprint, nin_last4, given_name, surname, method, verified_at)
values (pg_temp.u(3), repeat('f', 64), '4321', 'Ada', 'Obi', 'provider', now());

-- ── Who (4) ──
select is(pg_temp.fails($$ select api.backup_vault(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3)) $$),
  'authorization_denied:', 'members do not see the vault');
select is((api.backup_vault(pg_temp.u(2), pg_temp.s(2), pg_temp.ws(2))->>'canBackup')::boolean, false,
  'World Team sees the vault to request a restore, without backing up');
select is(pg_temp.fails($$ select api.start_backup(pg_temp.u(2), pg_temp.s(2), pg_temp.ws(2), pg_temp.k()) $$),
  'authorization_denied:', 'only Presidents back up');
select is((api.backup_vault(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1))->>'retentionDays')::int, 90,
  'backups are kept 90 days (Q2)');

-- ── Start (4) ──
create temp table b1 as select api.start_backup(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), 'k-backup-00000000001') as r;
insert into ids select 'b1', (r->'backup'->>'backupId')::uuid from b1;
select is((select r->'backup'->>'status' from b1), 'queued', 'a backup is queued');
select is((api.start_backup(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), 'k-backup-00000000001')->>'replayed')::boolean,
  true, 'the same key replays');
select is(pg_temp.fails($$ select api.start_backup(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.k()) $$),
  'conflict:backup_running', 'one backup at a time');
select is((select count(*)::int from audit.tenant_events where tenant_id = pg_temp.id('cedar') and action = 'backup.started'),
  1, 'starting is audited');

-- ── The worker (10) ──
create temp table p1 as select pg_temp.run(false) as r;
select is((select r->>'status' from p1), 'building', 'the snapshot is prepared');
select is((select (r->'counts'->>'people')::int from p1), 3, 'every person of the network');
select is((select (r->'counts'->>'memberships')::int from p1), 3, 'and every membership');
select ok((select r->'counts' ? 'audit' and r->'counts' ? 'role_permissions' and r->'counts' ? 'subscription' from p1),
  'with audit, role settings and the subscription');
select is((select count(*)::int from backups.rows where archive_id = pg_temp.id('b1')
  and data::text ~ '"(nin_[a-z]+|pin_hash|token_[a-z]+|account_ciphertext|object_path|idempotency_key|provider_email_token|provider_customer_code)"'), 0,
  'no NIN, PIN, token, ciphertext, storage path or idempotency key');
select is((select count(*)::int from backups.rows r where archive_id = pg_temp.id('b1')
  and data::text like '%' || pg_temp.id('pine')::text || '%'), 0, 'nothing from another network');
select is((select data->>'email' from backups.rows where archive_id = pg_temp.id('b1') and section = 'people'
  and data->>'uid' = pg_temp.uid(3)), 'u3@example.test', 'people carry their email for a restore');
select is(pg_temp.fails($$ select api.backup_rows(pg_temp.id('b1'), 'w2', 0, 10) $$), 'conflict:lease_lost',
  'only the leasing worker reads rows');
select is(jsonb_array_length(api.backup_rows(pg_temp.id('b1'), 'w1', 0, 2000)->'rows'),
  (select count(*)::int from backups.rows where archive_id = pg_temp.id('b1')), 'rows page in order');
select is((select api.backup_finalize(pg_temp.id('b1'), 'w1', (r->>'recordCount')::int, 1024, repeat('e', 64),
  (select jsonb_agg(jsonb_build_object('section', key, 'rows', value::int, 'sha256', repeat('d', 64)))
   from jsonb_each_text(r->'counts')))->>'status' from p1), 'ready', 'complete files become ready');

-- ── Ready (6) ──
select is((select status || '/' || (expires_at - finished_at)::text from backups.archives where id = pg_temp.id('b1')),
  'ready/90 days', 'ready, kept 90 days');
select is((select count(*)::int from backups.rows where archive_id = pg_temp.id('b1')), 0, 'prepared rows are removed');
select is((select count(*)::int from notify.items where kind = 'backup.ready' and user_id = pg_temp.u(1)), 1,
  'T02 and a bell item to whoever started it');
update identity.session_pin_proofs set verified_at = now() - interval '10 minutes' where user_id = pg_temp.u(1);
select is(pg_temp.fails($$ select api.authorize_backup_download(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1),
  pg_temp.id('b1')) $$), 'step_up_required:', 'downloading needs the PIN');
update identity.session_pin_proofs set verified_at = now() where user_id = pg_temp.u(1);
select matches(api.authorize_backup_download(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('b1'))->>'objectKey',
  '^backups/' || pg_temp.id('cedar') || '/' || pg_temp.id('b1') || '/1\.zip$', 'the app server gets the key');
select is((select count(*)::int from audit.tenant_events where tenant_id = pg_temp.id('cedar')
  and action = 'backup.downloaded'), 1, 'downloads are audited');

-- ── Incomplete and too large (4) ──
insert into ids select 'b2', (api.start_backup(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.k())
  ->'backup'->>'backupId')::uuid;
select is(pg_temp.run(true, 1)->'finalize'->>'status', 'failed', 'a file missing rows never becomes ready');
select is((select fail_reason from backups.archives where id = pg_temp.id('b2')), 'incomplete', 'it says why');
select is((select count(*)::int from notify.items where kind = 'backup.failed' and user_id = pg_temp.u(1)), 1,
  'T03 to whoever started it');
select is(pg_temp.fails($$ select api.authorize_backup_download(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1),
  pg_temp.id('b2')) $$), 'conflict:backup_not_ready', 'a failed backup cannot be downloaded');

-- ── Failed files are removed at once (2) ──
select ok((api.backup_expired()->'items') @> jsonb_build_array(jsonb_build_object('backupId', pg_temp.id('b2'))),
  'a failed backup''s files are listed for removal');
select is(api.backup_deleted(pg_temp.id('b2'))->>'status', 'deleted', 'and marked gone, while the row stays');

-- ── Paused networks (2) ──
update org.tenants set status = 'suspended' where id = pg_temp.id('cedar');
select is(pg_temp.fails($$ select api.backup_vault(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1)) $$), 'no error',
  'a paused network keeps its vault');
insert into ids select 'b3', (api.start_backup(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.k())
  ->'backup'->>'backupId')::uuid;
select is(pg_temp.run()->'finalize'->>'status', 'ready', 'and may still back up');
update org.tenants set status = 'active' where id = pg_temp.id('cedar');

-- ── Restore requests (13) ──
select is(pg_temp.fails($$ select api.request_restore(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('b1'),
  'Please restore our settings', pg_temp.k()) $$), 'authorization_denied:', 'members cannot request a restore');
select is(pg_temp.fails($$ select api.request_restore(pg_temp.u(2), pg_temp.s(2), pg_temp.ws(2), pg_temp.id('b1'),
  'Too short', pg_temp.k()) $$), 'validation_error:', 'a reason is required');
select is(pg_temp.fails($$ select api.request_restore(pg_temp.u(2), pg_temp.s(2), pg_temp.ws(2), pg_temp.id('b2'),
  'Settings were changed by mistake', pg_temp.k()) $$), 'conflict:backup_not_ready', 'only from a ready backup');
create temp table rq as select api.request_restore(pg_temp.u(2), pg_temp.s(2), pg_temp.ws(2), pg_temp.id('b1'),
  'Settings were changed by mistake', pg_temp.k()) as r;
insert into ids select 'r1', (r->'restore'->>'restoreId')::uuid from rq;
select matches((select r->'restore'->>'reference' from rq), '^RST-[0-9A-Z]{4}-[0-9A-Z]{4}$', 'an RST reference');
select is((select count(*)::int from notify.items where kind = 'backup.restore_update' and user_id = pg_temp.u(2)), 1,
  'T04 to the requester');
select is(pg_temp.fails($$ select api.request_restore(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('b1'),
  'A second request for the same', pg_temp.k()) $$), 'conflict:restore_open', 'one open request per network');
select is(pg_temp.fails($$ select api.platform_advance_restore(pg_temp.u(1), pg_temp.s(1), pg_temp.id('r1'), 'validating',
  'Checking it', pg_temp.k()) $$), 'authorization_denied:', 'no team member moves a restore (Q1)');
select is(pg_temp.fails($$ select api.platform_advance_restore(pg_temp.u(9), pg_temp.s(9), pg_temp.id('r1'), 'completed',
  'Skipping ahead', pg_temp.k()) $$), 'conflict:invalid_transition', 'statuses follow W-24');
select is(api.platform_advance_restore(pg_temp.u(9), pg_temp.s(9), pg_temp.id('r1'), 'validating', 'Archive checks',
  pg_temp.k())->'restore'->>'status', 'validating', 'Elivate validates');
select is(api.cancel_restore_request(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('r1'), pg_temp.k())
  ->'restore'->>'status', 'cancelled', 'a President may withdraw it before restoring');
select is((select string_agg(coalesce(from_status, '-') || '>' || to_status, ',' order by id)
  from backups.restore_events where request_id = pg_temp.id('r1')), '->requested,requested>validating,validating>cancelled',
  'every change is recorded');
select is((select count(*)::int from notify.items where kind = 'backup.restore_update' and user_id = pg_temp.u(2)), 3,
  'and the requester hears each one');
select is((select count(*)::int from audit.tenant_events where tenant_id = pg_temp.id('cedar')
  and target_type = 'restore_request'), 3, 'and each is audited');

-- ── Expiry (4) ──
update backups.archives set finished_at = now() - interval '91 days', expires_at = now() - interval '1 day'
where id = pg_temp.id('b1');
select is(backups.expire(), 1, 'backups past 90 days expire');
select ok((api.backup_expired()->'items') @> jsonb_build_array(jsonb_build_object('backupId', pg_temp.id('b1'))),
  'their files are listed for removal');
select is(api.backup_deleted(pg_temp.id('b1'))->>'status', 'deleted', 'and marked gone');
select is(pg_temp.fails($$ select api.authorize_backup_download(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1),
  pg_temp.id('b1')) $$), 'conflict:backup_expired', 'an expired backup cannot be downloaded');

select * from finish();
rollback;
