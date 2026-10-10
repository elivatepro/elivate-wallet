-- Blueprint 18 — B1/B2: kill switches (W-23). Eight independent switches stop
-- relevant NEW operations, platform-wide or on one network. A stopped switch
-- never erases or blocks existing state: cancellations, rejections, payouts
-- of withdrawals approved before the stop, reviews of submitted entries and
-- replays of already-committed commands (unknown-outcome recovery) keep
-- working. Postgres enforces the stop with row triggers on the tables a new
-- operation writes, so every command path is covered. Feature flags stay
-- deferred (owner answer Q5).

create schema platform;
revoke all on schema platform from public, anon, authenticated;

create function platform.switch_keys() returns text[]
language sql immutable set search_path = '' as $$
  select array['withdrawals', 'payouts', 'transfers', 'conversion', 'income', 'adjustments', 'reversals',
               'returned_funds']
$$;

create table platform.kill_switches (
  id bigint generated always as identity primary key,
  key text not null check (key = any (platform.switch_keys())),
  -- Null: platform-wide. Otherwise one network.
  tenant_id uuid references org.tenants (id) on delete restrict,
  stopped boolean not null default false,
  reason text check (reason is null or length(btrim(reason)) between 3 and 500),
  changed_by uuid references identity.accounts (user_id) on delete restrict,
  changed_at timestamptz,
  check ((changed_by is null) = (changed_at is null)),
  check ((changed_at is null) = (reason is null))
);

create unique index kill_switches_platform_idx on platform.kill_switches (key) where tenant_id is null;
create unique index kill_switches_tenant_idx on platform.kill_switches (key, tenant_id) where tenant_id is not null;
create index kill_switches_changed_by_idx on platform.kill_switches (changed_by);
-- The per-operation check reads only stopped rows.
create index kill_switches_stopped_idx on platform.kill_switches (key, tenant_id) where stopped;

insert into platform.kill_switches (key) select unnest(platform.switch_keys());

create table platform.kill_switch_changes (
  id bigint generated always as identity primary key,
  key text not null check (key = any (platform.switch_keys())),
  tenant_id uuid references org.tenants (id) on delete restrict,
  stopped boolean not null,
  reason text not null check (length(btrim(reason)) between 3 and 500),
  actor_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  request_id text,
  at timestamptz not null default now()
);

create index kill_switch_changes_key_idx on platform.kill_switch_changes (key, at desc);
create index kill_switch_changes_tenant_idx on platform.kill_switch_changes (tenant_id);
create index kill_switch_changes_actor_idx on platform.kill_switch_changes (actor_user_id);

create trigger kill_switch_changes_append_only
before update or delete on platform.kill_switch_changes
for each row execute function audit.reject_change();
create trigger kill_switch_changes_no_truncate
before truncate on platform.kill_switch_changes
for each statement execute function audit.reject_change();

alter table platform.kill_switches enable row level security;
alter table platform.kill_switch_changes enable row level security;

-- ── The check ─────────────────────────────────────────────────────────────

-- True when the switch is stopped platform-wide or on this network.
create function platform.is_stopped(p_key text, p_tenant_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from platform.kill_switches
    where key = p_key and stopped and (tenant_id is null or tenant_id = p_tenant_id)
  );
$$;

create function platform.require_running(p_key text, p_tenant_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if platform.is_stopped(p_key, p_tenant_id) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'operation_paused', 'operation', p_key));
  end if;
end;
$$;

-- The stopped switches that apply to one network (no reasons, no actors).
create function platform.stopped_for(p_tenant_id uuid)
returns text[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(distinct key order by key), '{}'::text[])
  from platform.kill_switches
  where stopped and (tenant_id is null or tenant_id = p_tenant_id);
$$;

-- ── Guards on the tables new operations write ─────────────────────────────

-- New withdrawal requests and approvals (requested → approved).
create function platform.guard_withdrawal()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or (old.status = 'requested' and new.status = 'approved') then
    perform platform.require_running('withdrawals', new.tenant_id);
  end if;
  return new;
end;
$$;

create trigger withdrawals_kill_switch
before insert or update of status on finance.withdrawals
for each row execute function platform.guard_withdrawal();

-- New payout records and their one correction.
create function platform.guard_payout()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform platform.require_running('payouts', (select tenant_id from finance.withdrawals where id = new.withdrawal_id));
  return new;
end;
$$;

create trigger payouts_kill_switch
before insert on finance.payouts
for each row execute function platform.guard_payout();

create function platform.guard_payout_revision()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform platform.require_running('payouts', (
    select w.tenant_id from finance.payouts p join finance.withdrawals w on w.id = p.withdrawal_id
    where p.id = new.payout_id
  ));
  return new;
end;
$$;

create trigger payout_revisions_kill_switch
before insert on finance.payout_revisions
for each row execute function platform.guard_payout_revision();

-- New pocket-move requests and approvals (requested → completed).
create function platform.guard_pocket_transfer()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or (old.status = 'requested' and new.status = 'completed') then
    perform platform.require_running('transfers', new.tenant_id);
  end if;
  return new;
end;
$$;

create trigger pocket_transfers_kill_switch
before insert or update of status on finance.pocket_transfers
for each row execute function platform.guard_pocket_transfer();

-- New conversions, adjustments and returned funds. Reviews of entries
-- already submitted (needs_review → posted/rejected) are not new operations.
create function platform.guard_entry()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform platform.require_running(case new.kind
    when 'conversion' then 'conversion'
    when 'adjustment' then 'adjustments'
    else 'returned_funds' end, new.tenant_id);
  return new;
end;
$$;

create trigger entries_kill_switch
before insert on finance.entries
for each row execute function platform.guard_entry();

