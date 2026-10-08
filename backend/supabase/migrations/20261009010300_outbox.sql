-- Blueprint 03 — B2/B4: the durable email outbox. Events are written in the
-- business transaction; a worker sends them through Cloudflare Email Sending.
-- Delivery is at-least-once; "sent" means the provider accepted the message.

create schema outbox;
revoke all on schema outbox from public, anon, authenticated;

create type outbox.delivery_status as enum (
  'pending', 'processing', 'retry_scheduled', 'sent', 'skipped', 'dead_lettered'
);
create type outbox.attempt_outcome as enum (
  'sent', 'retryable_failure', 'permanent_failure', 'outcome_unknown', 'lease_expired', 'skipped'
);

-- Template registry. Each email kind is added by the owning slice's migration
-- (plus its renderer in `_shared/email/templates.ts`). Rows never change.
create table outbox.templates (
  key text primary key check (key ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
  version int not null check (version > 0),
  duplicate_safe boolean not null,
  params text[] not null
);

insert into outbox.templates (key, version, duplicate_safe, params) values
  ('invitation.issued', 1, true, array['network', 'office', 'role', 'reference', 'expiresAt']);

create function outbox.reject_template_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform identity.fail('invariant_violation', jsonb_build_object('table', 'outbox.templates'));
  return null;
end;
$$;

create trigger templates_immutable
before update or delete or truncate on outbox.templates
for each statement execute function outbox.reject_template_change();

create table outbox.events (
  id uuid primary key default gen_random_uuid(),
  template text not null references outbox.templates (key) on delete restrict,
  template_version int not null,
  tenant_id uuid references org.tenants (id) on delete restrict,
  aggregate_type text not null check (aggregate_type ~ '^[a-z_]{1,40}$'),
  aggregate_id uuid not null,
  recipient_user_id uuid references identity.accounts (user_id) on delete restrict,
  recipient_email text check (recipient_email is null
    or (recipient_email = lower(btrim(recipient_email)) and length(recipient_email) between 3 and 254)),
  params jsonb not null check (jsonb_typeof(params) = 'object'),
  dedupe_key text not null unique check (length(dedupe_key) between 1 and 200),
  occurred_at timestamptz not null default now(),
  available_at timestamptz not null default now(),
  check (num_nonnulls(recipient_user_id, recipient_email) = 1)
);

create index events_aggregate_idx on outbox.events (aggregate_type, aggregate_id);
create index events_tenant_idx on outbox.events (tenant_id);
create index events_recipient_user_idx on outbox.events (recipient_user_id);

create trigger events_immutable
before update or delete on outbox.events
for each row execute function audit.reject_change();
create trigger events_no_truncate
before truncate on outbox.events
for each statement execute function audit.reject_change();

create table outbox.deliveries (
  event_id uuid primary key references outbox.events (id) on delete restrict,
  status outbox.delivery_status not null default 'pending',
  cycle int not null default 1 check (cycle > 0),
  attempt_count int not null default 0 check (attempt_count >= 0),
  max_attempts int not null default 8 check (max_attempts > 0),
  next_attempt_at timestamptz,
  lease_token uuid,
  lease_expires_at timestamptz,
  worker_id text check (worker_id is null or length(worker_id) <= 100),
  provider_message_id text check (provider_message_id is null or length(provider_message_id) <= 300),
  sent_at timestamptz,
  skipped_reason text check (skipped_reason is null or skipped_reason ~ '^[a-z][a-z0-9_.-]{0,63}$'),
  dead_lettered_at timestamptz,
  last_error_code text check (last_error_code is null or last_error_code ~ '^[a-z][a-z0-9_.-]{0,127}$'),
  updated_at timestamptz not null default now(),
  check (attempt_count <= max_attempts),
  -- Shape per status (ported from legacy outbox_delivery_state).
  check (case status
    when 'pending' then next_attempt_at is not null and lease_token is null
    when 'retry_scheduled' then next_attempt_at is not null and lease_token is null
    when 'processing' then lease_token is not null and lease_expires_at is not null and next_attempt_at is null
    when 'sent' then sent_at is not null and lease_token is null and next_attempt_at is null
    when 'skipped' then skipped_reason is not null and lease_token is null and next_attempt_at is null
    when 'dead_lettered' then dead_lettered_at is not null and lease_token is null and next_attempt_at is null
  end)
);

create index deliveries_due_idx on outbox.deliveries (next_attempt_at)
  where status in ('pending', 'retry_scheduled');
create index deliveries_lease_idx on outbox.deliveries (lease_expires_at) where status = 'processing';
create index deliveries_dead_idx on outbox.deliveries (dead_lettered_at desc) where status = 'dead_lettered';

create table outbox.attempts (
  id bigint generated always as identity primary key,
  event_id uuid not null references outbox.events (id) on delete restrict,
  cycle int not null,
  attempt_number int not null check (attempt_number > 0),
  lease_token uuid not null unique,
  outcome outbox.attempt_outcome not null,
  provider_status int check (provider_status is null or provider_status between 100 and 599),
  error_code text check (error_code is null or error_code ~ '^[a-z][a-z0-9_.-]{0,127}$'),
  latency_ms int check (latency_ms is null or latency_ms >= 0),
  started_at timestamptz,
  finished_at timestamptz not null default now()
);

create index attempts_event_idx on outbox.attempts (event_id, cycle, attempt_number);

create trigger attempts_append_only
before update or delete on outbox.attempts
for each row execute function audit.reject_change();
create trigger attempts_no_truncate
before truncate on outbox.attempts
for each statement execute function audit.reject_change();

create table outbox.requeues (
  id bigint generated always as identity primary key,
  event_id uuid not null references outbox.events (id) on delete restrict,
  from_cycle int not null,
  to_cycle int not null check (to_cycle = from_cycle + 1),
  reason text not null check (length(btrim(reason)) between 3 and 500),
  actor_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  at timestamptz not null default now()
);

create index requeues_event_idx on outbox.requeues (event_id);
create index requeues_actor_idx on outbox.requeues (actor_user_id);

create trigger requeues_append_only
before update or delete on outbox.requeues
for each row execute function audit.reject_change();

alter table outbox.templates enable row level security;
alter table outbox.events enable row level security;
alter table outbox.deliveries enable row level security;
alter table outbox.attempts enable row level security;
alter table outbox.requeues enable row level security;

-- Every event gets its delivery row in the same transaction.
create function outbox.create_delivery()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  insert into outbox.deliveries (event_id, next_attempt_at) values (new.id, new.available_at);
  return null;
end;
$$;

create trigger events_create_delivery
after insert on outbox.events
for each row execute function outbox.create_delivery();

-- Retry delay after the given attempt: 15 s doubling, capped at 1 hour.
create function outbox.retry_delay(p_attempt int)
returns interval
language sql
immutable
set search_path = ''
as $$
  select make_interval(secs => least(3600, 15 * power(2, greatest(p_attempt, 1) - 1))::int);
$$;

-- Enqueues an email inside the caller's business transaction (Tracks 04/05
-- and later slices call this). Prefer p_recipient_user_id: the current Auth
-- email is resolved at send time. Use p_recipient_email only for people who
-- may have no account yet. Params must be safe display values (strings or
-- numbers) named by the template. Idempotent per dedupe key: a repeat returns
-- the existing event id.
create function outbox.enqueue_email(
  p_template text,
  p_dedupe_key text,
  p_aggregate_type text,
  p_aggregate_id uuid,
  p_tenant_id uuid,
  p_recipient_user_id uuid,
  p_recipient_email text,
  p_params jsonb
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  template outbox.templates;
  param record;
  event_id uuid;
begin
  select * into template from outbox.templates where key = p_template;
  if template.key is null then
    perform identity.fail('invariant_violation', jsonb_build_object('reason', 'unknown_template'));
  end if;
  if p_params is null or jsonb_typeof(p_params) <> 'object' then
    perform identity.fail('invariant_violation', jsonb_build_object('reason', 'invalid_params'));
  end if;
  for param in select key, value from jsonb_each(p_params) loop
    if not param.key = any (template.params) or jsonb_typeof(param.value) not in ('string', 'number') then
      perform identity.fail('invariant_violation', jsonb_build_object('reason', 'invalid_params', 'param', param.key));
    end if;
  end loop;

  insert into outbox.events (
    template, template_version, tenant_id, aggregate_type, aggregate_id,
    recipient_user_id, recipient_email, params, dedupe_key
  ) values (
    template.key, template.version, p_tenant_id, p_aggregate_type, p_aggregate_id,
    p_recipient_user_id, lower(btrim(p_recipient_email)), p_params, p_dedupe_key
  )
  on conflict (dedupe_key) do nothing
  returning id into event_id;

  if event_id is null then
    select id into event_id from outbox.events where dedupe_key = p_dedupe_key;
  end if;
  return event_id;
end;
$$;

-- Is an event still worth sending? Invitation emails only while the
-- invitation is live and the event belongs to its current link.
create function outbox.is_relevant(p_event outbox.events)
returns boolean
language sql
stable
set search_path = ''
as $$
  select case p_event.template
    when 'invitation.issued' then exists (
      select 1 from org.invitations i
      join org.tenants t on t.id = i.tenant_id
      join org.offices o on o.id = i.office_id
      where i.id = p_event.aggregate_id and i.status = 'pending' and i.expires_at > now()
        and p_event.dedupe_key = 'invitation.issued:' || i.id::text || ':' || i.issue_count::text
        and t.status = 'active' and o.status = 'active'
    )
    else true
  end;
$$;
