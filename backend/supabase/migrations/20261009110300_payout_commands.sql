-- Blueprint 11 — W-10 payout recording, the E-03 receipt check worker, one
-- correction, W-11 independent review, and the completion posting.

-- ── Evidence: payout receipts ─────────────────────────────────────────────

-- The uploader's own file in this workspace's network. Income receipts need
-- record_income on the target; payout receipts approve_withdrawal.
create or replace function evidence.require_own_file(
  p_user_id uuid,
  p_workspace org.memberships,
  p_evidence_id uuid,
  p_lock boolean default false
)
returns evidence.files
language plpgsql
set search_path = ''
as $$
declare
  file evidence.files;
  target org.memberships;
begin
  if p_lock then
    select * into file from evidence.files
    where id = p_evidence_id and tenant_id = p_workspace.tenant_id and uploaded_by = p_user_id
    for update;
  else
    select * into file from evidence.files
    where id = p_evidence_id and tenant_id = p_workspace.tenant_id and uploaded_by = p_user_id;
  end if;
  if file.id is null then
    perform identity.fail('not_found');
  end if;
  select * into target from org.memberships where id = file.target_membership_id;
  perform authz.require(p_user_id, case file.purpose when 'payout' then 'approve_withdrawal' else 'record_income' end,
    p_workspace.tenant_id, target.office_id, target.user_id, p_workspace.id);
  return file;
end;
$$;

-- The approving leader of an approved, held withdrawal.
create function finance.require_payout_actor(p_user_id uuid, p_workspace org.memberships, p_w finance.withdrawals)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform finance.require_approver(p_user_id, p_workspace, p_w);
  if p_w.approved_by is distinct from p_user_id then
    perform identity.fail('authorization_denied', jsonb_build_object('reason', 'not_approver'));
  end if;
end;
$$;

create function api.create_payout_evidence_upload(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_withdrawal_id uuid,
  p_command_key text,
  p_file_name text,
  p_mime_type text,
  p_size int,
  p_sha256 text,
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
  v_id uuid := gen_random_uuid();
  file evidence.files;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  w := finance.withdrawal_in(workspace.tenant_id, p_withdrawal_id);
  perform finance.require_payout_actor(p_user_id, workspace, w);
  if w.status <> 'approved' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'withdrawal_state', 'status', w.status));
  end if;

  if p_command_key is null or p_command_key !~ '^[A-Za-z0-9_-]{16,100}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'idempotencyKey'));
  end if;
  if p_file_name is null or length(btrim(p_file_name)) not between 1 and 200 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'fileName'));
  end if;
  if p_mime_type is null or p_mime_type not in ('application/pdf', 'image/jpeg', 'image/png') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'mimeType'));
  end if;
  if p_size is null or p_size not between 1 and evidence.max_size() then
    perform identity.fail('validation_error', jsonb_build_object('field', 'size'));
  end if;
  if p_sha256 is null or lower(p_sha256) !~ '^[0-9a-f]{64}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'sha256'));
  end if;

  perform pg_advisory_xact_lock(hashtextextended('evidence.command:' || p_user_id::text || ':' || p_command_key, 0));
  if (
    select count(*) from evidence.files
    where uploaded_by = p_user_id and command_key = p_command_key
      and status in ('pending', 'finalized') and expires_at > now()
  ) >= evidence.max_open_per_command() then
    perform identity.fail('rate_limited', jsonb_build_object('retryAfterSeconds', 60));
  end if;

  insert into evidence.files (id, tenant_id, purpose, uploaded_by, target_membership_id, command_key, object_path,
    declared_name, declared_mime, declared_size, declared_sha256, expires_at)
  values (v_id, workspace.tenant_id, 'payout', p_user_id, w.membership_id, p_command_key,
    workspace.tenant_id::text || '/payout/' || v_id::text,
    btrim(p_file_name), p_mime_type, p_size, lower(p_sha256), now() + evidence.upload_ttl())
  returning * into file;

  return jsonb_build_object('evidenceId', file.id, 'objectPath', file.object_path, 'expiresAt', file.expires_at);
end;
$$;

