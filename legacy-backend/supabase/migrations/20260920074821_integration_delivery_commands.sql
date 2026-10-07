create or replace function internal.delivery_retry_delay_seconds(
  p_attempt_number integer
)
returns integer
language sql
immutable
strict
security invoker
set search_path = ''
as $$
  select least(
    3600::numeric,
    15::numeric * power(2::numeric, greatest(p_attempt_number - 1, 0))
  )::integer;
$$;

create or replace function internal.claim_outbox_deliveries(
  p_worker_id uuid,
  p_batch_size integer default 25,
  p_lease_seconds integer default 60,
  p_now timestamptz default clock_timestamp()
)
returns setof internal.outbox_delivery_claim
language plpgsql
security definer
set search_path = ''
as $$
declare
  candidate record;
  next_lease_token uuid;
  next_attempt_number integer;
  next_lease_expires_at timestamptz;
begin
  if p_worker_id is null then
    raise exception using
      errcode = '22023',
      message = 'worker id is required';
  end if;

  if p_batch_size not between 1 and 100 then
    raise exception using
      errcode = '22023',
      message = 'batch size must be between 1 and 100';
  end if;

  if p_lease_seconds not between 5 and 300 then
    raise exception using
      errcode = '22023',
      message = 'lease seconds must be between 5 and 300';
  end if;

  for candidate in
    select
      state.outbox_event_id,
      state.status,
      state.delivery_cycle,
      state.attempt_count,
      state.max_attempts,
      state.lease_token,
      state.leased_by,
      state.lease_started_at,
      state.lease_expires_at,
      event.tenant_id,
      event.aggregate_type,
      event.aggregate_id,
      event.event_type,
      event.payload,
      event.occurred_at
    from internal.outbox_delivery_state state
    join internal.outbox_events event
      on event.id = state.outbox_event_id
    where event.available_at <= p_now
      and (
        (
          state.status in ('pending', 'retry_scheduled')
          and state.next_attempt_at <= p_now
        )
        or (
          state.status = 'processing'
          and state.lease_expires_at <= p_now
        )
      )
    order by
      coalesce(state.next_attempt_at, state.lease_expires_at),
      event.occurred_at,
      state.outbox_event_id
    for update of state skip locked
    limit p_batch_size
  loop
    if candidate.status = 'processing' then
      insert into internal.integration_delivery_attempts (
        outbox_event_id,
        delivery_cycle,
        attempt_number,
        lease_token,
        worker_id,
        outcome,
        error_code,
        started_at,
        finished_at
      )
      values (
        candidate.outbox_event_id,
        candidate.delivery_cycle,
        candidate.attempt_count,
        candidate.lease_token,
        candidate.leased_by,
        'lease_expired',
        'lease_expired',
        candidate.lease_started_at,
        p_now
      );

      if candidate.attempt_count >= candidate.max_attempts then
        update internal.outbox_delivery_state state
           set status = 'dead_lettered',
               next_attempt_at = null,
               lease_token = null,
               leased_by = null,
               lease_started_at = null,
               lease_expires_at = null,
               dead_lettered_at = p_now,
               last_error_code = 'lease_expired',
               updated_at = p_now
         where state.outbox_event_id = candidate.outbox_event_id;

        continue;
      end if;
    end if;

    next_lease_token := extensions.gen_random_uuid();
    next_attempt_number := candidate.attempt_count + 1;
    next_lease_expires_at := p_now + make_interval(secs => p_lease_seconds);

    update internal.outbox_delivery_state state
       set status = 'processing',
           attempt_count = next_attempt_number,
           next_attempt_at = null,
           lease_token = next_lease_token,
           leased_by = p_worker_id,
           lease_started_at = p_now,
           lease_expires_at = next_lease_expires_at,
           delivered_at = null,
           dead_lettered_at = null,
           last_error_code = null,
           updated_at = p_now
     where state.outbox_event_id = candidate.outbox_event_id;

    return next (
      candidate.outbox_event_id,
      candidate.tenant_id,
      candidate.aggregate_type,
      candidate.aggregate_id,
      candidate.event_type,
      candidate.payload,
      candidate.occurred_at,
      candidate.delivery_cycle,
      next_attempt_number,
      next_lease_token,
      next_lease_expires_at,
      'outbox:' || candidate.outbox_event_id::text
    )::internal.outbox_delivery_claim;
  end loop;

  return;
end;
$$;

