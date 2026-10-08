-- Blueprint 04 — B3b/B4 reads: own wallet (decision 21: always visible to
-- its owner, read-only, no membership needed), managed wallets, office
-- subtree totals (W-05) and activity. Amounts are decimal strings.

-- Can the actor see one segment origin (office + owner) with a leadership
-- permission? A closed office is checked against its nearest active ancestor,
-- or the tenant itself when none is left (decision 23).
create function ledger.segment_visible(
  p_actor_user_id uuid,
  p_permission_key text,
  p_tenant_id uuid,
  p_office_id uuid,
  p_owner_user_id uuid,
  p_workspace_membership_id uuid
)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare
  office_status org.office_status;
  check_office uuid;
begin
  if p_owner_user_id = p_actor_user_id then
    return false;
  end if;
  select status into office_status from org.offices where id = p_office_id and tenant_id = p_tenant_id;
  if office_status is null then
    return false;
  end if;
  if office_status = 'active' then
    return (authz.decide(p_actor_user_id, p_permission_key, p_tenant_id, p_office_id, p_owner_user_id,
      p_workspace_membership_id)->>'allowed')::boolean;
  end if;

  select c.ancestor_id into check_office
  from org.office_closure c
  join org.offices a on a.id = c.ancestor_id
  where c.descendant_id = p_office_id and c.depth > 0 and a.status = 'active'
  order by c.depth
  limit 1;
  if check_office is null then
    -- Only tenant-wide authority (the President Team) covers a closed top office.
    return (authz.decide(p_actor_user_id, p_permission_key, p_tenant_id, null, null,
      p_workspace_membership_id)->>'allowed')::boolean;
  end if;
  return (authz.decide(p_actor_user_id, p_permission_key, p_tenant_id, check_office, p_owner_user_id,
    p_workspace_membership_id)->>'allowed')::boolean;
end;
$$;

-- Segments of one tenant the actor may see with any of the permissions,
-- evaluated once per (office, owner) pair.
create function ledger.visible_segments(
  p_actor_user_id uuid,
  p_workspace_membership_id uuid,
  p_tenant_id uuid,
  p_permission_keys text[],
  p_wallet_id uuid default null,
  p_scope_office_id uuid default null
)
returns setof ledger.balances
language sql
stable
set search_path = ''
as $$
  with seg as (
    select b.* from ledger.balances b
    where b.tenant_id = p_tenant_id
      and (p_wallet_id is null or b.wallet_id = p_wallet_id)
      and (p_scope_office_id is null or exists (
        select 1 from org.office_closure c where c.ancestor_id = p_scope_office_id and c.descendant_id = b.office_id))
  ),
  pairs as (select distinct seg.office_id, seg.owner_user_id from seg),
  allowed as (
    select pairs.office_id, pairs.owner_user_id from pairs
    where exists (
      select 1 from unnest(p_permission_keys) k
      where ledger.segment_visible(p_actor_user_id, k, p_tenant_id, pairs.office_id, pairs.owner_user_id,
        p_workspace_membership_id)
    )
  )
  select seg.* from seg
  join allowed on allowed.office_id = seg.office_id and allowed.owner_user_id = seg.owner_user_id;
$$;

