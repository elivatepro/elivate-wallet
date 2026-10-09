-- Blueprint 11 — W-09 withdrawals: request (hold), approve, reject, cancel,
-- destination reveal, and the reads behind My withdrawals and the queue.
-- Order in every command: session gate (step-up where required) → workspace →
-- target and authorization → idempotent replay → row locks → state checks.

-- The open payout record of a withdrawal, if any.
create function finance.open_payout(p_withdrawal_id uuid)
returns finance.payouts
language sql
stable
set search_path = ''
as $$
  select * from finance.payouts
  where withdrawal_id = p_withdrawal_id and status in ('verifying', 'correction_required', 'needs_review');
$$;

create function finance.can(
  p_user_id uuid,
  p_permission text,
  p_tenant_id uuid,
  p_office_id uuid,
  p_target_user_id uuid,
  p_workspace_id uuid
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_workspace_id is not null and coalesce((authz.decide(p_user_id, p_permission, p_tenant_id, p_office_id,
    p_target_user_id, p_workspace_id)->>'allowed')::boolean, false);
$$;

create function finance.payout_json(p_payout finance.payouts, p_detail boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'payoutId', p_payout.id,
    'attemptNo', p_payout.attempt_no,
    'status', p_payout.status,
    'revision', p_payout.revision,
    'submittedBy', org.person(p_payout.submitted_by),
    'createdAt', p_payout.created_at,
    'settledAt', p_payout.settled_at,
    'revisions', (
      select jsonb_agg(jsonb_build_object(
        'revision', r.revision,
        'amount', ledger.money(r.amount, 'NGN'),
        'fee', case when r.fee_amount is not null then ledger.money(r.fee_amount, 'NGN') end,
        'paidOn', r.paid_on,
        'bankReference', r.bank_reference,
        'notes', r.notes,
        'receipt', jsonb_build_object('evidenceId', f.id, 'name', f.declared_name, 'mimeType', f.mime, 'size', f.size),
        'createdAt', r.created_at,
        'check', (
          select jsonb_build_object(
            'status', c.status,
            'outcome', c.outcome,
            'reasons', to_jsonb(coalesce(c.reasons, '{}'::text[])),
            'attempts', c.attempts,
            'lastError', c.last_error,
            'finishedAt', c.finished_at,
            'facts', case when p_detail then c.facts->'receipt' end
          )
          from finance.payout_checks c where c.revision_id = r.id
        )
      ) order by r.revision)
      from finance.payout_revisions r
      join evidence.files f on f.id = r.evidence_id
      where r.payout_id = p_payout.id
    ),
    'review', (
      select jsonb_build_object('decision', v.decision, 'reason', v.reason, 'decidedAt', v.decided_at,
        'reviewer', org.person(v.reviewer_user_id))
      from finance.payout_reviews v where v.payout_id = p_payout.id
    )
  );
$$;

-- What the viewer may do next. Capabilities are hints for the UI; every
-- command re-checks them.
create function finance.withdrawal_caps(p_w finance.withdrawals, p_user_id uuid, p_workspace_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  open finance.payouts;
  check_status text;
  approver boolean;
  leader boolean;
begin
  open := finance.open_payout(p_w.id);
  leader := p_user_id <> p_w.owner_user_id
    and finance.can(p_user_id, 'approve_withdrawal', p_w.tenant_id, p_w.office_id, p_w.owner_user_id, p_workspace_id);
  approver := leader and p_w.approved_by = p_user_id;
  if open.id is not null then
    select c.status into check_status from finance.payout_checks c
    join finance.payout_revisions r on r.id = c.revision_id
    where r.payout_id = open.id and r.revision = open.revision;
  end if;
  return jsonb_build_object(
    'approve', p_w.status = 'requested' and leader,
    'reject', p_w.status = 'requested' and leader,
    'cancel', (p_w.status = 'requested' and p_user_id in (p_w.owner_user_id, p_w.requested_by))
      or (p_w.status = 'approved' and leader and open.id is null),
    'reveal', p_w.status = 'approved' and approver,
    'record', p_w.status = 'approved' and approver and open.id is null,
    'correct', p_w.status = 'approved' and approver and open.status = 'correction_required',
    'retryCheck', p_w.status = 'approved' and approver and open.status = 'verifying' and check_status = 'dead'
  );
end;
$$;

create function finance.withdrawal_json(p_withdrawal_id uuid, p_user_id uuid, p_workspace_id uuid)
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

-- A segment the actor may withdraw from: own (initiate_own_withdrawal) or a
-- managed member's (withdraw_on_behalf). Naira, ordinary pocket, active
-- membership in an active office (ended memberships keep read-only money).
create function finance.withdrawal_source(p_user_id uuid, p_workspace org.memberships, p_account_id uuid)
returns ledger.accounts
language plpgsql
set search_path = ''
as $$
declare
  account ledger.accounts;
  membership org.memberships;
  pocket ledger.pockets;
begin
  select * into account from ledger.accounts
  where id = p_account_id and class = 'member_value' and tenant_id = p_workspace.tenant_id;
  if account.id is null then
    perform identity.fail('not_found');
  end if;
  select * into membership from org.memberships where id = account.membership_id;
  if account.owner_user_id = p_user_id then
    perform authz.require(p_user_id, 'initiate_own_withdrawal', p_workspace.tenant_id, null, p_user_id, p_workspace.id);
  else
    perform authz.require(p_user_id, 'withdraw_on_behalf', p_workspace.tenant_id, membership.office_id,
      account.owner_user_id, p_workspace.id);
  end if;
  if not finance.target_eligible(membership) then
    perform identity.fail('target_not_eligible');
  end if;
  if account.currency <> 'NGN' then
    perform identity.fail('currency_not_supported', jsonb_build_object('currency', account.currency));
  end if;
  select * into pocket from ledger.pockets where id = account.pocket_id;
  if pocket.kind <> 'ordinary' or pocket.status <> 'active' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'accountId', 'reason', 'pocket_not_withdrawable'));
  end if;
  return account;
