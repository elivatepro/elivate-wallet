-- Blueprint 25 — B3: "Offices this month" on the network home (Paper NV01/NV03,
-- W-07 Leadership). One row per office in the selected workspace's scope (the
-- workspace office and everything below it, or the whole network for the
-- President Team) with its active members and the income recorded this month.
--
-- Same rules as api.leadership_overview:
-- - authority: view_managed_wallets or view_scoped_financial_reports over the
--   workspace office (tenant-wide for the President Team);
-- - only segments the viewer may see count (ledger.visible_segments); the rest
--   is reported as excluded, per office and in total; the viewer's own money is
--   never part of a leadership view (self-target guard), so it is neither
--   counted nor reported as excluded;
-- - income = postings of `income` transactions on those segments;
-- - one figure per currency, never added across currencies.
--
-- Each row counts its own office only (members anchored there, segments whose
-- origin office is that office), not the offices below it, so the rows add up
-- to the scope's total. "This month" is the network's month: its configured
-- time zone (org.tenant_settings.time_zone, Africa/Lagos by default).

create function api.leadership_offices(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid
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
  month_start timestamp;
  next_start timestamp;
  permissions constant text[] := array['view_managed_wallets', 'view_scoped_financial_reports'];
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  if workspace.office_id is not null then
    scope_office := org.office_in_tenant(workspace.tenant_id, workspace.office_id);
  end if;

  if not (authz.decide(p_user_id, permissions[1], workspace.tenant_id, workspace.office_id, null, workspace.id)->>'allowed')::boolean
    and not (authz.decide(p_user_id, permissions[2], workspace.tenant_id, workspace.office_id, null, workspace.id)->>'allowed')::boolean then
    perform identity.fail('authorization_denied');
  end if;

  zone := coalesce((select s.time_zone from org.tenant_settings s where s.tenant_id = workspace.tenant_id),
    'Africa/Lagos');
  month_start := date_trunc('month', now() at time zone zone);
  next_start := month_start + interval '1 month';

  return (
    with scope_offices as (
      select o.* from org.offices o
      where o.tenant_id = workspace.tenant_id
        and (workspace.office_id is null or exists (
          select 1 from org.office_closure c where c.ancestor_id = workspace.office_id and c.descendant_id = o.id))
    ),
    scope_seg as (
      select b.* from ledger.balances b
      where b.tenant_id = workspace.tenant_id
        and b.office_id in (select scope_offices.id from scope_offices)
    ),
    visible as (
      select * from ledger.visible_segments(p_user_id, workspace.id, workspace.tenant_id, permissions, null,
        workspace.office_id)
    ),
    hidden as (
      select * from scope_seg
      where scope_seg.owner_user_id <> p_user_id
        and scope_seg.account_id not in (select visible.account_id from visible)
    ),
    income as (
      select v.office_id, j.currency, sum(p.amount) as amount
      from ledger.postings p
      join visible v on v.account_id = p.account_id
      join ledger.journals j on j.id = p.journal_id
      join ledger.transactions t on t.id = j.transaction_id
      where t.type = 'income'
        and t.posted_at >= month_start at time zone zone
        and t.posted_at < next_start at time zone zone
      group by v.office_id, j.currency
    ),
    currencies as (
      select c.code as currency from ledger.currencies c
      where c.active or exists (select 1 from visible v where v.currency = c.code)
    ),
    people as (
      select distinct m.office_id, m.user_id
      from org.memberships m
      where m.tenant_id = workspace.tenant_id and m.status = 'active' and m.role <> 'president_team_member'
        and m.user_id <> p_user_id
        and m.office_id in (select scope_offices.id from scope_offices)
        and exists (
          select 1 from unnest(permissions) k
          where ledger.segment_visible(p_user_id, k, workspace.tenant_id, m.office_id, m.user_id, workspace.id))
    ),
    rows as (
      select o.* from scope_offices o
      where o.status = 'active' or exists (select 1 from income i where i.office_id = o.id)
    )
    select jsonb_build_object(
      'scope', jsonb_build_object(
        'kind', case when workspace.office_id is null then 'network' else 'office' end,
        'officeId', scope_office.id,
        'name', coalesce(scope_office.name, (select t.name from org.tenants t where t.id = workspace.tenant_id))
      ),
      'period', jsonb_build_object(
        'month', to_char(month_start, 'YYYY-MM'),
        'timeZone', zone
      ),
      'currencies', coalesce((select jsonb_agg(cur.currency order by cur.currency) from currencies cur), '[]'::jsonb),
      'offices', coalesce((
        select jsonb_agg(jsonb_build_object(
          'officeId', r.id,
          'name', r.name,
          'kind', r.office_type,
          'parentOfficeId', r.parent_office_id,
          'status', r.status,
          'members', (select count(*) from people pe where pe.office_id = r.id),
          'income', coalesce((
            select jsonb_agg(jsonb_build_object(
              'currency', cur.currency,
              'amount', ledger.money(coalesce((
                select i.amount from income i where i.office_id = r.id and i.currency = cur.currency), 0), cur.currency)
            ) order by cur.currency)
            from currencies cur
          ), '[]'::jsonb),
          'excludedMembers', (select count(distinct h.owner_user_id) from hidden h where h.office_id = r.id)
        ) order by array_position(array['world_team', 'director', 'team_leader'], r.office_type::text), r.name, r.id)
        from rows r
      ), '[]'::jsonb),
      'excluded', jsonb_build_object(
        'offices', (select count(distinct h.office_id) from hidden h),
        'members', (select count(distinct h.owner_user_id) from hidden h)
      )
    )
  );
end;
$$;

revoke all on function api.leadership_offices(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function api.leadership_offices(uuid, uuid, uuid) to service_role;
