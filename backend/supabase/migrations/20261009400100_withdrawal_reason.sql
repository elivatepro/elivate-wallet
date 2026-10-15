-- Blueprint 40 — a withdrawal says what it is for (owner decision 2026-10-15).
-- Whoever places it (the member, or a leader on their behalf) gives one
-- free-text reason, 3–500 characters after trimming (identity.require_reason).
-- Approvers see it in the queue and detail, the member on their own request
-- and in Activity's transaction detail, and it is in the "Withdrawal
-- requested" (M02) and "needs your approval" (M03) emails. Statements and
-- reports never carry it. Withdrawals placed before this have none (null).

-- ── Column ────────────────────────────────────────────────────────────────

alter table finance.withdrawals add column reason text
  check (reason is null or length(btrim(reason)) between 3 and 500);

-- Fixed at request time like the rest of the request.
create or replace function finance.guard_withdrawal()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'requested' then
      perform identity.fail('invariant_violation', jsonb_build_object('table', 'finance.withdrawals'));
    end if;
    new.created_at := now();
    return new;
  end if;
  if not ((old.status = 'requested' and new.status in ('approved', 'rejected', 'cancelled'))
          or (old.status = 'approved' and new.status in ('completed', 'cancelled')))
    or new.id <> old.id or new.reference <> old.reference or new.tenant_id <> old.tenant_id
    or new.office_id <> old.office_id or new.membership_id <> old.membership_id
    or new.wallet_id <> old.wallet_id or new.owner_user_id <> old.owner_user_id
    or new.account_id <> old.account_id or new.pocket_id <> old.pocket_id
    or new.currency <> old.currency or new.amount <> old.amount
    or new.payout_account_id <> old.payout_account_id or new.bank_code <> old.bank_code
    or new.bank_name <> old.bank_name or new.account_last4 <> old.account_last4
    or new.account_ciphertext <> old.account_ciphertext or new.key_version <> old.key_version
    or new.account_name <> old.account_name or new.requested_by <> old.requested_by
    or new.reservation_id <> old.reservation_id or new.idempotency_key <> old.idempotency_key
    or new.created_at <> old.created_at or new.reason is distinct from old.reason
    or (old.approved_by is not null and (new.approved_by <> old.approved_by or new.approved_at <> old.approved_at)) then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'finance.withdrawals'));
  end if;
  if new.status = 'approved' then
    new.approved_at := now();
  elsif new.status = 'completed' then
    new.completed_at := now();
  else
    new.decided_at := now();
  end if;
  return new;
end;
$$;

-- ── Reads ─────────────────────────────────────────────────────────────────

-- Every withdrawal read (My withdrawals, the queue, both details) shows it.
create or replace function finance.withdrawal_json(p_withdrawal_id uuid, p_user_id uuid, p_workspace_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'withdrawalId', w.id,
    'reference', w.reference,
    'status', w.status,
    'currency', w.currency,
    'amount', ledger.money(w.amount, w.currency),
    'reserved', case when r.status = 'active' then ledger.money(r.amount, w.currency) else '0.00' end,
    'pocket', jsonb_build_object('pocketId', pk.id, 'name', pk.name),
    'tenant', jsonb_build_object('id', t.id, 'name', t.name),
    'office', jsonb_build_object('id', o.id, 'name', o.name),
    'membershipId', w.membership_id,
    'role', m.role,
    'walletId', w.wallet_id,
    'member', org.person(w.owner_user_id),
    'requestedBy', org.person(w.requested_by),
    'onBehalf', w.requested_by <> w.owner_user_id,
    'reason', w.reason,
    'destination', jsonb_build_object(
      'payoutAccountId', w.payout_account_id,
      'bankName', w.bank_name,
      'accountLast4', w.account_last4,
      'accountNumberMasked', '•••• ' || w.account_last4,
      'accountName', w.account_name),
    'createdAt', w.created_at,
    'approvedAt', w.approved_at,
    'approvedBy', case when w.approved_by is not null then org.person(w.approved_by) end,
    'decidedAt', w.decided_at,
    'decidedBy', case when w.decided_by is not null then org.person(w.decided_by) end,
    'decisionReason', w.decision_reason,
    'completedAt', w.completed_at,
    'transactionId', w.transaction_id,
    'payout', (
      select finance.payout_json(p, false) from finance.payouts p
      where p.withdrawal_id = w.id order by p.attempt_no desc limit 1
    ),
    'payoutAttempts', (select count(*) from finance.payouts p where p.withdrawal_id = w.id),
    'can', finance.withdrawal_caps(w, p_user_id, p_workspace_id)
  )
  from finance.withdrawals w
  join ledger.reservations r on r.id = w.reservation_id
  join ledger.pockets pk on pk.id = w.pocket_id
  join org.tenants t on t.id = w.tenant_id
  join org.offices o on o.id = w.office_id
  join org.memberships m on m.id = w.membership_id
  where w.id = p_withdrawal_id;
