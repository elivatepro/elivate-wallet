-- Blueprint 04 — W-08 record income: exact split into pockets, posted at
-- once, idempotent, with receipts and a cancel path for unknown outcomes.

create table finance.income_records (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique references refs.issued (code) on delete restrict,
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  office_id uuid not null,
  membership_id uuid not null references org.memberships (id) on delete restrict,
  wallet_id uuid not null references ledger.wallets (id) on delete restrict,
  owner_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  currency text not null references ledger.currencies (code) on delete restrict,
  amount numeric(38, 18) not null check (amount > 0),
  source text not null check (length(btrim(source)) between 1 and 100),
  received_on date not null,
  provider_reference text check (provider_reference is null or length(btrim(provider_reference)) between 1 and 100),
  notes text check (notes is null or length(btrim(notes)) between 1 and 1000),
  fee_amount numeric(38, 18) check (fee_amount is null or fee_amount > 0),
  fee_currency text references ledger.currencies (code) on delete restrict,
  policy_id uuid not null references ledger.allocation_policies (id) on delete restrict,
  transaction_id uuid not null unique references ledger.transactions (id) on delete restrict,
  recorded_by uuid not null references identity.accounts (user_id) on delete restrict,
  idempotency_key text not null,
  recorded_at timestamptz not null default now(),
  unique (recorded_by, idempotency_key),
  foreign key (tenant_id, office_id) references org.offices (tenant_id, id) on delete restrict,
  check ((fee_amount is null) = (fee_currency is null))
);

create index income_records_tenant_idx on finance.income_records (tenant_id, recorded_at desc);
create index income_records_membership_idx on finance.income_records (membership_id);
create index income_records_owner_idx on finance.income_records (owner_user_id);

-- The exact posted split, zero lines included (F-01.6).
create table finance.income_allocations (
  income_id uuid not null references finance.income_records (id) on delete restrict,
  pocket_id uuid not null references ledger.pockets (id) on delete restrict,
  pocket_name text not null,
  sort_order int not null,
  basis_points int not null check (basis_points between 0 and 10000),
  amount numeric(38, 18) not null check (amount >= 0),
  account_id uuid references ledger.accounts (id) on delete restrict,
  primary key (income_id, pocket_id),
  check ((amount = 0) = (account_id is null))
);

create index income_allocations_pocket_idx on finance.income_allocations (pocket_id);
create index income_allocations_account_idx on finance.income_allocations (account_id);

-- Cancel marker for an attempt whose outcome the leader didn't see (W-08).
create table finance.income_attempt_cancellations (
  actor_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  idempotency_key text not null,
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  target_membership_id uuid not null references org.memberships (id) on delete restrict,
  reason text not null check (length(btrim(reason)) between 3 and 500),
  cancelled_at timestamptz not null default now(),
  primary key (actor_user_id, idempotency_key)
);

create trigger income_records_immutable
before update or delete on finance.income_records
for each row execute function audit.reject_change();
create trigger income_allocations_immutable
before update or delete on finance.income_allocations
for each row execute function audit.reject_change();
create trigger income_attempt_cancellations_immutable
before update or delete on finance.income_attempt_cancellations
for each row execute function audit.reject_change();
create trigger income_records_no_truncate before truncate on finance.income_records
for each statement execute function audit.reject_change();
create trigger income_allocations_no_truncate before truncate on finance.income_allocations
for each statement execute function audit.reject_change();
create trigger income_attempt_cancellations_no_truncate before truncate on finance.income_attempt_cancellations
for each statement execute function audit.reject_change();

alter table finance.income_records enable row level security;
alter table finance.income_allocations enable row level security;
alter table finance.income_attempt_cancellations enable row level security;

-- The same per-actor key lock identity.replay takes.
create function finance.lock_attempt(p_actor_user_id uuid, p_idempotency_key text)
returns void
language sql
set search_path = ''
as $$
  select pg_advisory_xact_lock(hashtextextended(p_actor_user_id::text || ':' || p_idempotency_key, 0));
