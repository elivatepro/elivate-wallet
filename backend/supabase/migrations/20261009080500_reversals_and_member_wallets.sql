-- Blueprint 08 — owner decisions of 2026-10-08 (Paper "App — Screens v4"
-- Q01–Q05):
-- * Reversals appear both as their own row (REV, opposite sign) and as a
--   `reversed` status, with a link, on the original transaction (Q03). The
--   reversal slice (W-15) posts a ledger transaction of type `reversal` whose
--   metadata carries `reversesTransactionId`; this migration defines how
--   activity and detail read that link, so the reversal slice only has to post.
-- * Activity filters: type (income / reversal) and status (posted / reversed),
--   plus the filtered `total` for the mobile sheet's "Show N results".
-- * Member wallets (leader view): each row says whether the person is active
--   or suspended in this network; the list carries its people count and scope;
--   a wallet carries the person's memberships here for the Q05 header.

create index transactions_reverses_idx on ledger.transactions ((metadata->>'reversesTransactionId'))
  where metadata ? 'reversesTransactionId';

-- The reversal that points at a transaction, or null.
create function ledger.reversed_by(p_transaction_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('transactionId', r.id, 'reference', r.reference, 'postedAt', r.posted_at)
  from ledger.transactions r
  where r.metadata ? 'reversesTransactionId' and r.metadata->>'reversesTransactionId' = p_transaction_id::text
  order by r.posted_at, r.id
  limit 1;
$$;

create or replace function ledger.activity(
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
  p_limit int,
  p_query text default null,
  p_status text default null,
  p_tz text default null
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
  zone text;
  query_text text;
  query_pattern text;
  query_reference text;
  query_amount numeric;
  result jsonb;
begin
  if p_currency is not null and p_currency !~ '^[A-Z]{3}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'currency'));
  end if;
  if p_direction is not null and p_direction not in ('in', 'out') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'direction'));
  end if;
  if p_type is not null and p_type not in ('income', 'reversal') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'type'));
  end if;
  -- Durable statuses of ledger movements (owner decision 2026-10-08): a
  -- movement is `posted`, or `reversed` once a reversal points at it.
  if p_status is not null and p_status not in ('posted', 'reversed') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'status'));
  end if;
  if p_query is not null and (length(btrim(p_query)) = 0 or length(p_query) > 100) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'q'));
  end if;
  zone := ledger.time_zone(p_tz);
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

  query_text := btrim(p_query);
  query_pattern := '%' || replace(replace(replace(query_text, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  query_reference := upper(regexp_replace(coalesce(query_text, ''), '[^A-Za-z0-9]', '', 'g'));
  query_amount := ledger.search_amount(query_text);

  with moves as (
    select t.id, t.reference, t.type, t.posted_at, t.tenant_id, j.currency, sum(p.amount) as amount,
      count(distinct a.pocket_id) as pocket_count
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
      and (from_date is null or t.posted_at >= from_date::timestamp at time zone zone)
      and (to_date is null or t.posted_at < (to_date + 1)::timestamp at time zone zone)
    group by t.id, t.reference, t.type, t.posted_at, t.tenant_id, j.currency
  ),
  filtered as (
    select m.*, case when rv.link is null then 'posted' else 'reversed' end as status,
      rv.link as reversal, i.source as title,
      to_char(m.posted_at at time zone zone, 'YYYY-MM') as month
    from moves m
    left join finance.income_records i on i.transaction_id = m.id
    cross join lateral (select ledger.reversed_by(m.id) as link) rv
    where (p_direction is null or (p_direction = 'in' and m.amount > 0) or (p_direction = 'out' and m.amount < 0))
      and (query_text is null
        or (length(query_reference) >= 3 and replace(m.reference, '-', '') like '%' || query_reference || '%')
        or i.source ilike query_pattern
        or i.provider_reference ilike query_pattern
        or (query_amount is not null and abs(m.amount) = query_amount))
  ),
  shown_status as (select * from filtered where p_status is null or filtered.status = p_status),
  page as (
    select f.*, row_number() over (order by f.posted_at desc, f.id desc, f.currency desc) as n
    from shown_status f
    where after is null or (f.posted_at, f.id, f.currency) < (after_at, after_id, after->>'c')
    order by f.posted_at desc, f.id desc, f.currency desc
    limit page_size + 1
  ),
  shown as (select * from page where n <= page_size)
  select jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'transactionId', s.id,
        'reference', s.reference,
        'type', s.type,
        'status', s.status,
        'title', s.title,
        'postedAt', s.posted_at,
        'tenantId', s.tenant_id,
        'currency', s.currency,
        'amount', ledger.money(s.amount, s.currency),
        'pocketCount', s.pocket_count,
        'reversedAt', s.reversal->'postedAt'
      ) order by s.n)
      from shown s
    ), '[]'::jsonb),
    'nextCursor', (
      select org.encode_cursor(jsonb_build_object(
        's', to_char(s.posted_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'id', s.id,
        'c', s.currency))
      from shown s
      where s.n = page_size and exists (select 1 from page where page.n > page_size)
    ),
    'months', coalesce((
      select jsonb_agg(jsonb_build_object('month', mo.month, 'currencies', mo.currencies) order by mo.month desc)
      from (
        select c.month, jsonb_agg(jsonb_build_object(
          'currency', c.currency,
          'in', ledger.money(c.money_in, c.currency),
          'out', ledger.money(c.money_out, c.currency)
        ) order by c.currency) as currencies
        from (
          select f.month, f.currency,
            coalesce(sum(f.amount) filter (where f.amount > 0), 0) as money_in,
            coalesce(sum(f.amount) filter (where f.amount < 0), 0) as money_out
          from shown_status f
          where f.month in (select shown.month from shown)
          group by f.month, f.currency
        ) c
        group by c.month
      ) mo
    ), '[]'::jsonb),
    'total', (select count(*) from shown_status),
    'timeZone', zone
  ) into result;

  return result;
