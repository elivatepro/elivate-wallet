create type internal.integration_delivery_status as enum (
  'pending',
  'processing',
  'retry_scheduled',
  'delivered',
  'dead_lettered'
);

create type internal.integration_attempt_outcome as enum (
  'delivered',
  'retryable_failure',
  'permanent_failure',
  'lease_expired'
);

create type internal.outbox_delivery_claim as (
  outbox_event_id uuid,
  tenant_id uuid,
  aggregate_type text,
  aggregate_id uuid,
  event_type text,
  payload jsonb,
  occurred_at timestamptz,
  delivery_cycle integer,
  attempt_number integer,
  lease_token uuid,
  lease_expires_at timestamptz,
  idempotency_key text
);

create table internal.outbox_delivery_state (
  outbox_event_id uuid primary key
    references internal.outbox_events (id) on delete restrict,
  status internal.integration_delivery_status not null default 'pending',
  delivery_cycle integer not null default 1
    check (delivery_cycle > 0),
  attempt_count integer not null default 0
    check (attempt_count >= 0),
  max_attempts smallint not null default 8
    check (max_attempts between 1 and 25),
  next_attempt_at timestamptz,
  lease_token uuid,
  leased_by uuid,
  lease_started_at timestamptz,
  lease_expires_at timestamptz,
  delivered_at timestamptz,
  dead_lettered_at timestamptz,
  last_error_code text,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  constraint outbox_delivery_state_attempt_limit
    check (attempt_count <= max_attempts),
  constraint outbox_delivery_state_error_code
    check (
      last_error_code is null
      or last_error_code ~ '^[a-z][a-z0-9_.-]{0,127}$'
    ),
  constraint outbox_delivery_state_shape
    check (
      (
        status in ('pending', 'retry_scheduled')
        and next_attempt_at is not null
        and lease_token is null
        and leased_by is null
        and lease_started_at is null
        and lease_expires_at is null
        and delivered_at is null
        and dead_lettered_at is null
        and (
          (status = 'pending' and last_error_code is null)
          or (status = 'retry_scheduled' and last_error_code is not null)
        )
      )
      or (
        status = 'processing'
        and next_attempt_at is null
        and lease_token is not null
        and leased_by is not null
        and lease_started_at is not null
        and lease_expires_at > lease_started_at
        and delivered_at is null
        and dead_lettered_at is null
        and last_error_code is null
      )
      or (
        status = 'delivered'
        and next_attempt_at is null
        and lease_token is null
        and leased_by is null
        and lease_started_at is null
        and lease_expires_at is null
        and delivered_at is not null
        and dead_lettered_at is null
        and last_error_code is null
      )
      or (
        status = 'dead_lettered'
        and next_attempt_at is null
        and lease_token is null
        and leased_by is null
        and lease_started_at is null
        and lease_expires_at is null
        and delivered_at is null
        and dead_lettered_at is not null
        and last_error_code is not null
      )
    )
);

create index outbox_delivery_state_ready
  on internal.outbox_delivery_state (next_attempt_at, outbox_event_id)
  where status in ('pending', 'retry_scheduled');

create index outbox_delivery_state_expired_lease
  on internal.outbox_delivery_state (lease_expires_at, outbox_event_id)
  where status = 'processing';

create table internal.integration_delivery_attempts (
  id uuid primary key default extensions.gen_random_uuid(),
  outbox_event_id uuid not null
    references internal.outbox_events (id) on delete restrict,
  delivery_cycle integer not null check (delivery_cycle > 0),
  attempt_number integer not null check (attempt_number > 0),
  lease_token uuid not null unique,
  worker_id uuid not null,
  outcome internal.integration_attempt_outcome not null,
  provider text,
  provider_reference text,
  provider_status_code smallint,
  error_code text,
  latency_ms integer,
  started_at timestamptz not null,
  finished_at timestamptz not null default clock_timestamp(),
  constraint integration_delivery_attempts_event_attempt
    unique (outbox_event_id, delivery_cycle, attempt_number),
  constraint integration_delivery_attempts_provider
    check (
      provider is null
      or provider ~ '^[a-z][a-z0-9_]{0,63}$'
    ),
  constraint integration_delivery_attempts_provider_reference
    check (
      provider_reference is null
      or char_length(provider_reference) between 1 and 256
    ),
  constraint integration_delivery_attempts_status_code
    check (
      provider_status_code is null
      or provider_status_code between 100 and 599
    ),
  constraint integration_delivery_attempts_error_code
    check (
      error_code is null
      or error_code ~ '^[a-z][a-z0-9_.-]{0,127}$'
    ),
  constraint integration_delivery_attempts_latency
    check (latency_ms is null or latency_ms >= 0),
  constraint integration_delivery_attempts_timing
    check (finished_at >= started_at),
  constraint integration_delivery_attempts_outcome_shape
    check (
      (
        outcome = 'delivered'
        and provider is not null
        and error_code is null
      )
      or (
        outcome in ('retryable_failure', 'permanent_failure')
        and provider is not null
        and error_code is not null
      )
      or (
        outcome = 'lease_expired'
        and provider is null
        and provider_reference is null
        and provider_status_code is null
        and error_code = 'lease_expired'
        and latency_ms is null
      )
    )
);

create index integration_delivery_attempts_event_finished
  on internal.integration_delivery_attempts (
    outbox_event_id,
    finished_at desc
  );

create table internal.outbox_delivery_requeues (
  id uuid primary key default extensions.gen_random_uuid(),
  outbox_event_id uuid not null
    references internal.outbox_events (id) on delete restrict,
  previous_delivery_cycle integer not null
    check (previous_delivery_cycle > 0),
  new_delivery_cycle integer not null
    check (new_delivery_cycle = previous_delivery_cycle + 1),
  reason_code text not null
    check (reason_code ~ '^[a-z][a-z0-9_.-]{0,127}$'),
  operator_reference text not null
    check (char_length(operator_reference) between 1 and 200),
  requeued_at timestamptz not null default clock_timestamp()
);

create index outbox_delivery_requeues_event
  on internal.outbox_delivery_requeues (
    outbox_event_id,
    requeued_at desc
  );

create or replace function internal.initialize_outbox_delivery_state()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  insert into internal.outbox_delivery_state (
    outbox_event_id,
    next_attempt_at
  )
  values (
    new.id,
    greatest(new.available_at, new.occurred_at)
  );

  return new;
end;
$$;

create trigger outbox_events_initialize_delivery_state
  after insert on internal.outbox_events
  for each row execute function internal.initialize_outbox_delivery_state();

insert into internal.outbox_delivery_state (
  outbox_event_id,
  next_attempt_at,
  created_at,
  updated_at
)
select
  event.id,
  greatest(event.available_at, event.occurred_at),
  event.occurred_at,
  clock_timestamp()
from internal.outbox_events event
on conflict (outbox_event_id) do nothing;
