-- Blueprint 03 — B4: worker and admin entry points for the outbox. The worker
-- (Edge Function `outbox-worker`) claims leased batches, sends, then reports
-- each result. Ported from legacy claim/complete/fail with its bugs fixed.

-- Housekeeping run before every claim: records invitation expiry.
create function api.outbox_run_maintenance()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  return jsonb_build_object('expiredInvitations', org.expire_overdue_invitations(500));
end;
$$;

-- Leases up to p_batch_size due deliveries (FOR UPDATE SKIP LOCKED). Expired
-- leases are recorded as `lease_expired` attempts first: duplicate-safe
-- templates go back to the queue (or dead-letter at the limit); others are
-- dead-lettered for an admin, since the provider may already have sent them.
-- Events no longer relevant are `skipped` instead of returned.
create function api.outbox_claim(p_worker_id text, p_batch_size int default 25, p_lease_seconds int default 60)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  candidate record;
  event outbox.events;
  template outbox.templates;
  recipient text;
  token uuid;
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
    select d.* from outbox.deliveries d
    join outbox.events e on e.id = d.event_id
    where e.available_at <= now()
      and ((d.status in ('pending', 'retry_scheduled') and d.next_attempt_at <= now())
           or (d.status = 'processing' and d.lease_expires_at <= now()))
    order by coalesce(d.next_attempt_at, d.lease_expires_at), e.occurred_at, d.event_id
    limit p_batch_size
    for update of d skip locked
  loop
    select * into event from outbox.events where id = candidate.event_id;
    select * into template from outbox.templates where key = event.template;

    if candidate.status = 'processing' then
      insert into outbox.attempts (event_id, cycle, attempt_number, lease_token, outcome, error_code, started_at)
      values (candidate.event_id, candidate.cycle, candidate.attempt_count, candidate.lease_token, 'lease_expired',
        'lease_expired', candidate.lease_expires_at);
      if not template.duplicate_safe or candidate.attempt_count >= candidate.max_attempts then
        update outbox.deliveries
        set status = 'dead_lettered', dead_lettered_at = now(), last_error_code = 'lease_expired',
            lease_token = null, lease_expires_at = null, worker_id = null, next_attempt_at = null, updated_at = now()
        where event_id = candidate.event_id;
        continue;
      end if;
    end if;

    if not outbox.is_relevant(event) then
      update outbox.deliveries
      set status = 'skipped', skipped_reason = 'not_relevant', lease_token = null, lease_expires_at = null,
          worker_id = null, next_attempt_at = null, updated_at = now()
      where event_id = candidate.event_id;
      continue;
    end if;

    recipient := coalesce(event.recipient_email,
      (select lower(btrim(u.email)) from auth.users u where u.id = event.recipient_user_id));
    if recipient is null then
      update outbox.deliveries
      set status = 'skipped', skipped_reason = 'recipient_unavailable', lease_token = null, lease_expires_at = null,
          worker_id = null, next_attempt_at = null, updated_at = now()
      where event_id = candidate.event_id;
      continue;
    end if;

    token := case when event.template = 'invitation.issued'
      then (select i.token_id from org.invitations i where i.id = event.aggregate_id) end;

    lease := gen_random_uuid();
    update outbox.deliveries
    set status = 'processing', attempt_count = attempt_count + 1, lease_token = lease,
        lease_expires_at = now() + make_interval(secs => p_lease_seconds), worker_id = p_worker_id,
        next_attempt_at = null, updated_at = now()
    where event_id = candidate.event_id;

    claimed := claimed || jsonb_build_object(
      'eventId', event.id,
      'leaseToken', lease,
      'cycle', candidate.cycle,
      'attempt', candidate.attempt_count + 1,
      'template', event.template,
      'version', event.template_version,
      'params', event.params,
      'to', recipient,
      'tokenId', token
    );
  end loop;

  return claimed;
end;
$$;

