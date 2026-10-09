-- Blueprint 12 — conversions, adjustments, returned funds and reversals in
-- activity and transaction detail; one evidence-review queue for payouts and
-- entries (W-11); the payout fix that keeps its receipt (Paper U03).

create index entries_transaction_idx on finance.entries (transaction_id) where transaction_id is not null;

-- ── Payout fix keeps the receipt (U03) ────────────────────────────────────

-- Attaches the receipt only the first time it is used.
create or replace function finance.add_revision(
  p_payout_id uuid,
  p_revision int,
  p_facts jsonb,
  p_evidence_id uuid,
  p_user_id uuid,
  p_key text
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_revision_id uuid;
begin
  insert into finance.payout_revisions (payout_id, revision, amount, fee_amount, paid_on, bank_reference, notes,
    evidence_id, submitted_by, idempotency_key)
  values (p_payout_id, p_revision, (p_facts->>'amount')::numeric, (p_facts->>'fee')::numeric,
    (p_facts->>'paidOn')::date, p_facts->>'bankReference', p_facts->>'notes', p_evidence_id, p_user_id, p_key)
  returning id into v_revision_id;
  update evidence.files set status = 'attached', attached_type = 'payout', attached_id = v_revision_id
  where id = p_evidence_id and status = 'finalized';
  insert into finance.payout_checks (payout_id, revision_id, next_attempt_at)
  values (p_payout_id, v_revision_id, now());
  return v_revision_id;
end;
$$;

-- The one correction (E-02). Without a new receipt the first record's receipt
-- is checked again against the corrected facts.
create or replace function api.correct_payout(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_payout_id uuid,
  p_amount text,
  p_fee_amount text,
  p_paid_on text,
  p_bank_reference text,
  p_notes text,
  p_evidence_id uuid,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  w finance.withdrawals;
  payout finance.payouts;
  facts jsonb;
  request jsonb;
  replayed jsonb;
  v_evidence uuid;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  select * into payout from finance.payouts where id = p_payout_id;
  if payout.id is null then
    perform identity.fail('not_found');
  end if;
  w := finance.withdrawal_in(workspace.tenant_id, payout.withdrawal_id);
  perform finance.require_payout_actor(p_user_id, workspace, w);
  facts := finance.payout_facts(w, p_amount, p_fee_amount, p_paid_on, p_bank_reference, p_notes);

  request := facts || jsonb_build_object('payoutId', payout.id, 'evidenceId', p_evidence_id);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'correct_payout', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into w from finance.withdrawals where id = w.id for update;
  select * into payout from finance.payouts where id = payout.id for update;
  if w.status <> 'approved' or payout.status <> 'correction_required' or payout.revision <> 1 then
    perform identity.fail('conflict', jsonb_build_object('reason', 'payout_state', 'status', payout.status));
  end if;
  if p_evidence_id is null then
    select evidence_id into v_evidence from finance.payout_revisions where payout_id = payout.id and revision = 1;
  else
    v_evidence := (finance.take_receipt(p_user_id, w, p_evidence_id, p_idempotency_key)).id;
  end if;
  update finance.payouts set status = 'verifying', revision = 2 where id = payout.id;
  perform finance.add_revision(payout.id, 2, facts, v_evidence, p_user_id, p_idempotency_key);

  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'payout.corrected', 'payout', payout.id::text,
    p_safe_after => jsonb_build_object('reference', w.reference, 'amount', facts->'amount', 'fee', facts->'fee',
      'paidOn', facts->'paidOn', 'revision', 2, 'newReceipt', p_evidence_id is not null),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'correct_payout', request,
    finance.withdrawal_json(w.id, p_user_id, workspace.id));
end;
$$;

-- ── Activity and detail ───────────────────────────────────────────────────

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
      rv.link as reversal,
      coalesce(i.source, wd.bank_name || ' •• ' || wd.account_last4, sp.name || ' → ' || dp.name,
        case en.kind
          when 'conversion' then en.currency || ' → ' || en.destination_currency
          when 'adjustment' then en.reason
          when 'returned_funds' then en.provider
        end,
        case when m.type = 'reversal' then 'Reverses ' || ot.reference end) as title,
      pt.amount as moved_amount,
      to_char(m.posted_at at time zone zone, 'YYYY-MM') as month
    from moves m
    left join finance.income_records i on i.transaction_id = m.id
    left join finance.withdrawals wd on wd.transaction_id = m.id
    left join finance.pocket_transfers pt on pt.transaction_id = m.id
    left join ledger.pockets sp on sp.id = pt.source_pocket_id
    left join ledger.pockets dp on dp.id = pt.destination_pocket_id
    left join finance.entries en on en.transaction_id = m.id
    left join finance.reversals rr on rr.transaction_id = m.id
    left join ledger.transactions ot on ot.id = rr.original_transaction_id
    cross join lateral (select ledger.reversed_by(m.id) as link) rv
    where (p_direction is null or (p_direction = 'in' and m.amount > 0) or (p_direction = 'out' and m.amount < 0))
      and (query_text is null
        or (length(query_reference) >= 3 and replace(m.reference, '-', '') like '%' || query_reference || '%')
        or (length(query_reference) >= 3 and replace(ot.reference, '-', '') like '%' || query_reference || '%')
        or i.source ilike query_pattern
        or i.provider_reference ilike query_pattern
        or wd.bank_name ilike query_pattern
        or en.provider ilike query_pattern
        or en.reason ilike query_pattern
        or en.external_reference ilike query_pattern
        or (query_amount is not null and pt.amount = query_amount)
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
        'reversedAt', s.reversal->'postedAt',
        'movedAmount', case when s.moved_amount is not null then ledger.money(s.moved_amount, s.currency) end
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
    ),
    'withdrawal', (
      select jsonb_build_object(
        'withdrawalId', w.id,
        'requested', ledger.money(w.amount, w.currency),
        'sent', ledger.money(r.amount, w.currency),
        'fee', case when r.fee_amount is not null then ledger.money(r.fee_amount, w.currency) end,
        'paidOn', r.paid_on,
        'bankReference', r.bank_reference,
        'destination', jsonb_build_object('bankName', w.bank_name, 'accountLast4', w.account_last4,
          'accountNumberMasked', '•••• ' || w.account_last4, 'accountName', w.account_name),
        'approvedBy', org.person(w.approved_by)
      )
      from finance.withdrawals w
      join finance.payouts p on p.withdrawal_id = w.id and p.status = 'completed'
      join finance.payout_revisions r on r.payout_id = p.id and r.revision = p.revision
      where w.transaction_id = t.id
    ),
    'pocketTransfer', (
      select jsonb_build_object(
        'transferId', pt.id,
        'amount', ledger.money(pt.amount, pt.currency),
        'from', jsonb_build_object('pocketId', sp.id, 'name', sp.name),
        'to', jsonb_build_object('pocketId', dp.id, 'name', dp.name),
        'requestedBy', org.person(pt.requested_by),
        'approvedBy', org.person(pt.decided_by)
      )
      from finance.pocket_transfers pt
      join ledger.pockets sp on sp.id = pt.source_pocket_id
      join ledger.pockets dp on dp.id = pt.destination_pocket_id
      where pt.transaction_id = t.id
    ),
    'entry', (
      select finance.entry_json(e.id) - 'evidence' - 'review'
        || jsonb_build_object('reviewedBy', org.person(e.reviewer_user_id))
      from finance.entries e where e.transaction_id = t.id
    ),
    'reversal', (
      select jsonb_build_object('category', r.category, 'note', r.note, 'reversedBy', org.person(r.reversed_by))
      from finance.reversals r where r.transaction_id = t.id
    )
  )
  from ledger.transactions t
  join org.tenants tn on tn.id = t.tenant_id
  join org.offices o on o.id = t.office_id
  where t.id = p_transaction_id;
