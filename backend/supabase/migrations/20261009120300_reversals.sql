-- Blueprint 12 — W-15 reversal and reinstatement. The President (protected,
-- non-delegable `reverse_transaction`) negates a posted transaction's exact
-- lines with reason, typed confirmation and a fresh PIN. Activity and detail
-- already read the link (Blueprint 08 B4a: `metadata.reversesTransactionId`).

-- Types that may be reversed. A completed withdrawal is corrected with
-- Returned funds instead (W-15 external boundary).
create function finance.reversible_type(p_type text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_type in ('income', 'pocket_transfer', 'conversion', 'adjustment', 'returned_funds', 'reversal');
$$;

-- A posted transaction of the network by its public reference (any case,
-- dashes optional); not_found otherwise.
create function finance.transaction_by_reference(p_tenant_id uuid, p_reference text)
returns ledger.transactions
language plpgsql
set search_path = ''
as $$
declare
  clean text;
  tx ledger.transactions;
begin
  clean := upper(regexp_replace(coalesce(p_reference, ''), '[^A-Za-z0-9]', '', 'g'));
  if length(clean) <> 11 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'reference'));
  end if;
  select * into tx from ledger.transactions
  where tenant_id = p_tenant_id
    and reference = left(clean, 3) || '-' || substr(clean, 4, 4) || '-' || right(clean, 4);
  if tx.id is null then
    perform identity.fail('not_found');
  end if;
  return tx;
end;
$$;

-- Why a transaction can't be reversed now, or null.
create function finance.reversal_blocker(p_tx ledger.transactions)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when not finance.reversible_type(p_tx.type) then 'not_reversible'
    when exists (select 1 from finance.reversals r where r.original_transaction_id = p_tx.id) then 'already_reversed'
  end;
$$;

-- E07 preview: the original, the lines the reversal would post and what each
-- pocket has available now.
create function api.reversal_preview(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_reference text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  tx ledger.transactions;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  tx := finance.transaction_by_reference(workspace.tenant_id, p_reference);
  perform authz.require(p_user_id, 'reverse_transaction', workspace.tenant_id, null, tx.owner_user_id, workspace.id);

  return jsonb_build_object(
    'transaction', ledger.transaction_json(tx.id),
    'title', coalesce(
      (select i.source from finance.income_records i where i.transaction_id = tx.id),
      (select sp.name || ' → ' || dp.name from finance.pocket_transfers pt
         join ledger.pockets sp on sp.id = pt.source_pocket_id
         join ledger.pockets dp on dp.id = pt.destination_pocket_id where pt.transaction_id = tx.id),
      (select e.reason from finance.entries e where e.transaction_id = tx.id and e.kind = 'adjustment'),
      (select e.provider from finance.entries e where e.transaction_id = tx.id)),
    'member', org.person(tx.owner_user_id),
    'walletId', tx.wallet_id,
    'blocker', finance.reversal_blocker(tx),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'pocketId', a.pocket_id,
        'pocket', pk.name,
        'currency', j.currency,
        'amount', ledger.money(-p.amount, j.currency),
        'available', ledger.money(b.posted - b.reserved, j.currency),
        'enough', p.amount <= 0 or pk.kind = 'debt' or b.posted - b.reserved >= p.amount
      ) order by j.entry_no, pk.sort_order, p.line_no)
      from ledger.journals j
      join ledger.postings p on p.journal_id = j.id
      join ledger.accounts a on a.id = p.account_id and a.class = 'member_value'
      join ledger.pockets pk on pk.id = a.pocket_id
      join ledger.balances b on b.account_id = a.id
      where j.transaction_id = tx.id
    ), '[]'::jsonb)
  );
end;
$$;