$$;

-- Activity's transaction detail (latest: 20261009120600_review_fixes).
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
        'approvedBy', org.person(w.approved_by),
        'reason', w.reason
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

-- ── Request ───────────────────────────────────────────────────────────────

-- The reason is part of the request: a replay with another reason is an
-- idempotency conflict.
drop function api.request_withdrawal(uuid, uuid, uuid, uuid, text, uuid, text, text);

create function api.request_withdrawal(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_account_id uuid,
  p_amount text,
  p_payout_account_id uuid,
  p_reason text,
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
  account ledger.accounts;
  destination payout.accounts;
  v_amount numeric;
  v_reason text;
  request jsonb;
  replayed jsonb;
  v_id uuid := gen_random_uuid();
  v_reference text;
  v_reservation uuid;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  account := finance.withdrawal_source(p_user_id, workspace, p_account_id);
  v_amount := ledger.parse_amount(p_amount, 'NGN', 'amount');
  if p_payout_account_id is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'payoutAccountId'));
  end if;
  -- Blueprint 40: what the withdrawal is for, 3–500 characters (field `reason`).
  v_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('accountId', account.id, 'amount', ledger.money(v_amount, 'NGN'),
    'payoutAccountId', p_payout_account_id, 'reason', v_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'request_withdrawal', request);
  if replayed is not null then
    return replayed;
  end if;

  -- Lock order: the owner's payout account (share), then the balance.
  destination := payout.eligible_destination(account.owner_user_id, p_payout_account_id);
  v_reservation := ledger.reserve(account.id, v_amount, 'withdrawal', 'withdrawal', v_id, p_user_id);
  v_reference := refs.issue('WDR');

  insert into finance.withdrawals (id, reference, tenant_id, office_id, membership_id, wallet_id, owner_user_id,
    account_id, pocket_id, currency, amount, payout_account_id, bank_code, bank_name, account_last4,
    account_ciphertext, key_version, account_name, requested_by, reservation_id, idempotency_key, reason)
  values (v_id, v_reference, account.tenant_id, account.office_id, account.membership_id, account.wallet_id,
    account.owner_user_id, account.id, account.pocket_id, 'NGN', v_amount, destination.id, destination.bank_code,
    destination.bank_name, destination.account_last4, destination.account_ciphertext, destination.key_version,
    destination.account_name, p_user_id, v_reservation, p_idempotency_key, v_reason);

  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'withdrawal.requested', 'withdrawal', v_id::text,
    v_reason,
    p_safe_after => jsonb_build_object('reference', v_reference, 'amount', ledger.money(v_amount, 'NGN'),
      'membershipId', account.membership_id, 'onBehalf', account.owner_user_id <> p_user_id,
      'payoutAccountId', destination.id),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'request_withdrawal', request,
    finance.withdrawal_json(v_id, p_user_id, workspace.id));
end;
$$;

-- ── Emails ────────────────────────────────────────────────────────────────
-- M02 and M03 may carry the reason (optional, so events queued before this
-- still render). The template rows are otherwise immutable; the version stays
-- 1 because the renderer reads both shapes. Deploy the outbox worker first.

do $$
begin
  alter table outbox.templates disable trigger templates_immutable;
  update outbox.templates set params = params || array['reason']
  where key in ('money.withdrawal_submitted', 'money.withdrawal_awaiting_approval')
    and not 'reason' = any (params);
  alter table outbox.templates enable trigger templates_immutable;
end;
$$;