-- Validated payout facts (W-10 step 3), shared by record and correct.
create function finance.payout_facts(
  p_w finance.withdrawals,
  p_amount text,
  p_fee_amount text,
  p_paid_on text,
  p_bank_reference text,
  p_notes text
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_amount numeric;
  v_fee numeric;
  v_paid date;
  today date := (now() at time zone finance.payout_zone())::date;
begin
  v_amount := ledger.parse_amount(p_amount, 'NGN', 'amount');
  if p_fee_amount is not null then
    v_fee := ledger.parse_amount(p_fee_amount, 'NGN', 'fee');
  end if;
  if v_amount + coalesce(v_fee, 0) > p_w.amount then
    perform identity.fail('validation_error', jsonb_build_object('field', 'amount', 'reason', 'exceeds_request',
      'maximum', ledger.money(p_w.amount, 'NGN')));
  end if;
  begin
    v_paid := p_paid_on::date;
  exception when others then
    perform identity.fail('validation_error', jsonb_build_object('field', 'paidOn'));
  end;
  if p_paid_on !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or v_paid > today + 1
    -- The earlier of the approval's Lagos and UTC dates: a receipt that prints
    -- a time zone is compared on its UTC date (owner decision 2026-10-09).
    or v_paid < least((p_w.approved_at at time zone finance.payout_zone())::date,
                      (p_w.approved_at at time zone 'UTC')::date) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'paidOn'));
  end if;
  return jsonb_build_object(
    'amount', ledger.money(v_amount, 'NGN'),
    'fee', case when v_fee is not null then ledger.money(v_fee, 'NGN') end,
    'paidOn', v_paid,
    'bankReference', case when p_bank_reference is not null then org.require_text(p_bank_reference, 'bankReference', 1, 100) end,
    'notes', case when p_notes is not null then org.require_text(p_notes, 'notes', 1, 1000) end
  );
end;
$$;

-- The receipt for a revision: the actor's finalized payout upload for this
-- withdrawal and command key. Locked; attached by the caller.
create function finance.take_receipt(
  p_user_id uuid,
  p_w finance.withdrawals,
  p_evidence_id uuid,
  p_key text
)
returns evidence.files
language plpgsql
set search_path = ''
as $$
declare
  file evidence.files;
begin
  select * into file from evidence.files
  where id = p_evidence_id and tenant_id = p_w.tenant_id and purpose = 'payout' and uploaded_by = p_user_id
    and target_membership_id = p_w.membership_id and command_key = p_key
    and status = 'finalized' and expires_at > now()
  for update;
  if file.id is null then
    perform identity.fail('evidence_invalid');
  end if;
  return file;
end;
$$;

create function finance.add_revision(
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
  where id = p_evidence_id;
  insert into finance.payout_checks (payout_id, revision_id, next_attempt_at)
  values (p_payout_id, v_revision_id, now());
  return v_revision_id;
end;
$$;

create function api.record_payout(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_withdrawal_id uuid,
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
  facts jsonb;
  request jsonb;
  replayed jsonb;
  v_payout_id uuid;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  w := finance.withdrawal_in(workspace.tenant_id, p_withdrawal_id);
  perform finance.require_payout_actor(p_user_id, workspace, w);
  -- State is checked after the replay lookup (under the lock), so a same-key
  -- retry still gets its saved result after the withdrawal completed.
  facts := finance.payout_facts(w, p_amount, p_fee_amount, p_paid_on, p_bank_reference, p_notes);
  if p_evidence_id is null then
    perform identity.fail('evidence_required');
  end if;

  request := facts || jsonb_build_object('withdrawalId', w.id, 'evidenceId', p_evidence_id);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'record_payout', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into w from finance.withdrawals where id = w.id for update;
  if w.status <> 'approved' or not exists (
    select 1 from ledger.reservations r where r.id = w.reservation_id and r.status = 'active'
  ) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'withdrawal_state', 'status', w.status));
  end if;
  if (finance.open_payout(w.id)).id is not null then
    perform identity.fail('conflict', jsonb_build_object('reason', 'payout_open'));
  end if;
  perform finance.take_receipt(p_user_id, w, p_evidence_id, p_idempotency_key);

  insert into finance.payouts (withdrawal_id, attempt_no, submitted_by)
  values (w.id, (select coalesce(max(attempt_no), 0) + 1 from finance.payouts where withdrawal_id = w.id), p_user_id)
  returning id into v_payout_id;
  perform finance.add_revision(v_payout_id, 1, facts, p_evidence_id, p_user_id, p_idempotency_key);

  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'payout.recorded', 'payout', v_payout_id::text,
    p_safe_after => jsonb_build_object('reference', w.reference, 'amount', facts->'amount', 'fee', facts->'fee',
      'paidOn', facts->'paidOn', 'revision', 1),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'record_payout', request,
    finance.withdrawal_json(w.id, p_user_id, workspace.id));
