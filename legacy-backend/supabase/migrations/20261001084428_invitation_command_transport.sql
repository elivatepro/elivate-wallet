-- Narrow service-only transport; private commands retain all domain checks.

create function command_api.create_invitation(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_office_id uuid,
  p_role_key public.role_key,
  p_email text,
  p_token_digest bytea,
  p_expires_at timestamptz
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select internal.create_invitation(p_idempotency_key, p_actor_user_id, p_session_id, p_tenant_id, p_office_id, p_role_key, p_email, p_token_digest, p_expires_at);
$$;

revoke all on function command_api.create_invitation(uuid, uuid, uuid, uuid, uuid, public.role_key, text, bytea, timestamptz)
  from public, anon, authenticated;
grant execute on function command_api.create_invitation(uuid, uuid, uuid, uuid, uuid, public.role_key, text, bytea, timestamptz)
  to service_role;

create function command_api.accept_invitation(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_token_digest bytea
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select internal.accept_invitation(p_idempotency_key, p_actor_user_id, p_token_digest);
$$;

revoke all on function command_api.accept_invitation(uuid, uuid, bytea)
  from public, anon, authenticated;
grant execute on function command_api.accept_invitation(uuid, uuid, bytea)
  to service_role;

create function command_api.revoke_invitation(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_invitation_id uuid
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select internal.revoke_invitation(p_idempotency_key, p_actor_user_id, p_session_id, p_invitation_id);
$$;

revoke all on function command_api.revoke_invitation(uuid, uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function command_api.revoke_invitation(uuid, uuid, uuid, uuid)
  to service_role;
