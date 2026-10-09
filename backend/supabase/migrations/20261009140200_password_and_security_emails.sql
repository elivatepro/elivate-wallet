-- Blueprint 14 — B1/B2/B4: changing the password while signed in (PIN only,
-- owner decision 2026-10-09), recording a password reset, the security
-- overview for Profile & security / Devices, and the A06 Password changed and
-- A08 PIN changed emails with their bell items.
--
-- The password itself never reaches the database: the app server changes it
-- through Supabase Auth (updateUser, which also signs out every other session)
-- between the PIN check here and the record call below.

create table identity.password_changes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references identity.accounts (user_id) on delete restrict,
  session_id uuid not null,
  method text not null check (method in ('signed_in', 'recovery')),
  authorized_at timestamptz not null default now(),
  changed_at timestamptz,
  check (changed_at is null or changed_at >= authorized_at)
);

create index password_changes_user_idx on identity.password_changes (user_id, changed_at desc);
-- A reset is recorded once per recovery session.
create unique index password_changes_recovery_once on identity.password_changes (session_id)
  where method = 'recovery';

alter table identity.password_changes enable row level security;

-- Only `changed_at` is ever set, once.
create function identity.guard_password_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' or new.id <> old.id or new.user_id <> old.user_id or new.session_id <> old.session_id
    or new.method <> old.method or new.authorized_at <> old.authorized_at
    or old.changed_at is not null then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'identity.password_changes'));
  end if;
  return new;
end;
$$;

create trigger password_changes_guard
before update or delete on identity.password_changes
for each row execute function identity.guard_password_change();

-- How long a PIN-authorized change may wait for Auth to save the password.
create function identity.password_change_window() returns interval
language sql immutable set search_path = '' as $$ select interval '10 minutes' $$;
-- A reset is recorded from the session the Recovery link opened, while fresh.
create function identity.recovery_session_window() returns interval
language sql immutable set search_path = '' as $$ select interval '1 hour' $$;

-- ── Commands ───────────────────────────────────────────────────────────────

-- Step 1 of a signed-in change: the PIN, with the same attempt counter and
-- lock as api.verify_pin / api.change_pin. Wrong PINs return a result instead
-- of raising, so the attempt count commits.
create function api.authorize_password_change(
  p_user_id uuid,
  p_session_id uuid,
  p_pin_hmac text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  credential identity.pin_credentials;
  change_id uuid;
begin
  perform identity.require_live_session(p_user_id, p_session_id);
  perform identity.check_pin_hmac(p_pin_hmac);

  -- Same lock order as change_pin: the credential first.
  select * into credential from identity.pin_credentials
  where user_id = p_user_id
  for update;
  if credential.user_id is null then
    perform identity.fail('pin_setup_required');
  end if;
  if credential.locked_at is not null then
    perform identity.fail('pin_locked');
  end if;
  perform identity.require_session(p_user_id, p_session_id);

  if extensions.crypt(p_pin_hmac, credential.pin_hash) <> credential.pin_hash then
    return identity.record_wrong_pin(p_user_id, p_session_id, credential.failed_attempts, p_request_id);
  end if;

  update identity.pin_credentials set failed_attempts = 0 where user_id = p_user_id;
  perform identity.open_pin_proof(p_user_id, p_session_id);

  insert into identity.password_changes (user_id, session_id, method)
  values (p_user_id, p_session_id, 'signed_in')
  returning id into change_id;

  perform audit.record('password.change_authorized', p_user_id, p_session_id, p_user_id,
    p_request_id => p_request_id);
  return jsonb_build_object('ok', true, 'changeId', change_id);
end;
$$;

-- Step 2: Auth saved the new password. Exactly one of a PIN-authorized change
-- from this session, or a reset from a fresh email-link (Recovery) session.
create function api.record_password_change(
  p_user_id uuid,
  p_session_id uuid,
  p_change_id uuid,
  p_recovery boolean,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  change identity.password_changes;
  changed timestamptz := now();
begin
  perform identity.require_live_session(p_user_id, p_session_id);
  if (p_change_id is null) = (p_recovery is not true) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'changeId'));
  end if;

  if p_change_id is not null then
    select * into change from identity.password_changes
    where id = p_change_id and user_id = p_user_id and session_id = p_session_id
    for update;
    if change.id is not null and change.changed_at is not null then
      perform identity.fail('conflict', jsonb_build_object('reason', 'password_change_already_recorded'));
    end if;
    if change.id is null or change.authorized_at <= now() - identity.password_change_window() then
      perform identity.fail('conflict', jsonb_build_object('reason', 'password_change_not_authorized'));
    end if;
    update identity.password_changes set changed_at = changed where id = change.id;
  else
    if exists (select 1 from identity.password_changes
               where session_id = p_session_id and method = 'recovery') then
      perform identity.fail('conflict', jsonb_build_object('reason', 'password_change_already_recorded'));
    end if;
    -- The Recovery link signs in with an email OTP; only a fresh one counts.
    if not exists (
      select 1 from auth.sessions s
      join auth.mfa_amr_claims m on m.session_id = s.id
      where s.id = p_session_id and s.user_id = p_user_id
        and s.created_at > now() - identity.recovery_session_window()
        and m.authentication_method in ('otp', 'magiclink', 'recovery')
    ) then
      perform identity.fail('conflict', jsonb_build_object('reason', 'password_change_not_authorized'));
    end if;
    -- Two overlapping calls: the unique index decides, and the loser gets the
    -- same conflict as a later replay (never an internal error).
    insert into identity.password_changes (user_id, session_id, method, authorized_at, changed_at)
    values (p_user_id, p_session_id, 'recovery', changed, changed)
    on conflict (session_id) where method = 'recovery' do nothing;
    if not found then
      perform identity.fail('conflict', jsonb_build_object('reason', 'password_change_already_recorded'));
    end if;
  end if;

  perform audit.record('password.changed', p_user_id, p_session_id, p_user_id,
    p_safe_after => jsonb_build_object('method', case when p_change_id is null then 'recovery' else 'signed_in' end),
    p_request_id => p_request_id);
  return jsonb_build_object('changedAt', changed);
