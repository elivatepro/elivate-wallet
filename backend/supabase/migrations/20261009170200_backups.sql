-- Blueprint 17 — B1/B2: the Team Backup Vault and restore requests (W-24,
-- U-06). A full-network backup is one background job: Postgres snapshots the
-- network in one transaction (allowlisted columns only, never secrets), the
-- app Worker writes the ZIP to private R2, and the file becomes ready only if
-- every prepared row made it. Backups are kept 90 days (owner answer Q2).
-- Restore requests are reviewed and run only by Elivate (owner answer Q1).
-- The schema is `backups`: `vault` is Supabase Vault's.

create schema backups;
revoke all on schema backups from public, anon, authenticated;

-- ── Limits ────────────────────────────────────────────────────────────────

create function backups.retention() returns interval
language sql immutable set search_path = '' as $$ select interval '90 days' $$;

-- Above this an archive is "too large" (Part A, applied decision).
create function backups.row_limit() returns int
language sql immutable set search_path = '' as $$ select 500000 $$;

create function backups.lease() returns interval
language sql immutable set search_path = '' as $$ select interval '10 minutes' $$;

create function backups.max_attempts() returns int
language sql immutable set search_path = '' as $$ select 3 $$;

-- Bumped when the archive layout changes; written into every manifest.
create function backups.format_version() returns int
language sql immutable set search_path = '' as $$ select 1 $$;

-- ── Archives ──────────────────────────────────────────────────────────────

create table backups.archives (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  started_by uuid not null references identity.accounts (user_id) on delete restrict,
  status text not null default 'queued'
    check (status in ('queued', 'preparing', 'building', 'ready', 'failed', 'too_large', 'expired')),
  record_count int check (record_count is null or record_count >= 0),
  byte_size bigint check (byte_size is null or byte_size > 0),
  sha256 text check (sha256 is null or sha256 ~ '^[0-9a-f]{64}$'),
  manifest jsonb check (manifest is null or jsonb_typeof(manifest) = 'object'),
  fail_reason text check (fail_reason is null or fail_reason ~ '^[a-z_]{3,40}$'),
  attempts int not null default 0 check (attempts >= 0),
  lease_owner text check (lease_owner is null or length(lease_owner) between 1 and 100),
  lease_expires_at timestamptz,
  idempotency_key text not null check (idempotency_key ~ '^[A-Za-z0-9_-]{16,100}$'),
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  expires_at timestamptz,
  -- Set when the R2 object of an expired archive is gone.
  deleted_at timestamptz,
  download_count int not null default 0 check (download_count >= 0),
  last_downloaded_at timestamptz,
  unique (started_by, idempotency_key),
  check ((status in ('ready', 'expired')) = (finished_at is not null and expires_at is not null and sha256 is not null
    and byte_size is not null and record_count is not null and manifest is not null)),
  check ((lease_owner is null) = (lease_expires_at is null)),
  check (deleted_at is null or status = 'expired')
);

create index archives_tenant_idx on backups.archives (tenant_id, created_at desc, id desc);
create index archives_starter_idx on backups.archives (started_by);
create index archives_queue_idx on backups.archives (status, created_at, id) where status in ('queued', 'preparing', 'building');
-- One backup at a time per network.
create unique index archives_one_running_idx on backups.archives (tenant_id)
  where status in ('queued', 'preparing', 'building');

alter table backups.archives enable row level security;

create table backups.rows (
  archive_id uuid not null references backups.archives (id) on delete cascade,
  seq int not null check (seq > 0),
  section text not null check (section ~ '^[a-z_]{2,40}$'),
  data jsonb not null check (jsonb_typeof(data) = 'object'),
  primary key (archive_id, seq)
);

alter table backups.rows enable row level security;

-- One key per attempt, so a worker whose lease ran out never touches a newer file.
create function backups.object_key(p_a backups.archives) returns text
language sql immutable set search_path = '' as $$
  select 'backups/' || p_a.tenant_id::text || '/' || p_a.id::text || '/' || p_a.attempts::text || '.zip'
$$;

-- "elivate-backup-cedar-2026-10-05-1140.zip" (WAT).
create function backups.file_name(p_a backups.archives) returns text
language sql stable set search_path = '' as $$
  select 'elivate-backup-'
    || coalesce(nullif(trim(both '-' from regexp_replace(lower(t.short_name), '[^a-z0-9]+', '-', 'g')), ''), 'network')
    || '-' || to_char(coalesce(p_a.finished_at, p_a.created_at) at time zone 'Africa/Lagos', 'YYYY-MM-DD-HH24MI')
    || '.zip'
  from org.tenants t where t.id = p_a.tenant_id
$$;

create function backups.archive_json(p_a backups.archives, p_can_download boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'backupId', p_a.id,
    'status', case when p_a.status = 'ready' and p_a.expires_at <= now() then 'expired' else p_a.status end,
    'startedBy', org.person(p_a.started_by),
    'recordCount', p_a.record_count,
    'byteSize', p_a.byte_size,
    'sha256', p_a.sha256,
    'counts', p_a.manifest->'counts',
    'failReason', p_a.fail_reason,
    'createdAt', p_a.created_at,
    'readyAt', p_a.finished_at,
    'expiresAt', p_a.expires_at,
    'canDownload', p_can_download and p_a.status = 'ready' and p_a.expires_at > now()
  );
$$;

-- ── Restore requests (W-24) ───────────────────────────────────────────────

