-- Blueprint 08 — B4.2: activity search, durable status filter and month
-- summaries (W-07 Activity), and the extra facts the detail panel shows.
-- Everything stays per currency; month summaries come from the full filtered
-- set (an aggregate read), never from the rows of one page.

drop function api.my_activity(uuid, uuid, uuid, text, uuid, text, text, text, text, text, int);
drop function api.managed_wallet_activity(uuid, uuid, uuid, uuid, text, uuid, text, text, text, text, text, int);
drop function ledger.activity(uuid, uuid, uuid[], text, uuid, text, text, text, text, text, int);

-- A validated IANA time zone name, or UTC when none is given. Dates and month
-- buckets use it; without it the existing inclusive UTC basis is kept.
create function ledger.time_zone(p_tz text)
returns text
language plpgsql
set search_path = ''
as $$
begin
  if p_tz is null then
    return 'UTC';
  end if;
  if length(p_tz) > 64 or not exists (select 1 from pg_catalog.pg_timezone_names where name = p_tz) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'tz'));
  end if;
  return p_tz;
end;
$$;

-- "₦180,000.00" / "180000" / "-48,000" → 180000.00; null when the text is not an amount.
create function ledger.search_amount(p_query text)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case when cleaned ~ '^[0-9]{1,20}(\.[0-9]{1,18})?$' then cleaned::numeric end
  from (select regexp_replace(p_query, '[₦$,\s+−-]', '', 'g') as cleaned) c;
$$;

-- Signed per-currency movements of one wallet, newest first, with the month
-- summaries (money in / money out per currency) of every month the page touches.
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
  if p_type is not null and p_type not in ('income') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'type'));
  end if;
  -- Durable statuses of ledger movements. Posted is the only one until
  -- reversals (W-15) land; later slices extend this list.
  if p_status is not null and p_status not in ('posted') then
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
    select m.*, 'posted'::text as status, i.source as title,
      to_char(m.posted_at at time zone zone, 'YYYY-MM') as month
    from moves m
    left join finance.income_records i on i.transaction_id = m.id
    where (p_direction is null or (p_direction = 'in' and m.amount > 0) or (p_direction = 'out' and m.amount < 0))
      and (p_status is null or p_status = 'posted')
      and (query_text is null
        or (length(query_reference) >= 3 and replace(m.reference, '-', '') like '%' || query_reference || '%')
        or i.source ilike query_pattern
        or i.provider_reference ilike query_pattern
        or (query_amount is not null and abs(m.amount) = query_amount))
  ),
  page as (
    select f.*, row_number() over (order by f.posted_at desc, f.id desc, f.currency desc) as n
    from filtered f
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
        'pocketCount', s.pocket_count
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
          from filtered f
          where f.month in (select shown.month from shown)
          group by f.month, f.currency
        ) c
        group by c.month
      ) mo
    ), '[]'::jsonb),
    'timeZone', zone
  ) into result;

  return result;
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
  p_limit int default null,
  p_query text default null,
  p_status text default null,
  p_tz text default null
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
    p_from, p_to, p_cursor, p_limit, p_query, p_status, p_tz);
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
  p_limit int default null,
  p_query text default null,
  p_status text default null,
  p_tz text default null
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
    p_from, p_to, p_cursor, p_limit, p_query, p_status, p_tz);
end;
$$;

-- Detail: adds the durable status, who recorded it and the network's pocket
-- order to Blueprint 04's shape (fields only added).
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
    'status', 'posted',
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

revoke all on function api.my_activity(uuid, uuid, uuid, text, uuid, text, text, text, text, text, int, text, text, text)
  from public, anon, authenticated;
grant execute on function api.my_activity(uuid, uuid, uuid, text, uuid, text, text, text, text, text, int, text, text, text)
  to service_role;
revoke all on function api.managed_wallet_activity(uuid, uuid, uuid, uuid, text, uuid, text, text, text, text, text, int, text, text, text)
  from public, anon, authenticated;
grant execute on function api.managed_wallet_activity(uuid, uuid, uuid, uuid, text, uuid, text, text, text, text, text, int, text, text, text)
  to service_role;