create function finance.reversal_json(p_reversal_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'reversalId', r.id,
    'reference', r.reference,
    'transactionId', r.transaction_id,
    'category', r.category,
    'note', r.note,
    'createdAt', r.created_at,
    'reverses', jsonb_build_object('transactionId', o.id, 'reference', o.reference, 'type', o.type),
    'member', org.person(t.owner_user_id),
    'walletId', t.wallet_id,
    'amounts', (
      select jsonb_agg(jsonb_build_object('currency', s.currency, 'amount', ledger.money(s.total, s.currency))
        order by s.currency)
      from (
        select j.currency, sum(p.amount) as total
        from ledger.journals j
        join ledger.postings p on p.journal_id = j.id
        join ledger.accounts a on a.id = p.account_id and a.class = 'member_value'
        where j.transaction_id = r.transaction_id
        group by j.currency
      ) s
    )
  )
  from finance.reversals r
  join ledger.transactions o on o.id = r.original_transaction_id
  join ledger.transactions t on t.id = r.transaction_id
  where r.id = p_reversal_id;
$$;

create function api.reverse_transaction(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_transaction_id uuid,
  p_category text,
  p_note text,
  p_confirm_reference text,
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
  tx ledger.transactions;
  clean_note text;
  request jsonb;
  replayed jsonb;
  blocker text;
  journals jsonb;
  v_reference text;
  v_transaction_id uuid;
  v_reversal_id uuid;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  select * into tx from ledger.transactions where id = p_transaction_id and tenant_id = workspace.tenant_id;
  if tx.id is null then
    perform identity.fail('not_found');
  end if;
  -- Tenant-wide and protected; never the President's own money (A-04).
  perform authz.require(p_user_id, 'reverse_transaction', workspace.tenant_id, null, tx.owner_user_id, workspace.id);

  if p_category is null
    or p_category not in ('recorded_twice', 'wrong_member', 'wrong_amount', 'wrong_pocket', 'other') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'category'));
  end if;
  if p_note is not null then
    clean_note := identity.require_reason(p_note);
  elsif p_category = 'other' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'note'));
  end if;
  -- High-risk confirmation (A-05): the reference typed back.
  if upper(btrim(coalesce(p_confirm_reference, ''))) <> tx.reference then
    perform identity.fail('conflict', jsonb_build_object('reason', 'confirmation_mismatch'));
  end if;

  request := jsonb_build_object('transactionId', tx.id, 'category', p_category, 'note', clean_note);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'reverse_transaction', request);
  if replayed is not null then
    return replayed;
  end if;

  -- Lock order: a returned-funds original's withdrawal, then the original.
  perform 1 from finance.withdrawals w
  join finance.entries e on e.withdrawal_id = w.id
  where e.transaction_id = tx.id
  for update of w;
  select * into tx from ledger.transactions where id = tx.id for update;
  blocker := finance.reversal_blocker(tx);
  if blocker is not null then
    perform identity.fail('conflict', jsonb_build_object('reason', blocker));
  end if;

  -- The exact opposite of every original line, same accounts (W-15).
  select jsonb_agg(jsonb_build_object('currency', j.currency, 'postings', (
      select jsonb_agg(jsonb_build_object('accountId', p.account_id, 'amount', (-p.amount)::text) order by p.line_no)
      from ledger.postings p where p.journal_id = j.id
    )) order by j.entry_no)
  into journals
  from ledger.journals j where j.transaction_id = tx.id;

  v_reference := refs.issue('REV');
  v_transaction_id := ledger.post('reversal', v_reference, tx.membership_id, p_user_id, p_idempotency_key, journals,
    '[]'::jsonb, jsonb_build_object('reversesTransactionId', tx.id, 'category', p_category));

  insert into finance.reversals (reference, tenant_id, original_transaction_id, transaction_id, category, note,
    reversed_by, idempotency_key)
  values (v_reference, workspace.tenant_id, tx.id, v_transaction_id, p_category, clean_note, p_user_id,
    p_idempotency_key)
  returning id into v_reversal_id;

  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'transaction.reversed', 'reversal',
    v_reversal_id::text, clean_note,
    p_safe_after => jsonb_build_object('reference', v_reference, 'reverses', tx.reference, 'type', tx.type,
      'category', p_category, 'membershipId', tx.membership_id),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'reverse_transaction', request,
    finance.reversal_json(v_reversal_id));
end;
$$;