create table backups.restore_requests (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  reference text not null unique references refs.issued (code) on delete restrict check (reference like 'RST-%'),
  archive_id uuid not null references backups.archives (id) on delete restrict,
  reason text not null check (length(reason) between 10 and 500),
  status text not null default 'requested'
    check (status in ('requested', 'validating', 'in_review', 'restoring', 'completed', 'rejected', 'cancelled',
                      'failed')),
  status_reason text check (status_reason is null or length(status_reason) between 3 and 500),
  requested_by uuid not null references identity.accounts (user_id) on delete restrict,
  cancelled_by uuid references identity.accounts (user_id) on delete restrict,
  operator_user_id uuid references identity.accounts (user_id) on delete restrict,
  idempotency_key text not null check (idempotency_key ~ '^[A-Za-z0-9_-]{16,100}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz,
  unique (requested_by, idempotency_key),
  check ((status in ('completed', 'rejected', 'cancelled', 'failed')) = (finished_at is not null)),
  check ((status = 'cancelled') = (cancelled_by is not null)),
  check (status not in ('rejected', 'failed') or status_reason is not null)
);

create index restore_requests_tenant_idx on backups.restore_requests (tenant_id, created_at desc, id desc);
create index restore_requests_archive_idx on backups.restore_requests (archive_id);
create index restore_requests_requester_idx on backups.restore_requests (requested_by);
create index restore_requests_canceller_idx on backups.restore_requests (cancelled_by);
create index restore_requests_operator_idx on backups.restore_requests (operator_user_id);
-- One open request per network (Part A, applied decision).
create unique index restore_requests_one_open_idx on backups.restore_requests (tenant_id)
  where status in ('requested', 'validating', 'in_review', 'restoring');

alter table backups.restore_requests enable row level security;

create table backups.restore_events (
  id bigint generated always as identity primary key,
  request_id uuid not null references backups.restore_requests (id) on delete restrict,
  from_status text,
  to_status text not null,
  reason text,
  actor_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  at timestamptz not null default now()
);

create index restore_events_request_idx on backups.restore_events (request_id, id);
create index restore_events_actor_idx on backups.restore_events (actor_user_id);

alter table backups.restore_events enable row level security;

create trigger restore_events_immutable
before update or delete or truncate on backups.restore_events
for each statement execute function audit.reject_change();

create function backups.status_label(p_status text) returns text
language sql immutable set search_path = '' as $$
  select case p_status
    when 'requested' then 'Requested'
    when 'validating' then 'Checking the backup'
    when 'in_review' then 'In review'
    when 'restoring' then 'Restoring'
    when 'completed' then 'Restored'
    when 'rejected' then 'Not restored'
    when 'cancelled' then 'Cancelled'
    else 'Failed' end
$$;

create function backups.restore_json(p_r backups.restore_requests, p_user_id uuid, p_can_cancel boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'restoreId', p_r.id,
    'reference', p_r.reference,
    'status', p_r.status,
    'statusReason', p_r.status_reason,
    'reason', p_r.reason,
    'backup', jsonb_build_object('backupId', a.id, 'readyAt', a.finished_at, 'byteSize', a.byte_size,
      'sha256', a.sha256),
    'requestedBy', org.person(p_r.requested_by),
    'createdAt', p_r.created_at,
    'updatedAt', p_r.updated_at,
    'canCancel', p_r.status in ('requested', 'validating', 'in_review')
      and (p_r.requested_by = p_user_id or p_can_cancel)
  )
  from backups.archives a where a.id = p_r.archive_id;
$$;

-- T04 + bell to the requester on every change (W-24).
create function backups.notify_restore(p_r backups.restore_requests)
returns void
language plpgsql
set search_path = ''
as $$
declare
  params jsonb := jsonb_build_object(
    'network', notify.network(p_r.tenant_id),
    'reference', p_r.reference,
    'status', backups.status_label(p_r.status),
    'path', '/app/settings/backups');
begin
  perform notify.emit(p_r.requested_by, p_r.tenant_id, 'backup.restore_update', 'restore_request', p_r.id, params,
    p_r.id::text || ':' || p_r.status, params);
end;
$$;

-- Moves a request (locked by the caller) and records the event and audit.
create function backups.transition(
  p_r backups.restore_requests,
  p_to text,
  p_actor_user_id uuid,
  p_reason text,
  p_request_id text
)
returns backups.restore_requests
language plpgsql
set search_path = ''
as $$
declare
  r backups.restore_requests;
begin
  update backups.restore_requests set
    status = p_to,
    status_reason = case when p_to in ('rejected', 'failed') then p_reason else status_reason end,
    cancelled_by = case when p_to = 'cancelled' then p_actor_user_id else cancelled_by end,
    operator_user_id = case when p_to in ('validating', 'in_review', 'restoring', 'completed', 'rejected', 'failed')
      then p_actor_user_id else operator_user_id end,
    updated_at = now(),
    finished_at = case when p_to in ('completed', 'rejected', 'cancelled', 'failed') then now() end
  where id = p_r.id
  returning * into r;
  insert into backups.restore_events (request_id, from_status, to_status, reason, actor_user_id)
  values (r.id, p_r.status, p_to, p_reason, p_actor_user_id);
  perform audit.record_tenant(r.tenant_id, p_actor_user_id, 'restore.' || p_to, 'restore_request', r.reference,
    p_reason, jsonb_build_object('status', p_r.status), jsonb_build_object('status', p_to), p_request_id);
  perform backups.notify_restore(r);
  return r;
end;
$$;

-- ── The snapshot (W-24: entitled data, never secrets) ─────────────────────

-- Only the listed keys of a row: new columns never leak into an archive.
create function backups.pick(p_row jsonb, p_keys text[])
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(jsonb_object_agg(k, p_row->k), '{}'::jsonb)
  from unnest(p_keys) k
  where p_row ? k;
$$;

-- Every row of the network, by section, in a stable order. Excluded:
-- passwords, PIN hashes, sessions, sign-ins, Auth and integration secrets,
-- Paystack tokens, invitation tokens, NINs, encrypted bank numbers (last 4
-- only), evidence file bodies and storage paths, idempotency keys, other
-- networks.
create function backups.snapshot(p_tenant_id uuid)
returns table (section text, data jsonb)
language sql
stable
set search_path = ''
as $$
  with people as (
    select distinct m.user_id from org.memberships m where m.tenant_id = p_tenant_id
  ),
  tx as (
    select t.* from ledger.transactions t where t.tenant_id = p_tenant_id
  ),
  acct as (
    select a.* from ledger.accounts a where a.tenant_id = p_tenant_id
  ),
  wd as (
    select w.* from finance.withdrawals w where w.tenant_id = p_tenant_id
  ),
  po as (
    select p.* from finance.payouts p join wd on wd.id = p.withdrawal_id
  )
  select s.section, s.data from (
    select 1 as o, 'network'::text, jsonb_build_object('id', t.id, 'name', t.name, 'shortName', t.short_name,
      'status', t.status, 'createdAt', t.created_at, 'activatedAt', t.activated_at,
      'activationSource', t.activation_source) || jsonb_build_object('settings', org.brand_json(t.id) - 'tenantId'),
      t.id::text as k
    from org.tenants t where t.id = p_tenant_id
    union all
    select 2, 'settings_revisions', backups.pick(to_jsonb(r), array['revision', 'name', 'short_name', 'theme',
      'slogan', 'support_name', 'support_email', 'support_phone', 'help_url', 'locale', 'time_zone', 'changed',
      'restored_from', 'actor_user_id', 'created_at']) || jsonb_build_object('has_logo', r.logo_key is not null),
      lpad(r.revision::text, 10, '0')
    from org.tenant_setting_revisions r where r.tenant_id = p_tenant_id
    union all
    select 3, 'offices', backups.pick(to_jsonb(o), array['id', 'parent_office_id', 'office_type', 'name', 'status',
      'created_by', 'created_at']), o.created_at::text || o.id::text
    from org.offices o where o.tenant_id = p_tenant_id
    union all
    select 4, 'office_moves', backups.pick(to_jsonb(x), array['id', 'office_id', 'from_parent_id', 'to_parent_id',
      'reason', 'actor_user_id', 'at']), x.at::text || x.id::text
    from org.office_moves x where x.tenant_id = p_tenant_id
    union all
    select 5, 'people', jsonb_build_object('user_id', a.user_id, 'uid', a.uid, 'status', a.status,
      'display_name', pr.display_name, 'first_name', pr.first_name, 'last_name', pr.last_name, 'email', u.email,
      'phone', pr.phone, 'rank', pr.rank, 'created_at', a.created_at), a.uid
    from people p
    join identity.accounts a on a.user_id = p.user_id
    left join identity.profiles pr on pr.user_id = p.user_id
    left join auth.users u on u.id = p.user_id
    union all
    select 6, 'memberships', backups.pick(to_jsonb(m), array['id', 'office_id', 'user_id', 'role', 'is_primary',
      'status', 'started_at', 'ended_at', 'ended_reason', 'replaced_by_id', 'created_by']),
      m.started_at::text || m.id::text
    from org.memberships m where m.tenant_id = p_tenant_id
    union all
    select 7, 'membership_events', backups.pick(to_jsonb(x), array['id', 'membership_id', 'action', 'from_status',
      'to_status', 'reason', 'actor_user_id', 'at']), x.at::text || x.id::text
    from org.membership_events x where x.tenant_id = p_tenant_id
    union all
    select 8, 'invitations', backups.pick(to_jsonb(i), array['id', 'reference', 'office_id', 'role', 'email',
      'status', 'expires_at', 'invited_by', 'reason', 'created_at', 'accepted_at', 'accepted_user_id',
      'accepted_membership_id', 'revoked_at', 'revoked_by', 'revoke_reason']), i.created_at::text || i.id::text
    from org.invitations i where i.tenant_id = p_tenant_id
    union all
    select 9, 'invitation_events', backups.pick(to_jsonb(x), array['id', 'invitation_id', 'action', 'actor_user_id',
      'reason', 'at']), x.at::text || x.id::text
    from org.invitation_events x where x.tenant_id = p_tenant_id
    union all
    select 10, 'role_permissions', backups.pick(to_jsonb(x), array['role', 'permission_key', 'allowed', 'updated_by',
      'updated_at']), x.role::text || x.permission_key
    from authz.role_permissions x where x.tenant_id = p_tenant_id
    union all
    select 11, 'access_assignments', backups.pick(to_jsonb(x), array['id', 'subject_user_id', 'created_by', 'reason',
      'created_at', 'revoked_at', 'revoked_by', 'revoke_reason']), x.created_at::text || x.id::text
    from authz.access_assignments x where x.tenant_id = p_tenant_id
    union all
    select 12, 'access_rules', backups.pick(to_jsonb(x), array['id', 'assignment_id', 'subject_user_id',
      'permission_key', 'effect', 'scope_type', 'scope_office_id', 'scope_user_id', 'starts_at', 'expires_at',
      'revoked_at']), x.id::text
    from authz.access_rules x where x.tenant_id = p_tenant_id
    union all
    select 13, 'reviewer_assignments', backups.pick(to_jsonb(x), array['id', 'membership_id', 'assigned_by', 'reason',
      'assigned_at', 'ended_at', 'ended_by', 'end_reason']), x.assigned_at::text || x.id::text
    from authz.reviewer_assignments x where x.tenant_id = p_tenant_id
    union all
    select 14, 'pockets', backups.pick(to_jsonb(x), array['id', 'kind', 'name', 'sort_order', 'status', 'created_by',
      'created_at', 'retired_at']), x.created_at::text || x.id::text
    from ledger.pockets x where x.tenant_id = p_tenant_id
    union all
    select 15, 'allocation_policies', backups.pick(to_jsonb(x), array['id', 'version', 'source', 'reason',
      'created_by', 'created_at']) || jsonb_build_object('lines', (
        select coalesce(jsonb_agg(backups.pick(to_jsonb(l), array['pocket_id', 'name', 'sort_order', 'basis_points'])
          order by l.sort_order), '[]'::jsonb)
        from ledger.allocation_policy_lines l where l.policy_id = x.id)),
      lpad(x.version::text, 10, '0')
    from ledger.allocation_policies x where x.tenant_id = p_tenant_id
    union all
    select 16, 'ledger_accounts', backups.pick(to_jsonb(x), array['id', 'class', 'currency', 'wallet_id',
      'membership_id', 'office_id', 'owner_user_id', 'pocket_id', 'system_key', 'created_at']),
      x.created_at::text || x.id::text
    from acct x
    union all
    select 17, 'balances', backups.pick(to_jsonb(x), array['account_id', 'currency', 'posted', 'reserved', 'version',
      'updated_at']), x.account_id::text
    from ledger.balances x where x.tenant_id = p_tenant_id
    union all
    select 18, 'transactions', backups.pick(to_jsonb(x), array['id', 'reference', 'type', 'office_id',
      'membership_id', 'wallet_id', 'owner_user_id', 'actor_user_id', 'posted_at', 'metadata']),
      x.posted_at::text || x.id::text
    from tx x
    union all
    select 19, 'postings', jsonb_build_object('transaction_id', j.transaction_id, 'entry_no', j.entry_no,
      'currency', j.currency, 'line_no', p.line_no, 'account_id', p.account_id, 'amount', p.amount),
      j.transaction_id::text || lpad(j.entry_no::text, 6, '0') || lpad(p.line_no::text, 6, '0')
    from tx join ledger.journals j on j.transaction_id = tx.id join ledger.postings p on p.journal_id = j.id
    union all
    select 20, 'reservations', backups.pick(to_jsonb(x), array['id', 'account_id', 'amount', 'purpose',
      'source_type', 'source_id', 'status', 'consumed_amount', 'consumed_by_transaction_id', 'release_reason',
      'actor_user_id', 'created_at', 'settled_at']), x.created_at::text || x.id::text
    from ledger.reservations x join acct on acct.id = x.account_id
    union all
    select 21, 'income_records', backups.pick(to_jsonb(x), array['id', 'reference', 'office_id', 'membership_id',
      'wallet_id', 'owner_user_id', 'currency', 'amount', 'source', 'received_on', 'provider_reference', 'notes',
      'fee_amount', 'fee_currency', 'policy_id', 'transaction_id', 'recorded_by', 'recorded_at']) || jsonb_build_object(
        'allocations', (select coalesce(jsonb_agg(backups.pick(to_jsonb(l), array['pocket_id', 'pocket_name',
          'sort_order', 'basis_points', 'amount', 'account_id']) order by l.sort_order), '[]'::jsonb)
          from finance.income_allocations l where l.income_id = x.id)),
      x.recorded_at::text || x.id::text
    from finance.income_records x where x.tenant_id = p_tenant_id
    union all
    select 22, 'entries', backups.pick(to_jsonb(x), array['id', 'reference', 'kind', 'office_id', 'membership_id',
      'wallet_id', 'owner_user_id', 'currency', 'amount', 'direction', 'pocket_id', 'account_id', 'reservation_id',
      'destination_currency', 'destination_amount', 'quoted_rate', 'provider', 'observed_at', 'external_reference',
      'reason', 'notes', 'withdrawal_id', 'policy_id', 'status', 'submitted_by', 'reviewer_user_id',
      'reviewer_membership_id', 'review_reason', 'decided_at', 'transaction_id', 'created_at']) || jsonb_build_object(
        'lines', (select coalesce(jsonb_agg(backups.pick(to_jsonb(l), array['pocket_id', 'pocket_name', 'sort_order',
          'basis_points', 'amount', 'account_id']) order by l.sort_order), '[]'::jsonb)
          from finance.entry_lines l where l.entry_id = x.id)),
      x.created_at::text || x.id::text
    from finance.entries x where x.tenant_id = p_tenant_id
    union all
    select 23, 'pocket_transfers', backups.pick(to_jsonb(x), array['id', 'reference', 'office_id', 'membership_id',
      'wallet_id', 'owner_user_id', 'currency', 'source_account_id', 'destination_account_id', 'source_pocket_id',
      'destination_pocket_id', 'amount', 'reservation_id', 'requested_by', 'status', 'decided_by', 'decided_at',
      'decision_reason', 'transaction_id', 'created_at']), x.created_at::text || x.id::text
    from finance.pocket_transfers x where x.tenant_id = p_tenant_id
    union all
    select 24, 'reversals', backups.pick(to_jsonb(x), array['id', 'reference', 'original_transaction_id',
      'transaction_id', 'category', 'note', 'reversed_by', 'created_at']), x.created_at::text || x.id::text
    from finance.reversals x where x.tenant_id = p_tenant_id
    union all
    select 25, 'withdrawals', backups.pick(to_jsonb(x), array['id', 'reference', 'office_id', 'membership_id',
      'wallet_id', 'owner_user_id', 'account_id', 'pocket_id', 'currency', 'amount', 'payout_account_id', 'bank_code',
      'bank_name', 'account_last4', 'account_name', 'requested_by', 'status', 'reservation_id', 'approved_by',
      'approved_at', 'decided_by', 'decided_at', 'decision_reason', 'completed_at', 'transaction_id', 'created_at']),
      x.created_at::text || x.id::text
    from wd x
    union all
    select 26, 'payouts', backups.pick(to_jsonb(x), array['id', 'withdrawal_id', 'attempt_no', 'status', 'revision',
      'submitted_by', 'created_at', 'settled_at']), x.created_at::text || x.id::text
    from po x
    union all
    select 27, 'payout_revisions', backups.pick(to_jsonb(x), array['id', 'payout_id', 'revision', 'amount',
      'fee_amount', 'paid_on', 'bank_reference', 'notes', 'evidence_id', 'submitted_by', 'created_at']),
      x.created_at::text || x.id::text
    from finance.payout_revisions x join po on po.id = x.payout_id
    union all
    select 28, 'payout_checks', backups.pick(to_jsonb(x), array['id', 'payout_id', 'revision_id', 'status', 'cycle',
      'outcome', 'reasons', 'model', 'policy_version', 'created_at', 'finished_at']), x.created_at::text || x.id::text
    from finance.payout_checks x join po on po.id = x.payout_id
    union all
    select 29, 'payout_reviews', backups.pick(to_jsonb(x), array['payout_id', 'reviewer_user_id',
      'reviewer_membership_id', 'decision', 'reason', 'decided_at']), x.decided_at::text || x.payout_id::text
    from finance.payout_reviews x join po on po.id = x.payout_id
    union all
    select 30, 'evidence', backups.pick(to_jsonb(x), array['id', 'purpose', 'uploaded_by', 'target_membership_id',
      'declared_name', 'size', 'sha256', 'mime', 'status', 'attached_type', 'attached_id', 'created_at',
      'finalized_at', 'settled_at']), x.created_at::text || x.id::text
    from evidence.files x where x.tenant_id = p_tenant_id
    union all
    select 31, 'subscription', jsonb_build_object('status', s.status, 'kind', s.kind, 'plan', p.key,
      'period_start', s.period_start, 'period_end', s.period_end, 'paused_at', s.paused_at, 'auto_renew', s.auto_renew,
      'next_plan', np.key, 'created_at', s.created_at, 'updated_at', s.updated_at), s.tenant_id::text
    from billing.subscriptions s join billing.plans p on p.id = s.plan_id
    left join billing.plans np on np.id = s.next_plan_id
    where s.tenant_id = p_tenant_id
    union all
    select 32, 'billing_periods', backups.pick(to_jsonb(x), array['id', 'kind', 'plan_id', 'starts_at', 'ends_at',
      'payment_id', 'actor_user_id', 'reason', 'created_at']), x.created_at::text || x.id::text
    from billing.periods x where x.tenant_id = p_tenant_id
    union all
    select 33, 'billing_payments', backups.pick(to_jsonb(x), array['id', 'reference', 'purpose', 'plan_id',
      'from_plan_id', 'amount', 'currency', 'days_left', 'status', 'applied', 'needs_review', 'initiated_by',
      'covers_from', 'covers_to', 'paid_at', 'created_at']), x.created_at::text || x.id::text
    from billing.payments x where x.tenant_id = p_tenant_id
    union all
    select 34, 'billing_owners', backups.pick(to_jsonb(x), array['id', 'user_id', 'membership_id', 'assigned_by',
      'assigned_at', 'ended_at', 'ended_by']), x.assigned_at::text || x.id::text
    from billing.owners x where x.tenant_id = p_tenant_id
    union all
    select 35, 'audit', backups.pick(to_jsonb(x), array['id', 'at', 'actor_user_id', 'action', 'target_type',
      'target_id', 'reason', 'safe_before', 'safe_after']), x.at::text || lpad(x.id::text, 20, '0')
    from audit.tenant_events x where x.tenant_id = p_tenant_id
  ) s (o, section, data, k)
  order by o, k;
$$;

-- ── Notifications ─────────────────────────────────────────────────────────

create function backups.notify_archive(p_a backups.archives, p_outcome text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  network text := notify.network(p_a.tenant_id);
  taken text := to_char(coalesce(p_a.finished_at, p_a.created_at) at time zone 'Africa/Lagos',
    'FMDD Mon YYYY, HH24:MI');
  params jsonb;
begin
  if p_outcome = 'ready' then
    params := jsonb_build_object('network', network, 'taken', taken,
      'size', pg_size_pretty(p_a.byte_size), 'path', '/app/settings/backups');
    perform notify.emit(p_a.started_by, p_a.tenant_id, 'backup.ready', 'backup', p_a.id, params,
      p_a.id::text, params);
  else
    params := jsonb_build_object('network', network, 'taken', taken, 'path', '/app/settings/backups');
    perform notify.emit(p_a.started_by, p_a.tenant_id, 'backup.failed', 'backup', p_a.id, params,
      p_a.id::text, params);
  end if;
end;
$$;

create function backups.finish_failed(p_archive_id uuid, p_status text, p_reason text)
returns backups.archives
language plpgsql
set search_path = ''
as $$
declare
  a backups.archives;
begin
  delete from backups.rows where archive_id = p_archive_id;
  update backups.archives set status = p_status, fail_reason = p_reason, lease_owner = null,
    lease_expires_at = null
  where id = p_archive_id
  returning * into a;
  perform audit.record_tenant(a.tenant_id, a.started_by, 'backup.failed', 'backup', a.id::text, null, null,
    jsonb_build_object('status', p_status, 'reason', p_reason), null);
  perform backups.notify_archive(a, 'failed');
  return a;
end;
$$;

create function backups.leased(p_archive_id uuid, p_worker text, p_status text)
returns backups.archives
language plpgsql
set search_path = ''
as $$
declare
  a backups.archives;
begin
  select * into a from backups.archives where id = p_archive_id for update;
  if a.id is null then
    perform identity.fail('not_found');
  end if;
  if a.status <> p_status or a.lease_owner is distinct from p_worker or a.lease_expires_at < now() then
    perform identity.fail('conflict', jsonb_build_object('reason', 'lease_lost'));
  end if;
  update backups.archives set lease_expires_at = now() + backups.lease() where id = a.id returning * into a;
  return a;
end;
$$;

-- Workers wake for exports, backups and expired archives to remove.
create or replace function exports.trigger_worker()
returns bigint
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1 from exports.files
    where status = 'queued' or (status in ('preparing', 'rendering') and lease_expires_at < now())
  ) and not exists (
    select 1 from backups.archives
    where status = 'queued' or (status in ('preparing', 'building') and lease_expires_at < now())
      or (status = 'expired' and deleted_at is null)
  ) then
    return null;
  end if;
  return exports.kick();
end;
$$;

-- Daily: ready archives past 90 days expire (their files are then removed).
create function backups.expire()
returns int
language plpgsql
set search_path = ''
as $$
declare
  a backups.archives;
  n int := 0;
begin
  for a in
    update backups.archives set status = 'expired'
    where status = 'ready' and expires_at <= now()
    returning *
  loop
    perform audit.record_tenant(a.tenant_id, null, 'backup.expired', 'backup', a.id::text, null, null,
      jsonb_build_object('expiresAt', a.expires_at), null);
    n := n + 1;
  end loop;
  return n;
end;
$$;

select cron.schedule('backups-expire', '17 2 * * *', 'select backups.expire()');

-- ── api: the vault ────────────────────────────────────────────────────────

create function backups.can(p_user_id uuid, p_key text, p_workspace org.memberships)
returns boolean
language sql
stable
set search_path = ''
as $$
  select (authz.decide(p_user_id, p_key, p_workspace.tenant_id, null, null, p_workspace.id)->>'allowed')::boolean
$$;

-- Backups and restore requests of the selected network. Presidents
-- (manage_team_settings) see and download everything; request_restore holders
-- see the list (no download) to pick a backup for a request.
create function api.backup_vault(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  can_manage boolean;
  can_request boolean;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  can_manage := backups.can(p_user_id, 'manage_team_settings', workspace);
  can_request := backups.can(p_user_id, 'request_restore', workspace);
  if not can_manage and not can_request then
    perform identity.fail('authorization_denied');
  end if;
  return jsonb_build_object(
    'backups', coalesce((
      select jsonb_agg(backups.archive_json(a, can_manage) order by a.created_at desc, a.id desc)
      from (select * from backups.archives where tenant_id = workspace.tenant_id
            and (deleted_at is null) order by created_at desc, id desc limit 50) a
    ), '[]'::jsonb),
    'restores', coalesce((
      select jsonb_agg(backups.restore_json(r, p_user_id, can_manage) order by r.created_at desc, r.id desc)
      from (select * from backups.restore_requests where tenant_id = workspace.tenant_id
            order by created_at desc, id desc limit 50) r
    ), '[]'::jsonb),
    'canBackup', can_manage,
    'canRequestRestore', can_request,
    'retentionDays', extract(day from backups.retention())::int,
    'rowLimit', backups.row_limit()
  );
end;
$$;

create function api.start_backup(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  request jsonb;
  replayed jsonb;
  a backups.archives;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  -- A paused network may still back up (Part A, applied decision).
  perform authz.require(p_user_id, 'manage_team_settings', workspace.tenant_id, null, null, workspace.id,
    p_allow_paused => true);
  request := jsonb_build_object('tenantId', workspace.tenant_id);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'start_backup', request);
  if replayed is not null then
    return replayed;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('backups.start:' || workspace.tenant_id::text, 0));
  if exists (select 1 from backups.archives where tenant_id = workspace.tenant_id
             and status in ('queued', 'preparing', 'building')) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'backup_running'));
  end if;
  insert into backups.archives (tenant_id, started_by, idempotency_key)
  values (workspace.tenant_id, p_user_id, p_idempotency_key)
  returning * into a;
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'backup.started', 'backup', a.id::text, null, null,
    null, p_request_id);
  perform exports.kick();
  return identity.store_result(p_user_id, p_idempotency_key, 'start_backup', request,
    jsonb_build_object('backup', backups.archive_json(a, true)));
