-- Blueprint 13 — B2: event sources. Each trigger runs inside the business
-- transaction that wrote the audit row, so the bell item and its email commit
-- (or roll back) with the change itself (F-02, T-03). Recipient rules are the
-- owner's answers of 2026-10-09 (Blueprint 13, "Who gets what").

create function notify.network(p_tenant_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select name from org.tenants where id = p_tenant_id;
$$;

create function notify.office(p_office_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select name from org.offices where id = p_office_id;
$$;

-- Display amount of a transaction for one wallet owner: what moved in or out
-- of their pockets in the first currency it touched (a pocket move counts the
-- amount moved, not the net zero).
create function notify.moved(p_transaction_id uuid, p_owner_user_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('amount', ledger.money(greatest(
      coalesce(sum(p.amount) filter (where p.amount > 0), 0),
      coalesce(-sum(p.amount) filter (where p.amount < 0), 0)), j.currency), 'currency', j.currency)
  from ledger.journals j
  join ledger.postings p on p.journal_id = j.id
  join ledger.accounts a on a.id = p.account_id
  where j.transaction_id = p_transaction_id and a.owner_user_id = p_owner_user_id
  group by j.currency, j.entry_no
  order by j.entry_no
  limit 1;
$$;

-- ── Tenant audit events (money, invitations, roles) ───────────────────────

create function notify.on_tenant_event()
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
            'office', coalesce(notify.office(w.office_id), network), 'path', path));
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

create trigger tenant_events_notify
after insert on audit.tenant_events
for each row execute function notify.on_tenant_event();

-- ── Memberships ended (A12) ────────────────────────────────────────────────
-- Every ending path (end membership, office close, ...) records `ended`; a
-- role change records `replaced` and gets A11 instead.

create function notify.on_membership_event()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  m org.memberships;
  base jsonb;
begin
  select * into m from org.memberships where id = new.membership_id;
  base := jsonb_strip_nulls(jsonb_build_object('office', notify.office(m.office_id), 'path', '/app/activity'));
  perform notify.emit(m.user_id, m.tenant_id, 'account.membership_ended', 'membership', m.id, base,
    'membership.ended:' || m.id::text, base || jsonb_build_object('network', notify.network(m.tenant_id)));
  return null;
end;
$$;

create trigger membership_events_notify
after insert on org.membership_events
for each row when (new.action = 'ended')
execute function notify.on_membership_event();

-- ── Account status (A10, platform admin) ───────────────────────────────────

create function notify.on_security_event()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  base jsonb;
begin
  base := jsonb_build_object('status', coalesce(new.safe_after->>'status', 'changed'), 'path', '/app');
  perform notify.emit(new.target_user_id, null, 'account.status_changed', 'account', new.target_user_id, base,
    'account.status_changed:' || new.id::text, base);
  return null;
end;
$$;

create trigger security_events_notify
after insert on audit.security_events
for each row when (new.action = 'account.status_changed' and new.target_user_id is not null)
execute function notify.on_security_event();

-- ── NIN reviews to decide (task only; Blueprint 06 Q4 reviewers) ──────────

create function notify.on_nin_review()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  holder uuid;
  base jsonb;
begin
  base := jsonb_build_object('member', notify.full_name(new.user_id),
    'office', coalesce(notify.office((select office_id from org.memberships where id = new.membership_id)),
      notify.network(new.tenant_id)),
    'path', '/app/reviews');
  for holder in
    select distinct m.user_id from org.memberships m
    where m.tenant_id = new.tenant_id and m.status = 'active' and identity.can_review(m, new)
  loop
    perform notify.emit(holder, new.tenant_id, 'task.nin_review', 'nin_review', new.id, base,
      'nin_review.requested:' || new.id::text);
  end loop;
  return null;
end;
$$;

create trigger nin_reviews_notify
after insert on identity.nin_reviews
for each row when (new.status = 'pending')
execute function notify.on_nin_review();

-- ── Older person emails get their bell item ───────────────────────────────

create function notify.on_person_email()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  insert into notify.items (user_id, tenant_id, kind, task, subject_type, subject_id, params, email_event_id,
    dedupe_key)
  values (new.recipient_user_id, new.tenant_id, new.template, false, new.aggregate_type, new.aggregate_id,
    new.params || jsonb_build_object('path', case new.template
      when 'payout_account.alert' then '/app/payout-accounts' else '/app' end),
    new.id, 'outbox:' || new.id::text)
  on conflict (user_id, dedupe_key) do nothing;
  return null;
end;
$$;

create trigger events_person_notify
after insert on outbox.events
for each row when (new.recipient_user_id is not null
  and new.template in ('identity.nin_review_decided', 'payout_account.alert'))
execute function notify.on_person_email();

revoke all on all functions in schema notify from public, anon, authenticated;