end;
$$;

-- A withdrawal of the workspace's network, unlocked; not_found otherwise.
create function finance.withdrawal_in(p_tenant_id uuid, p_withdrawal_id uuid)
returns finance.withdrawals
language plpgsql
set search_path = ''
as $$
declare
  w finance.withdrawals;
begin
  select * into w from finance.withdrawals where id = p_withdrawal_id and tenant_id = p_tenant_id;
  if w.id is null then
    perform identity.fail('not_found');
  end if;
  return w;
end;
$$;

create function finance.require_approver(p_user_id uuid, p_workspace org.memberships, p_w finance.withdrawals)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform authz.require(p_user_id, 'approve_withdrawal', p_w.tenant_id, p_w.office_id, p_w.owner_user_id, p_workspace.id);
end;
$$;

-- ── Reads ─────────────────────────────────────────────────────────────────

-- New withdrawal (M06): own Naira segments of active memberships in this
-- network with what is available, and the payout accounts that may be used.
create function api.withdrawal_sources(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform authz.require(p_user_id, 'initiate_own_withdrawal', workspace.tenant_id, null, p_user_id, workspace.id);
  return jsonb_build_object(
    'currency', 'NGN',
    'sources', coalesce((
      select jsonb_agg(jsonb_build_object(
        'accountId', b.account_id,
        'membershipId', b.membership_id,
        'office', jsonb_build_object('id', o.id, 'name', o.name),
        'pocket', jsonb_build_object('pocketId', pk.id, 'name', pk.name),
        'posted', ledger.money(b.posted, b.currency),
        'reserved', ledger.money(b.reserved, b.currency),
        'available', ledger.money(b.posted - b.reserved, b.currency)
      ) order by pk.sort_order, pk.id, o.name, b.membership_id)
      from ledger.balances b
      join ledger.pockets pk on pk.id = b.pocket_id
      join org.memberships m on m.id = b.membership_id
      join org.offices o on o.id = b.office_id
      where b.owner_user_id = p_user_id and b.tenant_id = workspace.tenant_id and b.currency = 'NGN'
        and pk.kind = 'ordinary' and pk.status = 'active' and finance.target_eligible(m)
        and (b.posted > 0 or b.reserved > 0)
    ), '[]'::jsonb),
    'payoutAccounts', coalesce((
      select jsonb_agg(payout.account_json(a) || jsonb_build_object(
        'usable', a.verification_status = 'verified' and a.name_match <> 'mismatched' and a.usable_from <= now())
        order by a.is_primary desc, a.created_at desc, a.id)
      from payout.accounts a
      where a.owner_user_id = p_user_id and a.status = 'active'
    ), '[]'::jsonb)
  );
end;
$$;

-- My withdrawals (W01): own requests in this network. Status filter `open`
-- (requested/approved), `completed`, `closed` (rejected/cancelled).
create function api.my_withdrawals(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_status text,
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
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  if p_status is not null and p_status not in ('open', 'completed', 'closed') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'status'));
  end if;
  page_size := org.page_limit(p_limit);
  after := org.decode_cursor(p_cursor);
  return finance.withdrawal_page(workspace, p_user_id, 'own', p_status, after, page_size);
