-- Blueprint 18 — B3 (owner answer Q7, "guided manual restore"): Elivate
-- validates a restore request's archive and reviews a read-only comparison
-- with the network's current data. Nothing is written back automatically:
-- the restore itself is an operator procedure, then the request is marked
-- completed with notes. Money and history sections are always "kept, never
-- overwritten" (W-24).
--
-- Flow (admin site, PIN to start): requested → validating (existing
-- platform_advance_restore) → the admin app server re-reads the archive from
-- private R2, checks the archive SHA-256, every file's SHA-256 and row count
-- against the manifest, and streams the rows here → in_review with the
-- differences, or failed with a safe reason.

-- Archive rows staged for one comparison; removed when the request finishes.
create table backups.restore_rows (
  restore_id uuid not null references backups.restore_requests (id) on delete cascade,
  section text not null check (section ~ '^[a-z_]{2,40}$'),
  key text not null,
  data jsonb not null check (jsonb_typeof(data) = 'object'),
  primary key (restore_id, section, key)
);

alter table backups.restore_rows enable row level security;

create table backups.restore_checks (
  restore_id uuid primary key references backups.restore_requests (id) on delete restrict,
  ok boolean not null,
  fail_reason text check (fail_reason is null or fail_reason ~ '^[a-z_]{3,40}$'),
  files int not null check (files >= 0),
  rows int not null check (rows >= 0),
  sections jsonb not null check (jsonb_typeof(sections) = 'array'),
  checked_by uuid not null references identity.accounts (user_id) on delete restrict,
  checked_at timestamptz not null default now(),
  check (ok = (fail_reason is null))
);

create index restore_checks_checked_by_idx on backups.restore_checks (checked_by);

alter table backups.restore_checks enable row level security;

-- Sections an operator may fix by hand; every other section is kept as is.
create function backups.manual_sections() returns text[]
language sql immutable set search_path = '' as $$
  select array['network', 'offices', 'people', 'memberships', 'invitations', 'role_permissions',
               'access_assignments', 'access_rules', 'reviewer_assignments', 'pockets']
$$;

-- The identity of a row within its section.
create function backups.row_key(p_section text, p_data jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    p_data->>'id',
    case p_section
      when 'people' then p_data->>'uid'
      when 'settings_revisions' then p_data->>'revision'
      when 'role_permissions' then concat_ws(':', p_data->>'role', p_data->>'permission_key')
      when 'subscription' then 'subscription'
    end,
    md5(p_data::text));
$$;

create function backups.locked_restore(p_restore_id uuid, p_status text)
returns backups.restore_requests
language plpgsql
set search_path = ''
as $$
declare
  r backups.restore_requests;
begin
  select * into r from backups.restore_requests where id = p_restore_id for update;
  if r.id is null then
    perform identity.fail('not_found');
  end if;
  if r.status <> p_status then
    perform identity.fail('conflict', jsonb_build_object('reason', 'invalid_transition', 'status', r.status));
  end if;
  return r;
end;
$$;

-- Where the archive is and what its manifest promises (app server only: the
-- Edge route requires the app-server secret).
create function api.admin_restore_source(p_user_id uuid, p_session_id uuid, p_restore_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r backups.restore_requests;
  a backups.archives;
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  r := backups.locked_restore(p_restore_id, 'validating');
  select * into a from backups.archives where id = r.archive_id;
  if a.status <> 'ready' or a.expires_at <= now() or a.deleted_at is not null then
    perform identity.fail('conflict', jsonb_build_object('reason', 'archive_unavailable'));
  end if;
  -- A new validation run starts from nothing.
  delete from backups.restore_rows where restore_id = r.id;
  return jsonb_build_object(
    'restoreId', r.id,
    'objectKey', backups.object_key(a),
    'byteSize', a.byte_size,
    'sha256', a.sha256,
    'recordCount', a.record_count,
    'files', coalesce(a.manifest->'files', '[]'::jsonb),
    'counts', coalesce(a.manifest->'counts', '{}'::jsonb)
  );
end;
$$;

-- Up to 1,000 archive rows of one section.
create function api.admin_restore_rows(
  p_user_id uuid,
  p_session_id uuid,
  p_restore_id uuid,
  p_section text,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r backups.restore_requests;
  added int;
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  if p_section is null or p_section !~ '^[a-z_]{2,40}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'section'));
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) > 1000
     or exists (select 1 from jsonb_array_elements(p_rows) x where jsonb_typeof(x) <> 'object') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'rows'));
  end if;
  r := backups.locked_restore(p_restore_id, 'validating');
  insert into backups.restore_rows (restore_id, section, key, data)
  select r.id, p_section, backups.row_key(p_section, x), x from jsonb_array_elements(p_rows) x
  on conflict (restore_id, section, key) do nothing;
  get diagnostics added = row_count;
  return jsonb_build_object('added', added);
