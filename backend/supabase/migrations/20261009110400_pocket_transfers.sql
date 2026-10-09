-- Blueprint 11 — W-13 pocket moves: request (hold), approve (posts at once),
-- reject, cancel; choices and lists. Same wallet, membership and currency;
-- Debt only receives, up to zero (F-01.8).

create function finance.transfer_json(p_transfer_id uuid, p_user_id uuid, p_workspace_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'transferId', t.id,
    'reference', t.reference,
    'status', t.status,
    'currency', t.currency,
    'amount', ledger.money(t.amount, t.currency),
    'reserved', case when r.status = 'active' then ledger.money(r.amount, t.currency) else ledger.money(0, t.currency) end,
    'from', jsonb_build_object('pocketId', sp.id, 'name', sp.name, 'kind', sp.kind),
    'to', jsonb_build_object('pocketId', dp.id, 'name', dp.name, 'kind', dp.kind),
    'tenant', jsonb_build_object('id', tn.id, 'name', tn.name),
    'office', jsonb_build_object('id', o.id, 'name', o.name),
    'membershipId', t.membership_id,
    'role', m.role,
    'walletId', t.wallet_id,
    'member', org.person(t.owner_user_id),
    'requestedBy', org.person(t.requested_by),
    'onBehalf', t.requested_by <> t.owner_user_id,
    'createdAt', t.created_at,
    'decidedAt', t.decided_at,
    'decidedBy', case when t.decided_by is not null then org.person(t.decided_by) end,
    'decisionReason', t.decision_reason,
    'transactionId', t.transaction_id,
    'can', jsonb_build_object(
      'approve', t.status = 'requested' and t.owner_user_id <> p_user_id
        and finance.can(p_user_id, 'approve_pocket_transfer', t.tenant_id, t.office_id, t.owner_user_id, p_workspace_id),
      'reject', t.status = 'requested' and t.owner_user_id <> p_user_id
        and finance.can(p_user_id, 'approve_pocket_transfer', t.tenant_id, t.office_id, t.owner_user_id, p_workspace_id),
      'cancel', t.status = 'requested' and p_user_id in (t.owner_user_id, t.requested_by))
  )
  from finance.pocket_transfers t
  join ledger.reservations r on r.id = t.reservation_id
  join ledger.pockets sp on sp.id = t.source_pocket_id
  join ledger.pockets dp on dp.id = t.destination_pocket_id
  join org.tenants tn on tn.id = t.tenant_id
  join org.offices o on o.id = t.office_id
  join org.memberships m on m.id = t.membership_id
  where t.id = p_transfer_id;
$$;

