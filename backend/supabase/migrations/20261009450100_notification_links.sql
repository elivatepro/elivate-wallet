-- Slice 45 (Blueprint 45): the owner's own withdrawal news opens that
-- withdrawal (Blueprint 44 D4, /app/withdrawals/<id>) instead of the list.
-- Bell items, Web Push and the M02/M03 emails share the one `path` param, so
-- all three follow; the allow-lists (frontend app-path, push text, email
-- notifications) accept exactly /app/withdrawals/<lowercase uuid>. Approver
-- and payout tasks keep their queue paths. Items already stored keep theirs.
-- Deploy the outbox worker with this (its email allow-list must know the path).
--
-- notify.on_tenant_event as last defined in 20261009400100_withdrawal_reason.sql;
-- the only change is the owner's `path`.

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
      'currency', w.currency, 'path', '/app/withdrawals/' || w.id::text);
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