end;
$$;

-- For the app server only: the storage key after the PIN (decided) and audit.
create function api.authorize_backup_download(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_backup_id uuid,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  a backups.archives;
begin
  perform identity.require_session(p_user_id, p_session_id, p_step_up => true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  perform authz.require(p_user_id, 'manage_team_settings', workspace.tenant_id, null, null, workspace.id,
    p_allow_paused => true);
  select * into a from backups.archives where id = p_backup_id and tenant_id = workspace.tenant_id for update;
  if a.id is null then
    perform identity.fail('not_found');
  end if;
  if a.status = 'expired' or (a.status = 'ready' and a.expires_at <= now()) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'backup_expired'));
  end if;
  if a.status <> 'ready' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'backup_not_ready'));
  end if;
  update backups.archives set download_count = download_count + 1, last_downloaded_at = now() where id = a.id;
  perform audit.record_tenant(a.tenant_id, p_user_id, 'backup.downloaded', 'backup', a.id::text, null, null,
    jsonb_build_object('sha256', a.sha256), p_request_id);
  return jsonb_build_object('objectKey', backups.object_key(a), 'fileName', backups.file_name(a),
    'contentType', 'application/zip', 'byteSize', a.byte_size, 'sha256', a.sha256);
end;
$$;

-- ── api: restore requests ─────────────────────────────────────────────────