-- What Debt can still receive: its deficit (never positive Debt).
create function finance.debt_room(p_account_id uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  select greatest(-coalesce((select posted from ledger.balances where account_id = p_account_id), 0), 0);
$$;

-- Move between pockets (B05): own segments of active memberships in this
-- network, grouped by membership and currency, with every active pocket as a
-- possible destination.
create function api.transfer_choices(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
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
  perform authz.require(p_user_id, 'transfer_between_own_pockets', workspace.tenant_id, null, p_user_id, workspace.id);
  return jsonb_build_object('groups', coalesce((
    select jsonb_agg(jsonb_build_object(
      'membershipId', g.membership_id,
      'office', jsonb_build_object('id', o.id, 'name', o.name),
      'currency', g.currency,
      'pockets', (
        select jsonb_agg(jsonb_build_object(
          'pocketId', pk.id,
          'name', pk.name,
          'kind', pk.kind,
          'accountId', b.account_id,
          'posted', ledger.money(coalesce(b.posted, 0), g.currency),
          'reserved', ledger.money(coalesce(b.reserved, 0), g.currency),
          'available', ledger.money(coalesce(b.posted - b.reserved, 0), g.currency),
          'canSend', pk.kind = 'ordinary' and coalesce(b.posted - b.reserved, 0) > 0,
          'canReceive', pk.kind = 'ordinary' or coalesce(b.posted, 0) < 0,
          'maxReceive', case when pk.kind = 'debt' then ledger.money(greatest(-coalesce(b.posted, 0), 0), g.currency) end
        ) order by pk.sort_order, pk.id)
        from ledger.pockets pk
        left join ledger.balances b
          on b.pocket_id = pk.id and b.membership_id = g.membership_id and b.currency = g.currency
          and b.wallet_id = g.wallet_id
        where pk.tenant_id = workspace.tenant_id and pk.status = 'active'
      )
    ) order by o.name, g.membership_id, g.currency)
    from (
      select distinct b.membership_id, b.currency, b.wallet_id, b.office_id
      from ledger.balances b
      join org.memberships m on m.id = b.membership_id
      where b.owner_user_id = p_user_id and b.tenant_id = workspace.tenant_id and finance.target_eligible(m)
    ) g
    join org.offices o on o.id = g.office_id
  ), '[]'::jsonb));
end;
$$;

create function api.request_pocket_transfer(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_source_account_id uuid,
  p_destination_pocket_id uuid,
  p_amount text,
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
  source ledger.accounts;
  membership org.memberships;
  source_pocket ledger.pockets;
  dest_pocket ledger.pockets;
  v_amount numeric;
  v_dest_account uuid;
  request jsonb;
  replayed jsonb;
  v_id uuid := gen_random_uuid();
  v_reservation uuid;
  v_reference text;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  select * into source from ledger.accounts
  where id = p_source_account_id and class = 'member_value' and tenant_id = workspace.tenant_id;
  if source.id is null then
    perform identity.fail('not_found');
  end if;
  select * into membership from org.memberships where id = source.membership_id;
  if source.owner_user_id = p_user_id then
    perform authz.require(p_user_id, 'transfer_between_own_pockets', workspace.tenant_id, null, p_user_id, workspace.id);
  else
    perform authz.require(p_user_id, 'transfer_between_pockets_on_behalf', workspace.tenant_id, membership.office_id,
      source.owner_user_id, workspace.id);
  end if;
  if not finance.target_eligible(membership) then
    perform identity.fail('target_not_eligible');
  end if;
  select * into source_pocket from ledger.pockets where id = source.pocket_id;
  select * into dest_pocket from ledger.pockets
  where id = p_destination_pocket_id and tenant_id = workspace.tenant_id and status = 'active';
  if dest_pocket.id is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'destinationPocketId'));
  end if;
  if source_pocket.kind <> 'ordinary' or source_pocket.status <> 'active' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'sourceAccountId', 'reason', 'not_a_source'));
  end if;
  if dest_pocket.id = source_pocket.id then
    perform identity.fail('validation_error', jsonb_build_object('field', 'destinationPocketId', 'reason', 'same_pocket'));
  end if;
  v_amount := ledger.parse_amount(p_amount, source.currency, 'amount');

  request := jsonb_build_object('sourceAccountId', source.id, 'destinationPocketId', dest_pocket.id,
    'amount', ledger.money(v_amount, source.currency));
  replayed := identity.replay(p_user_id, p_idempotency_key, 'request_pocket_transfer', request);
  if replayed is not null then
    return replayed;
  end if;

  v_dest_account := ledger.segment_account(source.wallet_id, source.membership_id, source.currency, dest_pocket.id);
  if dest_pocket.kind = 'debt' and v_amount > finance.debt_room(v_dest_account) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'debt_limit',
      'maximum', ledger.money(finance.debt_room(v_dest_account), source.currency)));
  end if;
  v_reservation := ledger.reserve(source.id, v_amount, 'pocket_transfer', 'pocket_transfer', v_id, p_user_id);
  v_reference := refs.issue('PTR');

  insert into finance.pocket_transfers (id, reference, tenant_id, office_id, membership_id, wallet_id, owner_user_id,
    currency, source_account_id, destination_account_id, source_pocket_id, destination_pocket_id, amount,
    reservation_id, requested_by, idempotency_key)
  values (v_id, v_reference, source.tenant_id, source.office_id, source.membership_id, source.wallet_id,
    source.owner_user_id, source.currency, source.id, v_dest_account, source_pocket.id, dest_pocket.id, v_amount,
    v_reservation, p_user_id, p_idempotency_key);

  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'pocket_transfer.requested', 'pocket_transfer',
    v_id::text, p_safe_after => jsonb_build_object('reference', v_reference, 'currency', source.currency,
      'amount', ledger.money(v_amount, source.currency), 'from', source_pocket.name, 'to', dest_pocket.name,
      'onBehalf', source.owner_user_id <> p_user_id),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'request_pocket_transfer', request,
    finance.transfer_json(v_id, p_user_id, workspace.id));
end;
$$;

create function finance.transfer_in(p_tenant_id uuid, p_transfer_id uuid)
returns finance.pocket_transfers
language plpgsql
set search_path = ''
as $$
declare
  t finance.pocket_transfers;