-- Marks a leased delivery sent. Idempotent per lease token; a stale lease is
-- reported, never applied.
create function api.outbox_complete(
  p_event_id uuid,
  p_lease_token uuid,
  p_provider_message_id text,
  p_provider_status int,
  p_latency_ms int
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  delivery outbox.deliveries;
begin
  select * into delivery from outbox.deliveries where event_id = p_event_id for update;
  if delivery.event_id is null then
    perform identity.fail('not_found');
  end if;
  if exists (select 1 from outbox.attempts where lease_token = p_lease_token and event_id = p_event_id) then
    return jsonb_build_object('applied', false, 'status', delivery.status, 'reason', 'already_recorded');
  end if;
  if delivery.status <> 'processing' or delivery.lease_token is distinct from p_lease_token then
    return jsonb_build_object('applied', false, 'status', delivery.status, 'reason', 'stale_lease');
  end if;

  insert into outbox.attempts (event_id, cycle, attempt_number, lease_token, outcome, provider_status, latency_ms, started_at)
  values (p_event_id, delivery.cycle, delivery.attempt_count, p_lease_token, 'sent', p_provider_status,
    greatest(p_latency_ms, 0), delivery.updated_at);
  update outbox.deliveries
  set status = 'sent', sent_at = now(), provider_message_id = left(p_provider_message_id, 300),
      lease_token = null, lease_expires_at = null, worker_id = null, last_error_code = null, updated_at = now()
  where event_id = p_event_id;
  return jsonb_build_object('applied', true, 'status', 'sent');
end;
$$;

-- Records a failed attempt. Permanent failures dead-letter; retryable ones are
-- rescheduled with exponential backoff until the attempt limit; an unknown
-- outcome (request may have been sent) is retried only for duplicate-safe
-- templates.
create function api.outbox_fail(
  p_event_id uuid,
  p_lease_token uuid,
  p_outcome text,
  p_error_code text,
  p_provider_status int,
  p_latency_ms int
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  delivery outbox.deliveries;
  safe boolean;
  next_status outbox.delivery_status;
begin
  if p_outcome is null or p_outcome not in ('retryable_failure', 'permanent_failure', 'outcome_unknown') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'outcome'));
  end if;
  if p_error_code is null or p_error_code !~ '^[a-z][a-z0-9_.-]{0,127}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'errorCode'));
  end if;

  select * into delivery from outbox.deliveries where event_id = p_event_id for update;
  if delivery.event_id is null then
    perform identity.fail('not_found');
  end if;
  if exists (select 1 from outbox.attempts where lease_token = p_lease_token and event_id = p_event_id) then
    return jsonb_build_object('applied', false, 'status', delivery.status, 'reason', 'already_recorded');
  end if;
  if delivery.status <> 'processing' or delivery.lease_token is distinct from p_lease_token then
    return jsonb_build_object('applied', false, 'status', delivery.status, 'reason', 'stale_lease');
  end if;

  select t.duplicate_safe into safe
  from outbox.events e join outbox.templates t on t.key = e.template
  where e.id = p_event_id;

  insert into outbox.attempts (event_id, cycle, attempt_number, lease_token, outcome, provider_status, error_code,
    latency_ms, started_at)
  values (p_event_id, delivery.cycle, delivery.attempt_count, p_lease_token, p_outcome::outbox.attempt_outcome,
    p_provider_status, p_error_code, greatest(p_latency_ms, 0), delivery.updated_at);

  next_status := case
    when p_outcome = 'permanent_failure' then 'dead_lettered'
    when p_outcome = 'outcome_unknown' and not safe then 'dead_lettered'
    when delivery.attempt_count >= delivery.max_attempts then 'dead_lettered'
    else 'retry_scheduled'
  end::outbox.delivery_status;

  update outbox.deliveries
  set status = next_status,
      next_attempt_at = case when next_status = 'retry_scheduled'
        then now() + outbox.retry_delay(delivery.attempt_count) end,
      dead_lettered_at = case when next_status = 'dead_lettered' then now() end,
      last_error_code = p_error_code,
      lease_token = null, lease_expires_at = null, worker_id = null, updated_at = now()
  where event_id = p_event_id;
  return jsonb_build_object('applied', true, 'status', next_status);
end;
$$;

-- Platform admins: dead-lettered emails, newest first. No addresses.
create function api.outbox_dead_letters(p_user_id uuid, p_session_id uuid, p_limit int default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  return coalesce((
    select jsonb_agg(item order by (item->>'deadLetteredAt') desc, item->>'eventId')
    from (
      select jsonb_build_object(
        'eventId', e.id,
        'template', e.template,
        'tenantId', e.tenant_id,
        'cycle', d.cycle,
        'attempts', d.attempt_count,
        'lastErrorCode', d.last_error_code,
        'occurredAt', e.occurred_at,
        'deadLetteredAt', to_char(d.dead_lettered_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
      ) as item
      from outbox.deliveries d
      join outbox.events e on e.id = d.event_id
      where d.status = 'dead_lettered'
      order by d.dead_lettered_at desc, d.event_id
      limit org.page_limit(p_limit)
    ) page
  ), '[]'::jsonb);
end;
$$;

-- Platform admin + reason + step-up: gives a dead-lettered email a new cycle.
create function api.outbox_requeue(
  p_user_id uuid,
  p_session_id uuid,
  p_event_id uuid,
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
  delivery outbox.deliveries;
begin
  perform pg_advisory_xact_lock(hashtextextended('identity.platform_admins', 0));
  perform identity.require_session(p_user_id, p_session_id, p_step_up => true);
  perform identity.require_platform_admin(p_user_id);
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('eventId', p_event_id, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'outbox_requeue', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into delivery from outbox.deliveries where event_id = p_event_id for update;
  if delivery.event_id is null then
    perform identity.fail('not_found');
  end if;
  if delivery.status <> 'dead_lettered' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'not_dead_lettered'));
  end if;

  update outbox.deliveries
  set status = 'pending', cycle = cycle + 1, attempt_count = 0, next_attempt_at = now(),
      dead_lettered_at = null, last_error_code = null, updated_at = now()
  where event_id = p_event_id;
  insert into outbox.requeues (event_id, from_cycle, to_cycle, reason, actor_user_id)
  values (p_event_id, delivery.cycle, delivery.cycle + 1, clean_reason, p_user_id);
  perform audit.record('outbox.requeued', p_user_id, p_session_id, null, clean_reason,
    jsonb_build_object('eventId', p_event_id, 'cycle', delivery.cycle),
    jsonb_build_object('eventId', p_event_id, 'cycle', delivery.cycle + 1), p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'outbox_requeue', request,
    jsonb_build_object('eventId', p_event_id, 'status', 'pending', 'cycle', delivery.cycle + 1));
end;
$$;

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
