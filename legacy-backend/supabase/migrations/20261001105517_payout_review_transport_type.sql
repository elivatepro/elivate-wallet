-- PostgREST must cast RPC inputs without access to private domain schemas.
drop function command_api.review_payout_assertion(uuid, uuid, evidence.review_decision, text, uuid, uuid);

create function command_api.review_payout_assertion(
  p_idempotency_key uuid,
  p_payout_assertion_id uuid,
  p_decision text,
  p_review_note text,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.payout_assertion_command_result
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_decision is null or p_decision not in ('clear', 'reject') then
    raise exception using errcode = '22023', message = 'Review decision is invalid';
  end if;

  return financial_ops.review_payout_assertion(
    p_idempotency_key, p_payout_assertion_id,
    p_decision::evidence.review_decision, p_review_note,
    p_actor_user_id, p_session_id
  );
end;
$$;

revoke all on function command_api.review_payout_assertion(uuid, uuid, text, text, uuid, uuid) from public, anon, authenticated;
grant execute on function command_api.review_payout_assertion(uuid, uuid, text, text, uuid, uuid) to service_role;