create function api.request_restore(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_backup_id uuid,
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
  workspace org.memberships;
  clean_reason text;
  request jsonb;
  replayed jsonb;
  a backups.archives;
  r backups.restore_requests;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  perform authz.require(p_user_id, 'request_restore', workspace.tenant_id, null, null, workspace.id,
    p_allow_paused => true);
  clean_reason := btrim(p_reason);
  if clean_reason is null or length(clean_reason) not between 10 and 500 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'reason'));
  end if;
  request := jsonb_build_object('tenantId', workspace.tenant_id, 'backupId', p_backup_id, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'request_restore', request);
  if replayed is not null then
    return replayed;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('backups.restore:' || workspace.tenant_id::text, 0));
  select * into a from backups.archives where id = p_backup_id and tenant_id = workspace.tenant_id;
  if a.id is null then
    perform identity.fail('not_found');
  end if;
  if a.status <> 'ready' or a.expires_at <= now() then
    perform identity.fail('conflict', jsonb_build_object('reason', 'backup_not_ready'));
  end if;
  if exists (select 1 from backups.restore_requests where tenant_id = workspace.tenant_id
             and status in ('requested', 'validating', 'in_review', 'restoring')) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'restore_open'));
  end if;

  insert into backups.restore_requests (tenant_id, reference, archive_id, reason, requested_by, idempotency_key)
  values (workspace.tenant_id, refs.issue('RST'), a.id, clean_reason, p_user_id, p_idempotency_key)
  returning * into r;
  insert into backups.restore_events (request_id, from_status, to_status, reason, actor_user_id)
  values (r.id, null, 'requested', clean_reason, p_user_id);
  perform audit.record_tenant(r.tenant_id, p_user_id, 'restore.requested', 'restore_request', r.reference,
    clean_reason, null, jsonb_build_object('backupId', a.id, 'sha256', a.sha256), p_request_id);
  perform backups.notify_restore(r);

  return identity.store_result(p_user_id, p_idempotency_key, 'request_restore', request,
    jsonb_build_object('restore', backups.restore_json(r, p_user_id, false)));
