-- Blueprint 15 — B2: statement and report figures. Postgres owns them: every
-- figure comes from posted ledger postings (opening = postings before the
-- period, closing = postings before the cut-off), reservations active at the
-- cut-off, and lifecycle timestamps. Order is always posted_at, then id, so
-- equal timestamps never skip or repeat a record. Money stays numeric here and
-- leaves as exact decimal strings.

-- ── Building blocks ───────────────────────────────────────────────────────

-- Net amount per transaction, owner and pocket over a set of member-value
-- accounts, for transactions posted in [p_from, p_to).
create function exports.lines(p_accounts uuid[], p_from timestamptz, p_to timestamptz)
returns table (transaction_id uuid, owner_user_id uuid, pocket_id uuid, amount numeric)
language sql
stable
set search_path = ''
as $$
  select t.id, a.owner_user_id, a.pocket_id, sum(p.amount)
  from ledger.accounts a
  join ledger.postings p on p.account_id = a.id
  join ledger.journals j on j.id = p.journal_id
  join ledger.transactions t on t.id = j.transaction_id
  where a.id = any (p_accounts) and a.class = 'member_value'
    and t.posted_at >= p_from and t.posted_at < p_to
  group by t.id, a.owner_user_id, a.pocket_id;
$$;

-- Posted balance of the accounts from postings strictly before p_at.
create function exports.balance_before(p_accounts uuid[], p_at timestamptz)
returns numeric
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(p.amount), 0)
  from ledger.postings p
  join ledger.journals j on j.id = p.journal_id
  join ledger.transactions t on t.id = j.transaction_id
  where p.account_id = any (p_accounts) and t.posted_at < p_at;
$$;

-- Reservations on the accounts that were active at the cut-off: created
-- before it and not settled before it. Each with its request and the status
-- the request had at that moment.
create function exports.pending_at(p_accounts uuid[], p_at timestamptz)
returns table (reservation_id uuid, owner_user_id uuid, pocket_id uuid, amount numeric, kind text,
               reference text, status text, created_at timestamptz)
language sql
stable
set search_path = ''
as $$
  select r.id, a.owner_user_id, a.pocket_id, r.amount, r.purpose,
    coalesce(w.reference, pt.reference, en.reference),
    case r.purpose
      when 'withdrawal' then case when w.approved_at is not null and w.approved_at < p_at then 'approved' else 'requested' end
      when 'pocket_transfer' then 'requested'
      else 'needs_review'
    end,
    r.created_at
  from ledger.reservations r
  join ledger.accounts a on a.id = r.account_id
  left join finance.withdrawals w on r.purpose = 'withdrawal' and w.reservation_id = r.id
  left join finance.pocket_transfers pt on r.purpose = 'pocket_transfer' and pt.reservation_id = r.id
  left join finance.entries en on r.purpose = 'conversion' and en.reservation_id = r.id
  where r.account_id = any (p_accounts) and r.created_at < p_at
    and (r.settled_at is null or r.settled_at >= p_at);
$$;

