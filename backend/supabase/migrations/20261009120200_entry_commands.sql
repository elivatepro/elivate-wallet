-- Blueprint 12 — W-12 conversions, W-14 adjustments and W-16 returned funds:
-- submitted with evidence, decided by an assigned Financial Evidence Reviewer
-- (W-11), posted only on clearance. Order in every command: session gate
-- (step-up) → workspace → target and authorization → idempotent replay → row
-- locks → state checks.

-- ── Helpers ───────────────────────────────────────────────────────────────

-- The permission that records an entry of this kind.
create function finance.entry_permission(p_kind text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
begin
  return case p_kind
    when 'conversion' then 'perform_currency_conversion'
    when 'adjustment' then 'manual_credit_debit_adjustment'
    when 'returned_funds' then 'record_returned_funds'
  end;
end;
$$;

create function finance.require_entry_kind(p_kind text)
returns text
language plpgsql
set search_path = ''
as $$
begin
  if finance.entry_permission(p_kind) is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'kind'));
  end if;
  return finance.entry_permission(p_kind);
end;
$$;

-- Rates are quoted per one unit of the base currency: USD when it is one side
-- (₦1,520.00 per $1, Paper B07), otherwise the alphabetically first.
create function finance.rate_base(p_a text, p_b text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when 'USD' in (p_a, p_b) then 'USD' else least(p_a, p_b) end;
$$;

-- An optional exact rate: up to 12 digits and 8 decimals, positive.
create function finance.parse_rate(p_rate text, p_field text)
returns numeric
language plpgsql
set search_path = ''
as $$
begin
  if p_rate is null then
    return null;
  end if;
  if p_rate !~ '^[0-9]{1,12}(\.[0-9]{1,8})?$' or p_rate::numeric <= 0 then
    perform identity.fail('validation_error', jsonb_build_object('field', p_field));
  end if;
  return p_rate::numeric;
end;
$$;

-- An observed moment (ISO 8601 with offset), not in the future, after 2000.
create function finance.parse_moment(p_value text, p_field text)
returns timestamptz
language plpgsql
set search_path = ''
as $$
declare
  parsed timestamptz;
begin
  if p_value is null or p_value !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]{1,6})?)?(Z|[+-][0-9]{2}:[0-9]{2})$' then
    perform identity.fail('validation_error', jsonb_build_object('field', p_field));
  end if;
  begin
    parsed := p_value::timestamptz;
  exception when others then
    perform identity.fail('validation_error', jsonb_build_object('field', p_field));
  end;
  if parsed > now() + interval '5 minutes' or parsed < timestamptz '2000-01-01 00:00:00+00' then
    perform identity.fail('validation_error', jsonb_build_object('field', p_field));
  end if;
  return parsed;
end;
$$;

-- 1–5 distinct evidence ids.
create function finance.evidence_list(p_evidence_ids uuid[])
returns uuid[]
language plpgsql
set search_path = ''
as $$
declare
  ids uuid[];
begin
  if p_evidence_ids is null or cardinality(p_evidence_ids) = 0 then
    perform identity.fail('evidence_required');
  end if;
  select array_agg(distinct e order by e) into ids from unnest(p_evidence_ids) e;
  if cardinality(ids) <> cardinality(p_evidence_ids) or cardinality(ids) > 5
    or array_position(ids, null) is not null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'evidenceIds'));
  end if;
  return ids;
end;
$$;

