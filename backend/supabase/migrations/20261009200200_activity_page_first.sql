-- Blueprint 20 — B3: activity pages first. ledger.activity used to aggregate
-- the whole wallet history (every posting, every title join, every reversal
-- lookup) before it applied the cursor, even for Home's five rows. Now:
--   * ledger.activity_rows walks ledger.transactions in the order of
--     transactions_wallet_idx (wallet_id, posted_at desc, id desc) from the
--     cursor, and computes the per-currency amounts, the title joins and
--     reversed_by per transaction only until it has `limit` rows. It runs as
--     a one-shot dynamic statement so the limit and the filters are planned
--     as constants every time (no generic plan over the whole history).
--   * The month summaries and the total (both over the whole filtered set)
--     are their own query, run only when the caller asks for them
--     (p_months, default true: every existing caller keeps its output).
-- Output, ordering, cursor format and amounts are unchanged; pgTAP 201
-- compares against the previous function.

drop function ledger.activity(uuid, uuid, uuid[], text, uuid, text, text, text, text, text, int, text, text, text);

-- One row per (transaction, currency) of a wallet, newest first, after the
-- (posted_at, id, currency) cursor, filtered exactly like the activity read.
-- p_limit null = every row.
create function ledger.activity_rows(
  p_wallet_id uuid,
  p_tenant_id uuid,
  p_account_ids uuid[],
  p_currency text,
  p_pocket_id uuid,
  p_direction text,
  p_type text,
  p_from_at timestamptz,
  p_to_at timestamptz,
  p_status text,
  p_query_text text,
  p_query_pattern text,
  p_query_reference text,
  p_query_amount numeric,
  p_zone text,
  p_after_at timestamptz,
  p_after_id uuid,
  p_after_currency text,
  p_limit int
)
returns table (
  id uuid,
  reference text,
  type text,
  posted_at timestamptz,
  tenant_id uuid,
  currency text,
  amount numeric,
  pocket_count bigint,
  status text,
  reversal jsonb,
  title text,
  moved_amount numeric,
  month text
)
language plpgsql
stable
set search_path = ''
as $$
begin
  return query execute $q$
    select t.id, t.reference::text, t.type::text, t.posted_at, t.tenant_id, m.currency::text, m.amount::numeric,
      m.pocket_count::bigint,
      (case when rv.link is null then 'posted' else 'reversed' end)::text,
      rv.link,
      coalesce(i.source, wd.bank_name || ' •• ' || wd.account_last4, sp.name || ' → ' || dp.name,
        case en.kind
          when 'conversion' then en.currency || ' → ' || en.destination_currency
          when 'adjustment' then en.reason
          when 'returned_funds' then en.provider
        end,
        case when t.type = 'reversal' then 'Reverses ' || ot.reference end)::text,
      pt.amount::numeric,
      to_char(t.posted_at at time zone $15, 'YYYY-MM')::text
    from ledger.transactions t
    cross join lateral (
      select j.currency, sum(p.amount) as amount, count(distinct a.pocket_id) as pocket_count
      from ledger.journals j
      join ledger.postings p on p.journal_id = j.id
      join ledger.accounts a on a.id = p.account_id
      where j.transaction_id = t.id and a.wallet_id = $1
        and ($3::uuid[] is null or a.id = any ($3::uuid[]))
        and ($4::text is null or j.currency = $4::text)
        and ($5::uuid is null or a.pocket_id = $5::uuid)
      group by j.currency
    ) m
    left join finance.income_records i on i.transaction_id = t.id
    left join finance.withdrawals wd on wd.transaction_id = t.id
    left join finance.pocket_transfers pt on pt.transaction_id = t.id
    left join ledger.pockets sp on sp.id = pt.source_pocket_id
    left join ledger.pockets dp on dp.id = pt.destination_pocket_id
    left join finance.entries en on en.transaction_id = t.id
    left join finance.reversals rr on rr.transaction_id = t.id
    left join ledger.transactions ot on ot.id = rr.original_transaction_id
    cross join lateral (select ledger.reversed_by(t.id) as link) rv
    where t.wallet_id = $1
      and ($2::uuid is null or t.tenant_id = $2::uuid)
      and ($7::text is null or t.type = $7::text)
      and ($8::timestamptz is null or t.posted_at >= $8::timestamptz)
      and ($9::timestamptz is null or t.posted_at < $9::timestamptz)
      -- The cursor: the transaction-level bound walks the index, the full
      -- (posted_at, id, currency) bound picks up within a transaction.
      and ($16::timestamptz is null or (t.posted_at, t.id) <= ($16::timestamptz, $17::uuid))
      and ($16::timestamptz is null or (t.posted_at, t.id, m.currency) < ($16::timestamptz, $17::uuid, $18::text))
      and ($6::text is null or ($6::text = 'in' and m.amount > 0) or ($6::text = 'out' and m.amount < 0))
      and ($11::text is null
        or (length($13::text) >= 3 and replace(t.reference, '-', '') like '%' || $13::text || '%')
        or (length($13::text) >= 3 and replace(ot.reference, '-', '') like '%' || $13::text || '%')
        or i.source ilike $12::text
        or i.provider_reference ilike $12::text
        or wd.bank_name ilike $12::text
        or en.provider ilike $12::text
        or en.reason ilike $12::text
        or en.external_reference ilike $12::text
        or ($14::numeric is not null and pt.amount = $14::numeric)
        or ($14::numeric is not null and abs(m.amount) = $14::numeric))
      and ($10::text is null or (case when rv.link is null then 'posted' else 'reversed' end) = $10::text)
    order by t.posted_at desc, t.id desc, m.currency desc
    limit $19
  $q$
  using p_wallet_id, p_tenant_id, p_account_ids, p_currency, p_pocket_id, p_direction, p_type, p_from_at, p_to_at,
    p_status, p_query_text, p_query_pattern, p_query_reference, p_query_amount, p_zone, p_after_at, p_after_id,
    p_after_currency, p_limit;
