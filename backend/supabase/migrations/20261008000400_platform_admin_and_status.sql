-- Blueprint 01 — platform admins (all have full access, U-09) and account status
-- administration (W-22). Reasons are mandatory; changes are audited.

create table identity.platform_admins (
  id bigint generated always as identity primary key,
  user_id uuid not null references identity.accounts (user_id) on delete restrict,
  granted_by uuid references identity.accounts (user_id) on delete restrict,
  granted_at timestamptz not null default now(),
  grant_reason text not null check (length(btrim(grant_reason)) between 3 and 500),
  revoked_by uuid references identity.accounts (user_id) on delete restrict,
  revoked_at timestamptz,
  revoke_reason text check (revoke_reason is null or length(btrim(revoke_reason)) between 3 and 500),
  check ((revoked_at is null) = (revoked_by is null) and (revoked_at is null) = (revoke_reason is null))
);

create unique index platform_admins_active_idx on identity.platform_admins (user_id)
where revoked_at is null;
create index platform_admins_granted_by_idx on identity.platform_admins (granted_by);
create index platform_admins_revoked_by_idx on identity.platform_admins (revoked_by);

create table identity.account_status_changes (
  id bigint generated always as identity primary key,
  user_id uuid not null references identity.accounts (user_id) on delete restrict,
  from_status identity.account_status not null,
  to_status identity.account_status not null,
  reason text not null check (length(btrim(reason)) between 3 and 500),
  actor_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  at timestamptz not null default now()
);

create index account_status_changes_user_idx on identity.account_status_changes (user_id, at desc);
create index account_status_changes_actor_idx on identity.account_status_changes (actor_user_id);

create trigger account_status_changes_append_only
before update or delete on identity.account_status_changes
for each row execute function audit.reject_change();

-- Stored results for idempotent commands (F-03).
create table identity.command_results (
  actor_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  idempotency_key text not null check (idempotency_key ~ '^[A-Za-z0-9_-]{16,100}$'),
  command text not null,
  request jsonb not null,
  result jsonb not null,
  created_at timestamptz not null default now(),
  primary key (actor_user_id, idempotency_key)
);

alter table identity.platform_admins enable row level security;
alter table identity.account_status_changes enable row level security;
alter table identity.command_results enable row level security;

-- Returns the stored result for a replay, null for a first attempt. Call only
-- after the actor's current authority has been checked (A-01).
create function identity.replay(
  p_actor_user_id uuid,
  p_idempotency_key text,
  p_command text,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  stored identity.command_results;
begin
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{16,100}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'idempotencyKey'));
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_actor_user_id::text || ':' || p_idempotency_key, 0));
  select * into stored from identity.command_results
  where actor_user_id = p_actor_user_id and idempotency_key = p_idempotency_key;

  if stored.actor_user_id is null then
    return null;
  end if;
  if stored.command <> p_command or stored.request <> p_request then
    perform identity.fail('idempotency_conflict');
  end if;
  return stored.result || jsonb_build_object('replayed', true);
end;
$$;

create function identity.store_result(
  p_actor_user_id uuid,
  p_idempotency_key text,
  p_command text,
  p_request jsonb,
  p_result jsonb
)
returns jsonb
language sql
set search_path = ''
as $$
  insert into identity.command_results (actor_user_id, idempotency_key, command, request, result)
  values (p_actor_user_id, p_idempotency_key, p_command, p_request, p_result);
  select p_result || jsonb_build_object('replayed', false);
$$;

create function identity.require_platform_admin(p_user_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1 from identity.platform_admins where user_id = p_user_id and revoked_at is null
  ) then
    perform identity.fail('authorization_denied');
  end if;
end;
$$;

create function identity.require_reason(p_reason text)
returns text
language plpgsql
set search_path = ''
as $$
begin
  if p_reason is null or length(btrim(p_reason)) not between 3 and 500 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'reason'));
  end if;
  return btrim(p_reason);
end;
$$;