end;
$$;

-- The one correction (E-02): revision 1 failed the check; the same leader
-- records corrected facts and a new receipt, checked again.
create function api.correct_payout(
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
  if p_evidence_id is null then
    perform identity.fail('evidence_required');
  end if;

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
  perform finance.take_receipt(p_user_id, w, p_evidence_id, p_idempotency_key);
  update finance.payouts set status = 'verifying', revision = 2 where id = payout.id;
  perform finance.add_revision(payout.id, 2, facts, p_evidence_id, p_user_id, p_idempotency_key);

  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'payout.corrected', 'payout', payout.id::text,
    p_safe_after => jsonb_build_object('reference', w.reference, 'amount', facts->'amount', 'fee', facts->'fee',
      'paidOn', facts->'paidOn', 'revision', 2),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'correct_payout', request,
    finance.withdrawal_json(w.id, p_user_id, workspace.id));
end;
$$;

-- E-03: only the original approver, with current scope and a fresh PIN, may
-- requeue a check that ran out of technical retries.
create function api.retry_payout_check(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_payout_id uuid,
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
  check_row finance.payout_checks;
  request jsonb;
  replayed jsonb;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  select * into payout from finance.payouts where id = p_payout_id;
  if payout.id is null then
    perform identity.fail('not_found');
  end if;
  w := finance.withdrawal_in(workspace.tenant_id, payout.withdrawal_id);
  perform finance.require_payout_actor(p_user_id, workspace, w);

  request := jsonb_build_object('payoutId', payout.id, 'revision', payout.revision);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'retry_payout_check', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into w from finance.withdrawals where id = w.id for update;
  select * into payout from finance.payouts where id = payout.id for update;
  select c.* into check_row from finance.payout_checks c
  join finance.payout_revisions r on r.id = c.revision_id
  where r.payout_id = payout.id and r.revision = payout.revision
  for update of c;
  if payout.status <> 'verifying' or check_row.status <> 'dead' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'check_state', 'status', check_row.status));
  end if;
  update finance.payout_checks
  set status = 'queued', attempts = 0, cycle = cycle + 1, next_attempt_at = now(), lease_token = null,
      lease_expires_at = null, finished_at = null
  where id = check_row.id;
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'payout.check_requeued', 'payout', payout.id::text,
    p_safe_after => jsonb_build_object('reference', w.reference, 'revision', payout.revision),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'retry_payout_check', request,
    finance.withdrawal_json(w.id, p_user_id, workspace.id));
end;
$$;

