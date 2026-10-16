-- Blueprint 42 — B1–B4: Web Push for "needs your action" tasks and the
-- owner's own money (owner decisions 2026-10-16). A push job is written with
-- its bell item, in the same transaction; the outbox worker sends it within
-- seconds (one pg_net kick per transaction, after commit) and the per-minute
-- cron run retries. A device's push belongs to its signed-in Auth session:
-- signing out, being signed out from Devices or a password change that signs
-- others out deletes the session and, with it, the subscription.

-- ── Which kinds push (Q1) ──────────────────────────────────────────────────

create table notify.push_kinds (
  key text primary key references notify.kinds (key) on delete restrict
);

create function notify.reject_push_kind_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform identity.fail('invariant_violation', jsonb_build_object('table', 'notify.push_kinds'));
  return null;
end;
$$;

create trigger push_kinds_immutable
before update or delete or truncate on notify.push_kinds
for each statement execute function notify.reject_push_kind_change();

insert into notify.push_kinds (key)
select key from notify.kinds
where task or key in ('money.income_posted', 'money.withdrawal_approved', 'money.withdrawal_completed',
  'money.withdrawal_not_approved');

-- ── Subscriptions (one per signed-in device) ───────────────────────────────

-- SSRF guard: only the browsers' own push services (checked again by the worker).
create function notify.push_endpoint_allowed(p_endpoint text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_endpoint is not null and length(p_endpoint) <= 1000 and p_endpoint !~ '[[:space:][:cntrl:]]'
    and p_endpoint ~ ('^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com'
      || '|web\.push\.apple\.com|([a-z0-9-]+\.)+push\.apple\.com|([a-z0-9-]+\.)+notify\.windows\.com)/');
$$;

create table notify.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references identity.accounts (user_id) on delete cascade,
  session_id uuid not null references auth.sessions (id) on delete cascade,
  endpoint text not null unique check (notify.push_endpoint_allowed(endpoint)),
  -- base64url without padding: an uncompressed P-256 point (65 bytes) and 16 bytes.
  p256dh text not null check (p256dh ~ '^B[A-Za-z0-9_-]{86}$'),
  auth text not null check (auth ~ '^[A-Za-z0-9_-]{22}$'),
  device_label text check (device_label is null or length(device_label) between 1 and 60),
  hide_amounts boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_success_at timestamptz,
  failures int not null default 0 check (failures >= 0)
);

create index push_subscriptions_user_idx on notify.push_subscriptions (user_id, updated_at desc);
create index push_subscriptions_session_idx on notify.push_subscriptions (session_id);

-- ── Jobs and attempts ──────────────────────────────────────────────────────