end;
$$;

-- Shared paging over withdrawals, newest first.
create function finance.withdrawal_page(
  p_workspace org.memberships,
  p_user_id uuid,
  p_view text,
  p_filter text,
  p_after jsonb,
  p_limit int
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  after_at timestamptz;
  after_id uuid;
  result jsonb;
begin
  if p_after is not null then
    begin
      after_at := (p_after->>'s')::timestamptz;
      after_id := (p_after->>'id')::uuid;
    exception when others then
      perform identity.fail('validation_error', jsonb_build_object('field', 'cursor'));
    end;
    if after_at is null or after_id is null then
      perform identity.fail('validation_error', jsonb_build_object('field', 'cursor'));
    end if;
  end if;

  with base as (
    select w.*, finance.open_payout(w.id) as open
    from finance.withdrawals w
    where w.tenant_id = p_workspace.tenant_id
      and case p_view
        when 'own' then w.owner_user_id = p_user_id
        else w.owner_user_id <> p_user_id
          and finance.can(p_user_id, 'approve_withdrawal', w.tenant_id, w.office_id, w.owner_user_id, p_workspace.id)
      end
  ),
  tabbed as (
    select b.*, (select c.status from finance.payout_checks c
                 join finance.payout_revisions r on r.id = c.revision_id
                 where r.payout_id = (b.open).id and r.revision = (b.open).revision) as check_status
    from base b
  ),
  filtered as (
    select * from tabbed t
    where case p_filter
      when 'open' then t.status in ('requested', 'approved')
      when 'completed' then t.status = 'completed'
      when 'closed' then t.status in ('rejected', 'cancelled')
      when 'action' then t.status = 'requested'
        or (t.status = 'approved' and ((t.open).id is null or (t.open).status = 'correction_required'
            or t.check_status = 'dead'))
      when 'verifying' then t.status = 'approved' and (t.open).status in ('verifying', 'needs_review')
        and t.check_status is distinct from 'dead'
      else true
    end
  ),
  page as (
    select f.id, f.created_at, row_number() over (order by f.created_at desc, f.id desc) as n
    from filtered f
    where p_after is null or (f.created_at, f.id) < (after_at, after_id)
    order by f.created_at desc, f.id desc
    limit p_limit + 1
  )
  select jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(finance.withdrawal_json(p.id, p_user_id, p_workspace.id) order by p.n)
      from page p where p.n <= p_limit
    ), '[]'::jsonb),
    'nextCursor', (
      select org.encode_cursor(jsonb_build_object(
        's', to_char(p.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), 'id', p.id))
      from page p where p.n = p_limit and exists (select 1 from page q where q.n > p_limit)
    ),
    'counts', (
      select jsonb_build_object(
        'all', count(*),
        'open', count(*) filter (where t.status in ('requested', 'approved')),
        'completed', count(*) filter (where t.status = 'completed'),
        'closed', count(*) filter (where t.status in ('rejected', 'cancelled')),
        'requested', count(*) filter (where t.status = 'requested'),
        'approved', count(*) filter (where t.status = 'approved'),
        'action', count(*) filter (where t.status = 'requested'
          or (t.status = 'approved' and ((t.open).id is null or (t.open).status = 'correction_required'
              or t.check_status = 'dead'))),
        'verifying', count(*) filter (where t.status = 'approved' and (t.open).status in ('verifying', 'needs_review')
          and t.check_status is distinct from 'dead'))
      from tabbed t
    ),
    'reserved', (
      select ledger.money(coalesce(sum(r.amount), 0), 'NGN')
      from tabbed t join ledger.reservations r on r.id = t.reservation_id
      where r.status = 'active' and (p_filter is distinct from 'action' or t.status = 'requested')
    )
  ) into result;
  return result;
end;
$$;