end;
$$;

-- Profile & security and Devices: when the password last changed and the
-- newest unusual sign-ins (Paper B09, Z07, S03/S04). Never the IP.
create function api.security_overview(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  return jsonb_build_object(
    'passwordChangedAt', (select max(changed_at) from identity.password_changes where user_id = p_user_id),
    'unusualSignIns', coalesce((
      select jsonb_agg(item order by at desc)
      from (
        select si.created_at as at, jsonb_build_object(
          'signInId', si.id,
          'signedInAt', si.created_at,
          'device', si.device,
          'city', si.city,
          'country', si.country,
          'reasons', to_jsonb(si.reasons),
          'current', si.session_id = p_session_id,
          'signedIn', exists (
            select 1 from auth.sessions s
            where s.id = si.session_id and s.user_id = p_user_id
              and (s.not_after is null or s.not_after > now()))
        ) as item
        from identity.sign_ins si
        where si.user_id = p_user_id and si.unusual
        order by si.created_at desc
        limit 10
      ) newest
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function
  api.authorize_password_change(uuid, uuid, text, text),
  api.record_password_change(uuid, uuid, uuid, boolean, text),
  api.security_overview(uuid, uuid)
from public, anon, authenticated;
grant execute on function
  api.authorize_password_change(uuid, uuid, text, text),
  api.record_password_change(uuid, uuid, uuid, boolean, text),
  api.security_overview(uuid, uuid)
to service_role;

-- ── A06 Password changed and A08 PIN changed ───────────────────────────────

insert into outbox.templates (key, version, duplicate_safe, params) values
  ('security.password_changed', 1, true, array['at', 'path']),
  ('security.pin_changed', 1, true, array['at', 'path']);

insert into notify.kinds (key, task, email_template) values
  ('security.password_changed', false, 'security.password_changed'),
  ('security.pin_changed', false, 'security.pin_changed');

-- The email goes out in the same transaction as the change (F-02, T-03):
-- api.change_pin and api.record_password_change both write this audit row.
create function notify.on_security_alert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  kind text := case new.action when 'pin.changed' then 'security.pin_changed' else 'security.password_changed' end;
  params jsonb := jsonb_build_object(
    'at', to_char(new.at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'path', '/app/account');
begin
  perform notify.emit(new.actor_user_id, null, kind, 'account', new.actor_user_id, params,
    'security:' || new.id::text, params);
  return null;
end;
$$;

create trigger security_events_alert
after insert on audit.security_events
for each row when (new.action in ('pin.changed', 'password.changed') and new.actor_user_id is not null)
execute function notify.on_security_alert();

revoke all on function notify.on_security_alert() from public, anon, authenticated;