-- One transaction as a statement/report row. Relationships are as of the
-- cut-off: a reversal posted later does not mark the original reversed yet.
-- Safe fields only: no bank details, evidence, reasons or notes.
create function exports.txn_json(
  p_transaction_id uuid,
  p_currency text,
  p_net numeric,
  p_balance numeric,
  p_pockets jsonb,
  p_as_of timestamptz,
  p_member boolean
)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'transactionId', t.id,
    'reference', t.reference,
    'type', t.type,
    'postedAt', to_char(t.posted_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'date', to_char(t.posted_at at time zone exports.zone(), 'YYYY-MM-DD'),
    'time', to_char(t.posted_at at time zone exports.zone(), 'HH24:MI'),
    'office', o.name,
    'member', case when p_member then org.person(t.owner_user_id) end,
    'amount', ledger.money(p_net, p_currency),
    'balance', case when p_balance is not null then ledger.money(p_balance, p_currency) end,
    'status', case when rv.reference is null then 'posted' else 'reversed' end,
    'reversedBy', rv.reference,
    'reverses', orig.reference,
    'reversalCategory', coalesce(own_rev.category, rv.category),
    'pockets', p_pockets,
    'income', case when i.id is not null then jsonb_build_object('source', i.source) end,
    'transfer', case when pt.id is not null then jsonb_build_object(
      'from', sp.name, 'to', dp.name, 'amount', ledger.money(pt.amount, pt.currency)) end,
    'conversion', case when en.kind = 'conversion' then jsonb_build_object(
      'currency', en.currency, 'amount', ledger.money(en.amount, en.currency),
      'destinationCurrency', en.destination_currency,
      'destinationAmount', ledger.money(en.destination_amount, en.destination_currency)) end,
    'adjustment', case when en.kind = 'adjustment' then jsonb_build_object('direction', en.direction) end,
    'returnedFor', case when en.kind = 'returned_funds' then rw.reference end
  ))
  from ledger.transactions t
  join org.offices o on o.id = t.office_id
  left join finance.income_records i on i.transaction_id = t.id
  left join finance.pocket_transfers pt on pt.transaction_id = t.id
  left join ledger.pockets sp on sp.id = pt.source_pocket_id
  left join ledger.pockets dp on dp.id = pt.destination_pocket_id
  left join finance.entries en on en.transaction_id = t.id
  left join finance.withdrawals rw on rw.id = en.withdrawal_id
  left join finance.reversals own_rev on own_rev.transaction_id = t.id
  left join ledger.transactions orig on orig.id = own_rev.original_transaction_id
  left join lateral (
    select rt.reference, r.category
    from finance.reversals r
    join ledger.transactions rt on rt.id = r.transaction_id
    where r.original_transaction_id = t.id and rt.posted_at < p_as_of
  ) rv on true
  where t.id = p_transaction_id;
$$;

-- Network header for files and emails (slice 10 adds logo and colour).
create function exports.network_json(p_tenant_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('tenantId', t.id, 'name', t.name, 'initial', upper(left(t.name, 1)))
  from org.tenants t where t.id = p_tenant_id;
$$;

-- ── Personal statement ────────────────────────────────────────────────────

-- The person's member-value accounts in one network and currency (every
-- membership, current or ended: their own money is always theirs to see).
create function exports.statement_accounts(p_file exports.files)
returns uuid[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(a.id order by a.id), '{}')
  from ledger.accounts a
  where a.wallet_id = p_file.wallet_id and a.tenant_id = p_file.tenant_id and a.currency = p_file.currency
    and a.class = 'member_value';
$$;

-- Writes the statement rows (one per posted transaction, oldest first, with
-- the running balance) and its summary, in the caller's transaction.
-- Returns {status: 'rendering' | 'too_large', rowCount}.
create function exports.prepare_statement(p_file exports.files)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  accounts uuid[] := exports.statement_accounts(p_file);
  start_at timestamptz := exports.start_at(p_file);
  opening numeric;
  closing numeric;
  net_total numeric;
  money_in numeric;
  money_out numeric;
  in_count int;
  out_types jsonb;
  row_total int;
  inserted int;
  pockets jsonb;
  pending jsonb;
  reserved numeric;
  owner uuid;