end;
$$;

-- The requester or a President may withdraw it before restoring starts.
create function api.cancel_restore_request(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_restore_id uuid,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  request jsonb;
  replayed jsonb;
  r backups.restore_requests;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  request := jsonb_build_object('tenantId', workspace.tenant_id, 'restoreId', p_restore_id);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'cancel_restore_request', request);
  if replayed is not null then
    return replayed;
  end if;
  select * into r from backups.restore_requests where id = p_restore_id and tenant_id = workspace.tenant_id
  for update;
  if r.id is null then
    perform identity.fail('not_found');
  end if;
  if r.requested_by <> p_user_id then
    perform authz.require(p_user_id, 'manage_team_settings', workspace.tenant_id, null, null, workspace.id,
      p_allow_paused => true);
  else
    perform authz.require(p_user_id, 'request_restore', workspace.tenant_id, null, null, workspace.id,
      p_allow_paused => true);
  end if;
  if r.status not in ('requested', 'validating', 'in_review') then
    perform identity.fail('conflict', jsonb_build_object('reason', 'restore_not_cancellable', 'status', r.status));
  end if;
  r := backups.transition(r, 'cancelled', p_user_id, null, p_request_id);
  return identity.store_result(p_user_id, p_idempotency_key, 'cancel_restore_request', request,
    jsonb_build_object('restore', backups.restore_json(r, p_user_id, true)));