-- A short-lived download of a payout receipt for the leaders who may approve
-- the withdrawal and for assigned reviewers. Returns the server-built path;
-- the Edge Function signs it for 60 seconds.
create function api.payout_receipt(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_payout_id uuid,
  p_revision int
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
  file evidence.files;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  select * into payout from finance.payouts where id = p_payout_id;
  if payout.id is null then
    perform identity.fail('not_found');
  end if;
  w := finance.withdrawal_in(workspace.tenant_id, payout.withdrawal_id);
  if not (
    finance.can(p_user_id, 'approve_withdrawal', w.tenant_id, w.office_id, w.owner_user_id, workspace.id)
    or finance.can(p_user_id, 'review_financial_evidence', w.tenant_id, w.office_id, w.owner_user_id, workspace.id)
  ) then
    perform identity.fail('authorization_denied');
  end if;
  select f.* into file from finance.payout_revisions r join evidence.files f on f.id = r.evidence_id
  where r.payout_id = payout.id and r.revision = p_revision;
  if file.id is null then
    perform identity.fail('not_found');
  end if;
  return jsonb_build_object('objectPath', file.object_path, 'name', file.declared_name, 'mimeType', file.mime);
end;
$$;

-- ── Completion (W-10 step 7) ──────────────────────────────────────────────

-- Posts the payout: source −(sent + fee), external outflow +sent, payout fee
-- +fee; consumes the hold for what left (the rest is freed with it). Caller
-- holds the withdrawal and payout rows FOR UPDATE.
create function finance.complete_withdrawal(p_payout_id uuid, p_resolution text, p_actor_user_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  payout finance.payouts;
  w finance.withdrawals;
  rev finance.payout_revisions;
  debit numeric;
  postings jsonb;
  v_transaction_id uuid;
begin
  select * into payout from finance.payouts where id = p_payout_id;
  select * into w from finance.withdrawals where id = payout.withdrawal_id;
  select * into rev from finance.payout_revisions where payout_id = payout.id and revision = payout.revision;
  if w.status <> 'approved' or rev.id is null then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'finance.withdrawals'));
  end if;
  debit := rev.amount + coalesce(rev.fee_amount, 0);
  if debit > w.amount then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'finance.payout_revisions'));
  end if;

  postings := jsonb_build_array(
    jsonb_build_object('accountId', w.account_id, 'amount', (-debit)::text),
    jsonb_build_object('accountId', ledger.system_account(w.tenant_id, 'NGN', 'external_outflow'),
      'amount', rev.amount::text));
  if rev.fee_amount is not null then
    postings := postings || jsonb_build_object('accountId', ledger.system_account(w.tenant_id, 'NGN', 'payout_fee'),
      'amount', rev.fee_amount::text);
  end if;

  v_transaction_id := ledger.post('withdrawal', w.reference, w.membership_id, p_actor_user_id, rev.idempotency_key,
    jsonb_build_array(jsonb_build_object('currency', 'NGN', 'postings', postings)),
    jsonb_build_array(jsonb_build_object('reservationId', w.reservation_id, 'amount', debit::text)),
    jsonb_build_object('withdrawalId', w.id, 'payoutId', payout.id, 'resolution', p_resolution));

  update finance.payouts set status = 'completed' where id = payout.id;
  update finance.withdrawals set status = 'completed', transaction_id = v_transaction_id where id = w.id;
  perform audit.record_tenant(w.tenant_id, p_actor_user_id, 'withdrawal.completed', 'withdrawal', w.id::text,
    p_safe_after => jsonb_build_object('reference', w.reference, 'sent', ledger.money(rev.amount, 'NGN'),
      'fee', case when rev.fee_amount is not null then ledger.money(rev.fee_amount, 'NGN') end,
      'resolution', p_resolution, 'payoutId', payout.id));
end;
$$;

-- ── Receipt check worker (service only, called by `payout-checker`) ───────

create function finance.check_reasons() returns text[]
language sql immutable set search_path = '' as $$
  select array[
    'amount_missing', 'amount_invalid', 'amount_mismatch',
    'currency_missing', 'currency_invalid', 'currency_mismatch',
    'recipientAccount_missing', 'recipientAccount_invalid', 'recipientAccount_mismatch',
    'recipientName_missing', 'recipientName_invalid', 'recipientName_mismatch',
    'paymentDate_missing', 'paymentDate_invalid', 'paymentDate_mismatch',
    'payment_not_successful', 'reading_confidence'
  ]::text[]
$$;