create table notify.push_jobs (
  item_id uuid primary key references notify.items (id) on delete cascade,
  status outbox.delivery_status not null default 'pending',
  attempt_count int not null default 0 check (attempt_count >= 0),
  max_attempts int not null default 6 check (max_attempts > 0),
  next_attempt_at timestamptz,
  lease_token uuid,
  lease_expires_at timestamptz,
  worker_id text check (worker_id is null or length(worker_id) <= 100),
  sent_at timestamptz,
  skipped_reason text check (skipped_reason is null or skipped_reason ~ '^[a-z][a-z0-9_]{0,63}$'),
  dead_lettered_at timestamptz,
  last_error_code text check (last_error_code is null or last_error_code ~ '^[a-z][a-z0-9_.-]{0,127}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (attempt_count <= max_attempts),
  check (case status
    when 'pending' then next_attempt_at is not null and lease_token is null
    when 'retry_scheduled' then next_attempt_at is not null and lease_token is null
    when 'processing' then lease_token is not null and lease_expires_at is not null and next_attempt_at is null
    when 'sent' then sent_at is not null and lease_token is null and next_attempt_at is null
    when 'skipped' then skipped_reason is not null and lease_token is null and next_attempt_at is null
    when 'dead_lettered' then dead_lettered_at is not null and lease_token is null and next_attempt_at is null
  end)
);

create index push_jobs_due_idx on notify.push_jobs (next_attempt_at) where status in ('pending', 'retry_scheduled');
create index push_jobs_lease_idx on notify.push_jobs (lease_expires_at) where status = 'processing';

-- Never the endpoint or the payload. Rows go only with their job (the bell's
-- 90-day housekeeping).
create table notify.push_attempts (
  id bigint generated always as identity primary key,
  job_id uuid not null references notify.push_jobs (item_id) on delete cascade,
  lease_token uuid not null,
  subscription_id uuid references notify.push_subscriptions (id) on delete set null,
  outcome text not null check (outcome in ('sent', 'retryable_failure', 'gone', 'permanent_failure',
    'lease_expired')),
  provider_status int check (provider_status is null or provider_status between 100 and 599),
  error_code text check (error_code is null or error_code ~ '^[a-z][a-z0-9_.-]{0,127}$'),
  latency_ms int check (latency_ms is null or latency_ms >= 0),
  at timestamptz not null default now()
);

create index push_attempts_job_idx on notify.push_attempts (job_id, at);
create index push_attempts_lease_idx on notify.push_attempts (lease_token);
create index push_attempts_subscription_idx on notify.push_attempts (subscription_id);

-- Rows never change, except that a removed device's id is cleared (set null).
create function notify.reject_push_attempt_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.subscription_id is null
    and (to_jsonb(new) - 'subscription_id') = (to_jsonb(old) - 'subscription_id') then
    return new;
  end if;
  perform identity.fail('invariant_violation', jsonb_build_object('table', 'notify.push_attempts'));
  return null;
end;
$$;

create trigger push_attempts_append_only
before update on notify.push_attempts
for each row execute function notify.reject_push_attempt_change();

alter table notify.push_kinds enable row level security;
alter table notify.push_subscriptions enable row level security;
alter table notify.push_jobs enable row level security;
alter table notify.push_attempts enable row level security;

-- Retry delay after the given attempt: 30 s, 2 min, 10 min, 30 min, 2 h.
create function notify.push_retry_delay(p_attempt int)
returns interval
language sql
immutable
set search_path = ''
as $$
  select (array[interval '30 seconds', interval '2 minutes', interval '10 minutes', interval '30 minutes',
    interval '2 hours'])[least(greatest(p_attempt, 1), 5)];
$$;

-- ── Writing (B2) ───────────────────────────────────────────────────────────

-- As Blueprint 13 left it, plus the push job for a Q1 kind when the person
-- has a device, and one worker kick per transaction.
create or replace function notify.emit(
  p_user_id uuid,
  p_tenant_id uuid,
  p_kind text,
  p_subject_type text,
  p_subject_id uuid,
  p_params jsonb,
  p_dedupe_key text,
  p_email_params jsonb default null
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  kind notify.kinds;
  -- One event may give the same person several kinds (M17 and a new task).
  dedupe text := p_kind || '|' || p_dedupe_key;
  item_id uuid;
  email_id uuid;
begin
  if p_user_id is null then
    return null;
  end if;
  select * into kind from notify.kinds where key = p_kind;
  if kind.key is null then
    perform identity.fail('invariant_violation', jsonb_build_object('reason', 'unknown_notification_kind'));
  end if;

  select id into item_id from notify.items where user_id = p_user_id and dedupe_key = dedupe;
  if item_id is not null then
    return item_id;
  end if;

  if kind.email_template is not null and p_email_params is not null then
    email_id := outbox.enqueue_email(
      kind.email_template,
      'notify:' || dedupe || ':' || p_user_id::text,
      p_subject_type,
      p_subject_id,
      p_tenant_id,
      p_user_id,
      null,
      jsonb_strip_nulls(p_email_params)
    );
  end if;

  insert into notify.items (user_id, tenant_id, kind, task, subject_type, subject_id, params, email_event_id,
    dedupe_key)
  values (p_user_id, p_tenant_id, kind.key, kind.task, p_subject_type, p_subject_id,
    jsonb_strip_nulls(p_params), email_id, dedupe)
  on conflict (user_id, dedupe_key) do nothing
  returning id into item_id;

  if item_id is not null
    and exists (select 1 from notify.push_kinds where key = kind.key)
    and exists (select 1 from notify.push_subscriptions where user_id = p_user_id) then
    insert into notify.push_jobs (item_id, next_attempt_at) values (item_id, now())
    on conflict on constraint push_jobs_pkey do nothing;
    -- pg_net sends only after commit, so the worker finds the job.
    if coalesce(current_setting('notify.push_kick', true), '') <> '1' then
      perform set_config('notify.push_kick', '1', true);
      perform outbox.trigger_worker();
    end if;
  end if;
  return item_id;
end;
$$;

-- ── Sending (B3) ───────────────────────────────────────────────────────────

-- Leases up to p_batch_size due jobs. Each comes with the item's kind, the
-- params the wording needs and the person's live devices. A done task, a task
-- the person can no longer do (the bell's own check, notify.can_act), an
-- account that isn't active, an item older than the push TTL or no device
-- left is `skipped` instead of returned. An expired lease is recorded and
-- retried (Topic makes a repeat replace the shown notification).
create function api.push_claim(p_worker_id text, p_batch_size int default 5, p_lease_seconds int default 120)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  candidate notify.push_jobs;
  item notify.items;
  devices jsonb;
  skip text;
  lease uuid;
  claimed jsonb := '[]'::jsonb;
begin
  if p_worker_id is null or p_worker_id !~ '^[A-Za-z0-9_.:-]{1,100}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'workerId'));
  end if;
  if p_batch_size is null or p_batch_size not between 1 and 25 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'batchSize'));
  end if;
  if p_lease_seconds is null or p_lease_seconds not between 10 and 300 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'leaseSeconds'));
  end if;

  for candidate in
    select j.* from notify.push_jobs j
    where (j.status in ('pending', 'retry_scheduled') and j.next_attempt_at <= now())
       or (j.status = 'processing' and j.lease_expires_at <= now())
    order by coalesce(j.next_attempt_at, j.lease_expires_at), j.item_id
    limit p_batch_size
    for update skip locked
  loop
    if candidate.status = 'processing' then
      insert into notify.push_attempts (job_id, lease_token, outcome, error_code)
      values (candidate.item_id, candidate.lease_token, 'lease_expired', 'lease_expired');
      if candidate.attempt_count >= candidate.max_attempts then
        update notify.push_jobs
        set status = 'dead_lettered', dead_lettered_at = now(), last_error_code = 'lease_expired',
            lease_token = null, lease_expires_at = null, worker_id = null, next_attempt_at = null, updated_at = now()
        where item_id = candidate.item_id;
        continue;
      end if;
    end if;

    select * into item from notify.items where id = candidate.item_id;
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id, 'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth, 'hideAmounts', s.hide_amounts)
        order by s.updated_at desc), '[]'::jsonb)
      into devices
    from (
      select s.* from notify.push_subscriptions s
      join auth.sessions a on a.id = s.session_id
      where s.user_id = item.user_id and (a.not_after is null or a.not_after > now())
      order by s.updated_at desc
      limit 10
    ) s;

    skip := case
      when item.task and (item.resolved_at is not null or not notify.task_open(item.kind, item.subject_id))
        then 'resolved'
      -- Same rule as the bell: an approver who lost the role gets nothing.
      when item.task and not exists (
          select 1 from org.memberships m
          where m.user_id = item.user_id and m.tenant_id = item.tenant_id and m.status = 'active'
            and notify.can_act(item, m))
        then 'not_allowed'
      when (select a.status from identity.accounts a where a.user_id = item.user_id)
        in ('suspended', 'deactivated') then 'account_inactive'
      -- Same as the push TTL (12 h): an old item is no news.
      when item.created_at < now() - interval '12 hours' then 'expired'
      when jsonb_array_length(devices) = 0 then 'no_device'
    end;
    if skip is not null then
      update notify.push_jobs
      set status = 'skipped', skipped_reason = skip, lease_token = null, lease_expires_at = null, worker_id = null,
          next_attempt_at = null, updated_at = now()
      where item_id = candidate.item_id;
      continue;
    end if;

    lease := gen_random_uuid();
    update notify.push_jobs
    set status = 'processing', attempt_count = attempt_count + 1, lease_token = lease,
        lease_expires_at = now() + make_interval(secs => p_lease_seconds), worker_id = p_worker_id,
        next_attempt_at = null, updated_at = now()
    where item_id = candidate.item_id;

    claimed := claimed || jsonb_build_object(
      'itemId', item.id,
      'leaseToken', lease,
      'attempt', candidate.attempt_count + 1,
      'kind', item.kind,
      -- Only what the push wording uses (P-06): never names, banks or references.
      'params', jsonb_strip_nulls(jsonb_build_object(
        'amount', item.params->>'amount',
        'currency', item.params->>'currency',
        'subject', item.params->>'subject',
        'path', item.params->>'path')),
      'devices', devices
    );
  end loop;

  return claimed;