end;
$$;

-- Elivate operators only (W-24), until the Admin app: PIN + reason.
create function api.platform_advance_restore(
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
  if p_status is null or p_status not in ('validating', 'in_review', 'restoring', 'completed', 'rejected', 'failed') then
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
  -- requested → validating → in_review → restoring → completed;
  -- in_review → rejected; validating or restoring → failed.
  if not ((r.status = 'requested' and p_status = 'validating')
       or (r.status = 'validating' and p_status in ('in_review', 'failed'))
       or (r.status = 'in_review' and p_status in ('restoring', 'rejected'))
       or (r.status = 'restoring' and p_status in ('completed', 'failed'))) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'invalid_transition', 'status', r.status));
  end if;
  r := backups.transition(r, p_status, p_user_id, clean_reason, p_request_id);
  return identity.store_result(p_user_id, p_idempotency_key, 'platform_advance_restore', request,
    jsonb_build_object('restore', backups.restore_json(r, p_user_id, false)));
end;
$$;

-- ── Worker steps (exports-worker, EXPORTS_WORKER_SECRET) ──────────────────

create function api.backup_claim(p_worker text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a backups.archives;
begin
  if p_worker is null or length(p_worker) not between 1 and 100 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'worker'));
  end if;
  loop
    select * into a from backups.archives
    where status = 'queued' or (status in ('preparing', 'building') and lease_expires_at < now())
    order by created_at, id
    for update skip locked
    limit 1;
    if a.id is null then
      return jsonb_build_object('job', null);
    end if;
    if a.attempts >= backups.max_attempts() then
      perform backups.finish_failed(a.id, 'failed', 'attempts_exhausted');
      a := null;
      continue;
    end if;
    delete from backups.rows where archive_id = a.id;
    update backups.archives set status = 'preparing', attempts = attempts + 1, lease_owner = p_worker,
      lease_expires_at = now() + backups.lease(), started_at = coalesce(started_at, now())
    where id = a.id
    returning * into a;
    return jsonb_build_object('job', jsonb_build_object('backupId', a.id, 'objectKey', backups.object_key(a),
      'attempt', a.attempts));
  end loop;