-- Locks the actor's finalized uploads for this kind, target and command key;
-- evidence_invalid unless every id qualifies.
create function finance.take_entry_evidence(
  p_user_id uuid,
  p_tenant_id uuid,
  p_kind text,
  p_target_membership_id uuid,
  p_key text,
  p_evidence_ids uuid[]
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  found int;
begin
  select count(*) into found from (
    select f.id from evidence.files f
    where f.id = any (p_evidence_ids)
      and f.tenant_id = p_tenant_id and f.purpose = p_kind and f.uploaded_by = p_user_id
      and f.target_membership_id = p_target_membership_id and f.command_key = p_key
      and f.status = 'finalized' and f.expires_at > now()
    order by f.id
    for update
  ) locked;
  if found <> cardinality(p_evidence_ids) then
    perform identity.fail('evidence_invalid');
  end if;
end;
$$;

-- An entry of the workspace's network, unlocked; not_found otherwise.
create function finance.entry_in(p_tenant_id uuid, p_entry_id uuid)
returns finance.entries
language plpgsql
set search_path = ''
as $$
declare
  e finance.entries;
begin
  select * into e from finance.entries where id = p_entry_id and tenant_id = p_tenant_id;
  if e.id is null then
    perform identity.fail('not_found');
  end if;
  return e;
end;
$$;

-- A transaction is in effect unless a reversal that is itself in effect
-- points at it (a reversed reversal reinstates the original).
create function ledger.in_effect(p_transaction_id uuid)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare
  reversal uuid;
begin
  reversal := (ledger.reversed_by(p_transaction_id)->>'transactionId')::uuid;
  return reversal is null or not ledger.in_effect(reversal);
end;
$$;

-- What left the member's pocket for a completed withdrawal: sent + fee.
create function finance.withdrawal_debit(p_withdrawal_id uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  select r.amount + coalesce(r.fee_amount, 0)
  from finance.withdrawals w
  join finance.payouts p on p.withdrawal_id = w.id and p.status = 'completed'
  join finance.payout_revisions r on r.payout_id = p.id and r.revision = p.revision
  where w.id = p_withdrawal_id and w.status = 'completed';
$$;

-- Returns of a withdrawal that are posted and in effect.
create function finance.returned_total(p_withdrawal_id uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(e.amount), 0) from finance.entries e
  where e.withdrawal_id = p_withdrawal_id and e.kind = 'returned_funds' and e.status = 'posted'
    and ledger.in_effect(e.transaction_id);
$$;

create function finance.pending_returns(p_withdrawal_id uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(e.amount), 0) from finance.entries e
  where e.withdrawal_id = p_withdrawal_id and e.kind = 'returned_funds' and e.status = 'needs_review';
$$;

create function finance.entry_json(p_entry_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'entryId', e.id,
    'reference', e.reference,
    'kind', e.kind,
    'status', e.status,
    'direction', e.direction,
    'currency', e.currency,
    'amount', ledger.money(e.amount, e.currency),
    'pocket', case when pk.id is not null then jsonb_build_object('pocketId', pk.id, 'name', pk.name) end,
    'conversion', case when e.kind = 'conversion' then jsonb_build_object(
      'destinationCurrency', e.destination_currency,
      'destinationAmount', ledger.money(e.destination_amount, e.destination_currency),
      'rateBase', finance.rate_base(e.currency, e.destination_currency),
      'rateQuote', case when finance.rate_base(e.currency, e.destination_currency) = e.currency
        then e.destination_currency else e.currency end,
      'effectiveRate', round(case when finance.rate_base(e.currency, e.destination_currency) = e.currency
        then e.destination_amount / e.amount else e.amount / e.destination_amount end, 6)::text,
      'quotedRate', case when e.quoted_rate is not null then trim_scale(e.quoted_rate)::text end
    ) end,
    'provider', e.provider,
    'observedAt', e.observed_at,
    'externalReference', e.external_reference,
    'reason', e.reason,
    'notes', e.notes,
    'withdrawal', (
      select jsonb_build_object('withdrawalId', w.id, 'reference', w.reference,
        'destination', jsonb_build_object('bankName', w.bank_name, 'accountLast4', w.account_last4))
      from finance.withdrawals w where w.id = e.withdrawal_id
    ),
    'lines', case when e.kind = 'adjustment' then (
      select jsonb_agg(jsonb_build_object(
        'pocketId', l.pocket_id, 'pocket', l.pocket_name, 'basisPoints', l.basis_points,
        'amount', ledger.money(l.amount, e.currency)
      ) order by l.sort_order, l.pocket_id)
      from finance.entry_lines l where l.entry_id = e.id
    ) end,
    'member', org.person(e.owner_user_id),
    'membershipId', e.membership_id,
    'walletId', e.wallet_id,
    'office', jsonb_build_object('id', o.id, 'name', o.name),
    'submittedBy', org.person(e.submitted_by),
    'createdAt', e.created_at,
    'evidence', coalesce((
      select jsonb_agg(jsonb_build_object(
        'evidenceId', f.id, 'name', f.declared_name, 'mimeType', f.mime, 'size', f.size
      ) order by f.created_at, f.id)
      from evidence.files f where f.attached_type = 'entry' and f.attached_id = e.id
    ), '[]'::jsonb),
    'review', case when e.status <> 'needs_review' then jsonb_build_object(
      'decision', case e.status when 'posted' then 'clear' else 'reject' end,
      'reason', e.review_reason, 'decidedAt', e.decided_at, 'reviewer', org.person(e.reviewer_user_id)) end,
    'transactionId', e.transaction_id
  )
  from finance.entries e
  join org.offices o on o.id = e.office_id
  left join ledger.pockets pk on pk.id = e.pocket_id
  where e.id = p_entry_id;
$$;

-- ── Evidence: who may upload and finalize ─────────────────────────────────

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
  perform authz.require(p_user_id,
    case file.purpose
      when 'payout' then 'approve_withdrawal'
      when 'income' then 'record_income'
      else finance.entry_permission(file.purpose)
    end,
    p_workspace.tenant_id, target.office_id, target.user_id, p_workspace.id);
  return file;
end;
$$;

-- Uploads for a conversion, adjustment or returned funds: the target is the
-- member's membership (for returned funds, the withdrawal's).
create function api.create_entry_evidence_upload(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_kind text,
  p_target_membership_id uuid,
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
  target org.memberships;
  permission text;
  v_id uuid := gen_random_uuid();
  file evidence.files;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  permission := finance.require_entry_kind(p_kind);
  target := org.membership_in_tenant(workspace.tenant_id, p_target_membership_id);
  if target.role = 'president_team_member' then
    perform identity.fail('target_not_eligible');
  end if;
  perform authz.require(p_user_id, permission, workspace.tenant_id, target.office_id, target.user_id, workspace.id);

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
  values (v_id, workspace.tenant_id, p_kind, p_user_id, target.id, p_command_key,
    workspace.tenant_id::text || '/' || p_kind || '/' || v_id::text,
    btrim(p_file_name), p_mime_type, p_size, lower(p_sha256), now() + evidence.upload_ttl())
  returning * into file;

  return jsonb_build_object('evidenceId', file.id, 'objectPath', file.object_path, 'expiresAt', file.expires_at);
end;
$$;

-- ── Reads for the forms ───────────────────────────────────────────────────

-- B07/E05 member picker: members the actor may convert or adjust for.
create function api.entry_targets(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_kind text,
  p_cursor text default null,
  p_limit int default null,
  p_query text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  permission text;
  page_size int;
  after jsonb;
  rows jsonb;
  pattern text;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  if p_kind not in ('conversion', 'adjustment') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'kind'));
  end if;
  permission := finance.entry_permission(p_kind);
  if p_query is not null and (length(btrim(p_query)) = 0 or length(p_query) > 100) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'q'));
  end if;
  pattern := '%' || replace(replace(replace(btrim(p_query), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  page_size := org.page_limit(p_limit);
  after := org.decode_cursor(p_cursor);

  select coalesce(jsonb_agg(item order by item->>'startedAt', item->>'membershipId'), '[]'::jsonb) into rows
  from (
    select jsonb_build_object(
      'membershipId', m.id,
      'person', org.person(m.user_id),
      'role', m.role,
      'officeId', m.office_id,
      'officeName', o.name,
      'startedAt', m.started_at
    ) as item
    from org.memberships m
    join org.offices o on o.id = m.office_id
    where m.tenant_id = workspace.tenant_id
      and m.user_id <> p_user_id
      and finance.target_eligible(m)
      and (p_query is null or exists (
        select 1 from identity.accounts a
        left join identity.profiles pr on pr.user_id = a.user_id
        where a.user_id = m.user_id
          and (a.uid ilike pattern or pr.display_name ilike pattern
               or concat_ws(' ', pr.first_name, pr.last_name) ilike pattern or o.name ilike pattern)))
      and finance.can(p_user_id, permission, workspace.tenant_id, m.office_id, m.user_id, workspace.id)
      and (after is null or (to_char(m.started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'), m.id::text)
                            > (after->>'s', after->>'id'))
    order by m.started_at, m.id
    limit page_size + 1
  ) page;

  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(e) from jsonb_array_elements(rows) with ordinality as x (e, n) where n <= page_size), '[]'::jsonb),
    'nextCursor', case when jsonb_array_length(rows) > page_size then (
      select org.encode_cursor(jsonb_build_object(
        's', to_char(m.started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'), 'id', m.id))
      from org.memberships m where m.id = (rows->(page_size - 1)->>'membershipId')::uuid
    ) end
  );
end;
$$;

-- One member's pockets per currency (with what is available) for the
-- conversion and adjustment forms, plus the network's split.
create function api.entry_segments(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_kind text,
  p_target_membership_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  target org.memberships;
  v_wallet_id uuid;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  if p_kind not in ('conversion', 'adjustment') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'kind'));
  end if;
  target := org.membership_in_tenant(workspace.tenant_id, p_target_membership_id);
  if target.role = 'president_team_member' then
    perform identity.fail('target_not_eligible');
  end if;
  perform authz.require(p_user_id, finance.entry_permission(p_kind), workspace.tenant_id, target.office_id,
    target.user_id, workspace.id);
  v_wallet_id := ledger.wallet_for(target.user_id);

  return jsonb_build_object(
    'membershipId', target.id,
    'person', org.person(target.user_id),
    'role', target.role,
    'office', (select jsonb_build_object('id', o.id, 'name', o.name) from org.offices o where o.id = target.office_id),
    'eligible', finance.target_eligible(target) and v_wallet_id is not null,
    'currencies', (select jsonb_agg(jsonb_build_object('code', c.code, 'scale', c.scale) order by c.code)
                   from ledger.currencies c where c.active),
    'allocation', ledger.allocation_json(workspace.tenant_id),
    'segments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'accountId', b.account_id,
        'currency', b.currency,
        'pocketId', p.id,
        'pocket', p.name,
        'kind', p.kind,
        'posted', ledger.money(b.posted, b.currency),
        'reserved', ledger.money(b.reserved, b.currency),
        'available', ledger.money(b.posted - b.reserved, b.currency)
      ) order by b.currency, p.sort_order, p.id)
      from ledger.balances b
      join ledger.pockets p on p.id = b.pocket_id
      where b.membership_id = target.id and b.wallet_id = v_wallet_id and p.status = 'active'
    ), '[]'::jsonb)
  );