$$;

-- ── One review queue (W-11): payouts and entries ──────────────────────────

create or replace function api.review_queue(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_tab text,
  p_cursor text,
  p_limit int
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
  after_at timestamptz;
  after_id uuid;
  result jsonb;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  if p_tab is null or p_tab not in ('assigned', 'cleared', 'rejected', 'all') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'tab'));
  end if;
  if not exists (
    select 1 from authz.reviewer_assignments ra
    where ra.membership_id = workspace.id and ra.ended_at is null
  ) then
    perform identity.fail('authorization_denied');
  end if;
  page_size := org.page_limit(p_limit);
  after := org.decode_cursor(p_cursor);
  if after is not null then
    begin
      after_at := (after->>'s')::timestamptz;
      after_id := (after->>'id')::uuid;
    exception when others then
      perform identity.fail('validation_error', jsonb_build_object('field', 'cursor'));
    end;
  end if;

  with visible as (
    select p.id, 'payout'::text as kind, p.status = 'needs_review' as open, p.created_at, v.decision
    from finance.payouts p
    join finance.withdrawals w on w.id = p.withdrawal_id
    left join finance.payout_reviews v on v.payout_id = p.id
    where w.tenant_id = workspace.tenant_id
      and (p.status = 'needs_review' or v.payout_id is not null)
      and w.owner_user_id <> p_user_id
      and not exists (select 1 from finance.payout_revisions r where r.payout_id = p.id and r.submitted_by = p_user_id)
      and finance.can(p_user_id, 'review_financial_evidence', w.tenant_id, w.office_id, w.owner_user_id, workspace.id)
    union all
    select e.id, e.kind, e.status = 'needs_review', e.created_at,
      case e.status when 'posted' then 'clear' when 'rejected' then 'reject' end
    from finance.entries e
    where e.tenant_id = workspace.tenant_id
      and e.owner_user_id <> p_user_id
      and e.submitted_by <> p_user_id
      and finance.can(p_user_id, 'review_financial_evidence', e.tenant_id, e.office_id, e.owner_user_id, workspace.id)
  ),
  tabbed as (
    select * from visible
    where case p_tab
      when 'assigned' then open
      when 'cleared' then decision = 'clear'
      when 'rejected' then decision = 'reject'
      else true
    end
  ),
  page as (
    select t.id, t.kind, t.created_at, row_number() over (order by t.created_at desc, t.id desc) as n
    from tabbed t
    where after is null or (t.created_at, t.id) < (after_at, after_id)
    order by t.created_at desc, t.id desc
    limit page_size + 1
  )
  select jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(
        case when p.kind = 'payout' then finance.review_case_json(p.id, p_user_id, workspace.id)
             else finance.entry_case_json(p.id) end
        order by p.n)
      from page p where p.n <= page_size
    ), '[]'::jsonb),
    'nextCursor', (
      select org.encode_cursor(jsonb_build_object(
        's', to_char(p.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), 'id', p.id))
      from page p where p.n = page_size and exists (select 1 from page q where q.n > page_size)
    ),
    'counts', (
      select jsonb_build_object(
        'assigned', count(*) filter (where open),
        'cleared', count(*) filter (where decision = 'clear'),
        'rejected', count(*) filter (where decision = 'reject'),
        'all', count(*))
      from visible
    )
  ) into result;
  return result;
end;
$$;

-- A payout case or an entry case by id.
create or replace function api.review_case(p_user_id uuid, p_session_id uuid, p_membership_id uuid, p_payout_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  payout finance.payouts;
  w finance.withdrawals;
  e finance.entries;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  select * into payout from finance.payouts where id = p_payout_id;
  if payout.id is null then
    e := finance.entry_in(workspace.tenant_id, p_payout_id);
    perform finance.require_entry_reviewer(p_user_id, workspace, e);
    return finance.entry_case_json(e.id);
  end if;
  w := finance.withdrawal_in(workspace.tenant_id, payout.withdrawal_id);
  perform finance.require_reviewer(p_user_id, workspace, w, payout);
  return finance.review_case_json(payout.id, p_user_id, workspace.id);
end;
$$;

-- Every api function: service_role only.
do $$
declare
  fn regprocedure;
begin
  for fn in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end;
$$;