end;
$$;

-- Writes the whole snapshot in this one transaction (REPEATABLE READ is not
-- needed: one statement sees one snapshot), or "too large" without rows.
create function api.backup_prepare(p_backup_id uuid, p_worker text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a backups.archives := backups.leased(p_backup_id, p_worker, 'preparing');
  inserted int;
  counts jsonb;
begin
  if not exists (
    select 1 from org.memberships m join identity.accounts ac on ac.user_id = m.user_id
    where m.tenant_id = a.tenant_id and m.user_id = a.started_by and m.status = 'active' and ac.status = 'active'
  ) or not (authz.decide(a.started_by, 'manage_team_settings', a.tenant_id)->>'allowed')::boolean then
    a := backups.finish_failed(a.id, 'failed', 'authorization_revoked');
    return jsonb_build_object('status', 'failed', 'failReason', a.fail_reason);
  end if;

  insert into backups.rows (archive_id, seq, section, data)
  select a.id, row_number() over (), s.section, s.data
  from backups.snapshot(a.tenant_id) s;
  get diagnostics inserted = row_count;

  if inserted > backups.row_limit() then
    a := backups.finish_failed(a.id, 'too_large', 'too_large');
    update backups.archives set record_count = inserted where id = a.id;
    return jsonb_build_object('status', 'too_large', 'recordCount', inserted, 'limit', backups.row_limit());
  end if;

  select coalesce(jsonb_object_agg(section, n), '{}'::jsonb) into counts
  from (select section, count(*) n from backups.rows where archive_id = a.id group by section) c;
  update backups.archives set status = 'building', record_count = inserted,
    manifest = jsonb_build_object('counts', counts)
  where id = a.id;
  return jsonb_build_object('status', 'building', 'recordCount', inserted, 'counts', counts,
    'network', jsonb_build_object('tenantId', a.tenant_id, 'name', notify.network(a.tenant_id)),
    'formatVersion', backups.format_version(), 'takenAt', now());
end;
$$;

create function api.backup_rows(p_backup_id uuid, p_worker text, p_after int, p_limit int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a backups.archives := backups.leased(p_backup_id, p_worker, 'building');
begin
  if p_after is null or p_after < 0 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'after'));
  end if;
  if p_limit is null or p_limit not between 1 and 2000 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'limit'));
  end if;
  return jsonb_build_object(
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object('seq', r.seq, 'section', r.section, 'data', r.data) order by r.seq)
      from (select * from backups.rows where archive_id = a.id and seq > p_after order by seq limit p_limit) r
    ), '[]'::jsonb),
    'recordCount', a.record_count
  );
