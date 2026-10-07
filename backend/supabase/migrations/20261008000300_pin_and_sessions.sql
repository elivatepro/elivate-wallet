-- Blueprint 01 — B3/B4: PIN credential, per-session PIN proof, session gate,
-- PIN reset and device sessions. The raw PIN never reaches the database: the
-- security Edge Function sends HMAC-SHA256(PIN_HMAC_SECRET, pin) as hex.

create table identity.pin_credentials (
  user_id uuid primary key references identity.accounts (user_id) on delete restrict,
  pin_hash text not null,
  key_version smallint not null default 1 check (key_version > 0),
  failed_attempts smallint not null default 0 check (failed_attempts between 0 and 5),
  locked_at timestamptz,
  set_at timestamptz not null default now(),
  check ((failed_attempts = 5) = (locked_at is not null))
);

create table identity.session_pin_proofs (
  session_id uuid primary key references auth.sessions (id) on delete cascade,
  user_id uuid not null references identity.accounts (user_id) on delete restrict,
  verified_at timestamptz not null,
  last_activity_at timestamptz not null
);

create index session_pin_proofs_user_idx on identity.session_pin_proofs (user_id);

create table identity.pin_reset_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references identity.accounts (user_id) on delete restrict,
  requested_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  check (expires_at > requested_at)
);

create index pin_reset_requests_user_idx on identity.pin_reset_requests (user_id, requested_at desc);

alter table identity.pin_credentials enable row level security;
alter table identity.session_pin_proofs enable row level security;
alter table identity.pin_reset_requests enable row level security;

-- Policy constants (A-05, owner decisions 2026-10-07/08).
create function identity.pin_max_attempts() returns smallint
language sql immutable set search_path = '' as $$ select 5::smallint $$;
create function identity.pin_idle_timeout() returns interval
language sql immutable set search_path = '' as $$ select interval '15 minutes' $$;
create function identity.step_up_window() returns interval
language sql immutable set search_path = '' as $$ select interval '5 minutes' $$;
create function identity.pin_reset_ttl() returns interval
language sql immutable set search_path = '' as $$ select interval '15 minutes' $$;
create function identity.pin_reset_cooldown() returns interval
language sql immutable set search_path = '' as $$ select interval '60 seconds' $$;

