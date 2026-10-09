-- Blueprint 15 — B3: statement and report commands, the job steps the app
-- Worker drives, downloads and the M15/bell notifications. Files are
-- authorized when requested, again when prepared and again on every download.

alter table audit.tenant_events drop constraint tenant_events_target_type_check;
alter table audit.tenant_events add constraint tenant_events_target_type_check
  check (target_type in (
    'tenant', 'office', 'membership', 'role_permission', 'access_assignment', 'reviewer_assignment',
    'invitation',
    'allocation_policy', 'income', 'evidence',
    'withdrawal', 'payout', 'pocket_transfer',
    'entry', 'reversal',
    'export'
  ));

-- ── Helpers ───────────────────────────────────────────────────────────────

-- Networks whose statements the person may make (owner answer Q8): any
-- network they hold or held money in, or are an active member of. A
-- President has no wallet in their own network (A-03).
create function exports.statement_networks(p_user_id uuid)
returns table (tenant_id uuid)
language sql
stable
set search_path = ''
as $$
  select distinct a.tenant_id
  from ledger.accounts a join ledger.wallets w on w.id = a.wallet_id
  where w.owner_user_id = p_user_id and a.class = 'member_value'
  union
  select m.tenant_id from org.memberships m
  where m.user_id = p_user_id and m.status = 'active' and m.role <> 'president_team_member';
$$;

create function exports.own_file(p_user_id uuid, p_file_id uuid, p_lock boolean default false)
returns exports.files
language plpgsql
set search_path = ''
as $$
declare
  f exports.files;
begin
  if p_lock then
    select * into f from exports.files where id = p_file_id and requested_by = p_user_id for update;
  else
    select * into f from exports.files where id = p_file_id and requested_by = p_user_id;
  end if;
  if f.id is null then
    perform identity.fail('not_found');
  end if;
  return f;
end;
$$;

-- May the person still make or get this report? The workspace must still be
-- theirs and the permission still held (W-18: authorized at generation and
-- at download).
create function exports.report_allowed(p_file exports.files)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  workspace org.memberships;
begin
  select m.* into workspace from org.memberships m
  left join org.offices o on o.id = m.office_id
  where m.id = p_file.workspace_membership_id and m.user_id = p_file.requested_by and m.status = 'active'
    and (m.office_id is null or o.status = 'active');
  if workspace.id is null then
    return false;
  end if;
  if not (authz.decide(p_file.requested_by, 'export_scoped_reports', workspace.tenant_id, workspace.office_id, null,
      workspace.id)->>'allowed')::boolean then
    return false;
  end if;
  if p_file.member_user_id is not null and not exists (
      select 1 from ledger.visible_segments(p_file.requested_by, workspace.id, workspace.tenant_id,
        array['export_scoped_reports'], null, workspace.office_id) v
      where v.owner_user_id = p_file.member_user_id) then
    return false;
  end if;
  -- A prepared file: everything in it must still be visible (a deny added
  -- after the file was made removes the whole file from reach).
  return p_file.included_accounts is null or p_file.included_accounts <@ exports.report_accounts(
    p_file.requested_by, workspace.id, workspace.tenant_id, p_file.scope_office_id, p_file.member_user_id,
    p_file.currency, array['export_scoped_reports']);
end;
$$;

create function exports.format_label(p_kind text) returns text
language sql immutable set search_path = '' as $$
  select case p_kind
    when 'statement_pdf' then 'PDF statement'
    when 'statement_csv' then 'CSV of transactions'
    when 'office_pdf' then 'Office report PDF'
    when 'transactions_csv' then 'Transactions CSV'
    else 'Member balances CSV'
  end
$$;

-- "elivate-statement-2026-09-01_2026-09-30-NGN-STM-4V9B-0412.pdf"
create function exports.file_name(p_file exports.files) returns text
language sql immutable set search_path = '' as $$
  select 'elivate-' || replace(p_file.kind, '_' || exports.format(p_file.kind), '') || '-'
    || to_char(p_file.period_from, 'YYYY-MM-DD') || '_' || to_char(p_file.period_to, 'YYYY-MM-DD') || '-'
    || p_file.currency || '-' || p_file.reference || '.' || exports.format(p_file.kind)
$$;

