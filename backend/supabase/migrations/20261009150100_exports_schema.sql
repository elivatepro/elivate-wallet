-- Blueprint 15 — B1: statements and reports (W-18). One table of files made
-- by background jobs, the rows a job prepares in one transaction, the WAT
-- period rules, and the M15 "Statement ready" catalogue rows.

create schema exports;
revoke all on schema exports from public, anon, authenticated;

-- ── Limits and time basis (owner decisions 2026-10-09) ────────────────────

-- Periods and printed times are WAT (Q1).
create function exports.zone() returns text
language sql immutable set search_path = '' as $$ select 'Africa/Lagos'::text $$;

-- Hard row limits (Q5): above them a file is "too large", never cut short.
create function exports.row_limit(p_format text) returns int
language sql immutable set search_path = '' as $$
  select case p_format when 'pdf' then 5000 else 50000 end
$$;

-- Jobs with more rows than this run "in the background": M15 + bell (Q5).
create function exports.notify_threshold() returns int
language sql immutable set search_path = '' as $$ select 1000 $$;

-- Ready files are kept 7 days (Q6).
create function exports.retention() returns interval
language sql immutable set search_path = '' as $$ select interval '7 days' $$;

create function exports.lease() returns interval
language sql immutable set search_path = '' as $$ select interval '5 minutes' $$;

create function exports.max_attempts() returns int
language sql immutable set search_path = '' as $$ select 3 $$;

-- ── Files ─────────────────────────────────────────────────────────────────

create table exports.files (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique references refs.issued (code) on delete restrict,
  kind text not null check (kind in ('statement_pdf', 'statement_csv', 'office_pdf', 'transactions_csv',
                                     'member_balances_csv')),
  requested_by uuid not null references identity.accounts (user_id) on delete restrict,
  session_id uuid not null,
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  currency text not null references ledger.currencies (code) on delete restrict,
  period_kind text not null check (period_kind in ('month', 'quarter', 'year', 'year_to_date', 'custom')),
  period_from date not null,
  period_to date not null,
  as_of timestamptz not null,
  -- Statements: the requester's own wallet.
  wallet_id uuid references ledger.wallets (id) on delete restrict,
  -- Reports: the workspace it was made from, its scope and an optional member.
  workspace_membership_id uuid references org.memberships (id) on delete restrict,
  scope_office_id uuid,
  member_user_id uuid references identity.accounts (user_id) on delete restrict,
  status text not null default 'queued'
    check (status in ('queued', 'preparing', 'rendering', 'ready', 'failed', 'too_large')),
  summary jsonb check (summary is null or jsonb_typeof(summary) = 'object'),
  row_count int check (row_count is null or row_count >= 0),
  page_count int check (page_count is null or page_count > 0),
  byte_size bigint check (byte_size is null or byte_size > 0),
  sha256 text check (sha256 is null or sha256 ~ '^[0-9a-f]{64}$'),
  has_preview boolean not null default false,
  fail_reason text check (fail_reason is null or fail_reason ~ '^[a-z_]{3,40}$'),
  notify boolean not null default false,
  attempts int not null default 0 check (attempts >= 0),
  lease_owner text check (lease_owner is null or length(lease_owner) between 1 and 100),
  lease_expires_at timestamptz,
  idempotency_key text not null check (idempotency_key ~ '^[A-Za-z0-9_-]{16,100}$'),
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  expires_at timestamptz,
  download_count int not null default 0 check (download_count >= 0),
  last_downloaded_at timestamptz,
  unique (requested_by, idempotency_key),
  foreign key (tenant_id, scope_office_id) references org.offices (tenant_id, id) on delete restrict,
  check (period_from <= period_to),
  check ((kind like 'statement_%') = (wallet_id is not null)),
  check ((kind like 'statement_%') = (workspace_membership_id is null)),
  check (kind not like 'statement_%' or (scope_office_id is null and member_user_id is null)),
  check (reference like case when kind like 'statement_%' then 'STM-%' else 'RPT-%' end),
  check ((status = 'ready') = (finished_at is not null and expires_at is not null and sha256 is not null
    and byte_size is not null and row_count is not null)),
  check ((lease_owner is null) = (lease_expires_at is null))
);

create index files_requester_idx on exports.files (requested_by, created_at desc, id desc);
create index files_queue_idx on exports.files (status, created_at, id) where status in ('queued', 'preparing', 'rendering');

alter table exports.files enable row level security;

-- Rows a job prepared, in output order. Written once by api.export_prepare,
-- read by the Worker, removed when the file is ready or failed.
create table exports.rows (
  file_id uuid not null references exports.files (id) on delete cascade,
  seq int not null check (seq > 0),
  section text not null check (section in ('txn', 'member')),
  data jsonb not null check (jsonb_typeof(data) = 'object'),
  primary key (file_id, seq)
);

alter table exports.rows enable row level security;

create function exports.format(p_kind text) returns text
language sql immutable set search_path = '' as $$
  select case when p_kind like '%_pdf' then 'pdf' else 'csv' end
$$;

-- Server-built storage key; only the Worker and the app server see it.
create function exports.object_key(p_file exports.files) returns text
language sql immutable set search_path = '' as $$
  select 'exports/' || p_file.tenant_id::text || '/' || p_file.id::text || '.' || exports.format(p_file.kind)
$$;

-- ── Periods (WAT, inclusive dates) ────────────────────────────────────────

-- Validates a period choice and returns its dates. `month`, `quarter` and
-- `year` must be whole calendar periods; `year_to_date` runs from 1 January to
-- today; `custom` is any range that has started. A period may end after today
-- (this month): the file is then "as of" the moment its job runs.
create function exports.period(p_kind text, p_from text, p_to text)
returns table (period_from date, period_to date)
language plpgsql
set search_path = ''
as $$
declare
  today date := (now() at time zone exports.zone())::date;
  f date := ledger.date_filter(p_from, 'from');
  t date := ledger.date_filter(p_to, 'to');