create function api.my_withdrawal(p_user_id uuid, p_session_id uuid, p_membership_id uuid, p_withdrawal_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  w finance.withdrawals;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  w := finance.withdrawal_in(workspace.tenant_id, p_withdrawal_id);
  if w.owner_user_id <> p_user_id and w.requested_by <> p_user_id then
    perform identity.fail('not_found');
  end if;
  return finance.withdrawal_json(w.id, p_user_id, workspace.id);
end;
$$;

-- Withdrawal queue (T03): requests from members this workspace may approve.
-- Tabs: `action`, `verifying`, `completed`, `closed`.
create function api.withdrawal_queue(
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
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  if p_tab is null or p_tab not in ('action', 'verifying', 'completed', 'closed') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'tab'));
  end if;
  if not exists (
    select 1 from authz.role_permissions rp
    where rp.tenant_id = workspace.tenant_id and rp.role = workspace.role
      and rp.permission_key = 'approve_withdrawal' and rp.allowed
  ) and not exists (
    select 1 from authz.access_rules r
    where r.tenant_id = workspace.tenant_id and r.subject_user_id = p_user_id
      and r.permission_key = 'approve_withdrawal' and r.effect = 'allow' and r.revoked_at is null
  ) then
    perform identity.fail('authorization_denied');
  end if;
  return finance.withdrawal_page(workspace, p_user_id, 'leader', p_tab, org.decode_cursor(p_cursor),
    org.page_limit(p_limit));
end;
$$;

create function api.withdrawal_detail(p_user_id uuid, p_session_id uuid, p_membership_id uuid, p_withdrawal_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  w finance.withdrawals;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  w := finance.withdrawal_in(workspace.tenant_id, p_withdrawal_id);
  if w.owner_user_id = p_user_id then
    perform identity.fail('not_found');
  end if;
  perform finance.require_approver(p_user_id, workspace, w);
  return finance.withdrawal_json(w.id, p_user_id, workspace.id);
end;
$$;

-- ── Commands ──────────────────────────────────────────────────────────────

create function api.request_withdrawal(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_account_id uuid,
  p_amount text,
  p_payout_account_id uuid,
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

  request := jsonb_build_object('accountId', account.id, 'amount', ledger.money(v_amount, 'NGN'),
    'payoutAccountId', p_payout_account_id);
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
    account_ciphertext, key_version, account_name, requested_by, reservation_id, idempotency_key)
  values (v_id, v_reference, account.tenant_id, account.office_id, account.membership_id, account.wallet_id,
    account.owner_user_id, account.id, account.pocket_id, 'NGN', v_amount, destination.id, destination.bank_code,
    destination.bank_name, destination.account_last4, destination.account_ciphertext, destination.key_version,
    destination.account_name, p_user_id, v_reservation, p_idempotency_key);

  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'withdrawal.requested', 'withdrawal', v_id::text,
    p_safe_after => jsonb_build_object('reference', v_reference, 'amount', ledger.money(v_amount, 'NGN'),
      'membershipId', account.membership_id, 'onBehalf', account.owner_user_id <> p_user_id,
      'payoutAccountId', destination.id),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'request_withdrawal', request,
    finance.withdrawal_json(v_id, p_user_id, workspace.id));
end;
$$;

create function api.approve_withdrawal(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_withdrawal_id uuid,
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
  membership org.memberships;
  request jsonb;
  replayed jsonb;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  w := finance.withdrawal_in(workspace.tenant_id, p_withdrawal_id);
  perform finance.require_approver(p_user_id, workspace, w);

  request := jsonb_build_object('withdrawalId', w.id);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'approve_withdrawal', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into w from finance.withdrawals where id = w.id for update;
  if w.status <> 'requested' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'withdrawal_state', 'status', w.status));
  end if;
  select * into membership from org.memberships where id = w.membership_id for share;
  if not finance.target_eligible(membership) then
    perform identity.fail('target_not_eligible');
  end if;
  -- The snapshot stays as requested; the account behind it must still be usable.
  perform payout.eligible_destination(w.owner_user_id, w.payout_account_id);

  update finance.withdrawals set status = 'approved', approved_by = p_user_id where id = w.id;
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'withdrawal.approved', 'withdrawal', w.id::text,
    p_safe_after => jsonb_build_object('reference', w.reference, 'amount', ledger.money(w.amount, 'NGN')),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'approve_withdrawal', request,
    finance.withdrawal_json(w.id, p_user_id, workspace.id));
end;
$$;

create function api.reject_withdrawal(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_withdrawal_id uuid,
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
  w finance.withdrawals;
  clean_reason text;
  request jsonb;
  replayed jsonb;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  w := finance.withdrawal_in(workspace.tenant_id, p_withdrawal_id);
  perform finance.require_approver(p_user_id, workspace, w);
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('withdrawalId', w.id, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'reject_withdrawal', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into w from finance.withdrawals where id = w.id for update;
  if w.status <> 'requested' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'withdrawal_state', 'status', w.status));
  end if;
  perform ledger.release(w.reservation_id, 'Withdrawal rejected: ' || clean_reason, p_user_id);
  update finance.withdrawals
  set status = 'rejected', decided_by = p_user_id, decision_reason = clean_reason
  where id = w.id;
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'withdrawal.rejected', 'withdrawal', w.id::text,
    p_reason => clean_reason,
    p_safe_after => jsonb_build_object('reference', w.reference, 'amount', ledger.money(w.amount, 'NGN')),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'reject_withdrawal', request,
    finance.withdrawal_json(w.id, p_user_id, workspace.id));