-- Bell item and, for "ready", M15. Statements are personal items (shown in
-- every workspace); reports belong to their network. Params are safe display
-- values only: never amounts, balances or file locations.
create function exports.notify(p_file exports.files, p_outcome text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  statement boolean := p_file.kind like 'statement_%';
  title text := exports.period_title(p_file.period_kind, p_file.period_from, p_file.period_to);
  path text := case when statement then '/app/statements' else '/app/reports' end;
  params jsonb := jsonb_build_object('title', title, 'currency', p_file.currency,
    'format', exports.format_label(p_file.kind), 'reference', p_file.reference, 'path', path,
    'what', case when statement then 'statement' else 'report' end);
begin
  if p_outcome = 'ready' then
    perform notify.emit(p_file.requested_by, case when statement then null else p_file.tenant_id end,
      case when statement then 'export.statement_ready' else 'export.report_ready' end,
      'export', p_file.id, params, p_file.id::text || ':' || p_file.retries::text || ':' || p_file.attempts::text,
      jsonb_build_object(
        'network', (select t.name from org.tenants t where t.id = p_file.tenant_id),
        'title', title,
        'currency', p_file.currency,
        'format', exports.format_label(p_file.kind),
        'chip', case when statement then 'Statement' else 'Report' end,
        'path', path));
  else
    perform notify.emit(p_file.requested_by, case when statement then null else p_file.tenant_id end,
      'export.failed', 'export', p_file.id, params,
      p_file.id::text || ':' || p_file.retries::text || ':' || p_file.attempts::text);
  end if;
end;
$$;

-- A job ends without a file: rows are dropped and a big job says so in the bell.
create function exports.finish_failed(p_file_id uuid, p_reason text)
returns exports.files
language plpgsql
set search_path = ''
as $$
declare
  f exports.files;
begin
  delete from exports.rows where file_id = p_file_id;
  update exports.files set status = 'failed', fail_reason = p_reason, lease_owner = null, lease_expires_at = null
  where id = p_file_id
  returning * into f;
  if f.notify then
    perform exports.notify(f, 'failed');
  end if;
  return f;
end;
$$;

-- The job row for a Worker step: it must hold an unexpired lease.
create function exports.leased(p_file_id uuid, p_worker text, p_status text)
returns exports.files
language plpgsql
set search_path = ''
as $$
declare
  f exports.files;
begin
  select * into f from exports.files where id = p_file_id for update;
  if f.id is null then
    perform identity.fail('not_found');
  end if;
  if f.status <> p_status or f.lease_owner is distinct from p_worker or f.lease_expires_at < now() then
    perform identity.fail('conflict', jsonb_build_object('reason', 'lease_lost'));
  end if;
  update exports.files set lease_expires_at = now() + exports.lease() where id = f.id returning * into f;
  return f;
end;
$$;

create function exports.parse_currency(p_currency text)
returns text
language plpgsql
set search_path = ''
as $$
begin
  if p_currency is null or not exists (select 1 from ledger.currencies c where c.code = p_currency) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'currency'));
  end if;
  return p_currency;
end;
$$;

create function exports.list(p_files exports.files[], p_cursor text, p_limit int)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  page_size int := org.page_limit(p_limit);
  after jsonb := org.decode_cursor(p_cursor);
  after_at timestamptz;
  after_id uuid;
begin
  if after is not null then
    begin
      after_at := (after->>'at')::timestamptz;
      after_id := (after->>'id')::uuid;
    exception when others then
      perform identity.fail('validation_error', jsonb_build_object('field', 'cursor'));
    end;
    if after_at is null or after_id is null then
      perform identity.fail('validation_error', jsonb_build_object('field', 'cursor'));
    end if;
  end if;
  return (
    with page as (
      select f as file, f.created_at, f.id, row_number() over (order by f.created_at desc, f.id desc) as n
      from unnest(p_files) f
      where after is null or (f.created_at, f.id) < (after_at, after_id)
      order by f.created_at desc, f.id desc
      limit page_size + 1
    )
    select jsonb_build_object(
      'items', coalesce((
        select jsonb_agg(exports.file_json(p.file) order by p.n) from page p where p.n <= page_size
      ), '[]'::jsonb),
      'nextCursor', (
        select org.encode_cursor(jsonb_build_object(
          'at', to_char(p.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), 'id', p.id))
        from page p
        where p.n = page_size and exists (select 1 from page x where x.n > page_size)
      )
    )
  );