end;
$$;

-- ── W-12 conversion ───────────────────────────────────────────────────────

create function api.submit_conversion(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_source_account_id uuid,
  p_amount text,
  p_destination_currency text,
  p_destination_amount text,
  p_quoted_rate text,
  p_provider text,
  p_converted_at text,
  p_external_reference text,
  p_notes text,
  p_evidence_ids uuid[],
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
  target org.memberships;
  pocket ledger.pockets;
  v_amount numeric;
  v_destination numeric;
  v_rate numeric;
  v_at timestamptz;
  clean_provider text;
  clean_reference text;
  clean_notes text;
  evidence_ids uuid[];
  request jsonb;
  replayed jsonb;
  v_id uuid := gen_random_uuid();
  v_reference text;
  v_reservation uuid;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  select * into account from ledger.accounts
  where id = p_source_account_id and class = 'member_value' and tenant_id = workspace.tenant_id;
  if account.id is null then
    perform identity.fail('not_found');
  end if;
  target := org.membership_in_tenant(workspace.tenant_id, account.membership_id);
  perform authz.require(p_user_id, 'perform_currency_conversion', workspace.tenant_id, target.office_id,
    target.user_id, workspace.id);

  v_amount := ledger.parse_amount(p_amount, account.currency, 'amount');
  perform ledger.currency_scale(p_destination_currency);
  if p_destination_currency = account.currency then
    perform identity.fail('validation_error', jsonb_build_object('field', 'destinationCurrency',
      'reason', 'same_currency'));
  end if;
  v_destination := ledger.parse_amount(p_destination_amount, p_destination_currency, 'destinationAmount');
  v_rate := finance.parse_rate(p_quoted_rate, 'quotedRate');
  clean_provider := org.require_text(p_provider, 'provider', 1, 100);
  v_at := finance.parse_moment(p_converted_at, 'convertedAt');
  if p_external_reference is not null then
    clean_reference := org.require_text(p_external_reference, 'externalReference', 1, 100);
  end if;
  if p_notes is not null then
    clean_notes := org.require_text(p_notes, 'notes', 1, 1000);
  end if;
  evidence_ids := finance.evidence_list(p_evidence_ids);

  request := jsonb_build_object(
    'sourceAccountId', account.id, 'amount', ledger.money(v_amount, account.currency),
    'destinationCurrency', p_destination_currency,
    'destinationAmount', ledger.money(v_destination, p_destination_currency),
    'quotedRate', trim_scale(v_rate)::text, 'provider', clean_provider, 'convertedAt', v_at,
    'externalReference', clean_reference, 'notes', clean_notes, 'evidenceIds', to_jsonb(evidence_ids));
  replayed := identity.replay(p_user_id, p_idempotency_key, 'submit_conversion', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into target from org.memberships where id = target.id for share;
  if not finance.target_eligible(target) then
    perform identity.fail('target_not_eligible');
  end if;
  select * into pocket from ledger.pockets where id = account.pocket_id;
  if pocket.kind <> 'ordinary' or pocket.status <> 'active' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'sourceAccountId',
      'reason', 'pocket_not_convertible'));
  end if;

  -- The converted value is held until the reviewer decides (Blueprint 12 Q3).
  v_reservation := ledger.reserve(account.id, v_amount, 'conversion', 'entry', v_id, p_user_id);
  perform finance.take_entry_evidence(p_user_id, workspace.tenant_id, 'conversion', target.id, p_idempotency_key,
    evidence_ids);

  v_reference := refs.issue('CNV');
  insert into finance.entries (id, reference, kind, tenant_id, office_id, membership_id, wallet_id, owner_user_id,
    currency, amount, direction, pocket_id, account_id, reservation_id, destination_currency, destination_amount,
    quoted_rate, provider, observed_at, external_reference, notes, submitted_by, idempotency_key)
  values (v_id, v_reference, 'conversion', workspace.tenant_id, target.office_id, target.id, account.wallet_id,
    target.user_id, account.currency, v_amount, 'debit', pocket.id, account.id, v_reservation,
    p_destination_currency, v_destination, v_rate, clean_provider, v_at, clean_reference, clean_notes,
    p_user_id, p_idempotency_key);
  update evidence.files set status = 'attached', attached_type = 'entry', attached_id = v_id
  where id = any (evidence_ids);

  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'conversion.submitted', 'entry', v_id::text,
    p_safe_after => jsonb_build_object('reference', v_reference, 'membershipId', target.id,
      'currency', account.currency, 'amount', ledger.money(v_amount, account.currency),
      'destinationCurrency', p_destination_currency,
      'destinationAmount', ledger.money(v_destination, p_destination_currency)),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'submit_conversion', request,
    finance.entry_json(v_id));
