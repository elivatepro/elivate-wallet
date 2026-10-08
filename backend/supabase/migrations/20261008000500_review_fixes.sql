-- Review fixes for slice 01 (PR #1):
-- 1. Admin commands take the platform-admin lock before checking the actor is
--    still an admin, so a concurrent revoke can't leave a stale authority check.
-- 2. Signup retries UID collisions up to 50 times (5 failed ~17% of the time
--    near the 70% threshold; 50 fails ~2e-8).

create or replace function api.set_account_status(
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
  perform pg_advisory_xact_lock(hashtextextended('identity.platform_admins', 0));
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

create or replace function api.grant_platform_admin(
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
  perform pg_advisory_xact_lock(hashtextextended('identity.platform_admins', 0));
  perform identity.require_platform_admin(p_user_id);
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('targetUid', upper(btrim(p_target_uid)), 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'grant_platform_admin', request);
  if replayed is not null then
    return replayed;
  end if;

  target_user_id := identity.account_by_uid(p_target_uid);

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

create or replace function api.revoke_platform_admin(
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
  perform pg_advisory_xact_lock(hashtextextended('identity.platform_admins', 0));
  perform identity.require_platform_admin(p_user_id);
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('targetUid', upper(btrim(p_target_uid)), 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'revoke_platform_admin', request);
  if replayed is not null then
    return replayed;
  end if;

  target_user_id := identity.account_by_uid(p_target_uid);

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

create or replace function identity.on_auth_user_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  attempts int := 0;
begin
  loop
    begin
      insert into identity.accounts (user_id, uid) values (new.id, identity.new_uid());
      exit;
    exception when unique_violation then
      attempts := attempts + 1;
      if attempts >= 50 then
        raise;
      end if;
    end;
  end loop;

  insert into identity.profiles (user_id) values (new.id);
  return null;
end;
$$;