end;
$$;

-- Records one leased job's results, one per device it was sent to. Sent to
-- any device counts as sent; a device the push service says is gone (404/410)
-- is deleted; otherwise a retryable failure is retried with backoff up to the
-- attempt limit. Idempotent per lease token; a stale lease is reported.
create function api.push_report(p_item_id uuid, p_lease_token uuid, p_results jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  job notify.push_jobs;
  owner uuid;
  result jsonb;
  device uuid;
  outcome text;
  any_sent boolean := false;
  any_retryable boolean := false;
  last_code text;
  next_status outbox.delivery_status;
begin
  if p_results is null or jsonb_typeof(p_results) <> 'array' or jsonb_array_length(p_results) > 10 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'results'));
  end if;
  for result in select value from jsonb_array_elements(p_results) loop
    if jsonb_typeof(result) <> 'object'
      or coalesce(result->>'subscriptionId', '') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or coalesce(result->>'outcome', '') not in ('sent', 'retryable_failure', 'gone', 'permanent_failure')
      or (result->>'errorCode' is not null and result->>'errorCode' !~ '^[a-z][a-z0-9_.-]{0,127}$')
      or (result->'providerStatus' is not null and jsonb_typeof(result->'providerStatus') <> 'null'
        and (jsonb_typeof(result->'providerStatus') <> 'number'
          or (result->>'providerStatus')::numeric not between 100 and 599))
      or (result->'latencyMs' is not null and (jsonb_typeof(result->'latencyMs') <> 'number'
        or (result->>'latencyMs')::numeric < 0)) then
      perform identity.fail('validation_error', jsonb_build_object('field', 'results'));
    end if;
  end loop;

  select * into job from notify.push_jobs where item_id = p_item_id for update;
  if job.item_id is null then
    perform identity.fail('not_found');
  end if;
  if exists (select 1 from notify.push_attempts where lease_token = p_lease_token and job_id = p_item_id) then
    return jsonb_build_object('applied', false, 'status', job.status, 'reason', 'already_recorded');
  end if;
  if job.status <> 'processing' or job.lease_token is distinct from p_lease_token then
    return jsonb_build_object('applied', false, 'status', job.status, 'reason', 'stale_lease');
  end if;
  select user_id into owner from notify.items where id = p_item_id;
  -- Lock this report's devices first, in one order, so two reports that share
  -- a device wait for each other instead of deadlocking (insert, then delete).
  perform 1 from notify.push_subscriptions
  where id in (select (value->>'subscriptionId')::uuid from jsonb_array_elements(p_results))
  order by id
  for update;

  for result in select value from jsonb_array_elements(p_results) loop
    device := (result->>'subscriptionId')::uuid;
    outcome := result->>'outcome';
    -- Only the job owner's devices; another id is ignored.
    if not exists (select 1 from notify.push_subscriptions where id = device and user_id = owner) then
      continue;
    end if;
    insert into notify.push_attempts (job_id, lease_token, subscription_id, outcome, provider_status, error_code,
      latency_ms)
    values (p_item_id, p_lease_token, device, outcome, (result->>'providerStatus')::numeric::int,
      result->>'errorCode', (result->>'latencyMs')::numeric::int);
    case outcome
      when 'sent' then
        any_sent := true;
        update notify.push_subscriptions set last_success_at = now(), failures = 0 where id = device;
      when 'gone' then
        delete from notify.push_subscriptions where id = device;
      else
        any_retryable := any_retryable or outcome = 'retryable_failure';
        last_code := coalesce(result->>'errorCode', outcome);
        update notify.push_subscriptions set failures = failures + 1 where id = device;
    end case;
  end loop;

  next_status := case
    when any_sent then 'sent'
    when any_retryable and job.attempt_count < job.max_attempts then 'retry_scheduled'
    when not exists (select 1 from notify.push_subscriptions where user_id = owner) then 'skipped'
    else 'dead_lettered'
  end::outbox.delivery_status;

  update notify.push_jobs
  set status = next_status,
      sent_at = case when next_status = 'sent' then now() end,
      next_attempt_at = case when next_status = 'retry_scheduled'
        then now() + notify.push_retry_delay(job.attempt_count) end,
      skipped_reason = case when next_status = 'skipped' then 'no_device' end,
      dead_lettered_at = case when next_status = 'dead_lettered' then now() end,
      last_error_code = case when next_status = 'sent' then null else coalesce(last_code, job.last_error_code) end,
      lease_token = null, lease_expires_at = null, worker_id = null, updated_at = now()
  where item_id = p_item_id;

  -- Nothing was recorded (every device already gone): keep the lease spent.
  if not exists (select 1 from notify.push_attempts where lease_token = p_lease_token and job_id = p_item_id) then
    insert into notify.push_attempts (job_id, lease_token, outcome, error_code)
    values (p_item_id, p_lease_token, 'gone', 'no_device');
  end if;
  return jsonb_build_object('applied', true, 'status', next_status);