$$;

-- Decision 22: active non-President membership in an active office, owner
-- account active or restricted.
create function finance.target_eligible(p_membership org.memberships)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_membership.status = 'active'
    and p_membership.role <> 'president_team_member'
    and exists (select 1 from org.offices o where o.id = p_membership.office_id and o.status = 'active')
    and exists (select 1 from identity.accounts a
                where a.user_id = p_membership.user_id and a.status in ('active', 'restricted'));
$$;

create function finance.income_result(p_income_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'incomeId', i.id,
    'reference', i.reference,
    'status', 'posted',
    'transactionId', i.transaction_id,
    'membershipId', i.membership_id,
    'currency', i.currency,
    'amount', ledger.money(i.amount, i.currency),
    'allocations', (
      select jsonb_agg(jsonb_build_object(
        'pocketId', a.pocket_id,
        'pocket', a.pocket_name,
        'basisPoints', a.basis_points,
        'amount', ledger.money(a.amount, i.currency)
      ) order by a.sort_order, a.pocket_id)
      from finance.income_allocations a where a.income_id = i.id
    )
  )
  from finance.income_records i
  where i.id = p_income_id;
$$;

create function api.record_income(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_target_membership_id uuid,
  p_currency text,
  p_amount text,
  p_source text,
  p_received_on text,
  p_provider_reference text,
  p_notes text,
  p_fee_amount text,
  p_fee_currency text,
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
  v_fee numeric;
  v_received date;
  clean_source text;
  clean_provider text;
  clean_notes text;
  evidence_ids uuid[];
  request jsonb;
  replayed jsonb;
  v_wallet_id uuid;
  active ledger.active_allocation_policies;
  v_files int;
  line record;
  postings jsonb := '[]'::jsonb;
  allocations jsonb := '[]'::jsonb;
  v_account_id uuid;
  v_reference text;
  v_transaction_id uuid;
  v_income_id uuid;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  target := org.membership_in_tenant(workspace.tenant_id, p_target_membership_id);
  if target.role = 'president_team_member' then
    perform identity.fail('target_not_eligible');
  end if;
  perform authz.require(p_user_id, 'record_income', workspace.tenant_id, target.office_id, target.user_id, workspace.id);

  v_amount := ledger.parse_amount(p_amount, p_currency, 'amount');
  clean_source := org.require_text(p_source, 'source', 1, 100);
  begin
    v_received := p_received_on::date;
  exception when others then
    perform identity.fail('validation_error', jsonb_build_object('field', 'receivedOn'));
  end;
  if p_received_on !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or v_received < date '2000-01-01'
    or v_received > (now() at time zone 'UTC')::date + 1 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'receivedOn'));
  end if;
  if p_provider_reference is not null then
    clean_provider := org.require_text(p_provider_reference, 'providerReference', 1, 100);
  end if;
  if p_notes is not null then
    clean_notes := org.require_text(p_notes, 'notes', 1, 1000);
  end if;
  if (p_fee_amount is null) <> (p_fee_currency is null) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'fee'));
  end if;
  if p_fee_amount is not null then
    v_fee := ledger.parse_amount(p_fee_amount, p_fee_currency, 'fee.amount');
  end if;
  if p_evidence_ids is null or cardinality(p_evidence_ids) = 0 then
    perform identity.fail('evidence_required');
  end if;
  select array_agg(distinct e order by e) into evidence_ids from unnest(p_evidence_ids) e;
  if cardinality(evidence_ids) <> cardinality(p_evidence_ids) or cardinality(evidence_ids) > 5
    or array_position(evidence_ids, null) is not null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'evidenceIds'));
  end if;

  request := jsonb_build_object(
    'targetMembershipId', target.id, 'currency', p_currency, 'amount', ledger.money(v_amount, p_currency),
    'source', clean_source, 'receivedOn', v_received, 'providerReference', clean_provider, 'notes', clean_notes,
    'fee', case when v_fee is not null then jsonb_build_object('amount', ledger.money(v_fee, p_fee_currency), 'currency', p_fee_currency) end,
    'evidenceIds', to_jsonb(evidence_ids));
  replayed := identity.replay(p_user_id, p_idempotency_key, 'record_income', request);
  if replayed is not null then
    return replayed;
  end if;
  if exists (
    select 1 from finance.income_attempt_cancellations
    where actor_user_id = p_user_id and idempotency_key = p_idempotency_key
  ) then
    perform identity.fail('attempt_cancelled');
  end if;

  -- Lock order step 4: the target membership, shared.
  select * into target from org.memberships where id = target.id for share;
  if not finance.target_eligible(target) then
    perform identity.fail('target_not_eligible');
  end if;
  v_wallet_id := ledger.require_wallet(target.user_id);

  -- Step 6: the active split.
  select * into active from ledger.active_allocation_policies where tenant_id = workspace.tenant_id for share;
  if active.tenant_id is null then
    perform identity.fail('allocation_policy_missing');
  end if;

  -- Step 7: receipts bound to this actor, target and key.
  select count(*) into v_files from (
    select f.id from evidence.files f
    where f.id = any (evidence_ids)
      and f.tenant_id = workspace.tenant_id and f.purpose = 'income' and f.uploaded_by = p_user_id
      and f.target_membership_id = target.id and f.command_key = p_idempotency_key
      and f.status = 'finalized' and f.expires_at > now()
    order by f.id
    for update
  ) locked;
  if v_files <> cardinality(evidence_ids) then
    perform identity.fail('evidence_invalid');
  end if;

  -- Step 9: segments in display order, then the split once (fix d).
  for line in
    select a.pocket_id, a.basis_points, a.amount, l.name, l.sort_order
    from ledger.allocate(active.policy_id, p_currency, v_amount) a
    join ledger.allocation_policy_lines l on l.policy_id = active.policy_id and l.pocket_id = a.pocket_id
    order by l.sort_order, a.pocket_id
  loop
    v_account_id := null;
    if line.amount > 0 then
      v_account_id := ledger.segment_account(v_wallet_id, target.id, p_currency, line.pocket_id);
      postings := postings || jsonb_build_object('accountId', v_account_id, 'amount', line.amount::text);
    end if;
    allocations := allocations || jsonb_build_object('pocketId', line.pocket_id, 'name', line.name,
      'sortOrder', line.sort_order, 'basisPoints', line.basis_points, 'amount', line.amount::text,
      'accountId', v_account_id);
  end loop;
  postings := jsonb_build_array(jsonb_build_object(
    'accountId', ledger.system_account(workspace.tenant_id, p_currency, 'external_inflow'),
    'amount', (-v_amount)::text)) || postings;

  v_reference := refs.issue('INC');
  v_transaction_id := ledger.post('income', v_reference, target.id, p_user_id, p_idempotency_key,
    jsonb_build_array(jsonb_build_object('currency', p_currency, 'postings', postings)));

  insert into finance.income_records (reference, tenant_id, office_id, membership_id, wallet_id, owner_user_id,
    currency, amount, source, received_on, provider_reference, notes, fee_amount, fee_currency, policy_id,
    transaction_id, recorded_by, idempotency_key)
  values (v_reference, workspace.tenant_id, target.office_id, target.id, v_wallet_id, target.user_id,
    p_currency, v_amount, clean_source, v_received, clean_provider, clean_notes, v_fee,
    case when v_fee is not null then p_fee_currency end, active.policy_id,
    v_transaction_id, p_user_id, p_idempotency_key)
  returning id into v_income_id;

  insert into finance.income_allocations (income_id, pocket_id, pocket_name, sort_order, basis_points, amount, account_id)
  select v_income_id, (a->>'pocketId')::uuid, a->>'name', (a->>'sortOrder')::int, (a->>'basisPoints')::int,
    (a->>'amount')::numeric, (a->>'accountId')::uuid
  from jsonb_array_elements(allocations) a;

  update evidence.files set status = 'attached', attached_type = 'income', attached_id = v_income_id
  where id = any (evidence_ids);

  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'income.recorded', 'income', v_income_id::text,
    p_safe_after => jsonb_build_object('reference', v_reference, 'currency', p_currency,
      'amount', ledger.money(v_amount, p_currency), 'membershipId', target.id, 'policyVersion', active.version),
    p_request_id => p_request_id);

  -- U-11 is open: no income email and no outbox event (Blueprint 04, Cross-track 2).
  return identity.store_result(p_user_id, p_idempotency_key, 'record_income', request,
    finance.income_result(v_income_id));