create function platform.guard_income()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform platform.require_running('income', new.tenant_id);
  return new;
end;
$$;

create trigger income_records_kill_switch
before insert on finance.income_records
for each row execute function platform.guard_income();

create function platform.guard_reversal()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform platform.require_running('reversals', new.tenant_id);
  return new;
end;
$$;

create trigger reversals_kill_switch
before insert on finance.reversals
for each row execute function platform.guard_reversal();

-- ── Reads and the command ─────────────────────────────────────────────────

create function platform.switch_json(p_s platform.kill_switches)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'key', p_s.key,
    'tenantId', p_s.tenant_id,
    'stopped', p_s.stopped,
    'reason', p_s.reason,
    'changedBy', case when p_s.changed_by is not null then org.person(p_s.changed_by) end,
    'changedAt', p_s.changed_at
  );
$$;

-- Platform switches, every per-network row that is stopped, or one network's rows.
create function api.admin_switches(p_user_id uuid, p_session_id uuid, p_tenant_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  if p_tenant_id is not null and not exists (select 1 from org.tenants where id = p_tenant_id) then
    perform identity.fail('not_found');
  end if;
  return jsonb_build_object(
    'platform', coalesce((
      select jsonb_agg(platform.switch_json(s) order by array_position(platform.switch_keys(), s.key))
      from platform.kill_switches s where s.tenant_id is null
    ), '[]'::jsonb),
    'networks', coalesce((
      select jsonb_agg(platform.switch_json(s) || jsonb_build_object('network', notify.network(s.tenant_id))
        order by s.changed_at desc, s.id)
      from platform.kill_switches s
      where s.tenant_id is not null and (s.stopped or s.tenant_id = p_tenant_id)
        and (p_tenant_id is null or s.tenant_id = p_tenant_id)
    ), '[]'::jsonb)
  );
end;
$$;

create function api.admin_set_switch(
  p_user_id uuid,
  p_session_id uuid,
  p_key text,
  p_tenant_id uuid,
  p_stopped boolean,
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
  s platform.kill_switches;
  changed boolean := false;
begin
  perform identity.require_session(p_user_id, p_session_id, p_step_up => true);
  perform identity.require_platform_admin(p_user_id);
  clean_reason := identity.require_reason(p_reason);
  if p_key is null or not (p_key = any (platform.switch_keys())) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'key'));
  end if;
  if p_stopped is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'stopped'));
  end if;

  request := jsonb_build_object('key', p_key, 'tenantId', p_tenant_id, 'stopped', p_stopped, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'admin_set_switch', request);
  if replayed is not null then
    return replayed;
  end if;

  if p_tenant_id is not null then
    if not exists (select 1 from org.tenants where id = p_tenant_id) then
      perform identity.fail('not_found');
    end if;
    insert into platform.kill_switches (key, tenant_id) values (p_key, p_tenant_id)
    on conflict (key, tenant_id) where tenant_id is not null do nothing;
  end if;

  select * into s from platform.kill_switches
  where key = p_key and tenant_id is not distinct from p_tenant_id
  for update;

  if s.stopped <> p_stopped then
    update platform.kill_switches
    set stopped = p_stopped, reason = clean_reason, changed_by = p_user_id, changed_at = now()
    where id = s.id
    returning * into s;
    insert into platform.kill_switch_changes (key, tenant_id, stopped, reason, actor_user_id, request_id)
    values (p_key, p_tenant_id, p_stopped, clean_reason, p_user_id, p_request_id);
    perform audit.record(case when p_stopped then 'kill_switch.stopped' else 'kill_switch.started' end,
      p_user_id, p_session_id, null, clean_reason,
      jsonb_build_object('key', p_key, 'tenantId', p_tenant_id, 'stopped', not p_stopped),
      jsonb_build_object('key', p_key, 'tenantId', p_tenant_id, 'stopped', p_stopped), p_request_id);
    -- A per-network stop is visible to that network's President (owner answer Q4).
    if p_tenant_id is not null then
      perform audit.record_tenant(p_tenant_id, p_user_id,
        case when p_stopped then 'operations.paused_by_elivate' else 'operations.resumed_by_elivate' end,
        'tenant', p_tenant_id::text, clean_reason, jsonb_build_object('operation', p_key, 'stopped', not p_stopped),
        jsonb_build_object('operation', p_key, 'stopped', p_stopped), p_request_id);
    end if;
    changed := true;
  end if;

  return identity.store_result(p_user_id, p_idempotency_key, 'admin_set_switch', request,
    jsonb_build_object('switch', platform.switch_json(s), 'changed', changed));
end;
$$;

-- Member app: which operations are stopped for the selected workspace's
-- network (buttons are disabled ahead of time; the database still refuses).
create function api.stopped_operations(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  ws org.memberships;
begin
  perform identity.require_session(p_user_id, p_session_id);
  select * into ws from org.memberships
  where id = p_membership_id and user_id = p_user_id and status in ('active', 'suspended', 'ended');
  if ws.id is null then
    perform identity.fail('workspace_invalid');
  end if;
  return jsonb_build_object('stopped', to_jsonb(platform.stopped_for(ws.tenant_id)));
end;
$$;

revoke all on all functions in schema platform from public, anon, authenticated;
revoke all on function api.admin_switches(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function api.admin_set_switch(uuid, uuid, text, uuid, boolean, text, text, text) from public, anon, authenticated;
revoke all on function api.stopped_operations(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function api.admin_switches(uuid, uuid, uuid) to service_role;
grant execute on function api.admin_set_switch(uuid, uuid, text, uuid, boolean, text, text, text) to service_role;
grant execute on function api.stopped_operations(uuid, uuid, uuid) to service_role;
