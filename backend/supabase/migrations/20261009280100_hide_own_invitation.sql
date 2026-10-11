-- Slice 28 (owner decision 2026-10-11): a leader no longer sees their own
-- invitation (the one they accepted to join) in the Invitations list. Same
-- signature, scope and authorization as before; one more filter.

create or replace function api.list_invitations(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_office_id uuid default null,
  p_status text default null,
  p_cursor text default null,
  p_limit int default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  scope_office_id uuid;
  page_size int;
  after jsonb;
  rows jsonb;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  scope_office_id := coalesce(p_office_id, workspace.office_id);
  if scope_office_id is not null then
    perform org.office_in_tenant(workspace.tenant_id, scope_office_id);
  end if;
  perform authz.require(p_user_id, 'invite_members', workspace.tenant_id, scope_office_id, null, workspace.id);
  if p_status is not null and p_status not in ('pending', 'accepted', 'expired', 'revoked') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'status'));
  end if;
  page_size := org.page_limit(p_limit);
  after := org.decode_cursor(p_cursor);

  select coalesce(jsonb_agg(item order by item->>'createdAt' desc, item->>'invitationId' desc), '[]'::jsonb) into rows
  from (
    select jsonb_build_object(
      'invitationId', i.id,
      'reference', i.reference,
      'email', i.email,
      'officeId', i.office_id,
      'officeName', o.name,
      'role', i.role,
      'status', org.invitation_effective_status(i),
      'expiresAt', i.expires_at,
      'invitedBy', org.person(i.invited_by),
      'issueCount', i.issue_count,
      'delivery', case when org.invitation_effective_status(i) = 'pending' then org.invitation_delivery(i) end,
      'createdAt', to_char(i.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'acceptedAt', i.accepted_at,
      'revokedAt', i.revoked_at
    ) as item
    from org.invitations i
    join org.offices o on o.id = i.office_id
    where i.tenant_id = workspace.tenant_id
      and (scope_office_id is null or exists (
        select 1 from org.office_closure c where c.ancestor_id = scope_office_id and c.descendant_id = i.office_id))
      and (p_status is null or org.invitation_effective_status(i) = p_status::org.invitation_status)
      and i.accepted_user_id is distinct from p_user_id
      and (authz.decide(p_user_id, 'invite_members', workspace.tenant_id, i.office_id, null, workspace.id)->>'allowed')::boolean
      and (after is null or (to_char(i.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), i.id::text)
                            < (after->>'c', after->>'id'))
    order by i.created_at desc, i.id desc
    limit page_size + 1
  ) page;

  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(e) from jsonb_array_elements(rows) with ordinality as x (e, n) where n <= page_size), '[]'::jsonb),
    'nextCursor', case when jsonb_array_length(rows) > page_size
      then org.encode_cursor(jsonb_build_object('c', rows->(page_size - 1)->>'createdAt', 'id', rows->(page_size - 1)->>'invitationId'))
    end
  );
end;
$$;