end;
$$;

-- ── W-14 adjustment ───────────────────────────────────────────────────────

create function api.submit_adjustment(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_target_membership_id uuid,
  p_direction text,
  p_currency text,
  p_amount text,
  p_reason text,
  p_notes text,
  p_evidence_ids uuid[],
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
  target org.memberships;
  v_amount numeric;
  clean_reason text;
  clean_notes text;
  evidence_ids uuid[];
  request jsonb;
  replayed jsonb;
  v_wallet_id uuid;
  active ledger.active_allocation_policies;
  line record;
  v_account_id uuid;
  v_id uuid := gen_random_uuid();
  v_reference text;
begin
  -- Adjustments always need the PIN (A-05, owner decision 2026-10-08).
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  target := org.membership_in_tenant(workspace.tenant_id, p_target_membership_id);
  if target.role = 'president_team_member' then
    perform identity.fail('target_not_eligible');
  end if;
  perform authz.require(p_user_id, 'manual_credit_debit_adjustment', workspace.tenant_id, target.office_id,
    target.user_id, workspace.id);

  if p_direction is null or p_direction not in ('credit', 'debit') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'direction'));
  end if;
  v_amount := ledger.parse_amount(p_amount, p_currency, 'amount');
  clean_reason := identity.require_reason(p_reason);
  if p_notes is not null then
    clean_notes := org.require_text(p_notes, 'notes', 1, 1000);
  end if;
  evidence_ids := finance.evidence_list(p_evidence_ids);

  request := jsonb_build_object(
    'targetMembershipId', target.id, 'direction', p_direction, 'currency', p_currency,
    'amount', ledger.money(v_amount, p_currency), 'reason', clean_reason, 'notes', clean_notes,
    'evidenceIds', to_jsonb(evidence_ids));
  replayed := identity.replay(p_user_id, p_idempotency_key, 'submit_adjustment', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into target from org.memberships where id = target.id for share;
  if not finance.target_eligible(target) then
    perform identity.fail('target_not_eligible');
  end if;
  v_wallet_id := ledger.require_wallet(target.user_id);
  select * into active from ledger.active_allocation_policies where tenant_id = workspace.tenant_id for share;
  if active.tenant_id is null then
    perform identity.fail('allocation_policy_missing');
  end if;
  perform finance.take_entry_evidence(p_user_id, workspace.tenant_id, 'adjustment', target.id, p_idempotency_key,
    evidence_ids);

  v_reference := refs.issue('ADJ');
  insert into finance.entries (id, reference, kind, tenant_id, office_id, membership_id, wallet_id, owner_user_id,
    currency, amount, direction, reason, notes, policy_id, submitted_by, idempotency_key)
  values (v_id, v_reference, 'adjustment', workspace.tenant_id, target.office_id, target.id, v_wallet_id,
    target.user_id, p_currency, v_amount, p_direction, clean_reason, clean_notes, active.policy_id,
    p_user_id, p_idempotency_key);

  -- The split is fixed now (W-14); a debit share must be available now too,
  -- and is checked again when it posts.
  for line in
    select a.pocket_id, a.basis_points, a.amount, l.name, l.sort_order
    from ledger.allocate(active.policy_id, p_currency, v_amount) a
    join ledger.allocation_policy_lines l on l.policy_id = active.policy_id and l.pocket_id = a.pocket_id
    order by l.sort_order, a.pocket_id
  loop
    v_account_id := null;
    if line.amount > 0 then
      v_account_id := ledger.segment_account(v_wallet_id, target.id, p_currency, line.pocket_id);
      if p_direction = 'debit' and ledger.available(v_account_id) < line.amount then
        perform identity.fail('insufficient_funds', jsonb_build_object(
          'available', ledger.money(ledger.available(v_account_id), p_currency), 'pocket', line.name));
      end if;
    end if;
    insert into finance.entry_lines (entry_id, pocket_id, pocket_name, sort_order, basis_points, amount, account_id)
    values (v_id, line.pocket_id, line.name, line.sort_order, line.basis_points, line.amount, v_account_id);
  end loop;

  update evidence.files set status = 'attached', attached_type = 'entry', attached_id = v_id
  where id = any (evidence_ids);

  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'adjustment.submitted', 'entry', v_id::text,
    clean_reason, p_safe_after => jsonb_build_object('reference', v_reference, 'membershipId', target.id,
      'direction', p_direction, 'currency', p_currency, 'amount', ledger.money(v_amount, p_currency),
      'policyId', active.policy_id),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'submit_adjustment', request,
    finance.entry_json(v_id));