-- Per network → currency → pocket. p_account_ids limits to visible segments
-- (null = every segment of the wallet, the owner's own view).
create function ledger.wallet_networks(
  p_wallet_id uuid,
  p_tenant_id uuid default null,
  p_account_ids uuid[] default null
)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with wallet_owner as (select w.owner_user_id from ledger.wallets w where w.id = p_wallet_id),
  seg as (
    select b.* from ledger.balances b
    where b.wallet_id = p_wallet_id
      and (p_tenant_id is null or b.tenant_id = p_tenant_id)
      and (p_account_ids is null or b.account_id = any (p_account_ids))
  ),
  networks as (
    select seg.tenant_id from seg
    union
    select m.tenant_id from org.memberships m, wallet_owner
    where p_account_ids is null and m.user_id = wallet_owner.owner_user_id and m.status = 'active'
      and m.role <> 'president_team_member' and (p_tenant_id is null or m.tenant_id = p_tenant_id)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'tenantId', t.id,
    'name', t.name,
    'status', t.status,
    'activeMember', exists (
      select 1 from org.memberships m, wallet_owner
      where m.tenant_id = t.id and m.user_id = wallet_owner.owner_user_id and m.status = 'active'
        and m.role <> 'president_team_member'),
    'pockets', coalesce((
      select jsonb_agg(jsonb_build_object('pocketId', p.id, 'name', p.name, 'kind', p.kind, 'status', p.status)
        order by p.sort_order, p.id)
      from ledger.pockets p
      where p.tenant_id = t.id and (p.status = 'active' or exists (select 1 from seg where seg.pocket_id = p.id))
    ), '[]'::jsonb),
    'currencies', coalesce((
      select jsonb_agg(jsonb_build_object(
        'currency', c.currency,
        'posted', ledger.money(c.posted, c.currency),
        'reserved', ledger.money(c.reserved, c.currency),
        'available', ledger.money(c.posted - c.reserved, c.currency),
        'pockets', (
          select jsonb_agg(jsonb_build_object(
            'pocketId', s.pocket_id,
            'posted', ledger.money(s.posted, c.currency),
            'reserved', ledger.money(s.reserved, c.currency),
            'available', ledger.money(s.posted - s.reserved, c.currency)
          ) order by p.sort_order, p.id)
          from (select seg.pocket_id, sum(seg.posted) as posted, sum(seg.reserved) as reserved
                from seg where seg.tenant_id = t.id and seg.currency = c.currency group by seg.pocket_id) s
          join ledger.pockets p on p.id = s.pocket_id
        )
      ) order by c.currency)
      from (select seg.currency, sum(seg.posted) as posted, sum(seg.reserved) as reserved
            from seg where seg.tenant_id = t.id group by seg.currency) c
    ), '[]'::jsonb)
  ) order by t.name, t.id), '[]'::jsonb)
  from networks n
  join org.tenants t on t.id = n.tenant_id;
$$;

create function ledger.date_filter(p_value text, p_field text)
returns date
language plpgsql
set search_path = ''
as $$
begin
  if p_value is null then
    return null;
  end if;
  if p_value !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', p_field));
  end if;
  begin
    return p_value::date;
  exception when others then
    perform identity.fail('validation_error', jsonb_build_object('field', p_field));
  end;
  return null;
end;
$$;

-- Signed per-currency movements of one wallet, newest first.
create function ledger.activity(
  p_wallet_id uuid,
  p_tenant_id uuid,
  p_account_ids uuid[],
  p_currency text,
  p_pocket_id uuid,
  p_direction text,
  p_type text,
  p_from text,
  p_to text,
  p_cursor text,
  p_limit int
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  page_size int;
  after jsonb;
  after_at timestamptz;
  after_id uuid;
  from_date date;
  to_date date;
  rows jsonb;
begin
  if p_currency is not null and p_currency !~ '^[A-Z]{3}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'currency'));
  end if;
  if p_direction is not null and p_direction not in ('in', 'out') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'direction'));
  end if;
  if p_type is not null and p_type not in ('income') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'type'));
  end if;
  from_date := ledger.date_filter(p_from, 'from');
  to_date := ledger.date_filter(p_to, 'to');
  page_size := org.page_limit(p_limit);
  after := org.decode_cursor(p_cursor);
  if after is not null then
    begin
      after_at := (after->>'s')::timestamptz;
      after_id := (after->>'id')::uuid;
    exception when others then
      perform identity.fail('validation_error', jsonb_build_object('field', 'cursor'));
    end;
    if after_at is null or after_id is null or after->>'c' is null then
      perform identity.fail('validation_error', jsonb_build_object('field', 'cursor'));
    end if;
  end if;

  select coalesce(jsonb_agg(item order by n), '[]'::jsonb) into rows
  from (
    select row_number() over (order by l.posted_at desc, l.id desc, l.currency desc) as n,
      jsonb_build_object(
        'transactionId', l.id,
        'reference', l.reference,
        'type', l.type,
        'postedAt', l.posted_at,
        'tenantId', l.tenant_id,
        'currency', l.currency,
        'amount', ledger.money(l.amount, l.currency),
        '_s', to_char(l.posted_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
      ) as item
    from (
      select t.id, t.reference, t.type, t.posted_at, t.tenant_id, j.currency, sum(p.amount) as amount
      from ledger.transactions t
      join ledger.journals j on j.transaction_id = t.id
      join ledger.postings p on p.journal_id = j.id
      join ledger.accounts a on a.id = p.account_id
      where t.wallet_id = p_wallet_id and a.wallet_id = p_wallet_id
        and (p_tenant_id is null or t.tenant_id = p_tenant_id)
        and (p_account_ids is null or a.id = any (p_account_ids))
        and (p_currency is null or j.currency = p_currency)
        and (p_pocket_id is null or a.pocket_id = p_pocket_id)
        and (p_type is null or t.type = p_type)
        and (from_date is null or t.posted_at >= from_date::timestamp at time zone 'UTC')
        and (to_date is null or t.posted_at < (to_date + 1)::timestamp at time zone 'UTC')
      group by t.id, t.reference, t.type, t.posted_at, t.tenant_id, j.currency
    ) l
    where (p_direction is null or (p_direction = 'in' and l.amount > 0) or (p_direction = 'out' and l.amount < 0))
      and (after is null or (l.posted_at, l.id, l.currency) < (after_at, after_id, after->>'c'))
    order by l.posted_at desc, l.id desc, l.currency desc
    limit page_size + 1
  ) page;

  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(e - '_s' order by x.n) from jsonb_array_elements(rows) with ordinality as x (e, n)
                       where x.n <= page_size), '[]'::jsonb),
    'nextCursor', case when jsonb_array_length(rows) > page_size then org.encode_cursor(jsonb_build_object(
      's', rows->(page_size - 1)->>'_s',
      'id', rows->(page_size - 1)->>'transactionId',
      'c', rows->(page_size - 1)->>'currency')) end
  );