end;
$$;

-- Ends a validation run: in_review with the differences, or failed.
create function api.admin_restore_validated(
  p_user_id uuid,
  p_session_id uuid,
  p_restore_id uuid,
  p_ok boolean,
  p_fail_reason text,
  p_report jsonb,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r backups.restore_requests;
  a backups.archives;
  loaded jsonb;
  reason text := p_fail_reason;
  ok boolean := coalesce(p_ok, false);
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  if jsonb_typeof(p_report) is distinct from 'object' or jsonb_typeof(p_report->'sections') is distinct from 'array' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'report'));
  end if;
  if not ok and (reason is null or reason !~ '^[a-z_]{3,40}$') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'failReason'));
  end if;
  r := backups.locked_restore(p_restore_id, 'validating');
  select * into a from backups.archives where id = r.archive_id;

  -- The database checks the counts too: every manifest row must be staged
  -- (keys are unique per section, so duplicates also fail here).
  if ok then
    select coalesce(jsonb_object_agg(section, n), '{}'::jsonb) into loaded
    from (select section, count(*)::int n from backups.restore_rows where restore_id = r.id group by section) c;
    if loaded <> coalesce(a.manifest->'counts', '{}'::jsonb) then
      ok := false;
      reason := 'row_count_mismatch';
    end if;
  end if;

  insert into backups.restore_checks (restore_id, ok, fail_reason, files, rows, sections, checked_by)
  values (r.id, ok, case when ok then null else reason end, jsonb_array_length(p_report->'sections'),
    coalesce((select sum((x->>'rows')::int) from jsonb_array_elements(p_report->'sections') x
              where jsonb_typeof(x->'rows') = 'number'), 0)::int,
    p_report->'sections', p_user_id)
  on conflict (restore_id) do update set ok = excluded.ok, fail_reason = excluded.fail_reason,
    files = excluded.files, rows = excluded.rows, sections = excluded.sections,
    checked_by = excluded.checked_by, checked_at = now();

  if ok then
    r := backups.transition(r, 'in_review', p_user_id, 'Archive validated', p_request_id);
  else
    delete from backups.restore_rows where restore_id = r.id;
    r := backups.transition(r, 'failed', p_user_id, 'Validation failed: ' || replace(reason, '_', ' '), p_request_id);
  end if;
  return jsonb_build_object('restore', backups.restore_json(r, p_user_id, false), 'ok', ok);
end;
$$;

-- Staged rows go once the request is finished.
create function backups.clear_restore_rows()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status in ('completed', 'rejected', 'cancelled', 'failed') then
    delete from backups.restore_rows where restore_id = new.id;
  end if;
  return null;
end;
$$;

create trigger restore_requests_clear_rows
after update of status on backups.restore_requests
for each row execute function backups.clear_restore_rows();

