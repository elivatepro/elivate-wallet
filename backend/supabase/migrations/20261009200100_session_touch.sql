-- Blueprint 20 — B2: the session touch is written at most every 30 seconds.
-- Every protected read and command calls identity.require_session, which
-- used to update session_pin_proofs.last_activity_at on every call, so calls
-- that ran in parallel queued behind each other on that row's lock. Now the
-- proof is read with a plain select and the activity time is written only
-- when it is at least 30 seconds old. The idle lock (A-05, 15 minutes) reads
-- last_activity_at as before and becomes up to 30 seconds looser; step-up
-- still reads verified_at, which this never changes. Same signature, same
-- failures.

create function identity.session_touch_interval() returns interval
language sql immutable set search_path = '' as $$ select interval '30 seconds' $$;

create or replace function identity.require_session(
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

  select p.verified_at into proof_verified_at
  from identity.session_pin_proofs p
  where p.session_id = p_session_id;

  update identity.session_pin_proofs
  set last_activity_at = now()
  where session_id = p_session_id
    and last_activity_at < now() - identity.session_touch_interval();

  if p_step_up and proof_verified_at <= now() - identity.step_up_window() then
    perform identity.fail('step_up_required');
  end if;
  return account_status;
end;
$$;

revoke all on function identity.session_touch_interval() from public, anon, authenticated;
revoke all on function identity.require_session(uuid, uuid, boolean) from public, anon, authenticated;