end;
$$;

create or replace function ledger.transaction_json(p_transaction_id uuid, p_account_ids uuid[] default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'transactionId', t.id,
    'reference', t.reference,
    'type', t.type,
    'status', case when ledger.reversed_by(t.id) is null then 'posted' else 'reversed' end,
    'reversedBy', ledger.reversed_by(t.id),
    'reverses', (
      select jsonb_build_object('transactionId', o.id, 'reference', o.reference, 'postedAt', o.posted_at)
      from ledger.transactions o
      where t.type = 'reversal' and o.id::text = t.metadata->>'reversesTransactionId'
    ),
    'postedAt', t.posted_at,
    'recordedBy', org.person(t.actor_user_id),
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

create or replace function api.list_managed_wallets(
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
  people int;
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

  with vis as (
    select * from ledger.visible_segments(p_user_id, workspace.id, workspace.tenant_id, array['view_managed_wallets'],
      null, p_office_id)
  ),
  matched as (
    select s.wallet_id, s.owner_user_id, a.uid
    from vis s
    join identity.accounts a on a.user_id = s.owner_user_id
    left join identity.profiles pr on pr.user_id = s.owner_user_id
    where (p_query is null or a.uid ilike pattern or pr.display_name ilike pattern
           or concat_ws(' ', pr.first_name, pr.last_name) ilike pattern)
      and (after is null or a.uid > after->>'uid')
    group by s.wallet_id, s.owner_user_id, a.uid
    order by a.uid
    limit page_size + 1
  )
  select
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'walletId', v.wallet_id,
        'person', org.person(v.owner_user_id),
        'status', (
          select case
            when bool_or(m.status = 'active') then 'active'
            when bool_or(m.status = 'suspended') then 'suspended'
            else 'ended' end
          from org.memberships m
          where m.tenant_id = workspace.tenant_id and m.user_id = v.owner_user_id
            and m.role <> 'president_team_member'
        ),
        'currencies', (
          select jsonb_agg(jsonb_build_object(
            'currency', c.currency,
            'posted', ledger.money(c.posted, c.currency),
            'reserved', ledger.money(c.reserved, c.currency),
            'available', ledger.money(c.posted - c.reserved, c.currency)
          ) order by c.currency)
          from (select s.currency, sum(s.posted) as posted, sum(s.reserved) as reserved
                from vis s where s.wallet_id = v.wallet_id group by s.currency) c
        )
      ) order by v.uid)
      from matched v
    ), '[]'::jsonb),
    (select count(distinct vis.owner_user_id) from vis)
  into rows, people;

  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(e) from jsonb_array_elements(rows) with ordinality as x (e, n) where n <= page_size), '[]'::jsonb),
    'nextCursor', case when jsonb_array_length(rows) > page_size
      then org.encode_cursor(jsonb_build_object('uid', rows->(page_size - 1)->'person'->>'uid')) end,
    'people', people,
    'scope', jsonb_build_object(
      'kind', case when coalesce(p_office_id, workspace.office_id) is null then 'network' else 'office' end,
      'name', coalesce(
        (select o.name from org.offices o where o.id = coalesce(p_office_id, workspace.office_id)),
        (select t.name from org.tenants t where t.id = workspace.tenant_id))
    )
  );
end;
$$;

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
      select jsonb_agg(jsonb_build_object('role', m.role, 'officeName', o.name, 'status', m.status)
        order by (m.status = 'active') desc, m.started_at desc)
      from org.memberships m
      join org.offices o on o.id = m.office_id
      where m.tenant_id = workspace.tenant_id and m.user_id = owner and m.status <> 'ended'
        and m.role <> 'president_team_member'
    ), '[]'::jsonb),
    'networks', ledger.wallet_networks(p_wallet_id, workspace.tenant_id, ids)
  );
end;
$$;