end;
$$;

-- ── W-16 returned funds ───────────────────────────────────────────────────

create function finance.returnable_json(p_withdrawal_id uuid)
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
    'member', org.person(w.owner_user_id),
    'membershipId', w.membership_id,
    'walletId', w.wallet_id,
    'pocket', jsonb_build_object('pocketId', pk.id, 'name', pk.name),
    'destination', jsonb_build_object('bankName', w.bank_name, 'accountLast4', w.account_last4,
      'accountNumberMasked', '•••• ' || w.account_last4, 'accountName', w.account_name),
    'completedAt', w.completed_at,
    'paidOn', (select r.paid_on from finance.payouts p
               join finance.payout_revisions r on r.payout_id = p.id and r.revision = p.revision
               where p.withdrawal_id = w.id and p.status = 'completed'),
    'paidOut', ledger.money(coalesce(finance.withdrawal_debit(w.id), 0), w.currency),
    'returned', ledger.money(finance.returned_total(w.id), w.currency),
    'pending', ledger.money(finance.pending_returns(w.id), w.currency),
    'remaining', ledger.money(greatest(coalesce(finance.withdrawal_debit(w.id), 0)
      - finance.returned_total(w.id) - finance.pending_returns(w.id), 0), w.currency),
    'returns', coalesce((
      select jsonb_agg(jsonb_build_object('entryId', e.id, 'reference', e.reference, 'status', e.status,
        'amount', ledger.money(e.amount, e.currency), 'createdAt', e.created_at,
        'inEffect', e.status <> 'posted' or ledger.in_effect(e.transaction_id))
        order by e.created_at, e.id)
      from finance.entries e where e.withdrawal_id = w.id and e.kind = 'returned_funds'
    ), '[]'::jsonb)
  )
  from finance.withdrawals w
  join ledger.pockets pk on pk.id = w.pocket_id
  where w.id = p_withdrawal_id;
