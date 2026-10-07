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

    return 'dead_lettered'::internal.integration_delivery_status;
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

  return 'retry_scheduled'::internal.integration_delivery_status;
end;
$$;

revoke all on function internal.fail_outbox_delivery(
  uuid, uuid, text, text, boolean, text, integer, integer, timestamptz
) from public, anon, authenticated, service_role;