create or replace function internal.complete_outbox_delivery(
  p_outbox_event_id uuid,
  p_lease_token uuid,
  p_provider text,
  p_provider_reference text default null,
  p_provider_status_code integer default null,
  p_latency_ms integer default null,
  p_now timestamptz default clock_timestamp()
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_state internal.outbox_delivery_state%rowtype;
begin
  if p_provider is null
     or btrim(p_provider) !~ '^[a-z][a-z0-9_]{0,63}$' then
    raise exception using
      errcode = '22023',
      message = 'provider is invalid';
  end if;

  if exists (
    select 1
      from internal.integration_delivery_attempts attempt
     where attempt.outbox_event_id = p_outbox_event_id
       and attempt.lease_token = p_lease_token
       and attempt.outcome = 'delivered'
  ) then
    return false;
  end if;

  select *
    into target_state
    from internal.outbox_delivery_state state
   where state.outbox_event_id = p_outbox_event_id
   for update;

  if target_state.outbox_event_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'outbox delivery state not found';
  end if;

  if target_state.status <> 'processing'
     or target_state.lease_token <> p_lease_token then
    raise exception using
      errcode = '55000',
      message = 'outbox delivery lease is not active';
  end if;

  if target_state.lease_expires_at <= p_now then
    raise exception using
      errcode = '55000',
      message = 'outbox delivery lease has expired';
  end if;

  insert into internal.integration_delivery_attempts (
    outbox_event_id,
    delivery_cycle,
    attempt_number,
    lease_token,
    worker_id,
    outcome,
    provider,
    provider_reference,
    provider_status_code,
    latency_ms,
    started_at,
    finished_at
  )
  values (
    target_state.outbox_event_id,
    target_state.delivery_cycle,
    target_state.attempt_count,
    target_state.lease_token,
    target_state.leased_by,
    'delivered',
    btrim(p_provider),
    nullif(btrim(p_provider_reference), ''),
    p_provider_status_code,
    p_latency_ms,
    target_state.lease_started_at,
    p_now
  );

  update internal.outbox_delivery_state state
     set status = 'delivered',
         next_attempt_at = null,
         lease_token = null,
         leased_by = null,
         lease_started_at = null,
         lease_expires_at = null,
         delivered_at = p_now,
         dead_lettered_at = null,
         last_error_code = null,
         updated_at = p_now
   where state.outbox_event_id = p_outbox_event_id;

  return true;
end;
$$;

create or replace function internal.fail_outbox_delivery(
  p_outbox_event_id uuid,
  p_lease_token uuid,
  p_provider text,
  p_error_code text,
  p_retryable boolean,
  p_provider_reference text default null,
  p_provider_status_code integer default null,
  p_latency_ms integer default null,
  p_now timestamptz default clock_timestamp()
)
returns internal.integration_delivery_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_state internal.outbox_delivery_state%rowtype;
  retry_at timestamptz;
begin
  if p_provider is null
     or btrim(p_provider) !~ '^[a-z][a-z0-9_]{0,63}$' then
    raise exception using
      errcode = '22023',
      message = 'provider is invalid';
  end if;

  if p_error_code is null
     or btrim(p_error_code) !~ '^[a-z][a-z0-9_.-]{0,127}$' then
    raise exception using
      errcode = '22023',
      message = 'error code is invalid';
  end if;

  if exists (
    select 1
      from internal.integration_delivery_attempts attempt
     where attempt.outbox_event_id = p_outbox_event_id
       and attempt.lease_token = p_lease_token
  ) then
    return (
      select state.status
        from internal.outbox_delivery_state state
       where state.outbox_event_id = p_outbox_event_id
    );
  end if;

  select *
    into target_state
    from internal.outbox_delivery_state state
   where state.outbox_event_id = p_outbox_event_id
   for update;

  if target_state.outbox_event_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'outbox delivery state not found';
  end if;

  if target_state.status <> 'processing'
     or target_state.lease_token <> p_lease_token then
    raise exception using
      errcode = '55000',
      message = 'outbox delivery lease is not active';
  end if;

  if target_state.lease_expires_at <= p_now then
    raise exception using
      errcode = '55000',
      message = 'outbox delivery lease has expired';
  end if;

  insert into internal.integration_delivery_attempts (
    outbox_event_id,
    delivery_cycle,
    attempt_number,
    lease_token,
    worker_id,
    outcome,
    provider,
    provider_reference,
    provider_status_code,
    error_code,
    latency_ms,
    started_at,
    finished_at
  )
  values (
    target_state.outbox_event_id,
    target_state.delivery_cycle,
    target_state.attempt_count,
    target_state.lease_token,
    target_state.leased_by,
    case
      when p_retryable then 'retryable_failure'::internal.integration_attempt_outcome
      else 'permanent_failure'::internal.integration_attempt_outcome
    end,
    btrim(p_provider),
    nullif(btrim(p_provider_reference), ''),
    p_provider_status_code,
    btrim(p_error_code),
    p_latency_ms,
    target_state.lease_started_at,
    p_now
  );

  if not p_retryable
     or target_state.attempt_count >= target_state.max_attempts then
    update internal.outbox_delivery_state state
       set status = 'dead_lettered',
           next_attempt_at = null,
           lease_token = null,
           leased_by = null,
           lease_started_at = null,
           lease_expires_at = null,
           delivered_at = null,
           dead_lettered_at = p_now,
           last_error_code = btrim(p_error_code),
           updated_at = p_now
     where state.outbox_event_id = p_outbox_event_id;

    return 'dead_lettered';
  end if;

  retry_at := p_now + make_interval(
    secs => internal.delivery_retry_delay_seconds(target_state.attempt_count)
  );

  update internal.outbox_delivery_state state
     set status = 'retry_scheduled',
         next_attempt_at = retry_at,
         lease_token = null,
         leased_by = null,
         lease_started_at = null,
         lease_expires_at = null,
         delivered_at = null,
         dead_lettered_at = null,
         last_error_code = btrim(p_error_code),
         updated_at = p_now
   where state.outbox_event_id = p_outbox_event_id;

  return 'retry_scheduled';
end;
$$;

create or replace function internal.requeue_dead_letter_delivery(
  p_outbox_event_id uuid,
  p_reason_code text,
  p_operator_reference text,
  p_now timestamptz default clock_timestamp()
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_state internal.outbox_delivery_state%rowtype;
  next_cycle integer;
begin
  if p_reason_code is null
     or btrim(p_reason_code) !~ '^[a-z][a-z0-9_.-]{0,127}$' then
    raise exception using
      errcode = '22023',
      message = 'reason code is invalid';
  end if;

  if p_operator_reference is null
     or char_length(btrim(p_operator_reference)) not between 1 and 200 then
    raise exception using
      errcode = '22023',
      message = 'operator reference is invalid';
  end if;

  select *
    into target_state
    from internal.outbox_delivery_state state
   where state.outbox_event_id = p_outbox_event_id
   for update;

  if target_state.outbox_event_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'outbox delivery state not found';
  end if;

  if target_state.status <> 'dead_lettered' then
    raise exception using
      errcode = '55000',
      message = 'only dead-lettered deliveries can be requeued';
  end if;

  next_cycle := target_state.delivery_cycle + 1;

  insert into internal.outbox_delivery_requeues (
    outbox_event_id,
    previous_delivery_cycle,
    new_delivery_cycle,
    reason_code,
    operator_reference,
    requeued_at
  )
  values (
    target_state.outbox_event_id,
    target_state.delivery_cycle,
    next_cycle,
    btrim(p_reason_code),
    btrim(p_operator_reference),
    p_now
  );

  update internal.outbox_delivery_state state
     set status = 'retry_scheduled',
         delivery_cycle = next_cycle,
         attempt_count = 0,
         next_attempt_at = p_now,
         lease_token = null,
         leased_by = null,
         lease_started_at = null,
         lease_expires_at = null,
         delivered_at = null,
         dead_lettered_at = null,
         last_error_code = 'operator_requeue',
         updated_at = p_now
   where state.outbox_event_id = p_outbox_event_id;

  return next_cycle;
end;
$$;

revoke all on function internal.delivery_retry_delay_seconds(integer)
  from public, anon, authenticated, service_role;
revoke all on function internal.claim_outbox_deliveries(
  uuid, integer, integer, timestamptz
) from public, anon, authenticated, service_role;
revoke all on function internal.complete_outbox_delivery(
  uuid, uuid, text, text, integer, integer, timestamptz
) from public, anon, authenticated, service_role;
revoke all on function internal.fail_outbox_delivery(
  uuid, uuid, text, text, boolean, text, integer, integer, timestamptz
) from public, anon, authenticated, service_role;
revoke all on function internal.requeue_dead_letter_delivery(
  uuid, text, text, timestamptz
) from public, anon, authenticated, service_role;
