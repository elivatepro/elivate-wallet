-- Blueprint 12 — a member's wallet (leader view, Paper v4 Q05) names each
-- membership's id, so "Convert" and "Adjust" open for that membership.

create or replace function api.managed_wallet(p_user_id uuid, p_session_id uuid, p_membership_id uuid, p_wallet_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  ids uuid[];
  owner uuid;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  ids := ledger.require_managed_accounts(p_user_id, workspace, p_wallet_id);
  select w.owner_user_id into owner from ledger.wallets w where w.id = p_wallet_id;
  return jsonb_build_object(
    'walletId', p_wallet_id,
    'person', org.person(owner),
    'memberships', coalesce((
      select jsonb_agg(jsonb_build_object('membershipId', m.id, 'role', m.role, 'officeName', o.name, 'status', m.status)
        order by (m.status = 'active') desc, m.started_at desc)
      from org.memberships m
      join org.offices o on o.id = m.office_id
      where m.tenant_id = workspace.tenant_id and m.user_id = owner and m.status <> 'ended'
        and m.role <> 'president_team_member'
        -- Only memberships the leader may see (the same per-office check as the segments).
        and ledger.segment_visible(p_user_id, 'view_managed_wallets', workspace.tenant_id, m.office_id, owner,
          workspace.id)
    ), '[]'::jsonb),
    'networks', ledger.wallet_networks(p_wallet_id, workspace.tenant_id, ids)
  );
end;
$$;