create function identity.account_by_uid(p_uid text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  found_user_id uuid;
begin
  select user_id into found_user_id from identity.accounts where uid = upper(btrim(p_uid));
  if found_user_id is null then
    perform identity.fail('not_found');
  end if;
  return found_user_id;
end;
$$;

-- ── Commands ──────────────────────────────────────────────────────────────

create function api.set_account_status(
  p_user_id uuid,
  p_session_id uuid,
  p_target_uid text,
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
  request jsonb;
  replayed jsonb;
  clean_reason text;
  target_user_id uuid;
  previous identity.account_status;
  next_status identity.account_status;
begin
  perform identity.require_session(p_user_id, p_session_id, p_step_up => true);
  perform identity.require_platform_admin(p_user_id);

  clean_reason := identity.require_reason(p_reason);
  if p_status is null or p_status not in ('active', 'restricted', 'suspended', 'deactivated') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'status'));
  end if;
  next_status := p_status::identity.account_status;

  request := jsonb_build_object('targetUid', upper(btrim(p_target_uid)), 'status', p_status, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'set_account_status', request);
  if replayed is not null then
    return replayed;
  end if;

  target_user_id := identity.account_by_uid(p_target_uid);
  if target_user_id = p_user_id then
    perform identity.fail('authorization_denied', jsonb_build_object('reason', 'self_target'));
  end if;

  select status into previous from identity.accounts where user_id = target_user_id for update;

  if previous <> next_status then
    update identity.accounts set status = next_status where user_id = target_user_id;
    insert into identity.account_status_changes (user_id, from_status, to_status, reason, actor_user_id)
    values (target_user_id, previous, next_status, clean_reason, p_user_id);
    if next_status in ('suspended', 'deactivated') then
      delete from identity.session_pin_proofs where user_id = target_user_id;
    end if;
    perform audit.record('account.status_changed', p_user_id, p_session_id, target_user_id, clean_reason,
      jsonb_build_object('status', previous), jsonb_build_object('status', next_status), p_request_id);
  end if;

  return identity.store_result(p_user_id, p_idempotency_key, 'set_account_status', request,
    jsonb_build_object('targetUid', upper(btrim(p_target_uid)), 'previousStatus', previous,
      'status', next_status, 'changed', previous <> next_status));
end;
$$;

create function api.grant_platform_admin(
  p_user_id uuid,
  p_session_id uuid,
  p_target_uid text,
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
  request jsonb;
  replayed jsonb;
  clean_reason text;
  target_user_id uuid;
  changed boolean := false;
begin
  perform identity.require_session(p_user_id, p_session_id, p_step_up => true);
  perform identity.require_platform_admin(p_user_id);
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('targetUid', upper(btrim(p_target_uid)), 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'grant_platform_admin', request);
  if replayed is not null then
    return replayed;
  end if;

  target_user_id := identity.account_by_uid(p_target_uid);
  perform pg_advisory_xact_lock(hashtextextended('identity.platform_admins', 0));

  if not exists (
    select 1 from identity.platform_admins where user_id = target_user_id and revoked_at is null
  ) then
    insert into identity.platform_admins (user_id, granted_by, grant_reason)
    values (target_user_id, p_user_id, clean_reason);
    perform audit.record('platform_admin.granted', p_user_id, p_session_id, target_user_id, clean_reason,
      p_request_id => p_request_id);
    changed := true;
  end if;

  return identity.store_result(p_user_id, p_idempotency_key, 'grant_platform_admin', request,
    jsonb_build_object('targetUid', upper(btrim(p_target_uid)), 'changed', changed));
end;
$$;

create function api.revoke_platform_admin(
  p_user_id uuid,
  p_session_id uuid,
  p_target_uid text,
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
  request jsonb;
  replayed jsonb;
  clean_reason text;
  target_user_id uuid;
  changed boolean := false;
begin
  perform identity.require_session(p_user_id, p_session_id, p_step_up => true);
  perform identity.require_platform_admin(p_user_id);
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('targetUid', upper(btrim(p_target_uid)), 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'revoke_platform_admin', request);
  if replayed is not null then
    return replayed;
  end if;

  target_user_id := identity.account_by_uid(p_target_uid);
  perform pg_advisory_xact_lock(hashtextextended('identity.platform_admins', 0));

  if exists (
    select 1 from identity.platform_admins where user_id = target_user_id and revoked_at is null
  ) then
    if (select count(*) from identity.platform_admins where revoked_at is null) <= 1 then
      perform identity.fail('conflict', jsonb_build_object('reason', 'last_platform_admin'));
    end if;
    update identity.platform_admins
    set revoked_at = now(), revoked_by = p_user_id, revoke_reason = clean_reason
    where user_id = target_user_id and revoked_at is null;
    perform audit.record('platform_admin.revoked', p_user_id, p_session_id, target_user_id, clean_reason,
      p_request_id => p_request_id);
    changed := true;
  end if;

  return identity.store_result(p_user_id, p_idempotency_key, 'revoke_platform_admin', request,
    jsonb_build_object('targetUid', upper(btrim(p_target_uid)), 'changed', changed));
end;
$$;

revoke all on function
  api.set_account_status(uuid, uuid, text, text, text, text, text),
  api.grant_platform_admin(uuid, uuid, text, text, text, text),
  api.revoke_platform_admin(uuid, uuid, text, text, text, text)
from public, anon, authenticated;

grant execute on function
  api.set_account_status(uuid, uuid, text, text, text, text, text),
  api.grant_platform_admin(uuid, uuid, text, text, text, text),
  api.revoke_platform_admin(uuid, uuid, text, text, text, text)
to service_role;