-- The owner's email repeats their reason; approvers' emails show it so the
-- request can be judged (owner decision 2026-10-15, an exception to "never
-- reasons" in notify.emit; bell items still never carry it).
create or replace function notify.on_tenant_event()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  a jsonb := coalesce(new.safe_after, '{}'::jsonb);
  network text := notify.network(new.tenant_id);
  dedupe text := new.action || ':' || coalesce(new.target_id, '');
  target uuid;
  holder uuid;
  w finance.withdrawals;
  p finance.payouts;
  t finance.pocket_transfers;
  e finance.entries;
  inv org.invitations;
  m org.memberships;
  money jsonb;
  base jsonb;
  path text;
begin
  case
  when new.action = 'income.recorded' then
    select user_id into target from org.memberships where id = (a->>'membershipId')::uuid;
    base := jsonb_build_object('reference', a->>'reference', 'amount', a->>'amount', 'currency', a->>'currency',
      'path', '/app/activity');
    perform notify.emit(target, new.tenant_id, 'money.income_posted', 'income', new.target_id::uuid, base, dedupe,
      base || jsonb_build_object('network', network));

  when new.action in ('withdrawal.requested', 'withdrawal.approved', 'withdrawal.rejected', 'withdrawal.cancelled',
      'withdrawal.completed') then
    select * into w from finance.withdrawals where id = new.target_id::uuid;
    base := jsonb_build_object('reference', w.reference, 'amount', ledger.money(w.amount, w.currency),
      'currency', w.currency, 'path', '/app/withdrawals');
    perform notify.emit(w.owner_user_id, w.tenant_id,
      case new.action
        when 'withdrawal.requested' then 'money.withdrawal_submitted'
        when 'withdrawal.approved' then 'money.withdrawal_approved'
        when 'withdrawal.rejected' then 'money.withdrawal_not_approved'
        when 'withdrawal.cancelled' then 'money.withdrawal_cancelled'
        else 'money.withdrawal_completed'
      end,
      'withdrawal', w.id, base, dedupe,
      base || jsonb_build_object('network', network)
        -- Blueprint 40: M02 repeats what the request is for (email only, never the bell).
        || case when new.action = 'withdrawal.requested'
             then jsonb_strip_nulls(jsonb_build_object('reason', w.reason))
             else '{}'::jsonb end
        || case when new.action = 'withdrawal.completed'
             then jsonb_strip_nulls(jsonb_build_object('firstName', notify.first_name(w.owner_user_id)))
             else '{}'::jsonb end);

    path := '/app/queue?withdrawal=' || w.id::text;
    base := base || jsonb_build_object('member', notify.full_name(w.owner_user_id), 'bank', w.bank_name,
      'last4', w.account_last4, 'path', path);
    if new.action = 'withdrawal.requested' then
      -- Everyone who can approve it (owner answer Q1); never the owner.
      for holder in select notify.holders(w.tenant_id, 'approve_withdrawal', w.office_id, w.owner_user_id) loop
        perform notify.emit(holder, w.tenant_id, 'task.withdrawal_approve', 'withdrawal', w.id, base, dedupe,
          jsonb_build_object('network', network, 'amount', base->>'amount', 'currency', w.currency,
            'reference', w.reference, 'member', notify.short_name(w.owner_user_id),
            'office', coalesce(notify.office(w.office_id), network), 'path', path)
            || jsonb_strip_nulls(jsonb_build_object('reason', w.reason)));
      end loop;
    elsif new.action = 'withdrawal.approved' then
      -- Only the approver records the payout (W-10).
      perform notify.emit(w.approved_by, w.tenant_id, 'task.payout_record', 'withdrawal', w.id, base, dedupe);
    end if;

  when new.action in ('payout.correction_required', 'payout.review_required', 'payout.rejected') then
    select * into p from finance.payouts where id = new.target_id::uuid;
    select * into w from finance.withdrawals where id = p.withdrawal_id;
    base := jsonb_build_object('reference', w.reference, 'amount', ledger.money(w.amount, w.currency),
      'currency', w.currency, 'member', notify.full_name(w.owner_user_id));
    if new.action = 'payout.correction_required' then
      path := '/app/queue?withdrawal=' || w.id::text;
      perform notify.emit(p.submitted_by, w.tenant_id, 'task.payout_fix', 'payout', p.id,
        base || jsonb_build_object('path', path), dedupe,
        jsonb_build_object('network', network, 'amount', base->>'amount', 'currency', w.currency,
          'reference', w.reference, 'path', path));
    elsif new.action = 'payout.review_required' then
      -- Assigned reviewers in scope (owner answer Q2), never whoever recorded it.
      for holder in
        select h from notify.holders(w.tenant_id, 'review_financial_evidence', w.office_id, w.owner_user_id) h
        where h <> p.submitted_by
          and not exists (select 1 from finance.payout_revisions r where r.payout_id = p.id and r.submitted_by = h)
      loop
        perform notify.emit(holder, w.tenant_id, 'task.payout_review', 'payout', p.id,
          base || jsonb_build_object('subject', 'payout', 'path', '/app/evidence'), dedupe,
          jsonb_build_object('network', network, 'amount', base->>'amount', 'currency', w.currency,
            'reference', w.reference, 'subject', 'payout', 'path', '/app/evidence'));
      end loop;
    else
      path := '/app/queue?withdrawal=' || w.id::text;
      perform notify.emit(p.submitted_by, w.tenant_id, 'money.payout_receipt_rejected', 'payout', p.id,
        base || jsonb_build_object('path', path), dedupe,
        jsonb_build_object('network', network, 'amount', base->>'amount', 'currency', w.currency,
          'reference', w.reference, 'path', path));
      -- The withdrawal stays approved and held: the approver records again or cancels.
      perform notify.emit(w.approved_by, w.tenant_id, 'task.payout_record', 'withdrawal', w.id,
        base || jsonb_build_object('bank', w.bank_name, 'last4', w.account_last4, 'path', path), dedupe);
    end if;

  when new.action in ('pocket_transfer.requested', 'pocket_transfer.completed', 'pocket_transfer.rejected') then
    select * into t from finance.pocket_transfers where id = new.target_id::uuid;
    base := jsonb_build_object('reference', t.reference, 'amount', ledger.money(t.amount, t.currency),
      'currency', t.currency,
      'from', (select name from ledger.pockets where id = t.source_pocket_id),
      'to', (select name from ledger.pockets where id = t.destination_pocket_id));
    if new.action = 'pocket_transfer.requested' then
      for holder in select notify.holders(t.tenant_id, 'approve_pocket_transfer', t.office_id, t.owner_user_id) loop
        perform notify.emit(holder, t.tenant_id, 'task.transfer_approve', 'pocket_transfer', t.id,
          base || jsonb_build_object('member', notify.full_name(t.owner_user_id), 'path', '/app/transfers'), dedupe);
      end loop;
    elsif new.action = 'pocket_transfer.completed' then
      perform notify.emit(t.owner_user_id, t.tenant_id, 'money.pocket_move_done', 'pocket_transfer', t.id,
        base || jsonb_build_object('path', '/app'), dedupe,
        base || jsonb_build_object('network', network, 'path', '/app'));
    else
      perform notify.emit(t.owner_user_id, t.tenant_id, 'money.pocket_move_declined', 'pocket_transfer', t.id,
        base || jsonb_build_object('path', '/app'), dedupe,
        jsonb_build_object('network', network, 'amount', base->>'amount', 'currency', t.currency,
          'reference', t.reference, 'path', '/app'));
    end if;

  when new.action ~ '^(conversion|adjustment|returned_funds)\.(submitted|posted|rejected)$' then
    select * into e from finance.entries where id = new.target_id::uuid;
    base := jsonb_build_object('reference', e.reference, 'amount', ledger.money(e.amount, e.currency),
      'currency', e.currency, 'subject', e.kind);
    if new.action like '%.submitted' then
      for holder in
        select h from notify.holders(e.tenant_id, 'review_financial_evidence', e.office_id, e.owner_user_id) h
        where h <> e.submitted_by
      loop
        perform notify.emit(holder, e.tenant_id, 'task.entry_review', 'entry', e.id,
          base || jsonb_build_object('member', notify.full_name(e.owner_user_id), 'direction', e.direction,
            'path', '/app/evidence'),
          dedupe,
          base || jsonb_build_object('network', network, 'path', '/app/evidence'));
      end loop;
    elsif new.action like '%.posted' then
      base := base - 'subject' || jsonb_build_object('path', '/app/activity');
      if e.kind = 'adjustment' then
        perform notify.emit(e.owner_user_id, e.tenant_id, 'money.adjustment_posted', 'entry', e.id,
          base || jsonb_build_object('direction', e.direction), dedupe,
          base || jsonb_build_object('network', network, 'direction', e.direction,
            'actor', notify.short_name(e.submitted_by)));
      elsif e.kind = 'conversion' then
        base := base || jsonb_build_object('destinationAmount', ledger.money(e.destination_amount,
          e.destination_currency), 'destinationCurrency', e.destination_currency);
        perform notify.emit(e.owner_user_id, e.tenant_id, 'money.conversion_posted', 'entry', e.id, base, dedupe,
          base || jsonb_build_object('network', network, 'actor', notify.short_name(e.submitted_by)));
      else
        base := base || jsonb_build_object('withdrawal',
          (select reference from finance.withdrawals where id = e.withdrawal_id));
        perform notify.emit(e.owner_user_id, e.tenant_id, 'money.returned_funds', 'entry', e.id, base, dedupe,
          base || jsonb_build_object('network', network));
      end if;
    else
      path := case e.kind
        when 'conversion' then '/app/convert'
        when 'adjustment' then '/app/adjust'
        else '/app/queue/returns?withdrawal=' || e.withdrawal_id::text
      end;
      perform notify.emit(e.submitted_by, e.tenant_id, 'money.entry_not_posted', 'entry', e.id,
        base || jsonb_build_object('path', path), dedupe,
        base || jsonb_build_object('network', network, 'path', path));
    end if;

  when new.action = 'transaction.reversed' then
    select user_id into target from org.memberships where id = (a->>'membershipId')::uuid;
    money := notify.moved(
      (select original_transaction_id from finance.reversals where id = new.target_id::uuid), target);
    if target is not null and money is not null then
      base := money || jsonb_build_object('reference', a->>'reference', 'reverses', a->>'reverses',
        'path', '/app/activity');
      perform notify.emit(target, new.tenant_id, 'money.transaction_reversed', 'reversal', new.target_id::uuid,
        base, dedupe, base || jsonb_build_object('network', network));
    end if;

  when new.action = 'invitation.accepted' then
    select * into inv from org.invitations where id = new.target_id::uuid;
    base := jsonb_build_object('member', notify.full_name(new.actor_user_id),
      'office', coalesce(notify.office(inv.office_id), network), 'role', inv.role::text, 'path', '/app/members');
    perform notify.emit(inv.invited_by, inv.tenant_id, 'team.invitation_accepted', 'invitation', inv.id, base, dedupe,
      base || jsonb_build_object('network', network)
        || jsonb_strip_nulls(jsonb_build_object('firstName', notify.first_name(new.actor_user_id))));

  when new.action = 'membership.role_changed' then
    select * into m from org.memberships where id = (a->>'membershipId')::uuid;
    base := jsonb_build_object('role', m.role::text, 'office', coalesce(notify.office(m.office_id), network),
      'path', '/app');
    perform notify.emit(m.user_id, m.tenant_id, 'account.role_changed', 'membership', m.id, base, dedupe,
      base || jsonb_build_object('network', network, 'actor', notify.short_name(new.actor_user_id)));

  else
    null;
  end case;
  return null;
end;
$$;

-- ── Privileges ────────────────────────────────────────────────────────────

revoke all on function api.request_withdrawal(uuid, uuid, uuid, uuid, text, uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function api.request_withdrawal(uuid, uuid, uuid, uuid, text, uuid, text, text, text)
  to service_role;

-- Backups carry the reason (F-03). Only when it is set, so archives made before this
-- slice still compare equal in restore review.
create or replace function backups.snapshot(p_tenant_id uuid)
returns table (section text, data jsonb)
language sql
stable
set search_path = ''
as $$
  with people as (
    select distinct m.user_id from org.memberships m where m.tenant_id = p_tenant_id
  ),
  tx as (
    select t.* from ledger.transactions t where t.tenant_id = p_tenant_id
  ),
  acct as (
    select a.* from ledger.accounts a where a.tenant_id = p_tenant_id
  ),
  wd as (
    select w.* from finance.withdrawals w where w.tenant_id = p_tenant_id
  ),
  po as (
    select p.* from finance.payouts p join wd on wd.id = p.withdrawal_id
  )
  select s.section, s.data from (
    select 1 as o, 'network'::text, jsonb_build_object('id', t.id, 'name', t.name, 'shortName', t.short_name,
      'status', t.status, 'createdAt', t.created_at, 'activatedAt', t.activated_at,
      'activationSource', t.activation_source) || jsonb_build_object('settings', org.brand_json(t.id) - 'tenantId'),
      t.id::text as k
    from org.tenants t where t.id = p_tenant_id
    union all
    select 2, 'settings_revisions', backups.pick(to_jsonb(r), array['revision', 'name', 'short_name', 'theme',
      'slogan', 'support_name', 'support_email', 'support_phone', 'help_url', 'locale', 'time_zone', 'changed',
      'restored_from', 'actor_user_id', 'created_at']) || jsonb_build_object('has_logo', r.logo_key is not null),
      lpad(r.revision::text, 10, '0')
    from org.tenant_setting_revisions r where r.tenant_id = p_tenant_id
    union all
    select 3, 'offices', backups.pick(to_jsonb(o), array['id', 'parent_office_id', 'office_type', 'name', 'status',
      'created_by', 'created_at']), o.created_at::text || o.id::text
    from org.offices o where o.tenant_id = p_tenant_id
    union all
    select 4, 'office_moves', backups.pick(to_jsonb(x), array['id', 'office_id', 'from_parent_id', 'to_parent_id',
      'reason', 'actor_user_id', 'at']), x.at::text || x.id::text
    from org.office_moves x where x.tenant_id = p_tenant_id
    union all
    select 5, 'people', jsonb_build_object('user_id', a.user_id, 'uid', a.uid, 'status', a.status,
      'display_name', pr.display_name, 'first_name', pr.first_name, 'last_name', pr.last_name, 'email', u.email,
      'phone', pr.phone, 'rank', pr.rank, 'created_at', a.created_at), a.uid
    from people p
    join identity.accounts a on a.user_id = p.user_id
    left join identity.profiles pr on pr.user_id = p.user_id
    left join auth.users u on u.id = p.user_id
    union all
    select 6, 'memberships', backups.pick(to_jsonb(m), array['id', 'office_id', 'user_id', 'role', 'is_primary',
      'status', 'started_at', 'ended_at', 'ended_reason', 'replaced_by_id', 'created_by']),
      m.started_at::text || m.id::text
    from org.memberships m where m.tenant_id = p_tenant_id
    union all
    select 7, 'membership_events', backups.pick(to_jsonb(x), array['id', 'membership_id', 'action', 'from_status',
      'to_status', 'reason', 'actor_user_id', 'at']), x.at::text || x.id::text
    from org.membership_events x where x.tenant_id = p_tenant_id
    union all
    select 8, 'invitations', backups.pick(to_jsonb(i), array['id', 'reference', 'office_id', 'role', 'email',
      'status', 'expires_at', 'invited_by', 'reason', 'created_at', 'accepted_at', 'accepted_user_id',
      'accepted_membership_id', 'revoked_at', 'revoked_by', 'revoke_reason']), i.created_at::text || i.id::text
    from org.invitations i where i.tenant_id = p_tenant_id
    union all
    select 9, 'invitation_events', backups.pick(to_jsonb(x), array['id', 'invitation_id', 'action', 'actor_user_id',
      'reason', 'at']), x.at::text || x.id::text
    from org.invitation_events x where x.tenant_id = p_tenant_id
    union all
    select 10, 'role_permissions', backups.pick(to_jsonb(x), array['role', 'permission_key', 'allowed', 'updated_by',
      'updated_at']), x.role::text || x.permission_key
    from authz.role_permissions x where x.tenant_id = p_tenant_id
    union all
    select 11, 'access_assignments', backups.pick(to_jsonb(x), array['id', 'subject_user_id', 'created_by', 'reason',
      'created_at', 'revoked_at', 'revoked_by', 'revoke_reason']), x.created_at::text || x.id::text
    from authz.access_assignments x where x.tenant_id = p_tenant_id
    union all
    select 12, 'access_rules', backups.pick(to_jsonb(x), array['id', 'assignment_id', 'subject_user_id',
      'permission_key', 'effect', 'scope_type', 'scope_office_id', 'scope_user_id', 'starts_at', 'expires_at',
      'revoked_at']), x.id::text
    from authz.access_rules x where x.tenant_id = p_tenant_id
    union all
    select 13, 'reviewer_assignments', backups.pick(to_jsonb(x), array['id', 'membership_id', 'assigned_by', 'reason',
      'assigned_at', 'ended_at', 'ended_by', 'end_reason']), x.assigned_at::text || x.id::text
    from authz.reviewer_assignments x where x.tenant_id = p_tenant_id
    union all
    select 14, 'pockets', backups.pick(to_jsonb(x), array['id', 'kind', 'name', 'sort_order', 'status', 'created_by',
      'created_at', 'retired_at']), x.created_at::text || x.id::text
    from ledger.pockets x where x.tenant_id = p_tenant_id
    union all
    select 15, 'allocation_policies', backups.pick(to_jsonb(x), array['id', 'version', 'source', 'reason',
      'created_by', 'created_at']) || jsonb_build_object('lines', (
        select coalesce(jsonb_agg(backups.pick(to_jsonb(l), array['pocket_id', 'name', 'sort_order', 'basis_points'])
          order by l.sort_order), '[]'::jsonb)
        from ledger.allocation_policy_lines l where l.policy_id = x.id)),
      lpad(x.version::text, 10, '0')
    from ledger.allocation_policies x where x.tenant_id = p_tenant_id
    union all
    select 16, 'ledger_accounts', backups.pick(to_jsonb(x), array['id', 'class', 'currency', 'wallet_id',
      'membership_id', 'office_id', 'owner_user_id', 'pocket_id', 'system_key', 'created_at']),
      x.created_at::text || x.id::text
    from acct x
    union all
    select 17, 'balances', backups.pick(to_jsonb(x), array['account_id', 'currency', 'posted', 'reserved', 'version',
      'updated_at']), x.account_id::text
    from ledger.balances x where x.tenant_id = p_tenant_id
    union all
    select 18, 'transactions', backups.pick(to_jsonb(x), array['id', 'reference', 'type', 'office_id',
      'membership_id', 'wallet_id', 'owner_user_id', 'actor_user_id', 'posted_at', 'metadata']),
      x.posted_at::text || x.id::text
    from tx x
    union all
    select 19, 'postings', jsonb_build_object('transaction_id', j.transaction_id, 'entry_no', j.entry_no,
      'currency', j.currency, 'line_no', p.line_no, 'account_id', p.account_id, 'amount', p.amount),
      j.transaction_id::text || lpad(j.entry_no::text, 6, '0') || lpad(p.line_no::text, 6, '0')
    from tx join ledger.journals j on j.transaction_id = tx.id join ledger.postings p on p.journal_id = j.id
    union all
    select 20, 'reservations', backups.pick(to_jsonb(x), array['id', 'account_id', 'amount', 'purpose',
      'source_type', 'source_id', 'status', 'consumed_amount', 'consumed_by_transaction_id', 'release_reason',
      'actor_user_id', 'created_at', 'settled_at']), x.created_at::text || x.id::text
    from ledger.reservations x join acct on acct.id = x.account_id
    union all
    select 21, 'income_records', backups.pick(to_jsonb(x), array['id', 'reference', 'office_id', 'membership_id',
      'wallet_id', 'owner_user_id', 'currency', 'amount', 'source', 'received_on', 'provider_reference', 'notes',
      'fee_amount', 'fee_currency', 'policy_id', 'transaction_id', 'recorded_by', 'recorded_at']) || jsonb_build_object(
        'allocations', (select coalesce(jsonb_agg(backups.pick(to_jsonb(l), array['pocket_id', 'pocket_name',
          'sort_order', 'basis_points', 'amount', 'account_id']) order by l.sort_order), '[]'::jsonb)
          from finance.income_allocations l where l.income_id = x.id)),
      x.recorded_at::text || x.id::text
    from finance.income_records x where x.tenant_id = p_tenant_id
    union all
    select 22, 'entries', backups.pick(to_jsonb(x), array['id', 'reference', 'kind', 'office_id', 'membership_id',
      'wallet_id', 'owner_user_id', 'currency', 'amount', 'direction', 'pocket_id', 'account_id', 'reservation_id',
      'destination_currency', 'destination_amount', 'quoted_rate', 'provider', 'observed_at', 'external_reference',
      'reason', 'notes', 'withdrawal_id', 'policy_id', 'status', 'submitted_by', 'reviewer_user_id',
      'reviewer_membership_id', 'review_reason', 'decided_at', 'transaction_id', 'created_at']) || jsonb_build_object(
        'lines', (select coalesce(jsonb_agg(backups.pick(to_jsonb(l), array['pocket_id', 'pocket_name', 'sort_order',
          'basis_points', 'amount', 'account_id']) order by l.sort_order), '[]'::jsonb)
          from finance.entry_lines l where l.entry_id = x.id)),
      x.created_at::text || x.id::text
    from finance.entries x where x.tenant_id = p_tenant_id
    union all
    select 23, 'pocket_transfers', backups.pick(to_jsonb(x), array['id', 'reference', 'office_id', 'membership_id',
      'wallet_id', 'owner_user_id', 'currency', 'source_account_id', 'destination_account_id', 'source_pocket_id',
      'destination_pocket_id', 'amount', 'reservation_id', 'requested_by', 'status', 'decided_by', 'decided_at',
      'decision_reason', 'transaction_id', 'created_at']), x.created_at::text || x.id::text
    from finance.pocket_transfers x where x.tenant_id = p_tenant_id
    union all
    select 24, 'reversals', backups.pick(to_jsonb(x), array['id', 'reference', 'original_transaction_id',
      'transaction_id', 'category', 'note', 'reversed_by', 'created_at']), x.created_at::text || x.id::text
    from finance.reversals x where x.tenant_id = p_tenant_id
    union all
    select 25, 'withdrawals', backups.pick(to_jsonb(x), array['id', 'reference', 'office_id', 'membership_id',
      'wallet_id', 'owner_user_id', 'account_id', 'pocket_id', 'currency', 'amount', 'payout_account_id', 'bank_code',
      'bank_name', 'account_last4', 'account_name', 'requested_by', 'status', 'reservation_id', 'approved_by',
      'approved_at', 'decided_by', 'decided_at', 'decision_reason', 'completed_at', 'transaction_id', 'created_at'])
      || case when x.reason is null then '{}'::jsonb else jsonb_build_object('reason', x.reason) end,
      x.created_at::text || x.id::text
    from wd x
    union all
    select 26, 'payouts', backups.pick(to_jsonb(x), array['id', 'withdrawal_id', 'attempt_no', 'status', 'revision',
      'submitted_by', 'created_at', 'settled_at']), x.created_at::text || x.id::text
    from po x
    union all
    select 27, 'payout_revisions', backups.pick(to_jsonb(x), array['id', 'payout_id', 'revision', 'amount',
      'fee_amount', 'paid_on', 'bank_reference', 'notes', 'evidence_id', 'submitted_by', 'created_at']),
      x.created_at::text || x.id::text
    from finance.payout_revisions x join po on po.id = x.payout_id
    union all
    select 28, 'payout_checks', backups.pick(to_jsonb(x), array['id', 'payout_id', 'revision_id', 'status', 'cycle',
      'outcome', 'reasons', 'model', 'policy_version', 'created_at', 'finished_at']), x.created_at::text || x.id::text
    from finance.payout_checks x join po on po.id = x.payout_id
    union all
    select 29, 'payout_reviews', backups.pick(to_jsonb(x), array['payout_id', 'reviewer_user_id',
      'reviewer_membership_id', 'decision', 'reason', 'decided_at']), x.decided_at::text || x.payout_id::text
    from finance.payout_reviews x join po on po.id = x.payout_id
    union all
    select 30, 'evidence', backups.pick(to_jsonb(x), array['id', 'purpose', 'uploaded_by', 'target_membership_id',
      'declared_name', 'size', 'sha256', 'mime', 'status', 'attached_type', 'attached_id', 'created_at',
      'finalized_at', 'settled_at']), x.created_at::text || x.id::text
    from evidence.files x where x.tenant_id = p_tenant_id
    union all
    select 31, 'subscription', jsonb_build_object('status', s.status, 'kind', s.kind, 'plan', p.key,
      'period_start', s.period_start, 'period_end', s.period_end, 'paused_at', s.paused_at, 'auto_renew', s.auto_renew,
      'next_plan', np.key, 'created_at', s.created_at, 'updated_at', s.updated_at), s.tenant_id::text
    from billing.subscriptions s join billing.plans p on p.id = s.plan_id
    left join billing.plans np on np.id = s.next_plan_id
    where s.tenant_id = p_tenant_id
    union all
    select 32, 'billing_periods', backups.pick(to_jsonb(x), array['id', 'kind', 'plan_id', 'starts_at', 'ends_at',
      'payment_id', 'actor_user_id', 'reason', 'created_at']), x.created_at::text || x.id::text
    from billing.periods x where x.tenant_id = p_tenant_id
    union all
    select 33, 'billing_payments', backups.pick(to_jsonb(x), array['id', 'reference', 'purpose', 'plan_id',
      'from_plan_id', 'amount', 'currency', 'days_left', 'status', 'applied', 'needs_review', 'initiated_by',
      'covers_from', 'covers_to', 'paid_at', 'created_at']), x.created_at::text || x.id::text
    from billing.payments x where x.tenant_id = p_tenant_id
    union all
    select 34, 'billing_owners', backups.pick(to_jsonb(x), array['id', 'user_id', 'membership_id', 'assigned_by',
      'assigned_at', 'ended_at', 'ended_by']), x.assigned_at::text || x.id::text
    from billing.owners x where x.tenant_id = p_tenant_id
    union all
    select 35, 'audit', backups.pick(to_jsonb(x), array['id', 'at', 'actor_user_id', 'action', 'target_type',
      'target_id', 'reason', 'safe_before', 'safe_after']), x.at::text || lpad(x.id::text, 20, '0')
    from audit.tenant_events x where x.tenant_id = p_tenant_id
  ) s (o, section, data, k)
  order by o, k;
$$;