$$;

create function api.returnable_withdrawal(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_withdrawal_id uuid
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
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  w := finance.withdrawal_in(workspace.tenant_id, p_withdrawal_id);
  perform authz.require(p_user_id, 'record_returned_funds', w.tenant_id, w.office_id, w.owner_user_id, workspace.id);
  return finance.returnable_json(w.id);
end;
$$;

create function api.submit_returned_funds(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_withdrawal_id uuid,
  p_amount text,
  p_seen_at text,
  p_returned_by text,
  p_bank_reference text,
  p_notes text,
  p_evidence_ids uuid[],
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
  v_amount numeric;
  v_seen timestamptz;
  clean_by text;
  clean_reference text;
  clean_notes text;
  evidence_ids uuid[];
  request jsonb;
  replayed jsonb;
  remaining numeric;
  v_id uuid := gen_random_uuid();
  v_reference text;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  w := finance.withdrawal_in(workspace.tenant_id, p_withdrawal_id);
  perform authz.require(p_user_id, 'record_returned_funds', w.tenant_id, w.office_id, w.owner_user_id, workspace.id);

  v_amount := ledger.parse_amount(p_amount, w.currency, 'amount');
  v_seen := finance.parse_moment(p_seen_at, 'seenAt');
  clean_by := org.require_text(p_returned_by, 'returnedBy', 1, 100);
  if p_bank_reference is not null then
    clean_reference := org.require_text(p_bank_reference, 'bankReference', 1, 100);
  end if;
  if p_notes is not null then
    clean_notes := org.require_text(p_notes, 'notes', 1, 1000);
  end if;
  evidence_ids := finance.evidence_list(p_evidence_ids);

  request := jsonb_build_object(
    'withdrawalId', w.id, 'amount', ledger.money(v_amount, w.currency), 'seenAt', v_seen,
    'returnedBy', clean_by, 'bankReference', clean_reference, 'notes', clean_notes,
    'evidenceIds', to_jsonb(evidence_ids));
  replayed := identity.replay(p_user_id, p_idempotency_key, 'submit_returned_funds', request);
  if replayed is not null then
    return replayed;
  end if;

  -- Lock order: the withdrawal serializes every return of it.
  select * into w from finance.withdrawals where id = w.id for update;
  if w.status <> 'completed' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'withdrawal_state', 'status', w.status));
  end if;
  if v_seen < w.approved_at - interval '1 day' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'seenAt'));
  end if;
  -- Pending returns count too, so two open returns can't both claim the rest.
  remaining := finance.withdrawal_debit(w.id) - finance.returned_total(w.id) - finance.pending_returns(w.id);
  if v_amount > remaining then
    perform identity.fail('conflict', jsonb_build_object('reason', 'exceeds_returnable',
      'remaining', ledger.money(greatest(remaining, 0), w.currency)));
  end if;
  perform finance.take_entry_evidence(p_user_id, workspace.tenant_id, 'returned_funds', w.membership_id,
    p_idempotency_key, evidence_ids);

  v_reference := refs.issue('RTN');
  insert into finance.entries (id, reference, kind, tenant_id, office_id, membership_id, wallet_id, owner_user_id,
    currency, amount, direction, pocket_id, account_id, provider, observed_at, external_reference, notes,
    withdrawal_id, submitted_by, idempotency_key)
  values (v_id, v_reference, 'returned_funds', w.tenant_id, w.office_id, w.membership_id, w.wallet_id,
    w.owner_user_id, w.currency, v_amount, 'credit', w.pocket_id, w.account_id, clean_by, v_seen,
    clean_reference, clean_notes, w.id, p_user_id, p_idempotency_key);
  update evidence.files set status = 'attached', attached_type = 'entry', attached_id = v_id
  where id = any (evidence_ids);

  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'returned_funds.submitted', 'entry', v_id::text,
    p_safe_after => jsonb_build_object('reference', v_reference, 'withdrawal', w.reference,
      'membershipId', w.membership_id, 'amount', ledger.money(v_amount, w.currency)),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'submit_returned_funds', request,
    finance.entry_json(v_id) || jsonb_build_object('returnable', finance.returnable_json(w.id)));