create function identity.check_pin_hmac(p_pin_hmac text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_pin_hmac is null or p_pin_hmac !~ '^[0-9a-f]{64}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'pin'));
  end if;
end;
$$;

-- Auth session is live, owned by the user, and the account may sign in.
create function identity.require_live_session(p_user_id uuid, p_session_id uuid)
returns identity.account_status
language plpgsql
set search_path = ''
as $$
declare
  account_status identity.account_status;
begin
  if p_user_id is null or p_session_id is null or not exists (
    select 1 from auth.sessions s
    where s.id = p_session_id
      and s.user_id = p_user_id
      and (s.not_after is null or s.not_after > now())
  ) then
    perform identity.fail('authentication_required');
  end if;

  select a.status into account_status from identity.accounts a where a.user_id = p_user_id;
  if account_status is null then
    perform identity.fail('authentication_required');
  end if;
  if account_status in ('suspended', 'deactivated') then
    perform identity.fail('account_blocked');
  end if;
  return account_status;
end;
$$;

-- B3 gate: pin_setup_required | pin_locked | pin_required | ready.
create function identity.pin_gate(p_user_id uuid, p_session_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when c.user_id is null then 'pin_setup_required'
    when c.locked_at is not null then 'pin_locked'
    when p.session_id is null
      or p.last_activity_at < now() - identity.pin_idle_timeout() then 'pin_required'
    else 'ready'
  end
  from (select p_user_id as user_id) u
  left join identity.pin_credentials c on c.user_id = u.user_id
  left join identity.session_pin_proofs p
    on p.session_id = p_session_id and p.user_id = u.user_id;
$$;

-- Every protected command/read calls this first. Records activity on success.
create function identity.require_session(
  p_user_id uuid,
  p_session_id uuid,
  p_step_up boolean default false
)
returns identity.account_status
language plpgsql
set search_path = ''
as $$
declare
  account_status identity.account_status;
  gate text;
  proof_verified_at timestamptz;
begin
  account_status := identity.require_live_session(p_user_id, p_session_id);
  gate := identity.pin_gate(p_user_id, p_session_id);
  if gate <> 'ready' then
    perform identity.fail(gate);
  end if;

  update identity.session_pin_proofs
  set last_activity_at = now()
  where session_id = p_session_id
  returning verified_at into proof_verified_at;

  if p_step_up and proof_verified_at <= now() - identity.step_up_window() then
    perform identity.fail('step_up_required');
  end if;
  return account_status;
end;
$$;

create function identity.open_pin_proof(p_user_id uuid, p_session_id uuid)
returns void
language sql
set search_path = ''
as $$
  insert into identity.session_pin_proofs (session_id, user_id, verified_at, last_activity_at)
  values (p_session_id, p_user_id, now(), now())
  on conflict (session_id) do update
  set verified_at = excluded.verified_at, last_activity_at = excluded.last_activity_at;
$$;

create function identity.security_state(p_user_id uuid, p_session_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'gate', identity.pin_gate(p_user_id, p_session_id),
    'uid', a.uid,
    'accountStatus', a.status,
    'attemptsRemaining', identity.pin_max_attempts() - coalesce(c.failed_attempts, 0),
    'stepUpExpiresAt', case
      when p.verified_at > now() - identity.step_up_window()
        then p.verified_at + identity.step_up_window()
    end
  )
  from identity.accounts a
  left join identity.pin_credentials c on c.user_id = a.user_id
  left join identity.session_pin_proofs p
    on p.session_id = p_session_id and p.user_id = a.user_id
  where a.user_id = p_user_id;
$$;

-- ── Commands ──────────────────────────────────────────────────────────────

create function api.security_state(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_live_session(p_user_id, p_session_id);
  return identity.security_state(p_user_id, p_session_id);
end;
$$;

create function api.set_pin(
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
begin
  perform identity.require_live_session(p_user_id, p_session_id);
  perform identity.check_pin_hmac(p_pin_hmac);

  insert into identity.pin_credentials (user_id, pin_hash)
  values (p_user_id, extensions.crypt(p_pin_hmac, extensions.gen_salt('bf', 10)))
  on conflict (user_id) do nothing;
  if not found then
    perform identity.fail('conflict', jsonb_build_object('reason', 'pin_already_set'));
  end if;

  perform identity.open_pin_proof(p_user_id, p_session_id);
  perform audit.record('pin.set', p_user_id, p_session_id, p_user_id, p_request_id => p_request_id);
  return identity.security_state(p_user_id, p_session_id);
end;
$$;

-- Wrong PINs return a result instead of raising, so the attempt count commits.
create function api.verify_pin(
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
  attempts smallint;
begin
  perform identity.require_live_session(p_user_id, p_session_id);
  perform identity.check_pin_hmac(p_pin_hmac);

  select * into credential from identity.pin_credentials
  where user_id = p_user_id
  for update;

  if credential.user_id is null then
    perform identity.fail('pin_setup_required');
  end if;
  if credential.locked_at is not null then
    perform identity.fail('pin_locked');
  end if;

  if extensions.crypt(p_pin_hmac, credential.pin_hash) = credential.pin_hash then
    update identity.pin_credentials set failed_attempts = 0 where user_id = p_user_id;
    perform identity.open_pin_proof(p_user_id, p_session_id);
    perform audit.record('pin.verified', p_user_id, p_session_id, p_user_id, p_request_id => p_request_id);
    return jsonb_build_object('ok', true, 'state', identity.security_state(p_user_id, p_session_id));
  end if;

  attempts := credential.failed_attempts + 1;
  update identity.pin_credentials
  set failed_attempts = attempts,
      locked_at = case when attempts >= identity.pin_max_attempts() then now() end
  where user_id = p_user_id;

  if attempts >= identity.pin_max_attempts() then
    delete from identity.session_pin_proofs where user_id = p_user_id;
    perform audit.record('pin.locked', p_user_id, p_session_id, p_user_id, p_request_id => p_request_id);
    return jsonb_build_object('ok', false, 'code', 'pin_locked', 'attemptsRemaining', 0);
  end if;

  perform audit.record('pin.rejected', p_user_id, p_session_id, p_user_id, p_request_id => p_request_id);
  return jsonb_build_object(
    'ok', false,
    'code', 'pin_incorrect',
    'attemptsRemaining', identity.pin_max_attempts() - attempts
  );
end;
$$;

-- Records a pending reset. The Edge Function then asks Auth to email a
-- single-use sign-in link; that link's session completes the reset.
create function api.request_pin_reset(
  p_user_id uuid,
  p_session_id uuid,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  reset_expires_at timestamptz;
begin
  perform identity.require_live_session(p_user_id, p_session_id);
  if not exists (select 1 from identity.pin_credentials where user_id = p_user_id) then
    perform identity.fail('pin_setup_required');
  end if;

  perform pg_advisory_xact_lock(hashtextextended('identity.pin_reset:' || p_user_id::text, 0));
  if exists (
    select 1 from identity.pin_reset_requests
    where user_id = p_user_id and requested_at > now() - identity.pin_reset_cooldown()
  ) then
    perform identity.fail('rate_limited', jsonb_build_object('retryAfterSeconds', 60));
  end if;

  -- Only the newest request may complete.
  update identity.pin_reset_requests
  set expires_at = greatest(requested_at + interval '1 microsecond', now())
  where user_id = p_user_id and consumed_at is null and expires_at > now();

  insert into identity.pin_reset_requests (user_id, expires_at)
  values (p_user_id, now() + identity.pin_reset_ttl())
  returning expires_at into reset_expires_at;

  perform audit.record('pin.reset_requested', p_user_id, p_session_id, p_user_id, p_request_id => p_request_id);
  return jsonb_build_object('expiresAt', reset_expires_at);
end;
$$;

create function api.complete_pin_reset(
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
  reset identity.pin_reset_requests;
begin
  perform identity.require_live_session(p_user_id, p_session_id);
  perform identity.check_pin_hmac(p_pin_hmac);

  select * into reset from identity.pin_reset_requests
  where user_id = p_user_id and consumed_at is null and expires_at > now()
  order by requested_at desc
  limit 1
  for update;

  if reset.id is null then
    perform identity.fail('conflict', jsonb_build_object('reason', 'no_pending_reset'));
  end if;

  -- This session must come from the emailed link, issued after the request.
  if not exists (
    select 1 from auth.mfa_amr_claims m
    where m.session_id = p_session_id
      and m.authentication_method in ('otp', 'magiclink')
      and m.created_at >= reset.requested_at
  ) then
    perform identity.fail('authorization_denied', jsonb_build_object('reason', 'email_link_session_required'));
  end if;

  update identity.pin_credentials
  set pin_hash = extensions.crypt(p_pin_hmac, extensions.gen_salt('bf', 10)),
      failed_attempts = 0,
      locked_at = null,
      set_at = now()
  where user_id = p_user_id;

  update identity.pin_reset_requests set consumed_at = now() where id = reset.id;

  -- A reset closes every open PIN window on every device (A-05).
  delete from identity.session_pin_proofs where user_id = p_user_id;
  perform identity.open_pin_proof(p_user_id, p_session_id);

  perform audit.record('pin.reset', p_user_id, p_session_id, p_user_id, p_request_id => p_request_id);
  return identity.security_state(p_user_id, p_session_id);
end;
$$;

create function api.list_sessions(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'sessionId', s.id,
      'createdAt', s.created_at,
      'lastActiveAt', coalesce(s.refreshed_at::timestamptz, s.updated_at, s.created_at),
      'userAgent', left(s.user_agent, 300),
      'current', s.id = p_session_id
    ) order by coalesce(s.refreshed_at::timestamptz, s.updated_at, s.created_at) desc)
    from auth.sessions s
    where s.user_id = p_user_id and (s.not_after is null or s.not_after > now())
  ), '[]'::jsonb);
end;
$$;

-- Signs out one own session, or every other own session. PIN proofs cascade.
create function api.revoke_sessions(
  p_user_id uuid,
  p_session_id uuid,
  p_target_session_id uuid,
  p_all_others boolean,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  revoked int;
begin
  perform identity.require_session(p_user_id, p_session_id);

  if p_all_others is true and p_target_session_id is null then
    delete from auth.sessions where user_id = p_user_id and id <> p_session_id;
  elsif p_all_others is not true and p_target_session_id is not null then
    delete from auth.sessions where user_id = p_user_id and id = p_target_session_id;
  else
    perform identity.fail('validation_error', jsonb_build_object('field', 'target'));
  end if;
  get diagnostics revoked = row_count;

  if p_target_session_id is not null and revoked = 0 then
    perform identity.fail('not_found');
  end if;

  perform audit.record('session.revoked', p_user_id, p_session_id, p_user_id,
    p_safe_after => jsonb_build_object('revoked', revoked, 'allOthers', coalesce(p_all_others, false)),
    p_request_id => p_request_id);
  return jsonb_build_object('revoked', revoked);
end;
$$;

revoke all on function
  api.security_state(uuid, uuid),
  api.set_pin(uuid, uuid, text, text),
  api.verify_pin(uuid, uuid, text, text),
  api.request_pin_reset(uuid, uuid, text),
  api.complete_pin_reset(uuid, uuid, text, text),
  api.list_sessions(uuid, uuid),
  api.revoke_sessions(uuid, uuid, uuid, boolean, text)
from public, anon, authenticated;

grant execute on function
  api.security_state(uuid, uuid),
  api.set_pin(uuid, uuid, text, text),
  api.verify_pin(uuid, uuid, text, text),
  api.request_pin_reset(uuid, uuid, text),
  api.complete_pin_reset(uuid, uuid, text, text),
  api.list_sessions(uuid, uuid),
  api.revoke_sessions(uuid, uuid, uuid, boolean, text)
to service_role;