begin
  select * into t from finance.pocket_transfers where id = p_transfer_id and tenant_id = p_tenant_id;
  if t.id is null then
    perform identity.fail('not_found');
  end if;
  return t;
end;
$$;

-- Approval and posting are one step (W-13): source −X, destination +X.
create function api.approve_pocket_transfer(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_transfer_id uuid,
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
  t finance.pocket_transfers;
  membership org.memberships;
  dest_pocket ledger.pockets;
  request jsonb;
  replayed jsonb;
  v_transaction_id uuid;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  t := finance.transfer_in(workspace.tenant_id, p_transfer_id);
  perform authz.require(p_user_id, 'approve_pocket_transfer', t.tenant_id, t.office_id, t.owner_user_id, workspace.id);

  request := jsonb_build_object('transferId', t.id);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'approve_pocket_transfer', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into t from finance.pocket_transfers where id = t.id for update;
  if t.status <> 'requested' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'transfer_state', 'status', t.status));
  end if;
  select * into membership from org.memberships where id = t.membership_id for share;
  if not finance.target_eligible(membership) then
    perform identity.fail('target_not_eligible');
  end if;
  select * into dest_pocket from ledger.pockets where id = t.destination_pocket_id;
  if dest_pocket.status <> 'active' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'pocket_retired'));
  end if;
  -- Debt is re-checked at posting, under the balance lock.
  perform 1 from ledger.balances where account_id in (t.source_account_id, t.destination_account_id)
  order by account_id for update;
  if dest_pocket.kind = 'debt' and t.amount > finance.debt_room(t.destination_account_id) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'debt_limit',
      'maximum', ledger.money(finance.debt_room(t.destination_account_id), t.currency)));
  end if;

  v_transaction_id := ledger.post('pocket_transfer', t.reference, t.membership_id, p_user_id, t.idempotency_key,
    jsonb_build_array(jsonb_build_object('currency', t.currency, 'postings', jsonb_build_array(
      jsonb_build_object('accountId', t.source_account_id, 'amount', (-t.amount)::text),
      jsonb_build_object('accountId', t.destination_account_id, 'amount', t.amount::text)))),
    jsonb_build_array(jsonb_build_object('reservationId', t.reservation_id, 'amount', t.amount::text)),
    jsonb_build_object('pocketTransferId', t.id));

  update finance.pocket_transfers
  set status = 'completed', decided_by = p_user_id, transaction_id = v_transaction_id
  where id = t.id;
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'pocket_transfer.completed', 'pocket_transfer',
    t.id::text, p_safe_after => jsonb_build_object('reference', t.reference, 'currency', t.currency,
      'amount', ledger.money(t.amount, t.currency)),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'approve_pocket_transfer', request,
    finance.transfer_json(t.id, p_user_id, workspace.id));
end;
$$;

create function api.reject_pocket_transfer(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_transfer_id uuid,
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
  t finance.pocket_transfers;
  clean_reason text;
  request jsonb;
  replayed jsonb;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  t := finance.transfer_in(workspace.tenant_id, p_transfer_id);
  perform authz.require(p_user_id, 'approve_pocket_transfer', t.tenant_id, t.office_id, t.owner_user_id, workspace.id);
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('transferId', t.id, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'reject_pocket_transfer', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into t from finance.pocket_transfers where id = t.id for update;
  if t.status <> 'requested' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'transfer_state', 'status', t.status));
  end if;
  perform ledger.release(t.reservation_id, 'Pocket move rejected: ' || clean_reason, p_user_id);
  update finance.pocket_transfers
  set status = 'rejected', decided_by = p_user_id, decision_reason = clean_reason
  where id = t.id;
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'pocket_transfer.rejected', 'pocket_transfer',
    t.id::text, p_reason => clean_reason,
    p_safe_after => jsonb_build_object('reference', t.reference, 'amount', ledger.money(t.amount, t.currency)),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'reject_pocket_transfer', request,
    finance.transfer_json(t.id, p_user_id, workspace.id));
end;
$$;