end;
$$;

-- One transaction as seen by a wallet owner (p_account_ids null) or a leader
-- (only the segments they may see).
create function ledger.transaction_json(p_transaction_id uuid, p_account_ids uuid[] default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'transactionId', t.id,
    'reference', t.reference,
    'type', t.type,
    'postedAt', t.posted_at,
    'tenant', jsonb_build_object('id', tn.id, 'name', tn.name),
    'office', jsonb_build_object('id', o.id, 'name', o.name),
    'membershipId', t.membership_id,
    'journals', (
      select jsonb_agg(jsonb_build_object(
        'currency', j.currency,
        'lines', (
          select jsonb_agg(jsonb_build_object(
            'pocketId', a.pocket_id,
            'pocket', pk.name,
            'amount', ledger.money(p.amount, j.currency)
          ) order by pk.sort_order, pk.id)
          from ledger.postings p
          join ledger.accounts a on a.id = p.account_id
          join ledger.pockets pk on pk.id = a.pocket_id
          where p.journal_id = j.id and a.class = 'member_value'
            and (p_account_ids is null or a.id = any (p_account_ids))
        )
      ) order by j.entry_no)
      from ledger.journals j where j.transaction_id = t.id
    ),
    'income', (
      select jsonb_build_object(
        'incomeId', i.id,
        'source', i.source,
        'receivedOn', i.received_on,
        'providerReference', i.provider_reference,
        'notes', i.notes,
        'currency', i.currency,
        'amount', ledger.money(i.amount, i.currency),
        'fee', case when i.fee_amount is not null then jsonb_build_object(
          'amount', ledger.money(i.fee_amount, i.fee_currency), 'currency', i.fee_currency) end,
        'allocations', (
          select jsonb_agg(jsonb_build_object(
            'pocketId', al.pocket_id, 'pocket', al.pocket_name, 'basisPoints', al.basis_points,
            'amount', ledger.money(al.amount, i.currency)
          ) order by al.sort_order, al.pocket_id)
          from finance.income_allocations al where al.income_id = i.id
        ),
        'receipts', coalesce((
          select jsonb_agg(jsonb_build_object(
            'evidenceId', f.id, 'name', f.declared_name, 'mimeType', f.mime, 'size', f.size
          ) order by f.created_at, f.id)
          from evidence.files f where f.attached_type = 'income' and f.attached_id = i.id
        ), '[]'::jsonb)
      )
      from finance.income_records i where i.transaction_id = t.id
    )
  )
  from ledger.transactions t
  join org.tenants tn on tn.id = t.tenant_id
  join org.offices o on o.id = t.office_id
  where t.id = p_transaction_id;
$$;

-- ── Own wallet (decision 21) ──────────────────────────────────────────────