end;
$$;

-- W-08 recovery: cancels an attempt whose outcome is unknown, or returns the
-- posted income if it already went through. Never deletes anything.
create function api.cancel_income_attempt(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_target_membership_id uuid,
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
  target org.memberships;
  clean_reason text;
  stored identity.command_results;
  cancelled finance.income_attempt_cancellations;
  evidence_cancelled int;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  target := org.membership_in_tenant(workspace.tenant_id, p_target_membership_id);
  perform authz.require(p_user_id, 'record_income', workspace.tenant_id, target.office_id, target.user_id, workspace.id);
  clean_reason := identity.require_reason(p_reason);
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{16,100}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'idempotencyKey'));
  end if;

  perform finance.lock_attempt(p_user_id, p_idempotency_key);

  select * into stored from identity.command_results
  where actor_user_id = p_user_id and idempotency_key = p_idempotency_key;
  if stored.actor_user_id is not null then
    if stored.command <> 'record_income' or stored.request->>'targetMembershipId' <> target.id::text then
      perform identity.fail('idempotency_conflict');
    end if;
    return stored.result || jsonb_build_object('replayed', true);
  end if;

  select * into cancelled from finance.income_attempt_cancellations
  where actor_user_id = p_user_id and idempotency_key = p_idempotency_key;
  if cancelled.actor_user_id is not null then
    if cancelled.target_membership_id <> target.id then
      perform identity.fail('idempotency_conflict');
    end if;
    return jsonb_build_object('status', 'cancelled', 'cancelledAt', cancelled.cancelled_at, 'replayed', true);
  end if;

  insert into finance.income_attempt_cancellations (actor_user_id, idempotency_key, tenant_id, target_membership_id, reason)
  values (p_user_id, p_idempotency_key, workspace.tenant_id, target.id, clean_reason)
  returning * into cancelled;

  update evidence.files set status = 'cancelled'
  where uploaded_by = p_user_id and command_key = p_idempotency_key and status in ('pending', 'finalized');
  get diagnostics evidence_cancelled = row_count;

  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'income.attempt_cancelled', 'membership', target.id::text,
    clean_reason, p_safe_after => jsonb_build_object('receiptsCancelled', evidence_cancelled), p_request_id => p_request_id);

  return jsonb_build_object('status', 'cancelled', 'cancelledAt', cancelled.cancelled_at, 'replayed', false);
end;
$$;

-- W-08 step 1: who the actor may record income for, plus the real setup state.
create function api.income_targets(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_office_id uuid default null,
  p_cursor text default null,
  p_limit int default null
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
  rows jsonb;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  if p_office_id is not null then
    perform org.office_in_tenant(workspace.tenant_id, p_office_id);
  end if;
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
      and (p_office_id is null or exists (
        select 1 from org.office_closure c where c.ancestor_id = p_office_id and c.descendant_id = m.office_id))
      and (authz.decide(p_user_id, 'record_income', workspace.tenant_id, m.office_id, m.user_id, workspace.id)->>'allowed')::boolean
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
    ) end,
    'allocation', ledger.allocation_json(workspace.tenant_id),
    'currencies', (select jsonb_agg(jsonb_build_object('code', c.code, 'scale', c.scale) order by c.code)
                   from ledger.currencies c where c.active)
  );
end;
$$;
