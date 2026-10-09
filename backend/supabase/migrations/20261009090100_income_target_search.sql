-- Blueprint 09 follow-up (owner decision 2026-10-08): the Record income member
-- picker searches the whole network, not only the pages already loaded.
-- api.income_targets gains an optional `p_query` (1-100 chars; UID, name or
-- office name, case-insensitive, wildcards escaped). Same authorization,
-- eligibility, ordering and cursor as before; without p_query it is unchanged.

drop function api.income_targets(uuid, uuid, uuid, uuid, text, int);

create function api.income_targets(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_office_id uuid default null,
  p_cursor text default null,
  p_limit int default null,
  p_query text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  page_size int;
  after jsonb;
  rows jsonb;
  pattern text;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  if p_office_id is not null then
    perform org.office_in_tenant(workspace.tenant_id, p_office_id);
  end if;
  if p_query is not null and (length(btrim(p_query)) = 0 or length(p_query) > 100) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'q'));
  end if;
  pattern := '%' || replace(replace(replace(btrim(p_query), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  page_size := org.page_limit(p_limit);
  after := org.decode_cursor(p_cursor);

  select coalesce(jsonb_agg(item order by item->>'startedAt', item->>'membershipId'), '[]'::jsonb) into rows
  from (
    select jsonb_build_object(
      'membershipId', m.id,
      'person', org.person(m.user_id),
      'role', m.role,
      'officeId', m.office_id,
      'officeName', o.name,
      'startedAt', m.started_at
    ) as item
    from org.memberships m
    join org.offices o on o.id = m.office_id
    where m.tenant_id = workspace.tenant_id
      and m.user_id <> p_user_id
      and finance.target_eligible(m)
      and (p_query is null or exists (
        select 1 from identity.accounts a
        left join identity.profiles pr on pr.user_id = a.user_id
        where a.user_id = m.user_id
          and (a.uid ilike pattern or pr.display_name ilike pattern
               or concat_ws(' ', pr.first_name, pr.last_name) ilike pattern or o.name ilike pattern)))
      and (p_office_id is null or exists (
        select 1 from org.office_closure c where c.ancestor_id = p_office_id and c.descendant_id = m.office_id))
      and (authz.decide(p_user_id, 'record_income', workspace.tenant_id, m.office_id, m.user_id, workspace.id)->>'allowed')::boolean
      and (after is null or (to_char(m.started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'), m.id::text)
                            > (after->>'s', after->>'id'))
    order by m.started_at, m.id
    limit page_size + 1
  ) page;

  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(e) from jsonb_array_elements(rows) with ordinality as x (e, n) where n <= page_size), '[]'::jsonb),
    'nextCursor', case when jsonb_array_length(rows) > page_size then (
      select org.encode_cursor(jsonb_build_object(
        's', to_char(m.started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'), 'id', m.id))
      from org.memberships m where m.id = (rows->(page_size - 1)->>'membershipId')::uuid
    ) end,
    'allocation', ledger.allocation_json(workspace.tenant_id),
    'currencies', (select jsonb_agg(jsonb_build_object('code', c.code, 'scale', c.scale) order by c.code)
                   from ledger.currencies c where c.active)
  );
end;
$$;

revoke all on function api.income_targets(uuid, uuid, uuid, uuid, text, int, text) from public, anon, authenticated;
grant execute on function api.income_targets(uuid, uuid, uuid, uuid, text, int, text) to service_role;