end;
$$;

-- ── Posting at clearance ──────────────────────────────────────────────────

-- Posts a cleared entry and marks it posted. The caller holds the entry (and,
-- for returned funds, its withdrawal) FOR UPDATE.
create function finance.post_entry(p_entry_id uuid, p_actor_user_id uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  e finance.entries;
  journals jsonb;
  consume jsonb := '[]'::jsonb;
  postings jsonb := '[]'::jsonb;
  sign numeric;
  line finance.entry_lines;
  v_destination uuid;
  remaining numeric;
begin
  select * into e from finance.entries where id = p_entry_id;
  if e.status <> 'needs_review' then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'finance.entries'));
  end if;

  if e.kind = 'conversion' then
    v_destination := ledger.segment_account(e.wallet_id, e.membership_id, e.destination_currency, e.pocket_id);
    journals := jsonb_build_array(
      jsonb_build_object('currency', e.currency, 'postings', jsonb_build_array(
        jsonb_build_object('accountId', e.account_id, 'amount', (-e.amount)::text),
        jsonb_build_object('accountId', ledger.system_account(e.tenant_id, e.currency, 'fx_clearing'),
          'amount', e.amount::text))),
      jsonb_build_object('currency', e.destination_currency, 'postings', jsonb_build_array(
        jsonb_build_object('accountId', ledger.system_account(e.tenant_id, e.destination_currency, 'fx_clearing'),
          'amount', (-e.destination_amount)::text),
        jsonb_build_object('accountId', v_destination, 'amount', e.destination_amount::text))));
    consume := jsonb_build_array(jsonb_build_object('reservationId', e.reservation_id, 'amount', e.amount::text));

  elsif e.kind = 'adjustment' then
    sign := case e.direction when 'credit' then 1 else -1 end;
    for line in select * from finance.entry_lines where entry_id = e.id and amount > 0 order by sort_order, pocket_id loop
      postings := postings || jsonb_build_object('accountId', line.account_id, 'amount', (sign * line.amount)::text);
    end loop;
    postings := jsonb_build_array(jsonb_build_object(
      'accountId', ledger.system_account(e.tenant_id, e.currency, 'adjustment'),
      'amount', (-sign * e.amount)::text)) || postings;
    journals := jsonb_build_array(jsonb_build_object('currency', e.currency, 'postings', postings));

  else
    -- Never more than is still returnable (W-16), under the withdrawal lock.
    remaining := finance.withdrawal_debit(e.withdrawal_id) - finance.returned_total(e.withdrawal_id);
    if e.amount > remaining then
      perform identity.fail('conflict', jsonb_build_object('reason', 'exceeds_returnable',
        'remaining', ledger.money(greatest(remaining, 0), e.currency)));
    end if;
    journals := jsonb_build_array(jsonb_build_object('currency', e.currency, 'postings', jsonb_build_array(
      jsonb_build_object('accountId', ledger.system_account(e.tenant_id, e.currency, 'returned_funds'),
        'amount', (-e.amount)::text),
      jsonb_build_object('accountId', e.account_id, 'amount', e.amount::text))));
  end if;

  return ledger.post(e.kind, e.reference, e.membership_id, p_actor_user_id, e.idempotency_key, journals, consume,
    jsonb_build_object('entryId', e.id));