end;
$$;

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
  p_tz text default null,
  p_months boolean default true
)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  page_size int;
  after jsonb;
  after_at timestamptz;
  after_id uuid;
  from_date date;
  to_date date;
  from_at timestamptz;
  to_at timestamptz;
  zone text;
  query_text text;
  query_pattern text;
  query_reference text;
  query_amount numeric;
  items jsonb;
  next_cursor text;
  shown_months text[];
  months jsonb := '[]'::jsonb;
  total bigint;
begin
  if p_currency is not null and p_currency !~ '^[A-Z]{3}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'currency'));
  end if;
  if p_direction is not null and p_direction not in ('in', 'out') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'direction'));
  end if;
  if p_type is not null and p_type not in ('income', 'reversal', 'withdrawal', 'pocket_transfer', 'conversion',
                                           'adjustment', 'returned_funds') then
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
  if from_date is not null then
    from_at := from_date::timestamp at time zone zone;
  end if;
  if to_date is not null then
    to_at := (to_date + 1)::timestamp at time zone zone;
  end if;

  query_text := btrim(p_query);
  query_pattern := '%' || replace(replace(replace(query_text, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  query_reference := upper(regexp_replace(coalesce(query_text, ''), '[^A-Za-z0-9]', '', 'g'));
  query_amount := ledger.search_amount(query_text);

  -- The page: limit + 1 rows, the last one only says whether there is more.
  with page as (
    select r.*, row_number() over (order by r.posted_at desc, r.id desc, r.currency desc) as n
    from ledger.activity_rows(p_wallet_id, p_tenant_id, p_account_ids, p_currency, p_pocket_id, p_direction, p_type,
      from_at, to_at, p_status, query_text, query_pattern, query_reference, query_amount, zone,
      after_at, after_id, after->>'c', page_size + 1) r
  ),
  shown as (select * from page where n <= page_size)
  select
    coalesce((
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
        'reversedAt', s.reversal->'postedAt',
        'movedAmount', case when s.moved_amount is not null then ledger.money(s.moved_amount, s.currency) end
      ) order by s.n)
      from shown s
    ), '[]'::jsonb),
    (
      select org.encode_cursor(jsonb_build_object(
        's', to_char(s.posted_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'id', s.id,
        'c', s.currency))
      from shown s
      where s.n = page_size and exists (select 1 from page where page.n > page_size)
    ),
    (select array_agg(distinct s.month) from shown s)
  into items, next_cursor, shown_months;

  -- Month summaries (of the months on this page) and the total come from the
  -- whole filtered set, never from one page.
  if p_months then
    with filtered as (
      select r.month, r.currency, r.amount
      from ledger.activity_rows(p_wallet_id, p_tenant_id, p_account_ids, p_currency, p_pocket_id, p_direction,
        p_type, from_at, to_at, p_status, query_text, query_pattern, query_reference, query_amount, zone,
        null, null, null, null) r
    )
    select
      coalesce((
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
            where f.month = any (shown_months)
            group by f.month, f.currency
          ) c
          group by c.month
        ) mo
      ), '[]'::jsonb),
      (select count(*) from filtered)
    into months, total;
  end if;

  return jsonb_build_object(
    'items', items,
    'nextCursor', next_cursor,
    'months', months,
    'timeZone', zone
  ) || case when p_months then jsonb_build_object('total', total) else '{}'::jsonb end;
end;
$$;

revoke all on function ledger.activity_rows(uuid, uuid, uuid[], text, uuid, text, text, timestamptz, timestamptz, text,
  text, text, text, numeric, text, timestamptz, uuid, text, int) from public, anon, authenticated;
revoke all on function ledger.activity(uuid, uuid, uuid[], text, uuid, text, text, text, text, text, int, text, text,
  text, boolean) from public, anon, authenticated;
