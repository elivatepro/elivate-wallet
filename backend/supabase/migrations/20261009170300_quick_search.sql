-- Blueprint 17 — B2: quick search (⌘K, P-06 owner decision 2026-10-07).
-- Everything the person can already see in the selected workspace: people
-- (name, UID, email, phone), offices, and transactions, withdrawals, pocket
-- moves and returned funds by public reference. Every row passes the same
-- resolver as its own page; results never widen authority, and email and
-- phone come back masked. Pages and actions are matched in the app.

create function org.can(p_user_id uuid, p_key text, p_workspace org.memberships, p_office_id uuid,
  p_target_user_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select (authz.decide(p_user_id, p_key, p_workspace.tenant_id, p_office_id, p_target_user_id,
    p_workspace.id)->>'allowed')::boolean
$$;

-- "+234 •• •••• 2210" (E11).
create function org.masked_phone(p_phone text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_phone is null or length(regexp_replace(p_phone, '[^0-9]', '', 'g')) < 6 then null
    when p_phone like '+234%' then '+234 •• •••• ' || right(p_phone, 4)
    else left(p_phone, 3) || ' ••• ' || right(p_phone, 4)
  end
$$;

create function api.quick_search(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_query text,
  p_limit int default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  q text := btrim(p_query);
  n int := least(greatest(coalesce(p_limit, 5), 1), 10);
  needle text;
  prefix text;
  digits text;
  ref_prefix text;
  people jsonb;
  offices jsonb;
  records jsonb;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  if q is null or length(q) not between 2 and 80 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'q'));
  end if;
  needle := '%' || replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  prefix := replace(replace(replace(lower(q), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  digits := regexp_replace(q, '[^0-9]', '', 'g');
  -- A local number (0801…) matches the stored +234801….
  if digits ~ '^0[0-9]{10}$' then
    digits := substr(digits, 2);
  end if;
  -- References: "WDR-3J8Q-1142", "wdr3j8q", "WDR-3J8Q" all match by prefix.
  ref_prefix := case when upper(q) ~ '^[A-Z]{3}-?[0-9A-Z]{0,4}-?[0-9A-Z]{0,4}$' then
    regexp_replace(regexp_replace(upper(q), '^([A-Z]{3})-?', '\1-'), '^([A-Z]{3}-[0-9A-Z]{4})-?', '\1-') end;

  -- People: the members this workspace can manage or view, and oneself.
  select coalesce(jsonb_agg(item), '[]'::jsonb) into people
  from (
    select jsonb_build_object(
      'membershipId', m.id,
      'person', org.person(m.user_id),
      'role', m.role,
      'status', m.status,
      'officeName', o.name,
      'emailMasked', org.masked_email(m.user_id),
      'phoneMasked', org.masked_phone(pr.phone),
      'self', m.user_id = p_user_id
    ) as item
    from org.memberships m
    join identity.accounts a on a.user_id = m.user_id
    left join identity.profiles pr on pr.user_id = m.user_id
    left join org.offices o on o.id = m.office_id
    left join auth.users u on u.id = m.user_id
    where m.tenant_id = workspace.tenant_id and m.status <> 'ended'
      and (a.uid ilike needle
           or concat_ws(' ', pr.first_name, pr.last_name) ilike needle
           or coalesce(pr.display_name, '') ilike needle
           or (position('@' in q) > 0 and lower(u.email) like prefix)
           or (length(digits) >= 4 and q ~ '^[0-9[:space:]+()-]+$'
               and regexp_replace(coalesce(pr.phone, ''), '[^0-9]', '', 'g') like '%' || digits || '%'))
      and (m.user_id = p_user_id
           or org.can(p_user_id, 'manage_members', workspace, m.office_id, m.user_id)
           or org.can(p_user_id, 'view_managed_wallets', workspace, m.office_id, m.user_id))
    order by (a.uid ilike q) desc, (m.user_id = p_user_id) desc, m.started_at, m.id
    limit n
  ) x;

  -- Offices the workspace can manage or report on.
  select coalesce(jsonb_agg(item), '[]'::jsonb) into offices
  from (
    select jsonb_build_object(
      'officeId', o.id,
      'name', o.name,
      'officeType', o.office_type,
      'status', o.status,
      'parentName', p.name,
      'memberCount', (select count(*) from org.memberships mm
        join org.office_closure c on c.descendant_id = mm.office_id
        where c.ancestor_id = o.id and mm.status = 'active')
    ) as item
    from org.offices o
    left join org.offices p on p.id = o.parent_office_id
    where o.tenant_id = workspace.tenant_id and o.name ilike needle
      and (org.can(p_user_id, 'manage_members', workspace, o.id, null)
           or org.can(p_user_id, 'view_managed_wallets', workspace, o.id, null)
           or org.can(p_user_id, 'view_scoped_financial_reports', workspace, o.id, null))
    order by (o.name ilike q) desc, o.name, o.id
    limit n
  ) x;

  -- Records by public reference: one's own, or those the workspace may see.
  if ref_prefix is not null and length(ref_prefix) >= 5 then
    select coalesce(jsonb_agg(item order by ord), '[]'::jsonb) into records
    from (
      select r.item, row_number() over (order by r.at desc, r.reference) as ord
      from (
        select jsonb_build_object('kind', 'withdrawal', 'id', w.id, 'reference', w.reference, 'status', w.status,
          'amount', jsonb_build_object('amount', ledger.money(w.amount, w.currency), 'currency', w.currency), 'person', org.person(w.owner_user_id),
          'officeName', o.name, 'walletId', w.wallet_id, 'at', w.created_at,
          'own', w.owner_user_id = p_user_id) as item,
          w.created_at as at, w.reference
        from finance.withdrawals w left join org.offices o on o.id = w.office_id
        where w.tenant_id = workspace.tenant_id and w.reference like ref_prefix || '%'
          and (w.owner_user_id = p_user_id
               or org.can(p_user_id, 'approve_withdrawal', workspace, w.office_id, w.owner_user_id)
               or org.can(p_user_id, 'view_managed_wallets', workspace, w.office_id, w.owner_user_id))
        union all
        select jsonb_build_object('kind', 'transfer', 'id', t.id, 'reference', t.reference, 'status', t.status,
          'amount', jsonb_build_object('amount', ledger.money(t.amount, t.currency), 'currency', t.currency), 'person', org.person(t.owner_user_id),
          'officeName', o.name, 'walletId', t.wallet_id, 'at', t.created_at,
          'own', t.owner_user_id = p_user_id),
          t.created_at, t.reference
        from finance.pocket_transfers t left join org.offices o on o.id = t.office_id
        where t.tenant_id = workspace.tenant_id and t.reference like ref_prefix || '%'
          and (t.owner_user_id = p_user_id
               or org.can(p_user_id, 'approve_pocket_transfer', workspace, t.office_id, t.owner_user_id)
               or org.can(p_user_id, 'view_managed_wallets', workspace, t.office_id, t.owner_user_id))
        union all
        select jsonb_build_object('kind', 'returned_funds', 'id', e.id, 'reference', e.reference,
          'status', e.status, 'withdrawalId', e.withdrawal_id, 'amount', jsonb_build_object('amount', ledger.money(e.amount, e.currency), 'currency', e.currency),
          'person', org.person(e.owner_user_id), 'officeName', o.name, 'walletId', e.wallet_id,
          'at', e.created_at,
          'own', e.owner_user_id = p_user_id),
          e.created_at, e.reference
        from finance.entries e left join org.offices o on o.id = e.office_id
        where e.tenant_id = workspace.tenant_id and e.kind = 'returned_funds' and e.reference like ref_prefix || '%'
          and (e.owner_user_id = p_user_id
               or org.can(p_user_id, 'record_returned_funds', workspace, e.office_id, e.owner_user_id)
               or org.can(p_user_id, 'view_managed_wallets', workspace, e.office_id, e.owner_user_id))
        union all
        select jsonb_build_object('kind', 'transaction', 'id', t.id, 'reference', t.reference, 'type', t.type,
          'walletId', t.wallet_id, 'person', org.person(t.owner_user_id), 'officeName', o.name, 'at', t.posted_at,
          'own', t.owner_user_id = p_user_id),
          t.posted_at, t.reference
        from ledger.transactions t left join org.offices o on o.id = t.office_id
        where t.tenant_id = workspace.tenant_id and t.reference like ref_prefix || '%'
          and t.owner_user_id is not null
          and not exists (select 1 from finance.withdrawals w2 where w2.reference = t.reference)
          and not exists (select 1 from finance.pocket_transfers t2 where t2.reference = t.reference)
          and not exists (select 1 from finance.entries e2 where e2.reference = t.reference
                          and e2.kind = 'returned_funds')
          and (t.owner_user_id = p_user_id
               or org.can(p_user_id, 'view_managed_wallets', workspace, t.office_id, t.owner_user_id))
      ) r
      order by r.at desc, r.reference
      limit n
    ) x;
  end if;

  return jsonb_build_object(
    'query', q,
    'people', people,
    'offices', offices,
    'records', coalesce(records, '[]'::jsonb)
  );
end;
$$;

revoke all on function org.can(uuid, text, org.memberships, uuid, uuid) from public, anon, authenticated;
revoke all on function org.masked_phone(text) from public, anon, authenticated;
revoke all on function api.quick_search(uuid, uuid, uuid, text, int) from public, anon, authenticated;
grant execute on function api.quick_search(uuid, uuid, uuid, text, int) to service_role;