begin
  if p_kind is null or p_kind not in ('month', 'quarter', 'year', 'year_to_date', 'custom') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'period'));
  end if;
  if f is null or t is null or f > t then
    perform identity.fail('validation_error', jsonb_build_object('field', 'period'));
  end if;
  if (p_kind = 'month' and (f <> date_trunc('month', f)::date
        or t <> (date_trunc('month', f) + interval '1 month - 1 day')::date))
    or (p_kind = 'quarter' and (f <> date_trunc('quarter', f)::date
        or t <> (date_trunc('quarter', f) + interval '3 months - 1 day')::date))
    or (p_kind = 'year' and (f <> date_trunc('year', f)::date
        or t <> (date_trunc('year', f) + interval '1 year - 1 day')::date))
    or (p_kind = 'year_to_date' and (f <> date_trunc('year', today)::date or t <> today)) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'period'));
  end if;
  if f > today then
    perform identity.fail('conflict', jsonb_build_object('reason', 'period_in_future'));
  end if;
  if f < date '2000-01-01' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'period'));
  end if;
  period_from := f;
  period_to := t;
  return next;
end;
$$;

create function exports.start_at(p_file exports.files) returns timestamptz
language sql stable set search_path = '' as $$
  select p_file.period_from::timestamp at time zone exports.zone()
$$;

-- "September 2026", "Q3 2026", "2026", "2026 so far", "1 Sep – 15 Oct 2026".
create function exports.period_title(p_kind text, p_from date, p_to date) returns text
language sql immutable set search_path = '' as $$
  select case p_kind
    when 'month' then trim(to_char(p_from, 'FMMonth YYYY'))
    when 'quarter' then 'Q' || to_char(p_from, 'Q YYYY')
    when 'year' then to_char(p_from, 'YYYY')
    when 'year_to_date' then to_char(p_from, 'YYYY') || ' so far'
    else case
      when extract(year from p_from) = extract(year from p_to)
        then to_char(p_from, 'FMDD Mon') || ' – ' || to_char(p_to, 'FMDD Mon YYYY')
      else to_char(p_from, 'FMDD Mon YYYY') || ' – ' || to_char(p_to, 'FMDD Mon YYYY')
    end
  end
$$;

-- Wire shape of a file for its requester. Never the storage key.
create function exports.file_json(p_file exports.files) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'exportId', p_file.id,
    'reference', p_file.reference,
    'kind', p_file.kind,
    'format', exports.format(p_file.kind),
    'tenantId', p_file.tenant_id,
    'currency', p_file.currency,
    'period', jsonb_build_object(
      'kind', p_file.period_kind,
      'from', to_char(p_file.period_from, 'YYYY-MM-DD'),
      'to', to_char(p_file.period_to, 'YYYY-MM-DD'),
      'title', exports.period_title(p_file.period_kind, p_file.period_from, p_file.period_to),
      'asOf', p_file.as_of,
      'timeZone', exports.zone()
    ),
    'scope', case when p_file.workspace_membership_id is not null then jsonb_build_object(
      'officeId', p_file.scope_office_id,
      'member', case when p_file.member_user_id is not null then org.person(p_file.member_user_id) end
    ) end,
    -- Expired is derived: a ready file past its 7 days.
    'status', case when p_file.status = 'ready' and p_file.expires_at <= now() then 'expired' else p_file.status end,
    'rowCount', p_file.row_count,
    'pageCount', p_file.page_count,
    'byteSize', p_file.byte_size,
    'hasPreview', p_file.has_preview and p_file.kind = 'statement_pdf',
    'failReason', p_file.fail_reason,
    'background', p_file.notify,
    'createdAt', p_file.created_at,
    'readyAt', p_file.finished_at,
    'expiresAt', p_file.expires_at
  )
$$;

-- ── Worker wake-up (pg_net via Vault, as for the outbox) ──────────────────

-- POSTs the app Worker's run endpoint (Vault `exports_worker_url`,
-- `exports_worker_secret`; no-op when missing). Requests leave after commit.
create function exports.kick()
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  worker_url text;
  worker_secret text;
begin
  select decrypted_secret into worker_url from vault.decrypted_secrets where name = 'exports_worker_url';
  select decrypted_secret into worker_secret from vault.decrypted_secrets where name = 'exports_worker_secret';
  if coalesce(worker_url, '') = '' or coalesce(worker_secret, '') = '' then
    return null;
  end if;
  return net.http_post(
    url := worker_url,
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || worker_secret),
    timeout_milliseconds := 120000
  );
end;
$$;

-- Every minute: wake the Worker only when a job is waiting or a lease ran out.
create function exports.trigger_worker()
returns bigint
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1 from exports.files
    where status = 'queued' or (status in ('preparing', 'rendering') and lease_expires_at < now())
  ) then
    return null;
  end if;
  return exports.kick();
end;
$$;

select cron.schedule('exports-worker', '* * * * *', 'select exports.trigger_worker()');

-- ── Catalogue: M15 and its bell items (Blueprint 13 pattern) ──────────────

insert into outbox.templates (key, version, duplicate_safe, params) values
  ('money.statement_ready', 1, true, array['network', 'title', 'currency', 'format', 'chip', 'path']);

insert into notify.kinds (key, task, email_template) values
  ('export.statement_ready', false, 'money.statement_ready'),
  ('export.report_ready', false, 'money.statement_ready'),
  ('export.failed', false, null);

revoke all on all functions in schema exports from public, anon, authenticated;
revoke all on all tables in schema exports from public, anon, authenticated;
