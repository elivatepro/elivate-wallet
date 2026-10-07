create or replace function internal.prevent_organization_command_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'organization command idempotency history is append-only';
end;
$$;

create trigger organization_command_idempotency_prevent_mutation
  before update or delete on internal.organization_command_idempotency
  for each row execute function internal.prevent_organization_command_mutation();

alter table internal.organization_command_idempotency enable row level security;
alter table internal.organization_command_idempotency force row level security;

create policy organization_command_idempotency_private_deny
  on internal.organization_command_idempotency
  as restrictive
  for all
  to public
  using (false)
  with check (false);

revoke all on internal.organization_command_idempotency
  from public, anon, authenticated, service_role;

revoke all on function internal.organization_request_fingerprint(text, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function internal.organization_replay_result(uuid, text, uuid, bytea, text)
  from public, anon, authenticated, service_role;
revoke all on function internal.record_organization_command(uuid, text, uuid, uuid, bytea, text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function internal.lock_membership_subject(uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function internal.bump_membership_authorization_versions(uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function internal.ensure_wallet_for_member(uuid)
  from public, anon, authenticated, service_role;
revoke all on function internal.assert_membership_not_billing_owner(uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function internal.lock_active_office(uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function internal.create_invitation(
  uuid, uuid, uuid, uuid, uuid, public.role_key, text, bytea, timestamptz
) from public, anon, authenticated, service_role;
revoke all on function internal.revoke_invitation(uuid, uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function internal.expire_invitations(timestamptz)
  from public, anon, authenticated, service_role;
revoke all on function internal.accept_invitation(uuid, uuid, bytea)
  from public, anon, authenticated, service_role;
revoke all on function internal.create_membership(
  uuid, uuid, uuid, uuid, uuid, uuid, public.role_key
) from public, anon, authenticated, service_role;
revoke all on function internal.activate_membership(uuid, uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function internal.suspend_membership(uuid, uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function internal.end_membership(uuid, uuid, uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function internal.move_membership(
  uuid, uuid, uuid, uuid, uuid, public.role_key
) from public, anon, authenticated, service_role;
revoke all on function internal.prevent_organization_command_mutation()
  from public, anon, authenticated, service_role;

comment on function internal.create_invitation(
  uuid, uuid, uuid, uuid, uuid, public.role_key, text, bytea, timestamptz
) is
  'Private idempotent command; authorizes invite_members and never exposes the raw invitation token.';
comment on function internal.accept_invitation(uuid, uuid, bytea) is
  'Private idempotent acceptance command; binds authenticated identity and email to a pending invitation.';
comment on function internal.create_membership(
  uuid, uuid, uuid, uuid, uuid, uuid, public.role_key
) is
  'Private idempotent command; authorizes manage_members and enforces commercial seat capacity.';
comment on function internal.move_membership(
  uuid, uuid, uuid, uuid, uuid, public.role_key
) is
  'Private idempotent move command; requires source and destination scope, ends the old membership, and preserves primary state.';