end;
$$;

-- The ZIP is in storage. Ready only if every prepared row is in it and the
-- manifest's per-file counts match the database's.
create function api.backup_finalize(
  p_backup_id uuid,
  p_worker text,
  p_record_count int,
  p_byte_size bigint,
  p_sha256 text,
  p_files jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a backups.archives := backups.leased(p_backup_id, p_worker, 'building');
  stored int;
  file_counts jsonb;
begin
  if p_byte_size is null or p_byte_size <= 0 or p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$'
    or jsonb_typeof(p_files) is distinct from 'array' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'file'));
  end if;
  if exists (select 1 from jsonb_array_elements(p_files) f
             where jsonb_typeof(f->'rows') is distinct from 'number' or coalesce(f->>'section', '') !~ '^[a-z_]{2,40}$'
               or coalesce(f->>'sha256', '') !~ '^[0-9a-f]{64}$') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'files'));
  end if;
  select coalesce(jsonb_object_agg(f->>'section', (f->>'rows')::int), '{}'::jsonb) into file_counts
  from jsonb_array_elements(p_files) f;
  select count(*) into stored from backups.rows where archive_id = a.id;
  if p_record_count is distinct from a.record_count or stored <> a.record_count
     or file_counts <> a.manifest->'counts' then
    a := backups.finish_failed(a.id, 'failed', 'incomplete');
    return jsonb_build_object('status', 'failed', 'failReason', a.fail_reason);
  end if;

  delete from backups.rows where archive_id = a.id;
  update backups.archives set status = 'ready', byte_size = p_byte_size, sha256 = p_sha256,
    manifest = manifest || jsonb_build_object('files', p_files, 'formatVersion', backups.format_version()),
    finished_at = now(), expires_at = now() + backups.retention(), lease_owner = null, lease_expires_at = null
  where id = a.id
  returning * into a;
  perform audit.record_tenant(a.tenant_id, a.started_by, 'backup.ready', 'backup', a.id::text, null, null,
    jsonb_build_object('records', a.record_count, 'sha256', a.sha256), null);
  perform backups.notify_archive(a, 'ready');
  return jsonb_build_object('status', 'ready');
end;
$$;

create function api.backup_fail(p_backup_id uuid, p_worker text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a backups.archives;
begin
  if p_reason is null or p_reason not in ('read_failed', 'render_failed', 'storage_failed', 'incomplete', 'timeout') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'reason'));
  end if;
  select * into a from backups.archives where id = p_backup_id for update;
  if a.id is null then
    perform identity.fail('not_found');
  end if;
  if a.status not in ('preparing', 'building') or a.lease_owner is distinct from p_worker then
    perform identity.fail('conflict', jsonb_build_object('reason', 'lease_lost'));
  end if;
  a := backups.finish_failed(a.id, 'failed', p_reason);
  return jsonb_build_object('status', 'failed', 'failReason', a.fail_reason);
end;
$$;

-- Expired archives whose files still need removing (every attempt's key).
create function api.backup_expired(p_limit int default 20)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select jsonb_build_object('items', coalesce(jsonb_agg(jsonb_build_object('backupId', a.id,
    'objectKeys', (select jsonb_agg('backups/' || a.tenant_id::text || '/' || a.id::text || '/' || n::text || '.zip')
                   from generate_series(1, greatest(a.attempts, 1)) n)) order by a.expires_at), '[]'::jsonb))
  from (select * from backups.archives where status = 'expired' and deleted_at is null
        order by expires_at limit least(greatest(coalesce(p_limit, 20), 1), 100)) a;
$$;

create function api.backup_deleted(p_backup_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a backups.archives;
begin
  update backups.archives set deleted_at = now()
  where id = p_backup_id and status = 'expired' and deleted_at is null
  returning * into a;
  if a.id is null then
    return jsonb_build_object('status', 'unchanged');
  end if;
  perform audit.record_tenant(a.tenant_id, null, 'backup.deleted', 'backup', a.id::text, null, null, null, null);
  return jsonb_build_object('status', 'deleted');
end;
$$;

-- ── T02–T04 catalogue ─────────────────────────────────────────────────────

insert into outbox.templates (key, version, duplicate_safe, params) values
  ('team.backup_ready', 1, true, array['network', 'taken', 'size', 'path']),
  ('team.backup_failed', 1, true, array['network', 'taken', 'path']),
  ('team.restore_update', 1, true, array['network', 'reference', 'status', 'path']);

insert into notify.kinds (key, task, email_template) values
  ('backup.ready', false, 'team.backup_ready'),
  ('backup.failed', false, 'team.backup_failed'),
  ('backup.restore_update', false, 'team.restore_update');

revoke all on all functions in schema backups from public, anon, authenticated;
revoke all on all tables in schema backups from public, anon, authenticated;

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