-- Leases up to p_limit ready checks. A lease that ran out with no attempts
-- left goes to `dead`.
create function api.claim_payout_checks(p_worker text, p_limit int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  claimed jsonb := '[]'::jsonb;
  item record;
  v_token uuid;
begin
  if p_worker is null or p_worker !~ '^[A-Za-z0-9._:-]{1,100}$' or p_limit is null or p_limit not between 1 and 10 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'worker'));
  end if;

  update finance.payout_checks
  set status = 'dead', last_error = coalesce(last_error, 'lease_expired'), lease_token = null, lease_expires_at = null
  where status = 'leased' and lease_expires_at < now() and attempts >= finance.max_check_attempts();

  for item in
    select c.id from finance.payout_checks c
    where (c.status = 'queued' and c.next_attempt_at <= now())
       or (c.status = 'leased' and c.lease_expires_at < now() and c.attempts < finance.max_check_attempts())
    order by coalesce(c.next_attempt_at, c.lease_expires_at), c.id
    limit p_limit
    for update skip locked
  loop
    v_token := gen_random_uuid();
    update finance.payout_checks
    set status = 'leased', lease_token = v_token, lease_expires_at = now() + finance.check_lease(),
        attempts = attempts + 1, next_attempt_at = null
    where id = item.id;
    claimed := claimed || (
      select jsonb_build_object(
        'checkId', c.id,
        'leaseToken', v_token,
        'attempt', c.attempts,
        'payoutId', c.payout_id,
        'revision', r.revision,
        'expected', jsonb_build_object(
          'amount', ledger.money(r.amount, 'NGN'),
          'currency', 'NGN',
          'paidOn', r.paid_on,
          'recipientName', w.account_name,
          'accountLast4', w.account_last4,
          'ownerUserId', w.owner_user_id,
          'accountCiphertext', w.account_ciphertext,
          'keyVersion', w.key_version),
        'receipt', jsonb_build_object('objectPath', f.object_path, 'size', f.size, 'sha256', f.sha256, 'mimeType', f.mime)
      )
      from finance.payout_checks c
      join finance.payout_revisions r on r.id = c.revision_id
      join finance.payouts p on p.id = c.payout_id
      join finance.withdrawals w on w.id = p.withdrawal_id
      join evidence.files f on f.id = r.evidence_id
      where c.id = item.id
    );
  end loop;
  return claimed;
end;
$$;

create function finance.leased_check(p_check_id uuid, p_lease_token uuid)
returns finance.payout_checks
language plpgsql
set search_path = ''
as $$
declare
  check_row finance.payout_checks;
begin
  select * into check_row from finance.payout_checks where id = p_check_id for update;
  if check_row.id is null or check_row.status <> 'leased' or check_row.lease_token is distinct from p_lease_token then
    perform identity.fail('conflict', jsonb_build_object('reason', 'lease_lost'));
  end if;
  return check_row;
end;
$$;

-- Records the comparison. A match completes the withdrawal; a mismatch on
-- revision 1 asks for the one correction, on revision 2 sends it to review.
-- A check for a revision that is no longer current is obsolete.
create function api.finish_payout_check(
  p_check_id uuid,
  p_lease_token uuid,
  p_outcome text,
  p_facts jsonb,
  p_reasons text[],
  p_model text,
  p_policy_version text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  peek finance.payout_checks;
  check_row finance.payout_checks;
  payout finance.payouts;
  w finance.withdrawals;
  rev finance.payout_revisions;
  receipt jsonb;
  digits text;
begin
  select * into peek from finance.payout_checks where id = p_check_id;
  if peek.id is null then
    perform identity.fail('not_found');
  end if;
  -- Lock order: withdrawal → payout → check.
  select w2.* into w from finance.payouts p2 join finance.withdrawals w2 on w2.id = p2.withdrawal_id
  where p2.id = peek.payout_id;
  select * into w from finance.withdrawals where id = w.id for update;
  select * into payout from finance.payouts where id = peek.payout_id for update;
  check_row := finance.leased_check(p_check_id, p_lease_token);
  select * into rev from finance.payout_revisions where id = check_row.revision_id;

  if p_outcome is null or p_outcome not in ('match', 'mismatch') or p_reasons is null
    or jsonb_typeof(p_facts) is distinct from 'object' or jsonb_typeof(p_facts->'receipt') is distinct from 'object'
    or p_policy_version is distinct from 'strict-single-receipt-v1'
    or p_model is null or p_model !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
    or (p_outcome = 'match') <> (cardinality(p_reasons) = 0)
    or not (p_reasons <@ finance.check_reasons()) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'result'));
  end if;

  if payout.status <> 'verifying' or payout.revision <> rev.revision or w.status <> 'approved' then
    update finance.payout_checks set status = 'obsolete', lease_token = null, lease_expires_at = null
    where id = check_row.id;
    return jsonb_build_object('status', 'obsolete');
  end if;

  -- A match is re-checked here against what was recorded (defence in depth).
  if p_outcome = 'match' then
    receipt := p_facts->'receipt';
    -- Same normalization as the worker's comparison (payout-checker/compare.ts).
    digits := regexp_replace(coalesce(receipt->>'recipientAccount', ''), '[[:space:]-]', '', 'g');
    if btrim(receipt->>'amount') is null or btrim(receipt->>'amount') !~ '^[0-9]{1,20}(\.[0-9]{1,18})?$'
      or btrim(receipt->>'amount')::numeric <> rev.amount
      or upper(btrim(receipt->>'currency')) is distinct from 'NGN'
      or digits !~ '^[0-9]+$' or right(digits, 4) <> w.account_last4
      or receipt->>'paymentStatus' is distinct from 'successful'
      or receipt->>'confidence' is distinct from 'high'
      or p_facts->>'paymentDate' is distinct from rev.paid_on::text then
      perform identity.fail('validation_error', jsonb_build_object('field', 'result', 'reason', 'match_not_supported'));
    end if;
  end if;

  update finance.payout_checks
  set status = 'done', outcome = p_outcome, facts = p_facts, reasons = p_reasons, model = p_model,
      policy_version = p_policy_version, lease_token = null, lease_expires_at = null, last_error = null
  where id = check_row.id;

  if p_outcome = 'match' then
    perform finance.complete_withdrawal(payout.id, 'automated_match', payout.submitted_by);
  elsif payout.revision = 1 then
    update finance.payouts set status = 'correction_required' where id = payout.id;
    perform audit.record_tenant(w.tenant_id, payout.submitted_by, 'payout.correction_required', 'payout',
      payout.id::text, p_safe_after => jsonb_build_object('reference', w.reference, 'reasons', to_jsonb(p_reasons)));
  else
    update finance.payouts set status = 'needs_review' where id = payout.id;
    perform audit.record_tenant(w.tenant_id, payout.submitted_by, 'payout.review_required', 'payout',
      payout.id::text, p_safe_after => jsonb_build_object('reference', w.reference, 'reasons', to_jsonb(p_reasons)));
  end if;
  return jsonb_build_object('status', (select status from finance.payouts where id = payout.id));