-- The wallet holder or whoever asked, before a decision (W-13).
create function api.cancel_pocket_transfer(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_transfer_id uuid,
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
  t finance.pocket_transfers;
  request jsonb;
  replayed jsonb;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  t := finance.transfer_in(workspace.tenant_id, p_transfer_id);
  if t.owner_user_id = p_user_id then
    perform authz.require(p_user_id, 'transfer_between_own_pockets', t.tenant_id, null, p_user_id, workspace.id);
  elsif t.requested_by = p_user_id then
    perform authz.require(p_user_id, 'transfer_between_pockets_on_behalf', t.tenant_id, t.office_id, t.owner_user_id,
      workspace.id);
  else
    perform identity.fail('not_found');
  end if;

  request := jsonb_build_object('transferId', t.id);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'cancel_pocket_transfer', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into t from finance.pocket_transfers where id = t.id for update;
  if t.status <> 'requested' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'transfer_state', 'status', t.status));
  end if;
  perform ledger.release(t.reservation_id, 'Pocket move cancelled by the requester', p_user_id);
  update finance.pocket_transfers set status = 'cancelled', decided_by = p_user_id where id = t.id;
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'pocket_transfer.cancelled', 'pocket_transfer',
    t.id::text, p_safe_after => jsonb_build_object('reference', t.reference, 'amount', ledger.money(t.amount, t.currency)),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'cancel_pocket_transfer', request,
    finance.transfer_json(t.id, p_user_id, workspace.id));
end;
$$;

-- Lists: own (`view` = own; status open/completed/closed) and the leader
-- queue (`view` = leader; tab waiting/history).
create function finance.transfer_page(
  p_workspace org.memberships,
  p_user_id uuid,
  p_view text,
  p_filter text,
  p_cursor text,
  p_limit int
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  page_size int;
  after jsonb;
  after_at timestamptz;
  after_id uuid;
  result jsonb;
begin
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

  with base as (
    select t.* from finance.pocket_transfers t
    where t.tenant_id = p_workspace.tenant_id
      and case p_view
        when 'own' then t.owner_user_id = p_user_id
        else t.owner_user_id <> p_user_id
          and finance.can(p_user_id, 'approve_pocket_transfer', t.tenant_id, t.office_id, t.owner_user_id, p_workspace.id)
      end
  ),
  filtered as (
    select * from base b
    where case p_filter
      when 'open' then b.status = 'requested'
      when 'waiting' then b.status = 'requested'
      when 'completed' then b.status = 'completed'
      when 'closed' then b.status in ('rejected', 'cancelled')
      when 'history' then b.status <> 'requested'
      else true
    end
  ),
  page as (
    select f.id, f.created_at, row_number() over (order by f.created_at desc, f.id desc) as n
    from filtered f
    where after is null or (f.created_at, f.id) < (after_at, after_id)
    order by f.created_at desc, f.id desc
    limit page_size + 1
  )
  select jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(finance.transfer_json(p.id, p_user_id, p_workspace.id) order by p.n)
      from page p where p.n <= page_size
    ), '[]'::jsonb),
    'nextCursor', (
      select org.encode_cursor(jsonb_build_object(
        's', to_char(p.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), 'id', p.id))
      from page p where p.n = page_size and exists (select 1 from page q where q.n > page_size)
    ),
    'counts', (
      select jsonb_build_object('open', count(*) filter (where status = 'requested'),
        'history', count(*) filter (where status <> 'requested'), 'all', count(*))
      from base
    ),
    'reserved', (
      select coalesce(jsonb_agg(jsonb_build_object('currency', x.currency, 'amount', ledger.money(x.total, x.currency))
        order by x.currency), '[]'::jsonb)
      from (select b.currency, sum(b.amount) as total from base b where b.status = 'requested' group by b.currency) x
    )
  ) into result;
  return result;
end;
$$;

create function api.my_pocket_transfers(
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
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  if p_status is not null and p_status not in ('open', 'completed', 'closed') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'status'));
  end if;
  return finance.transfer_page(workspace, p_user_id, 'own', p_status, p_cursor, p_limit);
end;
$$;

create function api.transfer_queue(
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
  if p_tab is null or p_tab not in ('waiting', 'history') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'tab'));
  end if;
  if not exists (
    select 1 from authz.role_permissions rp
    where rp.tenant_id = workspace.tenant_id and rp.role = workspace.role
      and rp.permission_key = 'approve_pocket_transfer' and rp.allowed
  ) and not exists (
    select 1 from authz.access_rules r
    where r.tenant_id = workspace.tenant_id and r.subject_user_id = p_user_id
      and r.permission_key = 'approve_pocket_transfer' and r.effect = 'allow' and r.revoked_at is null
  ) then
    perform identity.fail('authorization_denied');
  end if;
  return finance.transfer_page(workspace, p_user_id, 'leader', p_tab, p_cursor, p_limit);
end;
$$;