end;
$$;

-- ── Personal statements ───────────────────────────────────────────────────

create function api.statement_options(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  wallet uuid;
begin
  perform identity.require_session(p_user_id, p_session_id);
  select id into wallet from ledger.wallets where owner_user_id = p_user_id;
  return jsonb_build_object(
    'networks', coalesce((
      select jsonb_agg(exports.network_json(n.tenant_id) || jsonb_build_object(
          'currencies', (
            select jsonb_agg(c.code order by c.code) from ledger.currencies c
            where c.active or exists (
              select 1 from ledger.accounts a
              where a.wallet_id = wallet and a.tenant_id = n.tenant_id and a.currency = c.code))
        ) order by t.name, t.id)
      from exports.statement_networks(p_user_id) n
      join org.tenants t on t.id = n.tenant_id
    ), '[]'::jsonb),
    'today', to_char((now() at time zone exports.zone())::date, 'YYYY-MM-DD'),
    'timeZone', exports.zone(),
    'limits', jsonb_build_object('pdf', exports.row_limit('pdf'), 'csv', exports.row_limit('csv'))
  );
end;
$$;

create function api.create_statement(
  p_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_currency text,
  p_period_kind text,
  p_from text,
  p_to text,
  p_format text,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  request jsonb := jsonb_build_object('tenantId', p_tenant_id, 'currency', p_currency, 'periodKind', p_period_kind,
    'from', p_from, 'to', p_to, 'format', p_format);
  replayed jsonb;
  tenant uuid := p_tenant_id;
  wallet uuid;
  period record;
  f exports.files;
begin
  perform identity.require_session(p_user_id, p_session_id);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'create_statement', request);
  if replayed is not null then
    return replayed;
  end if;

  if p_format is null or p_format not in ('pdf', 'csv') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'format'));
  end if;
  perform exports.parse_currency(p_currency);
  if tenant is null then
    if (select count(*) from exports.statement_networks(p_user_id)) = 1 then
      select n.tenant_id into tenant from exports.statement_networks(p_user_id) n;
    else
      perform identity.fail('validation_error', jsonb_build_object('field', 'tenantId'));
    end if;
  end if;
  if not exists (select 1 from exports.statement_networks(p_user_id) n where n.tenant_id = tenant) then
    perform identity.fail('not_found');
  end if;
  select id into wallet from ledger.wallets where owner_user_id = p_user_id;
  if wallet is null then
    perform identity.fail('not_found');
  end if;
  select * into period from exports.period(p_period_kind, p_from, p_to);

  insert into exports.files (reference, kind, requested_by, session_id, tenant_id, currency, period_kind, period_from,
    period_to, as_of, wallet_id, idempotency_key)
  values (refs.issue('STM'), 'statement_' || p_format, p_user_id, p_session_id, tenant, p_currency, p_period_kind,
    period.period_from, period.period_to,
    least(now(), (period.period_to + 1)::timestamp at time zone exports.zone()), wallet, p_idempotency_key)
  returning * into f;

  perform audit.record('export.requested', p_user_id, p_session_id, p_user_id, null, null,
    jsonb_build_object('reference', f.reference, 'kind', f.kind, 'tenantId', f.tenant_id), p_request_id);
  perform exports.kick();
  return identity.store_result(p_user_id, p_idempotency_key, 'create_statement', request, exports.file_json(f));
end;
$$;