end;
$$;

-- Requested: the member or the leader who asked on their behalf, no reason
-- (Paper W03). Approved: a leader who may approve it, only with no open payout
-- record, reason and PIN (W-09).
create function api.cancel_withdrawal(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_withdrawal_id uuid,
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
  w finance.withdrawals;
  clean_reason text;
  request jsonb;
  replayed jsonb;
  as_leader boolean;
begin
  perform identity.require_live_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  w := finance.withdrawal_in(workspace.tenant_id, p_withdrawal_id);
  as_leader := w.status = 'approved';

  if as_leader then
    perform org.require_writer(p_user_id, p_session_id, true);
    perform org.require_active_tenant(workspace.tenant_id);
    perform finance.require_approver(p_user_id, workspace, w);
    clean_reason := identity.require_reason(p_reason);
  else
    perform org.require_writer(p_user_id, p_session_id);
    if w.owner_user_id = p_user_id then
      perform authz.require(p_user_id, 'initiate_own_withdrawal', w.tenant_id, null, p_user_id, workspace.id);
    elsif w.requested_by = p_user_id then
      perform authz.require(p_user_id, 'withdraw_on_behalf', w.tenant_id, w.office_id, w.owner_user_id, workspace.id);
    else
      perform identity.fail('not_found');
    end if;
    if p_reason is not null then
      clean_reason := identity.require_reason(p_reason);
    end if;
  end if;

  request := jsonb_build_object('withdrawalId', w.id, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'cancel_withdrawal', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into w from finance.withdrawals where id = w.id for update;
  if w.status not in ('requested', 'approved') or (w.status = 'approved') <> as_leader then
    perform identity.fail('conflict', jsonb_build_object('reason', 'withdrawal_state', 'status', w.status));
  end if;
  if as_leader and exists (
    select 1 from finance.payouts p
    where p.withdrawal_id = w.id and p.status in ('verifying', 'correction_required', 'needs_review')
    for update
  ) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'payout_open'));
  end if;

  perform ledger.release(w.reservation_id,
    coalesce('Withdrawal cancelled: ' || clean_reason, 'Withdrawal cancelled by the requester'), p_user_id);
  update finance.withdrawals
  set status = 'cancelled', decided_by = p_user_id, decision_reason = clean_reason
  where id = w.id;
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'withdrawal.cancelled', 'withdrawal', w.id::text,
    p_reason => clean_reason,
    p_safe_after => jsonb_build_object('reference', w.reference, 'amount', ledger.money(w.amount, 'NGN'),
      'wasApproved', as_leader),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'cancel_withdrawal', request,
    finance.withdrawal_json(w.id, p_user_id, workspace.id));
end;
$$;

-- W-10 step 2: the approving leader, still allowed to approve it, with a fresh
-- PIN, while it is approved and held. Audited before the ciphertext leaves;
-- the Edge Function decrypts and answers with cache-control: no-store.
create function api.reveal_withdrawal_destination(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_withdrawal_id uuid,
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
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  w := finance.withdrawal_in(workspace.tenant_id, p_withdrawal_id);
  perform finance.require_approver(p_user_id, workspace, w);
  select * into w from finance.withdrawals where id = w.id for share;
  if w.status <> 'approved' or not exists (
    select 1 from ledger.reservations r where r.id = w.reservation_id and r.status = 'active'
  ) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'withdrawal_state', 'status', w.status));
  end if;
  if w.approved_by <> p_user_id then
    perform identity.fail('authorization_denied', jsonb_build_object('reason', 'not_approver'));
  end if;
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'withdrawal.destination_revealed', 'withdrawal',
    w.id::text, p_safe_after => jsonb_build_object('reference', w.reference, 'accountLast4', w.account_last4),
    p_request_id => p_request_id);
  return jsonb_build_object(
    'withdrawalId', w.id,
    'reference', w.reference,
    'bankCode', w.bank_code,
    'bankName', w.bank_name,
    'accountName', w.account_name,
    'accountLast4', w.account_last4,
    'ownerUserId', w.owner_user_id,
    'ciphertext', w.account_ciphertext,
    'keyVersion', w.key_version
  );
end;
$$;