end;
$$;

-- ── W-11 review of entries ────────────────────────────────────────────────

create function finance.require_entry_reviewer(p_user_id uuid, p_workspace org.memberships, p_entry finance.entries)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform authz.require(p_user_id, 'review_financial_evidence', p_entry.tenant_id, p_entry.office_id,
    p_entry.owner_user_id, p_workspace.id);
  if p_entry.submitted_by = p_user_id then
    perform identity.fail('self_target_forbidden');
  end if;
end;
$$;

create function finance.entry_case_json(p_entry_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'kind', e.kind,
    'caseId', e.id,
    'status', e.status,
    'entry', finance.entry_json(e.id),
    'returnable', case when e.kind = 'returned_funds' then finance.returnable_json(e.withdrawal_id) end,
    'canDecide', e.status = 'needs_review'
  )
  from finance.entries e where e.id = p_entry_id;
$$;

create function api.review_entry(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_entry_id uuid,
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
  e finance.entries;
  clean_reason text;
  request jsonb;
  replayed jsonb;
  v_transaction_id uuid;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  e := finance.entry_in(workspace.tenant_id, p_entry_id);
  perform finance.require_entry_reviewer(p_user_id, workspace, e);
  if p_decision is null or p_decision not in ('clear', 'reject') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'decision'));
  end if;
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('entryId', e.id, 'decision', p_decision, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'review_entry', request);
  if replayed is not null then
    return replayed;
  end if;

  if e.withdrawal_id is not null then
    perform 1 from finance.withdrawals where id = e.withdrawal_id for update;
  end if;
  select * into e from finance.entries where id = e.id for update;
  if e.status <> 'needs_review' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'entry_state', 'status', e.status));
  end if;

  if p_decision = 'clear' then
    v_transaction_id := finance.post_entry(e.id, p_user_id);
    update finance.entries
    set status = 'posted', transaction_id = v_transaction_id, reviewer_user_id = p_user_id,
        reviewer_membership_id = workspace.id, review_reason = clean_reason
    where id = e.id;
  else
    if e.reservation_id is not null then
      perform ledger.release(e.reservation_id, left('Evidence rejected: ' || clean_reason, 500), p_user_id);
    end if;
    update finance.entries
    set status = 'rejected', reviewer_user_id = p_user_id, reviewer_membership_id = workspace.id,
        review_reason = clean_reason
    where id = e.id;
  end if;

  perform audit.record_tenant(workspace.tenant_id, p_user_id,
    e.kind || case p_decision when 'clear' then '.posted' else '.rejected' end, 'entry', e.id::text,
    p_reason => clean_reason, p_safe_after => jsonb_build_object('reference', e.reference,
      'membershipId', e.membership_id, 'currency', e.currency, 'amount', ledger.money(e.amount, e.currency),
      'direction', e.direction, 'transactionId', v_transaction_id),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'review_entry', request,
    finance.entry_case_json(e.id));
end;
$$;

-- A short-lived download of an entry's evidence for those who may record that
-- kind for the member, and assigned reviewers. The Edge Function signs it.
create function api.entry_evidence(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_entry_id uuid,
  p_evidence_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  e finance.entries;
  file evidence.files;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  e := finance.entry_in(workspace.tenant_id, p_entry_id);
  if not (
    finance.can(p_user_id, finance.entry_permission(e.kind), e.tenant_id, e.office_id, e.owner_user_id, workspace.id)
    or finance.can(p_user_id, 'review_financial_evidence', e.tenant_id, e.office_id, e.owner_user_id, workspace.id)
  ) then
    perform identity.fail('authorization_denied');
  end if;
  select * into file from evidence.files
  where id = p_evidence_id and attached_type = 'entry' and attached_id = e.id;
  if file.id is null then
    perform identity.fail('not_found');
  end if;
  return jsonb_build_object('objectPath', file.object_path, 'name', file.declared_name, 'mimeType', file.mime);
end;
$$;