create function api.my_exports(p_user_id uuid, p_session_id uuid, p_cursor text default null, p_limit int default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  return exports.list(array(
    select f from exports.files f where f.requested_by = p_user_id and f.kind like 'statement_%'), p_cursor, p_limit);
end;
$$;

-- ── Leadership reports ────────────────────────────────────────────────────

-- The Reports page (Paper S05/S12): live totals for the workspace's scope.
create function api.report_overview(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_currency text,
  p_period_kind text,
  p_from text,
  p_to text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  permissions constant text[] := array['view_scoped_financial_reports', 'export_scoped_reports'];
  workspace org.memberships;
  period record;
  start_at timestamptz;
  as_of timestamptz;
  accounts uuid[];
  summary jsonb;
  scope_name text;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  if not (authz.decide(p_user_id, permissions[1], workspace.tenant_id, workspace.office_id, null, workspace.id)->>'allowed')::boolean
    and not (authz.decide(p_user_id, permissions[2], workspace.tenant_id, workspace.office_id, null, workspace.id)->>'allowed')::boolean then
    perform identity.fail('authorization_denied');
  end if;
  perform exports.parse_currency(p_currency);
  select * into period from exports.period(p_period_kind, p_from, p_to);
  start_at := period.period_from::timestamp at time zone exports.zone();
  as_of := least(now(), (period.period_to + 1)::timestamp at time zone exports.zone());

  accounts := exports.report_accounts(p_user_id, workspace.id, workspace.tenant_id, workspace.office_id, null,
    p_currency, permissions);
  summary := exports.report_summary(p_user_id, workspace.id, workspace.tenant_id, workspace.office_id, null,
    p_currency, accounts, start_at, as_of, permissions);
  select o.name into scope_name from org.offices o where o.id = workspace.office_id;

  return summary || jsonb_build_object(
    'scope', jsonb_build_object(
      'kind', case when workspace.office_id is null then 'network' else 'office' end,
      'name', coalesce(scope_name, (select t.name from org.tenants t where t.id = workspace.tenant_id))),
    'currency', p_currency,
    'period', jsonb_build_object(
      'kind', p_period_kind,
      'from', to_char(period.period_from, 'YYYY-MM-DD'),
      'to', to_char(period.period_to, 'YYYY-MM-DD'),
      'title', exports.period_title(p_period_kind, period.period_from, period.period_to),
      'asOf', to_char(as_of at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'current', as_of < (period.period_to + 1)::timestamp at time zone exports.zone(),
      'timeZone', exports.zone()),
    'members', (
      with mf as (select * from exports.member_figures(accounts, p_currency, start_at, as_of))
      select jsonb_build_object(
        'top', coalesce((select jsonb_agg(mf.data order by mf.seq) from mf where mf.seq <= 3), '[]'::jsonb),
        'rest', jsonb_build_object(
          'count', (select count(*) from mf where mf.seq > 3),
          'income', ledger.money(coalesce((select sum(mf.income) from mf where mf.seq > 3), 0), p_currency),
          'paidOut', ledger.money(coalesce((select sum(mf.paid_out) from mf where mf.seq > 3), 0), p_currency),
          'reserved', ledger.money(coalesce((select sum(mf.reserved) from mf where mf.seq > 3), 0), p_currency)))
    ),
    'canExport', (authz.decide(p_user_id, 'export_scoped_reports', workspace.tenant_id, workspace.office_id, null,
      workspace.id)->>'allowed')::boolean,
    'currencies', (select jsonb_agg(c.code order by c.code) from ledger.currencies c where c.active)
  );
end;
$$;

create function api.create_report(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_kind text,
  p_member_wallet_id uuid,
  p_currency text,
  p_period_kind text,
  p_from text,
  p_to text,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  request jsonb := jsonb_build_object('membershipId', p_membership_id, 'kind', p_kind, 'memberWalletId', p_member_wallet_id,
    'currency', p_currency, 'periodKind', p_period_kind, 'from', p_from, 'to', p_to);
  replayed jsonb;
  workspace org.memberships;
  period record;
  member uuid;
  f exports.files;
begin
  perform identity.require_session(p_user_id, p_session_id);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'create_report', request);
  if replayed is not null then
    return replayed;
  end if;

  workspace := authz.require_workspace(p_user_id, p_membership_id);
  if not (authz.decide(p_user_id, 'export_scoped_reports', workspace.tenant_id, workspace.office_id, null,
      workspace.id)->>'allowed')::boolean then
    perform identity.fail('authorization_denied');
  end if;
  if p_kind is null or p_kind not in ('office_pdf', 'transactions_csv', 'member_balances_csv') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'kind'));
  end if;
  perform exports.parse_currency(p_currency);
  select * into period from exports.period(p_period_kind, p_from, p_to);
  -- One member (picked from Member wallets): someone else whose money the
  -- actor may see in this scope.
  if p_member_wallet_id is not null then
    select owner_user_id into member from ledger.wallets where id = p_member_wallet_id;
    if member is null or member = p_user_id or not exists (
        select 1 from ledger.visible_segments(p_user_id, workspace.id, workspace.tenant_id,
          array['export_scoped_reports'], p_member_wallet_id, workspace.office_id) v) then
      perform identity.fail('not_found');
    end if;
  end if;

  insert into exports.files (reference, kind, requested_by, session_id, tenant_id, currency, period_kind, period_from,
    period_to, as_of, workspace_membership_id, scope_office_id, member_user_id, idempotency_key)
  values (refs.issue('RPT'), p_kind, p_user_id, p_session_id, workspace.tenant_id, p_currency, p_period_kind,
    period.period_from, period.period_to,
    least(now(), (period.period_to + 1)::timestamp at time zone exports.zone()), workspace.id, workspace.office_id,
    member, p_idempotency_key)
  returning * into f;

  perform audit.record_tenant(f.tenant_id, p_user_id, 'export.requested', 'export', f.id::text, null, null,
    jsonb_build_object('reference', f.reference, 'kind', f.kind, 'officeId', f.scope_office_id,
      'memberUserId', f.member_user_id), p_request_id);
  perform exports.kick();
  return identity.store_result(p_user_id, p_idempotency_key, 'create_report', request, exports.file_json(f));
end;
$$;

-- People the actor may export ("One member" picker, Paper S05/S06): owners
-- of segments visible with export_scoped_reports in the workspace scope.
create function api.report_members(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_query text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  term text := btrim(p_query);
  pattern text;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  if not (authz.decide(p_user_id, 'export_scoped_reports', workspace.tenant_id, workspace.office_id, null,
      workspace.id)->>'allowed')::boolean then
    perform identity.fail('authorization_denied');
  end if;
  if term is null or length(term) not between 2 and 100 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'q'));
  end if;
  pattern := '%' || replace(replace(replace(term, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  return jsonb_build_object('items', coalesce((
    select jsonb_agg(x.item order by x.name, x.wallet_id)
    from (
      select distinct on (v.wallet_id) v.wallet_id,
        coalesce(org.person(v.owner_user_id)->>'name', '') as name,
        jsonb_build_object('walletId', v.wallet_id, 'person', org.person(v.owner_user_id)) as item
      from ledger.visible_segments(p_user_id, workspace.id, workspace.tenant_id, array['export_scoped_reports'],
        null, workspace.office_id) v
      join identity.accounts a on a.user_id = v.owner_user_id
      left join identity.profiles pr on pr.user_id = v.owner_user_id
      where upper(a.uid) = upper(term)
        or concat_ws(' ', pr.first_name, pr.last_name) ilike pattern
        or pr.display_name ilike pattern
      order by v.wallet_id
    ) x
  ), '[]'::jsonb));
end;
$$;

create function api.workspace_exports(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_cursor text default null,
  p_limit int default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  return exports.list(array(
    select f from exports.files f
    where f.requested_by = p_user_id and f.workspace_membership_id = workspace.id), p_cursor, p_limit);
end;
$$;

-- ── Either kind ───────────────────────────────────────────────────────────

create function api.export_file(p_user_id uuid, p_session_id uuid, p_export_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  return exports.file_json(exports.own_file(p_user_id, p_export_id));
end;
$$;

-- Failed → a fresh attempt of the same file, re-authorized now.
create function api.retry_export(p_user_id uuid, p_session_id uuid, p_export_id uuid, p_request_id text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  f exports.files;
begin
  perform identity.require_session(p_user_id, p_session_id);
  f := exports.own_file(p_user_id, p_export_id, true);
  if f.status <> 'failed' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'nothing_to_retry'));
  end if;
  if f.kind not like 'statement_%' and not exports.report_allowed(f) then
    perform identity.fail('authorization_denied');
  end if;
  update exports.files set status = 'queued', attempts = 0, retries = retries + 1, fail_reason = null,
    summary = null, row_count = null, included_accounts = null, notify = false, started_at = null,
    session_id = p_session_id,
    as_of = least(now(), (period_to + 1)::timestamp at time zone exports.zone())
  where id = f.id
  returning * into f;
  if f.kind like 'statement_%' then
    perform audit.record('export.retried', p_user_id, p_session_id, p_user_id, null, null,
      jsonb_build_object('reference', f.reference), p_request_id);
  else
    perform audit.record_tenant(f.tenant_id, p_user_id, 'export.retried', 'export', f.id::text, null, null,
      jsonb_build_object('reference', f.reference), p_request_id);
  end if;
  perform exports.kick();
  return exports.file_json(f);
end;
$$;

-- For the app server only: the storage key after every check. Reports need a
-- fresh PIN proof (owner answer Q7). Each file download is audited.
create function api.authorize_export_download(
  p_user_id uuid,
  p_session_id uuid,
  p_export_id uuid,
  p_part text default 'file',
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  f exports.files;
  statement boolean;
begin
  if p_part is null or p_part not in ('file', 'preview') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'part'));
  end if;
  f := exports.own_file(p_user_id, p_export_id, true);
  statement := f.kind like 'statement_%';
  perform identity.require_session(p_user_id, p_session_id, p_step_up => not statement and p_part = 'file');
  if f.status <> 'ready' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'export_not_ready'));
  end if;
  if f.expires_at <= now() then
    perform identity.fail('conflict', jsonb_build_object('reason', 'export_expired'));
  end if;
  if p_part = 'preview' and not (f.has_preview and f.kind = 'statement_pdf') then
    perform identity.fail('not_found');
  end if;
  if not statement and not exports.report_allowed(f) then
    perform identity.fail('authorization_denied');
  end if;

  if p_part = 'file' then
    update exports.files set download_count = download_count + 1, last_downloaded_at = now() where id = f.id;
    if statement then
      perform audit.record('export.downloaded', p_user_id, p_session_id, p_user_id, null, null,
        jsonb_build_object('reference', f.reference, 'kind', f.kind), p_request_id);
    else
      perform audit.record_tenant(f.tenant_id, p_user_id, 'export.downloaded', 'export', f.id::text, null, null,
        jsonb_build_object('reference', f.reference, 'kind', f.kind), p_request_id);
    end if;
  end if;

  return jsonb_build_object(
    'objectKey', exports.object_key(f) || case when p_part = 'preview' then '.png' else '' end,
    'fileName', exports.file_name(f) || case when p_part = 'preview' then '.png' else '' end,
    'contentType', case
      when p_part = 'preview' then 'image/png'
      when exports.format(f.kind) = 'pdf' then 'application/pdf'
      else 'text/csv; charset=utf-8' end,
    'byteSize', case when p_part = 'file' then f.byte_size end,
    'sha256', case when p_part = 'file' then f.sha256 end
  );
end;
$$;

-- ── Worker steps (exports-worker Edge Function, EXPORTS_WORKER_SECRET) ────

-- Leases the oldest waiting job (or one whose lease ran out). A job that ran
-- out of attempts fails instead.
create function api.export_claim(p_worker text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  f exports.files;
begin
  if p_worker is null or length(p_worker) not between 1 and 100 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'worker'));
  end if;
  loop
    select * into f from exports.files
    where status = 'queued' or (status in ('preparing', 'rendering') and lease_expires_at < now())
    order by created_at, id
    for update skip locked
    limit 1;
    if f.id is null then
      return jsonb_build_object('job', null);
    end if;
    if f.attempts >= exports.max_attempts() then
      perform exports.finish_failed(f.id, 'attempts_exhausted');
      f := null;
      continue;
    end if;
    delete from exports.rows where file_id = f.id;
    update exports.files set status = 'preparing', attempts = attempts + 1, included_accounts = null,
      lease_owner = p_worker,
      lease_expires_at = now() + exports.lease(), started_at = coalesce(started_at, now())
    where id = f.id
    returning * into f;
    return jsonb_build_object('job', jsonb_build_object(
      'exportId', f.id, 'reference', f.reference, 'kind', f.kind, 'format', exports.format(f.kind),
      'objectKey', exports.object_key(f), 'fileName', exports.file_name(f), 'attempt', f.attempts));
  end loop;
