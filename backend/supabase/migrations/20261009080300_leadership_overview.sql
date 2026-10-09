-- Blueprint 08 — B4.3: the leadership dashboard (W-07 Leadership; Paper T01
-- desktop, T04 mobile hero card). One aggregate read for the selected
-- workspace's scope: the workspace office and everything below it, or the
-- whole network for the President Team. Only authorized segments count; the
-- rest is reported as excluded. Currencies are never added together.
--
-- Withdrawal figures (payouts completed, open requests, "needs your action")
-- belong to the withdrawals slice, which adds its fields to this read.

create function api.leadership_overview(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_tz text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  scope_office org.offices;
  zone text;
  local_now timestamp;
  month_start timestamp;
  previous_start timestamp;
  week_start timestamp;
  can_invite boolean;
  permissions constant text[] := array['view_managed_wallets', 'view_scoped_financial_reports'];
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  zone := ledger.time_zone(p_tz);
  if workspace.office_id is not null then
    scope_office := org.office_in_tenant(workspace.tenant_id, workspace.office_id);
  end if;

  if not (authz.decide(p_user_id, permissions[1], workspace.tenant_id, workspace.office_id, null, workspace.id)->>'allowed')::boolean
    and not (authz.decide(p_user_id, permissions[2], workspace.tenant_id, workspace.office_id, null, workspace.id)->>'allowed')::boolean then
    perform identity.fail('authorization_denied');
  end if;
  can_invite := (authz.decide(p_user_id, 'invite_members', workspace.tenant_id, workspace.office_id, null,
    workspace.id)->>'allowed')::boolean;

  local_now := now() at time zone zone;
  month_start := date_trunc('month', local_now);
  previous_start := month_start - interval '1 month';
  week_start := date_trunc('week', local_now) - interval '4 weeks';

  return (
    with scope_seg as (
      select b.* from ledger.balances b
      where b.tenant_id = workspace.tenant_id
        and (workspace.office_id is null or exists (
          select 1 from org.office_closure c where c.ancestor_id = workspace.office_id and c.descendant_id = b.office_id))
    ),
    visible as (
      select * from ledger.visible_segments(p_user_id, workspace.id, workspace.tenant_id, permissions, null,
        workspace.office_id)
    ),
    -- The viewer's own money is never part of a leadership view (self-target
    -- guard), so it is not reported as excluded either.
    hidden as (
      select * from scope_seg
      where scope_seg.owner_user_id <> p_user_id
        and scope_seg.account_id not in (select visible.account_id from visible)
    ),
    income as (
      select j.currency, t.posted_at at time zone zone as local_at, p.amount
      from ledger.postings p
      join ledger.journals j on j.id = p.journal_id
      join ledger.transactions t on t.id = j.transaction_id
      where p.account_id in (select visible.account_id from visible)
        and t.type = 'income'
        and t.posted_at >= least(previous_start, week_start) at time zone zone
    ),
    currencies as (
      select c.code as currency from ledger.currencies c
      where c.active or exists (select 1 from visible v where v.currency = c.code)
    ),
    people as (
      select distinct m.user_id, m.id
      from org.memberships m
      where m.tenant_id = workspace.tenant_id and m.status = 'active' and m.role <> 'president_team_member'
        and m.user_id <> p_user_id
        and (workspace.office_id is null or exists (
          select 1 from org.office_closure c where c.ancestor_id = workspace.office_id and c.descendant_id = m.office_id))
        and exists (
          select 1 from unnest(permissions) k
          where ledger.segment_visible(p_user_id, k, workspace.tenant_id, m.office_id, m.user_id, workspace.id))
    )
    select jsonb_build_object(
      'scope', jsonb_build_object(
        'kind', case when workspace.office_id is null then 'network' else 'office' end,
        'officeId', scope_office.id,
        'name', coalesce(scope_office.name, (select t.name from org.tenants t where t.id = workspace.tenant_id))
      ),
      'period', jsonb_build_object(
        'month', to_char(month_start, 'YYYY-MM'),
        'previousMonth', to_char(previous_start, 'YYYY-MM'),
        'timeZone', zone
      ),
      'currencies', coalesce((
        select jsonb_agg(jsonb_build_object(
          'currency', cur.currency,
          'incomeThisMonth', ledger.money(coalesce((
            select sum(i.amount) from income i where i.currency = cur.currency and i.local_at >= month_start), 0), cur.currency),
          'incomePreviousMonth', ledger.money(coalesce((
            select sum(i.amount) from income i where i.currency = cur.currency
              and i.local_at >= previous_start and i.local_at < month_start), 0), cur.currency),
          'posted', ledger.money(coalesce((select sum(v.posted) from visible v where v.currency = cur.currency), 0), cur.currency),
          'reserved', ledger.money(coalesce((select sum(v.reserved) from visible v where v.currency = cur.currency), 0), cur.currency),
          'available', ledger.money(coalesce((
            select sum(v.posted - v.reserved) from visible v where v.currency = cur.currency), 0), cur.currency),
          'weeks', (
            select jsonb_agg(jsonb_build_object(
              'start', to_char(w.start, 'YYYY-MM-DD'),
              'income', ledger.money(coalesce((
                select sum(i.amount) from income i
                where i.currency = cur.currency and i.local_at >= w.start and i.local_at < w.start + interval '1 week'), 0),
                cur.currency)
            ) order by w.start)
            from generate_series(week_start, week_start + interval '4 weeks', interval '1 week') as w (start)
          )
        ) order by cur.currency)
        from currencies cur
      ), '[]'::jsonb),
      'members', jsonb_build_object(
        'active', (select count(distinct people.user_id) from people),
        'activeMemberships', (select count(*) from people),
        'pendingInvitations', case when can_invite then (
          select count(*) from org.invitations inv
          where inv.tenant_id = workspace.tenant_id and inv.status = 'pending' and inv.expires_at > now()
            and (workspace.office_id is null or exists (
              select 1 from org.office_closure c where c.ancestor_id = workspace.office_id and c.descendant_id = inv.office_id))
            and (authz.decide(p_user_id, 'invite_members', workspace.tenant_id, inv.office_id, null, workspace.id)->>'allowed')::boolean
        ) end
      ),
      'excluded', jsonb_build_object(
        'offices', (select count(distinct h.office_id) from hidden h),
        'members', (select count(distinct h.owner_user_id) from hidden h)
      )
    )
  );
end;
$$;

revoke all on function api.leadership_overview(uuid, uuid, uuid, text) from public, anon, authenticated;
grant execute on function api.leadership_overview(uuid, uuid, uuid, text) to service_role;
