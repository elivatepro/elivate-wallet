-- Possession of an unexpired invitation token permits only recipient preview.
-- Membership creation remains in the verified-identity acceptance command.
create function read_api.invitation_preview(p_token_digest bytea)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_token_digest is null or pg_catalog.octet_length(p_token_digest) <> 32 then
    return null;
  end if;

  return (
    select pg_catalog.jsonb_build_object('email', invitation.email)
      from public.invitations invitation
      join public.tenants tenant on tenant.id = invitation.tenant_id
      left join public.offices office on office.id = invitation.office_id
        and office.tenant_id = invitation.tenant_id
     where invitation.token_digest = p_token_digest
       and invitation.status = 'pending'
       and invitation.expires_at > pg_catalog.statement_timestamp()
       and tenant.status = 'active'
       and (invitation.office_id is null or office.status = 'active')
  );
end;
$$;

revoke all on function read_api.invitation_preview(bytea)
  from public, anon, authenticated, service_role;
grant execute on function read_api.invitation_preview(bytea) to service_role;
