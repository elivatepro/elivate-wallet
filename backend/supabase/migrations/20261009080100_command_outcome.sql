-- Blueprint 08 — B4.1: unknown-outcome recovery (F-03, W-00). A person whose
-- command timed out or lost its connection asks what happened to *their own*
-- attempt, by its idempotency key. The answer is authoritative: the lookup
-- takes the same per-actor key lock as identity.replay, so an attempt still
-- running in the database finishes (commit or rollback) before it answers.
--
-- It reports the fate only (committed / cancelled / not found) plus the public
-- reference when the result carries one. The full result is returned only by
-- a same-key replay of the command itself, which re-checks current authority,
-- session and step-up (F-03: "current authorization ... before protected
-- replay results are returned").

create function api.command_outcome(
  p_user_id uuid,
  p_session_id uuid,
  p_idempotency_key text,
  p_command text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  stored identity.command_results;
  v_cancelled_at timestamptz;
begin
  perform identity.require_session(p_user_id, p_session_id);
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{16,100}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'idempotencyKey'));
  end if;
  if p_command is not null and p_command !~ '^[a-z][a-z_]{0,59}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'command'));
  end if;

  -- Same lock as identity.replay / finance.lock_attempt: waits for an attempt
  -- that is still running under this key.
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text || ':' || p_idempotency_key, 0));

  select * into stored from identity.command_results
  where actor_user_id = p_user_id and idempotency_key = p_idempotency_key;
  if stored.actor_user_id is not null then
    if p_command is not null and stored.command <> p_command then
      perform identity.fail('idempotency_conflict');
    end if;
    return jsonb_build_object(
      'status', 'committed',
      'command', stored.command,
      'committedAt', stored.created_at,
      'reference', case when jsonb_typeof(stored.result->'reference') = 'string'
        then stored.result->>'reference' end
    );
  end if;

  -- W-08 recovery: an income attempt cancelled under the same key.
  if p_command is null or p_command = 'record_income' then
    select c.cancelled_at into v_cancelled_at from finance.income_attempt_cancellations c
    where c.actor_user_id = p_user_id and c.idempotency_key = p_idempotency_key;
    if v_cancelled_at is not null then
      return jsonb_build_object('status', 'cancelled', 'command', 'record_income',
        'cancelledAt', v_cancelled_at);
    end if;
  end if;

  return jsonb_build_object('status', 'not_found', 'command', p_command);
end;
$$;

revoke all on function api.command_outcome(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function api.command_outcome(uuid, uuid, text, text) to service_role;