end;
$$;

-- Re-authorizes, then writes every row in one transaction (or reports
-- "too large" without writing any).
create function api.export_prepare(p_export_id uuid, p_worker text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  f exports.files := exports.leased(p_export_id, p_worker, 'preparing');
  outcome jsonb;
begin
  if f.kind like 'statement_%' then
    if (select status from identity.accounts where user_id = f.requested_by) not in ('active', 'restricted') then
      f := exports.finish_failed(f.id, 'account_unavailable');
      return jsonb_build_object('status', 'failed', 'failReason', f.fail_reason);
    end if;
    outcome := exports.prepare_statement(f);
  else
    if not exports.report_allowed(f) then
      f := exports.finish_failed(f.id, 'authorization_revoked');
      return jsonb_build_object('status', 'failed', 'failReason', f.fail_reason);
    end if;
    outcome := exports.prepare_report(f);
  end if;

  if outcome->>'status' = 'too_large' then
    delete from exports.rows where file_id = f.id;
    update exports.files set status = 'too_large', row_count = (outcome->>'rowCount')::int, lease_owner = null,
      lease_expires_at = null
    where id = f.id;
    return jsonb_build_object('status', 'too_large', 'rowCount', (outcome->>'rowCount')::int,
      'limit', exports.row_limit(exports.format(f.kind)));
  end if;

  update exports.files set status = 'rendering', notify = row_count > exports.notify_threshold()
  where id = f.id
  returning * into f;
  return jsonb_build_object('status', 'rendering', 'rowCount', f.row_count, 'summary', f.summary,
    'background', f.notify);
end;
$$;

-- Rows in seq order after `p_after`, at most `p_limit` (≤ 1,000).
create function api.export_rows(p_export_id uuid, p_worker text, p_after int, p_limit int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  f exports.files := exports.leased(p_export_id, p_worker, 'rendering');
begin
  if p_after is null or p_after < 0 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'after'));
  end if;
  if p_limit is null or p_limit not between 1 and 1000 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'limit'));
  end if;
  return jsonb_build_object(
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object('seq', r.seq, 'section', r.section, 'data', r.data) order by r.seq)
      from (select * from exports.rows where file_id = f.id and seq > p_after order by seq limit p_limit) r
    ), '[]'::jsonb),
    'rowCount', f.row_count
  );