end;
$$;

-- Technical failure (E-02): retried with backoff; never consumes the
-- correction. Out of attempts → dead (approver may requeue).
create function api.fail_payout_check(p_check_id uuid, p_lease_token uuid, p_error text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  check_row finance.payout_checks;
begin
  if p_error is null or p_error !~ '^[a-z_]{2,40}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'error'));
  end if;
  check_row := finance.leased_check(p_check_id, p_lease_token);
  if check_row.attempts >= finance.max_check_attempts() then
    update finance.payout_checks
    set status = 'dead', last_error = p_error, lease_token = null, lease_expires_at = null
    where id = check_row.id;
    return jsonb_build_object('status', 'dead');
  end if;
  update finance.payout_checks
  set status = 'queued', last_error = p_error, lease_token = null, lease_expires_at = null,
      next_attempt_at = now() + least(interval '1 hour', interval '30 seconds' * power(2, check_row.attempts - 1))
  where id = check_row.id;
  return jsonb_build_object('status', 'queued');
end;
$$;

-- ── Independent review (W-11) ─────────────────────────────────────────────

create function finance.require_reviewer(p_user_id uuid, p_workspace org.memberships, p_w finance.withdrawals,
  p_payout finance.payouts)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform authz.require(p_user_id, 'review_financial_evidence', p_w.tenant_id, p_w.office_id, p_w.owner_user_id,
    p_workspace.id);
  if p_payout.submitted_by = p_user_id
    or exists (select 1 from finance.payout_revisions r where r.payout_id = p_payout.id and r.submitted_by = p_user_id) then
    perform identity.fail('self_target_forbidden');
  end if;
end;
$$;

create function finance.review_case_json(p_payout_id uuid, p_user_id uuid, p_workspace_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'kind', 'payout',
    'payoutId', p.id,
    'status', p.status,
    'withdrawal', finance.withdrawal_json(p.withdrawal_id, p_user_id, p_workspace_id) - 'can' - 'payout',
    'payout', finance.payout_json(p, true),
    'canDecide', p.status = 'needs_review'
  )
  from finance.payouts p where p.id = p_payout_id;
$$;

-- Evidence review queue (C09). Tabs: `assigned` (needs review), `cleared`,
-- `rejected`, `all`; only cases this reviewer may decide or has seen.
create function api.review_queue(
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
    select p.id, p.status, p.created_at, v.decision
    from finance.payouts p
    join finance.withdrawals w on w.id = p.withdrawal_id
    left join finance.payout_reviews v on v.payout_id = p.id
    where w.tenant_id = workspace.tenant_id
      and (p.status = 'needs_review' or v.payout_id is not null)
      and w.owner_user_id <> p_user_id
      and not exists (select 1 from finance.payout_revisions r where r.payout_id = p.id and r.submitted_by = p_user_id)
      and finance.can(p_user_id, 'review_financial_evidence', w.tenant_id, w.office_id, w.owner_user_id, workspace.id)
  ),
  tabbed as (
    select * from visible
    where case p_tab
      when 'assigned' then status = 'needs_review'
      when 'cleared' then decision = 'clear'
      when 'rejected' then decision = 'reject'
      else true
    end
  ),
  page as (
    select t.id, t.created_at, row_number() over (order by t.created_at desc, t.id desc) as n
    from tabbed t
    where after is null or (t.created_at, t.id) < (after_at, after_id)
    order by t.created_at desc, t.id desc
    limit page_size + 1
  )
  select jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(finance.review_case_json(p.id, p_user_id, workspace.id) order by p.n)
      from page p where p.n <= page_size
    ), '[]'::jsonb),
    'nextCursor', (
      select org.encode_cursor(jsonb_build_object(
        's', to_char(p.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), 'id', p.id))
      from page p where p.n = page_size and exists (select 1 from page q where q.n > page_size)
    ),
    'counts', (
      select jsonb_build_object(
        'assigned', count(*) filter (where status = 'needs_review'),
        'cleared', count(*) filter (where decision = 'clear'),
        'rejected', count(*) filter (where decision = 'reject'),
        'all', count(*))
      from visible
    )
  ) into result;
  return result;
