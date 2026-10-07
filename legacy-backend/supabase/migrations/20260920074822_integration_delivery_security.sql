create or replace function internal.prevent_integration_history_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception using
    errcode = '55000',
    message = format('%I.%I is append-only', tg_table_schema, tg_table_name);
end;
$$;

create trigger integration_delivery_attempts_prevent_mutation
  before update or delete on internal.integration_delivery_attempts
  for each row execute function internal.prevent_integration_history_mutation();

create trigger outbox_delivery_requeues_prevent_mutation
  before update or delete on internal.outbox_delivery_requeues
  for each row execute function internal.prevent_integration_history_mutation();

alter table internal.outbox_delivery_state enable row level security;
alter table internal.integration_delivery_attempts enable row level security;
alter table internal.outbox_delivery_requeues enable row level security;

alter table internal.outbox_delivery_state force row level security;
alter table internal.integration_delivery_attempts force row level security;
alter table internal.outbox_delivery_requeues force row level security;

create policy outbox_delivery_state_private_deny
  on internal.outbox_delivery_state
  as restrictive
  for all
  to public
  using (false)
  with check (false);

create policy integration_delivery_attempts_private_deny
  on internal.integration_delivery_attempts
  as restrictive
  for all
  to public
  using (false)
  with check (false);

create policy outbox_delivery_requeues_private_deny
  on internal.outbox_delivery_requeues
  as restrictive
  for all
  to public
  using (false)
  with check (false);

revoke all on internal.outbox_delivery_state
  from public, anon, authenticated, service_role;
revoke all on internal.integration_delivery_attempts
  from public, anon, authenticated, service_role;
revoke all on internal.outbox_delivery_requeues
  from public, anon, authenticated, service_role;
revoke all on function internal.initialize_outbox_delivery_state()
  from public, anon, authenticated, service_role;
revoke all on function internal.prevent_integration_history_mutation()
  from public, anon, authenticated, service_role;

comment on table internal.outbox_delivery_state is
  'Mutable worker lease and retry state kept separate from immutable outbox events.';
comment on table internal.integration_delivery_attempts is
  'Append-only, redacted delivery outcomes; provider response bodies and secrets are forbidden.';
comment on table internal.outbox_delivery_requeues is
  'Append-only operator requeue history for dead-lettered outbox deliveries.';