end;
$$;

-- The file is in storage. It becomes ready only if every prepared row made it.
create function api.export_finalize(
  p_export_id uuid,
  p_worker text,
  p_row_count int,
  p_page_count int,
  p_byte_size bigint,
  p_sha256 text,
  p_has_preview boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  f exports.files := exports.leased(p_export_id, p_worker, 'rendering');
  stored int;
begin
  if p_byte_size is null or p_byte_size <= 0 or p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$'
    or (p_page_count is not null and p_page_count <= 0) or (exports.format(f.kind) = 'pdf' and p_page_count is null) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'file'));
  end if;
  select count(*) into stored from exports.rows where file_id = f.id;
  if p_row_count is distinct from f.row_count or stored <> f.row_count then
    f := exports.finish_failed(f.id, 'incomplete');
    return jsonb_build_object('status', 'failed', 'failReason', f.fail_reason);
  end if;

  delete from exports.rows where file_id = f.id;
  update exports.files set status = 'ready', page_count = p_page_count, byte_size = p_byte_size, sha256 = p_sha256,
    has_preview = coalesce(p_has_preview, false) and kind = 'statement_pdf', finished_at = now(),
    expires_at = now() + exports.retention(), lease_owner = null, lease_expires_at = null
  where id = f.id
  returning * into f;
  if f.notify then
    perform exports.notify(f, 'ready');
  end if;
  return jsonb_build_object('status', 'ready');
end;
$$;

create function api.export_fail(p_export_id uuid, p_worker text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  f exports.files;
begin
  if p_reason is null or p_reason not in ('read_failed', 'render_failed', 'storage_failed', 'incomplete', 'timeout') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'reason'));
  end if;
  select * into f from exports.files where id = p_export_id for update;
  if f.id is null then
    perform identity.fail('not_found');
  end if;
  if f.status not in ('preparing', 'rendering') or f.lease_owner is distinct from p_worker then
    perform identity.fail('conflict', jsonb_build_object('reason', 'lease_lost'));
  end if;
  f := exports.finish_failed(f.id, p_reason);
  return jsonb_build_object('status', 'failed', 'failReason', f.fail_reason);
end;
$$;

revoke all on all functions in schema exports from public, anon, authenticated;

-- Every api function: service_role only.
do $$
declare
  fn regprocedure;
begin
  for fn in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end;
$$;