end;
$$;

create function api.review_case(p_user_id uuid, p_session_id uuid, p_membership_id uuid, p_payout_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  payout finance.payouts;
  w finance.withdrawals;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  select * into payout from finance.payouts where id = p_payout_id;
  if payout.id is null then
    perform identity.fail('not_found');
  end if;
  w := finance.withdrawal_in(workspace.tenant_id, payout.withdrawal_id);
  perform finance.require_reviewer(p_user_id, workspace, w, payout);
  return finance.review_case_json(payout.id, p_user_id, workspace.id);
end;
$$;

create function api.review_payout(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_payout_id uuid,
  p_decision text,
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
  payout finance.payouts;
  w finance.withdrawals;
  clean_reason text;
  request jsonb;
  replayed jsonb;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  select * into payout from finance.payouts where id = p_payout_id;
  if payout.id is null then
    perform identity.fail('not_found');
  end if;
  w := finance.withdrawal_in(workspace.tenant_id, payout.withdrawal_id);
  perform finance.require_reviewer(p_user_id, workspace, w, payout);
  if p_decision is null or p_decision not in ('clear', 'reject') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'decision'));
  end if;
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('payoutId', payout.id, 'decision', p_decision, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'review_payout', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into w from finance.withdrawals where id = w.id for update;
  select * into payout from finance.payouts where id = payout.id for update;
  if payout.status <> 'needs_review' or w.status <> 'approved' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'payout_state', 'status', payout.status));
  end if;

  insert into finance.payout_reviews (payout_id, reviewer_user_id, reviewer_membership_id, decision, reason)
  values (payout.id, p_user_id, workspace.id, p_decision, clean_reason);
  perform audit.record_tenant(workspace.tenant_id, p_user_id,
    case p_decision when 'clear' then 'payout.cleared' else 'payout.rejected' end, 'payout', payout.id::text,
    p_reason => clean_reason, p_safe_after => jsonb_build_object('reference', w.reference),
    p_request_id => p_request_id);
  if p_decision = 'clear' then
    perform finance.complete_withdrawal(payout.id, 'manual_clear', p_user_id);
  else
    -- The withdrawal stays approved and held (W-10 rejection).
    update finance.payouts set status = 'rejected' where id = payout.id;
  end if;

  return identity.store_result(p_user_id, p_idempotency_key, 'review_payout', request,
    finance.review_case_json(payout.id, p_user_id, workspace.id));
end;
$$;