begin
  select owner_user_id into owner from ledger.wallets where id = p_file.wallet_id;

  select count(distinct l.transaction_id) into row_total from exports.lines(accounts, start_at, p_file.as_of) l;
  if row_total > exports.row_limit(exports.format(p_file.kind)) then
    return jsonb_build_object('status', 'too_large', 'rowCount', row_total);
  end if;

  opening := exports.balance_before(accounts, start_at);
  closing := exports.balance_before(accounts, p_file.as_of);

  with l as (select * from exports.lines(accounts, start_at, p_file.as_of)),
  tx as (
    select l.transaction_id, sum(l.amount) as net,
      jsonb_agg(jsonb_build_object('pocket', pk.name, 'amount', ledger.money(l.amount, p_file.currency))
        order by pk.sort_order, pk.id) as pockets
    from l join ledger.pockets pk on pk.id = l.pocket_id
    group by l.transaction_id
  ),
  ordered as (
    select tx.*,
      row_number() over (order by t.posted_at, t.id) as seq,
      opening + sum(tx.net) over (order by t.posted_at, t.id rows between unbounded preceding and current row) as balance
    from tx join ledger.transactions t on t.id = tx.transaction_id
  )
  insert into exports.rows (file_id, seq, section, data)
  select p_file.id, o.seq, 'txn',
    exports.txn_json(o.transaction_id, p_file.currency, o.net, o.balance, o.pockets, p_file.as_of, false)
  from ordered o;
  get diagnostics inserted = row_count;

  select coalesce(sum(x.net), 0), coalesce(sum(x.net) filter (where x.net > 0), 0),
    coalesce(sum(x.net) filter (where x.net < 0), 0), count(*) filter (where x.net > 0)
  into net_total, money_in, money_out, in_count
  from (select l.transaction_id, sum(l.amount) as net
        from exports.lines(accounts, start_at, p_file.as_of) l group by l.transaction_id) x;

  select coalesce(jsonb_object_agg(o.type, o.n), '{}'::jsonb) into out_types
  from (select t.type, count(*) as n
        from (select l.transaction_id, sum(l.amount) as net
              from exports.lines(accounts, start_at, p_file.as_of) l group by l.transaction_id) x
        join ledger.transactions t on t.id = x.transaction_id
        where x.net < 0 group by t.type) o;

  -- Every figure must reconcile to the ledger, or the file fails.
  if inserted <> row_total or opening + net_total <> closing then
    perform identity.fail('invariant_violation', jsonb_build_object('reason', 'statement_does_not_reconcile'));
  end if;

  with acc as (select a.id, a.pocket_id from ledger.accounts a where a.id = any (accounts)),
  per_pocket as (
    select acc.pocket_id,
      exports.balance_before(array_agg(acc.id), start_at) as opening,
      exports.balance_before(array_agg(acc.id), p_file.as_of) as closing
    from acc group by acc.pocket_id
  ),
  moves as (
    select l.pocket_id,
      coalesce(sum(l.amount) filter (where l.amount > 0), 0) as money_in,
      coalesce(sum(l.amount) filter (where l.amount < 0), 0) as money_out
    from exports.lines(accounts, start_at, p_file.as_of) l group by l.pocket_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'pocket', pk.name,
      'kind', pk.kind,
      'opening', ledger.money(pp.opening, p_file.currency),
      'in', ledger.money(coalesce(m.money_in, 0), p_file.currency),
      'out', ledger.money(coalesce(m.money_out, 0), p_file.currency),
      'closing', ledger.money(pp.closing, p_file.currency)
    ) order by pk.sort_order, pk.id), '[]'::jsonb)
  into pockets
  from per_pocket pp
  join ledger.pockets pk on pk.id = pp.pocket_id
  left join moves m on m.pocket_id = pp.pocket_id
  where pp.opening <> 0 or pp.closing <> 0 or m.pocket_id is not null;

  select coalesce(sum(p.amount), 0),
    coalesce(jsonb_agg(jsonb_build_object(
      'kind', p.kind, 'reference', p.reference, 'status', p.status, 'pocket', pk.name,
      'date', to_char(p.created_at at time zone exports.zone(), 'YYYY-MM-DD'),
      'amount', ledger.money(p.amount, p_file.currency)
    ) order by p.created_at, p.reservation_id), '[]'::jsonb)
  into reserved, pending
  from exports.pending_at(accounts, p_file.as_of) p
  join ledger.pockets pk on pk.id = p.pocket_id;

  update exports.files set
    row_count = inserted,
    summary = jsonb_build_object(
      'type', 'statement',
      'network', exports.network_json(p_file.tenant_id),
      'person', org.person(owner),
      'memberships', coalesce((
        select jsonb_agg(jsonb_build_object('office', o.name, 'role', m.role, 'status', m.status)
          order by m.started_at, m.id)
        from org.memberships m join org.offices o on o.id = m.office_id
        where m.user_id = owner and m.tenant_id = p_file.tenant_id
          and (m.status = 'active' or m.id in (select a.membership_id from ledger.accounts a where a.id = any (accounts)))
      ), '[]'::jsonb),
      'currency', p_file.currency,
      'period', jsonb_build_object(
        'kind', p_file.period_kind,
        'from', to_char(p_file.period_from, 'YYYY-MM-DD'),
        'to', to_char(p_file.period_to, 'YYYY-MM-DD'),
        'title', exports.period_title(p_file.period_kind, p_file.period_from, p_file.period_to),
        'asOf', to_char(p_file.as_of at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'cutShort', p_file.as_of < (p_file.period_to + 1)::timestamp at time zone exports.zone(),
        'timeZone', exports.zone()
      ),
      'opening', ledger.money(opening, p_file.currency),
      'moneyIn', ledger.money(money_in, p_file.currency),
      'moneyOut', ledger.money(money_out, p_file.currency),
      'closing', ledger.money(closing, p_file.currency),
      'inCount', in_count,
      'outTypes', out_types,
      'pockets', pockets,
      'pending', pending,
      'reserved', ledger.money(reserved, p_file.currency),
      'available', ledger.money(closing - reserved, p_file.currency),
      'generatedAt', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'reference', p_file.reference
    )
  where id = p_file.id;

  return jsonb_build_object('status', 'rendering', 'rowCount', inserted);
end;
$$;

-- ── Leadership reports ────────────────────────────────────────────────────

-- Accounts of one currency the actor may see with any of the permissions in
-- the scope (office subtree, or the whole network for tenant-wide authority),
-- optionally one member. Never the actor's own (self-target guard).
create function exports.report_accounts(
  p_actor_user_id uuid,
  p_workspace_membership_id uuid,
  p_tenant_id uuid,
  p_scope_office_id uuid,
  p_member_user_id uuid,
  p_currency text,
  p_permissions text[]
)
returns uuid[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(v.account_id order by v.account_id), '{}')
  from ledger.visible_segments(p_actor_user_id, p_workspace_membership_id, p_tenant_id, p_permissions, null,
    p_scope_office_id) v
  where v.currency = p_currency and (p_member_user_id is null or v.owner_user_id = p_member_user_id);
$$;

-- People in scope whose money the actor may not see (reported, never added).
create function exports.excluded_people(
  p_actor_user_id uuid,
  p_tenant_id uuid,
  p_scope_office_id uuid,
  p_member_user_id uuid,
  p_currency text,
  p_accounts uuid[]
)
returns int
language sql
stable
set search_path = ''
as $$
  select count(distinct b.owner_user_id)::int
  from ledger.balances b
  where b.tenant_id = p_tenant_id and b.currency = p_currency and b.owner_user_id <> p_actor_user_id
    and (p_member_user_id is null or b.owner_user_id = p_member_user_id)
    and (p_scope_office_id is null or exists (
      select 1 from org.office_closure c where c.ancestor_id = p_scope_office_id and c.descendant_id = b.office_id))
    and not b.account_id = any (p_accounts);
$$;

-- Report totals over a set of accounts for [p_from, p_as_of): money held by
-- movement type (reconciled), reserved at the cut-off, net income by pocket,
-- withdrawals by lifecycle, and membership counts.
create function exports.report_summary(
  p_actor_user_id uuid,
  p_workspace_membership_id uuid,
  p_tenant_id uuid,
  p_scope_office_id uuid,
  p_member_user_id uuid,
  p_currency text,
  p_accounts uuid[],
  p_from timestamptz,
  p_as_of timestamptz,
  p_permissions text[]
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  opening numeric := exports.balance_before(p_accounts, p_from);
  closing numeric := exports.balance_before(p_accounts, p_as_of);
  held jsonb;
  held_total numeric;
  reserved numeric;
  reserved_count int;
  by_pocket jsonb;
  net_income numeric;
  withdrawals jsonb;
  memberships int;
  people int;
  joined int;
begin
  with tx as (
    select l.transaction_id, sum(l.amount) as net
    from exports.lines(p_accounts, p_from, p_as_of) l group by l.transaction_id
  ),
  typed as (
    select case
        when t.type = 'conversion' and tx.net > 0 then 'conversion_in'
        when t.type = 'conversion' then 'conversion_out'
        else t.type
      end as kind, tx.net
    from tx join ledger.transactions t on t.id = tx.transaction_id
  ),
  grouped as (
    select typed.kind, count(*) as n, sum(typed.net) as amount from typed group by typed.kind
  )
  select coalesce(jsonb_agg(jsonb_build_object('kind', g.kind, 'count', g.n,
      'amount', ledger.money(g.amount, p_currency))
      order by array_position(array['income', 'reversal', 'withdrawal', 'returned_funds', 'conversion_in',
        'conversion_out', 'adjustment', 'pocket_transfer'], g.kind)), '[]'::jsonb),
    coalesce(sum(g.amount), 0)
  into held, held_total
  from grouped g
  where g.kind <> 'pocket_transfer' or g.amount <> 0;

  if opening + held_total <> closing then
    perform identity.fail('invariant_violation', jsonb_build_object('reason', 'report_does_not_reconcile'));
  end if;

  select coalesce(sum(p.amount), 0), count(*) into reserved, reserved_count
  from exports.pending_at(p_accounts, p_as_of) p;

  with l as (
    select l.pocket_id, l.amount
    from exports.lines(p_accounts, p_from, p_as_of) l
    join ledger.transactions t on t.id = l.transaction_id
    left join finance.reversals r on r.transaction_id = t.id
    left join ledger.transactions o on o.id = r.original_transaction_id
    where t.type = 'income' or (t.type = 'reversal' and o.type = 'income')
  ),
  per as (select l.pocket_id, sum(l.amount) as amount from l group by l.pocket_id)
  select coalesce(jsonb_agg(jsonb_build_object('pocket', pk.name, 'amount', ledger.money(per.amount, p_currency))
      order by pk.sort_order, pk.id), '[]'::jsonb),
    coalesce(sum(per.amount), 0)
  into by_pocket, net_income
  from per join ledger.pockets pk on pk.id = per.pocket_id;

  with w as (
    select * from finance.withdrawals w
    where w.account_id = any (p_accounts) and w.currency = p_currency
  ),
  stages (stage, n, amount) as (
    select 'requested', count(*), coalesce(sum(w.amount), 0) from w
      where w.created_at >= p_from and w.created_at < p_as_of
    union all
    select 'approved', count(*), coalesce(sum(w.amount), 0) from w
      where w.approved_at >= p_from and w.approved_at < p_as_of
    union all
    select 'completed', count(*), coalesce(sum(w.amount), 0) from w
      where w.completed_at >= p_from and w.completed_at < p_as_of
    union all
    select 'rejected', count(*), coalesce(sum(w.amount), 0) from w
      where w.status = 'rejected' and w.decided_at >= p_from and w.decided_at < p_as_of
    union all
    select 'cancelled', count(*), coalesce(sum(w.amount), 0) from w
      where w.status = 'cancelled' and w.decided_at >= p_from and w.decided_at < p_as_of
  )
  select jsonb_agg(jsonb_build_object('stage', s.stage, 'count', s.n, 'amount', ledger.money(s.amount, p_currency))
    order by array_position(array['requested', 'approved', 'completed', 'rejected', 'cancelled'], s.stage))
  into withdrawals
  from stages s;

  -- Memberships vs distinct people (W-07): active memberships in scope the
  -- actor may see, never the actor's own; joined = started in the period.
  with m as (
    select m.* from org.memberships m
    where m.tenant_id = p_tenant_id and m.role <> 'president_team_member' and m.user_id <> p_actor_user_id
      and (p_member_user_id is null or m.user_id = p_member_user_id)
      and (p_scope_office_id is null or exists (
        select 1 from org.office_closure c where c.ancestor_id = p_scope_office_id and c.descendant_id = m.office_id))
      and exists (
        select 1 from unnest(p_permissions) k
        where ledger.segment_visible(p_actor_user_id, k, p_tenant_id, m.office_id, m.user_id,
          p_workspace_membership_id))
  )
  select count(*) filter (where m.status = 'active'),
    count(distinct m.user_id) filter (where m.status = 'active'),
    count(*) filter (where m.started_at >= p_from and m.started_at < p_as_of)
  into memberships, people, joined
  from m;

  return jsonb_build_object(
    'opening', ledger.money(opening, p_currency),
    'closing', ledger.money(closing, p_currency),
    'held', held,
    'reserved', ledger.money(reserved, p_currency),
    'reservedCount', reserved_count,
    'available', ledger.money(closing - reserved, p_currency),
    'netIncomeByPocket', by_pocket,
    'netIncome', ledger.money(net_income, p_currency),
    'withdrawals', withdrawals,
    'counts', jsonb_build_object('activeMemberships', memberships, 'people', people, 'joined', joined),
    'excludedPeople', exports.excluded_people(p_actor_user_id, p_tenant_id, p_scope_office_id, p_member_user_id,
      p_currency, p_accounts)
  );
end;
$$;

-- Per member over the accounts: opening, income, paid out, in, out, closing,
-- reserved. Ordered by income (largest first), then name, then id.
create function exports.member_figures(p_accounts uuid[], p_currency text, p_from timestamptz, p_as_of timestamptz)
returns table (owner_user_id uuid, seq bigint, income numeric, paid_out numeric, reserved numeric, data jsonb)
language sql
stable
set search_path = ''
as $$
  with acc as (
    select a.id, a.owner_user_id, a.membership_id from ledger.accounts a where a.id = any (p_accounts)
  ),
  owners as (select distinct acc.owner_user_id from acc),
  tx as (
    select l.owner_user_id, l.transaction_id, sum(l.amount) as net
    from exports.lines(p_accounts, p_from, p_as_of) l group by l.owner_user_id, l.transaction_id
  ),
  moves as (
    select tx.owner_user_id,
      coalesce(sum(tx.net) filter (where t.type = 'income'), 0) as income,
      coalesce(-sum(tx.net) filter (where t.type = 'withdrawal'), 0) as paid_out,
      coalesce(sum(tx.net) filter (where tx.net > 0), 0) as money_in,
      coalesce(sum(tx.net) filter (where tx.net < 0), 0) as money_out
    from tx join ledger.transactions t on t.id = tx.transaction_id
    group by tx.owner_user_id
  ),
  figures as (
    select o.owner_user_id,
      (select exports.balance_before(array_agg(acc.id), p_from) from acc where acc.owner_user_id = o.owner_user_id) as opening,
      (select exports.balance_before(array_agg(acc.id), p_as_of) from acc where acc.owner_user_id = o.owner_user_id) as closing,
      coalesce((select sum(p.amount) from exports.pending_at(
        (select array_agg(acc.id) from acc where acc.owner_user_id = o.owner_user_id), p_as_of) p), 0) as reserved,
      coalesce(m.income, 0) as income, coalesce(m.paid_out, 0) as paid_out,
      coalesce(m.money_in, 0) as money_in, coalesce(m.money_out, 0) as money_out,
      org.person(o.owner_user_id) as person,
      (select jsonb_agg(distinct off.name) from acc join org.memberships ms on ms.id = acc.membership_id
        join org.offices off on off.id = ms.office_id where acc.owner_user_id = o.owner_user_id) as offices
    from owners o left join moves m on m.owner_user_id = o.owner_user_id
  )
  select f.owner_user_id,
    row_number() over (order by f.income desc, f.person->>'name', f.owner_user_id),
    f.income, f.paid_out, f.reserved,
    jsonb_build_object(
      'member', f.person,
      'offices', coalesce(f.offices, '[]'::jsonb),
      'opening', ledger.money(f.opening, p_currency),
      'income', ledger.money(f.income, p_currency),
      'paidOut', ledger.money(f.paid_out, p_currency),
      'in', ledger.money(f.money_in, p_currency),
      'out', ledger.money(f.money_out, p_currency),
      'closing', ledger.money(f.closing, p_currency),
      'reserved', ledger.money(f.reserved, p_currency),
      'available', ledger.money(f.closing - f.reserved, p_currency)
    )
  from figures f;
$$;

-- Writes the report rows (members for the office PDF and the balances CSV,
-- transactions for the transactions CSV) and its summary.
create function exports.prepare_report(p_file exports.files)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  permissions constant text[] := array['export_scoped_reports'];
  accounts uuid[];
  start_at timestamptz := exports.start_at(p_file);
  row_total int;
  inserted int;
  totals jsonb;
  scope_name text;
begin
  accounts := exports.report_accounts(p_file.requested_by, p_file.workspace_membership_id, p_file.tenant_id,
    p_file.scope_office_id, p_file.member_user_id, p_file.currency, permissions);

  if p_file.kind = 'transactions_csv' then
    select count(distinct l.transaction_id) into row_total from exports.lines(accounts, start_at, p_file.as_of) l;
  else
    select count(distinct a.owner_user_id) into row_total from ledger.accounts a where a.id = any (accounts);
  end if;
  if row_total > exports.row_limit(exports.format(p_file.kind)) then
    return jsonb_build_object('status', 'too_large', 'rowCount', row_total);
  end if;

  totals := exports.report_summary(p_file.requested_by, p_file.workspace_membership_id, p_file.tenant_id,
    p_file.scope_office_id, p_file.member_user_id, p_file.currency, accounts, start_at, p_file.as_of, permissions);

  if p_file.kind = 'transactions_csv' then
    with l as (select * from exports.lines(accounts, start_at, p_file.as_of)),
    tx as (
      select l.transaction_id, sum(l.amount) as net,
        jsonb_agg(jsonb_build_object('pocket', pk.name, 'amount', ledger.money(l.amount, p_file.currency))
          order by pk.sort_order, pk.id) as pockets
      from l join ledger.pockets pk on pk.id = l.pocket_id
      group by l.transaction_id
    )
    insert into exports.rows (file_id, seq, section, data)
    select p_file.id, row_number() over (order by t.posted_at, t.id), 'txn',
      exports.txn_json(tx.transaction_id, p_file.currency, tx.net, null, tx.pockets, p_file.as_of, true)
    from tx join ledger.transactions t on t.id = tx.transaction_id;
  else
    insert into exports.rows (file_id, seq, section, data)
    select p_file.id, mf.seq, 'member', mf.data
    from exports.member_figures(accounts, p_file.currency, start_at, p_file.as_of) mf;
  end if;
  get diagnostics inserted = row_count;
  if inserted <> row_total then
    perform identity.fail('invariant_violation', jsonb_build_object('reason', 'report_rows_incomplete'));
  end if;

  select o.name into scope_name from org.offices o where o.id = p_file.scope_office_id;

  update exports.files set
    row_count = inserted,
    included_accounts = accounts,
    summary = totals || jsonb_build_object(
      'type', 'report',
      'network', exports.network_json(p_file.tenant_id),
      'scope', jsonb_build_object(
        'kind', case when p_file.scope_office_id is null then 'network' else 'office' end,
        'name', coalesce(scope_name, (select t.name from org.tenants t where t.id = p_file.tenant_id)),
        'member', case when p_file.member_user_id is not null then org.person(p_file.member_user_id) end
      ),
      'preparedFor', org.person(p_file.requested_by) || jsonb_build_object('role',
        (select m.role from org.memberships m where m.id = p_file.workspace_membership_id)),
      'currency', p_file.currency,
      'period', jsonb_build_object(
        'kind', p_file.period_kind,
        'from', to_char(p_file.period_from, 'YYYY-MM-DD'),
        'to', to_char(p_file.period_to, 'YYYY-MM-DD'),
        'title', exports.period_title(p_file.period_kind, p_file.period_from, p_file.period_to),
        'asOf', to_char(p_file.as_of at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'cutShort', p_file.as_of < (p_file.period_to + 1)::timestamp at time zone exports.zone(),
        'timeZone', exports.zone()
      ),
      'members', inserted,
      'generatedAt', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'reference', p_file.reference
    )
  where id = p_file.id;

  return jsonb_build_object('status', 'rendering', 'rowCount', inserted);
end;
$$;

revoke all on all functions in schema exports from public, anon, authenticated;