end;
$$;

-- ── This device's switch (B4) ──────────────────────────────────────────────

create function notify.push_device_json(p_subscription notify.push_subscriptions)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('on', p_subscription.id is not null,
    'hideAmounts', coalesce(p_subscription.hide_amounts, false));
$$;

-- Turns push on for this signed-in session's browser (or updates its Hide
-- amounts). An endpoint already held by another session or person moves to
-- this one (one person per device); this session keeps one subscription.
create function api.push_subscribe(
  p_user_id uuid,
  p_session_id uuid,
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_hide_amounts boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  saved notify.push_subscriptions;
begin
  perform identity.require_session(p_user_id, p_session_id);
  if p_endpoint is null or length(p_endpoint) > 1000 or p_endpoint !~ '^https://[^[:space:][:cntrl:]]+$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'endpoint'));
  end if;
  if not notify.push_endpoint_allowed(p_endpoint) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'push_host_not_allowed'));
  end if;
  if p_p256dh is null or p_p256dh !~ '^B[A-Za-z0-9_-]{86}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'p256dh'));
  end if;
  if p_auth is null or p_auth !~ '^[A-Za-z0-9_-]{22}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'auth'));
  end if;
  if p_hide_amounts is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'hideAmounts'));
  end if;

  delete from notify.push_subscriptions where session_id = p_session_id and endpoint <> p_endpoint;
  insert into notify.push_subscriptions (user_id, session_id, endpoint, p256dh, auth, device_label, hide_amounts)
  values (p_user_id, p_session_id, p_endpoint, p_p256dh, p_auth,
    (select s.device from identity.sign_ins s where s.session_id = p_session_id), p_hide_amounts)
  on conflict (endpoint) do update
  set user_id = excluded.user_id, session_id = excluded.session_id, p256dh = excluded.p256dh,
      auth = excluded.auth, device_label = excluded.device_label, hide_amounts = excluded.hide_amounts,
      failures = case when notify.push_subscriptions.user_id = excluded.user_id
        then notify.push_subscriptions.failures else 0 end,
      last_success_at = case when notify.push_subscriptions.user_id = excluded.user_id
        then notify.push_subscriptions.last_success_at end,
      updated_at = now()
  returning * into saved;
  return notify.push_device_json(saved);
end;
$$;

-- Is push on for this session's browser (the given endpoint)?
create function api.push_subscription_state(p_user_id uuid, p_session_id uuid, p_endpoint text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  saved notify.push_subscriptions;
begin
  perform identity.require_session(p_user_id, p_session_id);
  if p_endpoint is null or length(p_endpoint) > 1000 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'endpoint'));
  end if;
  select * into saved from notify.push_subscriptions
  where endpoint = p_endpoint and user_id = p_user_id and session_id = p_session_id;
  return notify.push_device_json(saved);
end;
$$;

-- Turns push off for an endpoint of the caller's. Idempotent.
create function api.push_unsubscribe(p_user_id uuid, p_session_id uuid, p_endpoint text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  if p_endpoint is null or length(p_endpoint) > 1000 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'endpoint'));
  end if;
  delete from notify.push_subscriptions where endpoint = p_endpoint and user_id = p_user_id;
  return jsonb_build_object('on', false, 'hideAmounts', false);
end;
$$;

revoke all on all functions in schema notify from public, anon, authenticated;

do $$
declare
  fn regprocedure;
begin
  for fn in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and p.proname in ('push_claim', 'push_report', 'push_subscribe',
      'push_subscription_state', 'push_unsubscribe')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end;
$$;
