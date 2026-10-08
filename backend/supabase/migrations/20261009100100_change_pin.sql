-- Blueprint 10 — B4: change the transaction PIN while signed in (W-22, A-05).
-- The person proves the current PIN (same attempt counter and lock as
-- api.verify_pin, so this route cannot be used to guess more PINs) and sets a
-- new one. Every other session's PIN window closes; this session gets a fresh
-- proof. The raw PINs never reach the database (HMAC hex only).

-- Shared wrong-PIN bookkeeping (verify_pin keeps its own copy; behaviour is
-- identical: +1 attempt, lock at 5 and close every PIN window on the lock).
create function identity.record_wrong_pin(
  p_user_id uuid,
  p_session_id uuid,
  p_failed_attempts smallint,
  p_request_id text
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  attempts smallint := p_failed_attempts + 1;
begin
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

revoke all on function identity.record_wrong_pin(uuid, uuid, smallint, text)
  from public, anon, authenticated;

-- Wrong current PINs return a result instead of raising, so the attempt count
-- commits (same contract as api.verify_pin).
create function api.change_pin(
  p_user_id uuid,
  p_session_id uuid,
  p_current_pin_hmac text,
  p_new_pin_hmac text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  credential identity.pin_credentials;
begin
  -- Gate `ready`: a session that still owes its PIN unlocks first.
  perform identity.require_session(p_user_id, p_session_id);
  if p_current_pin_hmac is null or p_current_pin_hmac !~ '^[0-9a-f]{64}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'currentPin'));
  end if;
  perform identity.check_pin_hmac(p_new_pin_hmac);

  select * into credential from identity.pin_credentials
  where user_id = p_user_id
  for update;
  if credential.user_id is null then
    perform identity.fail('pin_setup_required');
  end if;
  if credential.locked_at is not null then
    perform identity.fail('pin_locked');
  end if;

  if extensions.crypt(p_current_pin_hmac, credential.pin_hash) <> credential.pin_hash then
    return identity.record_wrong_pin(p_user_id, p_session_id, credential.failed_attempts, p_request_id);
  end if;

  if p_new_pin_hmac = p_current_pin_hmac then
    perform identity.fail('validation_error', jsonb_build_object('field', 'pin', 'reason', 'same_pin'));
  end if;

  update identity.pin_credentials
  set pin_hash = extensions.crypt(p_new_pin_hmac, extensions.gen_salt('bf', 10)),
      failed_attempts = 0,
      locked_at = null,
      set_at = now()
  where user_id = p_user_id;

  -- A new PIN closes the PIN window on every other device (A-05, like a reset);
  -- this session proved the PIN just now, so it gets a fresh window.
  delete from identity.session_pin_proofs
  where user_id = p_user_id and session_id <> p_session_id;
  perform identity.open_pin_proof(p_user_id, p_session_id);

  perform audit.record('pin.changed', p_user_id, p_session_id, p_user_id, p_request_id => p_request_id);
  return jsonb_build_object('ok', true, 'state', identity.security_state(p_user_id, p_session_id));
end;
$$;

revoke all on function api.change_pin(uuid, uuid, text, text, text) from public, anon, authenticated;
grant execute on function api.change_pin(uuid, uuid, text, text, text) to service_role;
