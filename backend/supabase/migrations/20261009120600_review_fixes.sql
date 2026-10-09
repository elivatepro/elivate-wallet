-- Blueprint 12 — review fixes (PR #34):
-- * Reinstating a returned-funds credit (reversing its reversal) is held to
--   the same limit as a new return: the chain is followed to the withdrawal,
--   which is locked, and the total in effect may never exceed what left.
-- * A reversal's note is the President's own: transaction detail (also read
--   by the wallet owner) carries the category only.

-- The first transaction of a reversal chain (itself when it reverses nothing).
create function ledger.chain_root(p_transaction_id uuid)
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  current uuid := p_transaction_id;
  reverses uuid;
begin
  loop
    select (t.metadata->>'reversesTransactionId')::uuid into reverses
    from ledger.transactions t where t.id = current and t.type = 'reversal';
    exit when reverses is null;
    current := reverses;
  end loop;
  return current;
end;
$$;

create or replace function api.reverse_transaction(
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
  v_withdrawal_id uuid;
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

  -- Lock order: the withdrawal behind a returned-funds chain (W-16), then the
  -- original. A reversal of a reversal of a return is still about that return.
  select e.withdrawal_id into v_withdrawal_id from finance.entries e
  where e.transaction_id = ledger.chain_root(tx.id) and e.kind = 'returned_funds';
  if v_withdrawal_id is not null then
    perform 1 from finance.withdrawals where id = v_withdrawal_id for update;
  end if;
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

  -- A reinstated return counts again: never more than what left (W-16).
  if v_withdrawal_id is not null
    and finance.returned_total(v_withdrawal_id) > finance.withdrawal_debit(v_withdrawal_id) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'exceeds_returnable'));
  end if;

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

-- The owner reads this too: the President's note stays out (it is in the audit log).
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
      select jsonb_build_object('category', r.category, 'reversedBy', org.person(r.reversed_by))
      from finance.reversals r where r.transaction_id = t.id
    )
  )
  from ledger.transactions t
  join org.tenants tn on tn.id = t.tenant_id
  join org.offices o on o.id = t.office_id
  where t.id = p_transaction_id;
$$;

revoke all on function ledger.chain_root(uuid) from public, anon, authenticated;