create function api.my_wallet(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet_id uuid;
begin
  perform identity.require_session(p_user_id, p_session_id);
  v_wallet_id := ledger.require_wallet(p_user_id);
  return jsonb_build_object('walletId', v_wallet_id, 'networks', ledger.wallet_networks(v_wallet_id));
end;
$$;

create function api.my_activity(
  p_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid default null,
  p_currency text default null,
  p_pocket_id uuid default null,
  p_direction text default null,
  p_type text default null,
  p_from text default null,
  p_to text default null,
  p_cursor text default null,
  p_limit int default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet_id uuid;
begin
  perform identity.require_session(p_user_id, p_session_id);
  v_wallet_id := ledger.require_wallet(p_user_id);
  return ledger.activity(v_wallet_id, p_tenant_id, null, p_currency, p_pocket_id, p_direction, p_type,
    p_from, p_to, p_cursor, p_limit);
end;
$$;

create function api.my_transaction(p_user_id uuid, p_session_id uuid, p_transaction_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet_id uuid;
begin
  perform identity.require_session(p_user_id, p_session_id);
  v_wallet_id := ledger.require_wallet(p_user_id);
  if not exists (select 1 from ledger.transactions where id = p_transaction_id and wallet_id = v_wallet_id) then
    perform identity.fail('not_found');
  end if;
  return ledger.transaction_json(p_transaction_id);
end;
$$;

create function api.ledger_currencies(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  return coalesce((
    select jsonb_agg(jsonb_build_object('code', c.code, 'scale', c.scale) order by c.code)
    from ledger.currencies c where c.active
  ), '[]'::jsonb);
end;
$$;

-- ── Managed wallets (W-07) ────────────────────────────────────────────────

create function api.list_managed_wallets(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_office_id uuid default null,
  p_query text default null,
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
  page_size int;
  after jsonb;
  pattern text;
  rows jsonb;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  if p_office_id is not null then
    perform org.office_in_tenant(workspace.tenant_id, p_office_id);
  end if;
  if p_query is not null and (length(btrim(p_query)) = 0 or length(p_query) > 100) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'q'));
  end if;
  page_size := org.page_limit(p_limit);
  after := org.decode_cursor(p_cursor);
  pattern := '%' || replace(replace(replace(btrim(p_query), '\', '\\'), '%', '\%'), '_', '\_') || '%';

  select coalesce(jsonb_agg(item order by item->'person'->>'uid'), '[]'::jsonb) into rows
  from (
    select jsonb_build_object(
      'walletId', v.wallet_id,
      'person', org.person(v.owner_user_id),
      'currencies', (
        select jsonb_agg(jsonb_build_object(
          'currency', c.currency,
          'posted', ledger.money(c.posted, c.currency),
          'reserved', ledger.money(c.reserved, c.currency),
          'available', ledger.money(c.posted - c.reserved, c.currency)
        ) order by c.currency)
        from (select s.currency, sum(s.posted) as posted, sum(s.reserved) as reserved
              from unnest(v.segments) s group by s.currency) c
      )
    ) as item
    from (
      select s.wallet_id, s.owner_user_id, a.uid, array_agg(s) as segments
      from ledger.visible_segments(p_user_id, workspace.id, workspace.tenant_id, array['view_managed_wallets'],
        null, p_office_id) s
      join identity.accounts a on a.user_id = s.owner_user_id
      left join identity.profiles pr on pr.user_id = s.owner_user_id
      where (p_query is null or a.uid ilike pattern or pr.display_name ilike pattern
             or concat_ws(' ', pr.first_name, pr.last_name) ilike pattern)
        and (after is null or a.uid > after->>'uid')
      group by s.wallet_id, s.owner_user_id, a.uid
      order by a.uid
      limit page_size + 1
    ) v
  ) page;

  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(e) from jsonb_array_elements(rows) with ordinality as x (e, n) where n <= page_size), '[]'::jsonb),
    'nextCursor', case when jsonb_array_length(rows) > page_size
      then org.encode_cursor(jsonb_build_object('uid', rows->(page_size - 1)->'person'->>'uid')) end
  );
end;
$$;

-- Visible segment ids of one wallet in the workspace tenant, or not_found.
create function ledger.require_managed_accounts(p_user_id uuid, p_workspace org.memberships, p_wallet_id uuid)
returns uuid[]
language plpgsql
set search_path = ''
as $$
declare
  ids uuid[];
begin
  select array_agg(s.account_id) into ids
  from ledger.visible_segments(p_user_id, p_workspace.id, p_workspace.tenant_id, array['view_managed_wallets'],
    p_wallet_id, null) s;
  if ids is null then
    perform identity.fail('not_found');
  end if;
  return ids;
end;
$$;

create function api.managed_wallet(p_user_id uuid, p_session_id uuid, p_membership_id uuid, p_wallet_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  ids uuid[];
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  ids := ledger.require_managed_accounts(p_user_id, workspace, p_wallet_id);
  return jsonb_build_object(
    'walletId', p_wallet_id,
    'person', (select org.person(w.owner_user_id) from ledger.wallets w where w.id = p_wallet_id),
    'networks', ledger.wallet_networks(p_wallet_id, workspace.tenant_id, ids)
  );
end;
$$;

create function api.managed_wallet_activity(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_wallet_id uuid,
  p_currency text default null,
  p_pocket_id uuid default null,
  p_direction text default null,
  p_type text default null,
  p_from text default null,
  p_to text default null,
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
  ids uuid[];
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  ids := ledger.require_managed_accounts(p_user_id, workspace, p_wallet_id);
  return ledger.activity(p_wallet_id, workspace.tenant_id, ids, p_currency, p_pocket_id, p_direction, p_type,
    p_from, p_to, p_cursor, p_limit);
end;
$$;

create function api.managed_transaction(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_wallet_id uuid,
  p_transaction_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  ids uuid[];
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  ids := ledger.require_managed_accounts(p_user_id, workspace, p_wallet_id);
  if not exists (
    select 1 from ledger.transactions t
    join ledger.journals j on j.transaction_id = t.id
    join ledger.postings p on p.journal_id = j.id
    where t.id = p_transaction_id and t.wallet_id = p_wallet_id and t.tenant_id = workspace.tenant_id
      and p.account_id = any (ids)
  ) then
    perform identity.fail('not_found');
  end if;
  return ledger.transaction_json(p_transaction_id, ids);
end;
$$;

-- ── Office subtree totals (W-05, W-07) ────────────────────────────────────

create function api.office_totals(p_user_id uuid, p_session_id uuid, p_membership_id uuid, p_office_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  office org.offices;
  permissions constant text[] := array['view_managed_wallets', 'view_scoped_financial_reports'];
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  office := org.office_in_tenant(workspace.tenant_id, p_office_id);
  if not (authz.decide(p_user_id, permissions[1], workspace.tenant_id, office.id, null, workspace.id)->>'allowed')::boolean
    and not (authz.decide(p_user_id, permissions[2], workspace.tenant_id, office.id, null, workspace.id)->>'allowed')::boolean then
    perform identity.fail('authorization_denied');
  end if;

  return (
    with seg as (
      select b.* from org.office_closure c
      join ledger.balances b on b.office_id = c.descendant_id
      where c.ancestor_id = office.id
    ),
    visible as (
      select * from ledger.visible_segments(p_user_id, workspace.id, workspace.tenant_id, permissions, null, office.id)
    ),
    hidden as (select * from seg where seg.account_id not in (select visible.account_id from visible))
    select jsonb_build_object(
      'officeId', office.id,
      'currencies', coalesce((
        select jsonb_agg(jsonb_build_object(
          'currency', c.currency,
          'posted', ledger.money(c.posted, c.currency),
          'reserved', ledger.money(c.reserved, c.currency),
          'available', ledger.money(c.posted - c.reserved, c.currency),
          'pockets', (
            select jsonb_agg(jsonb_build_object(
              'pocketId', s.pocket_id,
              'name', p.name,
              'posted', ledger.money(s.posted, c.currency),
              'reserved', ledger.money(s.reserved, c.currency),
              'available', ledger.money(s.posted - s.reserved, c.currency)
            ) order by p.sort_order, p.id)
            from (select v.pocket_id, sum(v.posted) as posted, sum(v.reserved) as reserved
                  from visible v where v.currency = c.currency group by v.pocket_id) s
            join ledger.pockets p on p.id = s.pocket_id
          )
        ) order by c.currency)
        from (select v.currency, sum(v.posted) as posted, sum(v.reserved) as reserved
              from visible v group by v.currency) c
      ), '[]'::jsonb),
      'distinctMembers', (select count(distinct v.owner_user_id) from visible v),
      'segments', (select count(*) from visible),
      'excluded', jsonb_build_object(
        'offices', (select count(distinct h.office_id) from hidden h),
        'members', (select count(distinct h.owner_user_id) from hidden h)
      )
    )
  );
end;
$$;