-- One request with its validation and the per-section differences.
create function api.admin_restore(p_user_id uuid, p_session_id uuid, p_restore_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r backups.restore_requests;
  c backups.restore_checks;
  diff jsonb;
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  select * into r from backups.restore_requests where id = p_restore_id;
  if r.id is null then
    perform identity.fail('not_found');
  end if;
  select * into c from backups.restore_checks where restore_id = r.id;

  if r.status in ('in_review', 'restoring') and exists (select 1 from backups.restore_rows where restore_id = r.id) then
    with live as (
      select s.section, backups.row_key(s.section, s.data) as key, s.data from backups.snapshot(r.tenant_id) s
    ),
    archived as (
      select section, key, data from backups.restore_rows where restore_id = r.id
    ),
    joined as (
      select coalesce(l.section, x.section) as section,
             (x.key is not null) as in_archive, (l.key is not null) as in_live,
             (x.key is not null and l.key is not null and x.data <> l.data) as changed
      from live l full join archived x on x.section = l.section and x.key = l.key
    )
    select coalesce(jsonb_agg(g.obj order by g.section), '[]'::jsonb) into diff
    from (
      select section, jsonb_build_object(
        'section', section,
        'archive', count(*) filter (where in_archive),
        'now', count(*) filter (where in_live),
        'added', count(*) filter (where in_live and not in_archive),
        'removed', count(*) filter (where in_archive and not in_live),
        'changed', count(*) filter (where changed),
        'onRestore', case when section = any (backups.manual_sections()) then 'manual' else 'kept' end
      ) as obj
      from joined group by section
    ) g;
  end if;

  return backups.restore_json(r, p_user_id, false) - 'canCancel' || jsonb_build_object(
    'network', notify.network(r.tenant_id),
    'tenantId', r.tenant_id,
    'operator', case when r.operator_user_id is not null then org.person(r.operator_user_id) end,
    'finishedAt', r.finished_at,
    'validation', case when c.restore_id is not null then jsonb_build_object(
      'ok', c.ok, 'failReason', c.fail_reason, 'files', c.files, 'rows', c.rows, 'checkedAt', c.checked_at,
      'checkedBy', org.person(c.checked_by)) end,
    'differences', diff,
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('from', e.from_status, 'to', e.to_status, 'reason', e.reason,
        'actor', org.person(e.actor_user_id), 'at', e.at) order by e.id)
      from backups.restore_events e where e.request_id = r.id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function backups.manual_sections() from public, anon, authenticated;
revoke all on function backups.row_key(text, jsonb) from public, anon, authenticated;
revoke all on function backups.locked_restore(uuid, text) from public, anon, authenticated;
revoke all on function backups.clear_restore_rows() from public, anon, authenticated;
do $$
declare
  f text;
begin
  foreach f in array array[
    'api.admin_restore_source(uuid, uuid, uuid)',
    'api.admin_restore_rows(uuid, uuid, uuid, text, jsonb)',
    'api.admin_restore_validated(uuid, uuid, uuid, boolean, text, jsonb, text)',
    'api.admin_restore(uuid, uuid, uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- In review only after a passing validation run (admin_restore_validated);
-- an operator can still fail a stuck validation. Latest body, edited.
create or replace function api.platform_advance_restore(
  p_user_id uuid,
  p_session_id uuid,
  p_restore_id uuid,
  p_status text,
  p_reason text,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  clean_reason text;
  request jsonb;
  replayed jsonb;
  r backups.restore_requests;
begin
  perform identity.require_session(p_user_id, p_session_id, p_step_up => true);
  perform identity.require_platform_admin(p_user_id);
  clean_reason := identity.require_reason(p_reason);
  if p_status is null or p_status not in ('validating', 'restoring', 'completed', 'rejected', 'failed') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'status'));
  end if;
  request := jsonb_build_object('restoreId', p_restore_id, 'status', p_status, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'platform_advance_restore', request);
  if replayed is not null then
    return replayed;
  end if;
  select * into r from backups.restore_requests where id = p_restore_id for update;
  if r.id is null then
    perform identity.fail('not_found');
  end if;
  -- requested → validating; validating → failed; in_review → restoring or
  -- rejected; restoring → completed or failed.
  if not ((r.status = 'requested' and p_status = 'validating')
       or (r.status = 'validating' and p_status = 'failed')
       or (r.status = 'in_review' and p_status in ('restoring', 'rejected'))
       or (r.status = 'restoring' and p_status in ('completed', 'failed'))) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'invalid_transition', 'status', r.status));
  end if;
  r := backups.transition(r, p_status, p_user_id, clean_reason, p_request_id);
  return identity.store_result(p_user_id, p_idempotency_key, 'platform_advance_restore', request,
    jsonb_build_object('restore', backups.restore_json(r, p_user_id, false)));
end;
$$;
