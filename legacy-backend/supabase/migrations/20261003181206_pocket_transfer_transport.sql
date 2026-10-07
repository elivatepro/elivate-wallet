-- Actor and selected workspace are checked independently of target authorization.
create function financial_ops.require_transfer_context(
  p_actor_user_id uuid, p_actor_membership_id uuid, p_tenant_id uuid,
  p_office_id uuid, p_owner_user_id uuid
) returns void language plpgsql security invoker set search_path = '' as $$
declare actor public.memberships%rowtype;
begin
  perform financial_ops.require_command_actor(p_actor_user_id);
  if not exists(select 1 from public.user_accounts where user_id=p_actor_user_id and status='active') then
    raise exception using errcode='42501',message='transfers require an active account';
  end if;
  if p_actor_membership_id is null then
    if p_owner_user_id <> p_actor_user_id or p_owner_user_id is null then
      raise exception using errcode='42501',message='personal transfers require your own Wallet';
    end if;
    return;
  end if;
  select membership.* into actor from public.memberships membership
    join public.tenants tenant on tenant.id=membership.tenant_id and tenant.status='active'
    left join public.offices office on office.id=membership.office_id
    where membership.id=p_actor_membership_id and membership.user_id=p_actor_user_id
      and membership.status='active' and membership.role_key in
        ('team_leader','director','world_team_member','president_team_member')
      and (membership.office_id is null or office.status='active');
  if actor.id is null or actor.tenant_id <> p_tenant_id or p_owner_user_id=p_actor_user_id then
    raise exception using errcode='42501',message='transfer is outside your selected workspace';
  end if;
end;
$$;
revoke all on function financial_ops.require_transfer_context(uuid,uuid,uuid,uuid,uuid)
  from public,anon,authenticated,service_role;

-- Native workspace scope remains the default; a surviving explicit grant can expand
-- only the specific permission represented by this canonical decision.
create function financial_ops.transfer_decision_covers_context(
  p_actor_membership_id uuid, p_target_office_id uuid, p_decision authz.authorization_decision
) returns boolean language sql stable security invoker set search_path = '' as $$
  select ((p_decision).decision='ALLOW' or ((p_decision).decision='STEP_UP_REQUIRED'
    and (p_decision).reason_code in ('step_up_required','action_confirmation_required')))
    and (p_actor_membership_id is null or exists(select 1 from public.memberships actor
      where actor.id=p_actor_membership_id and actor.user_id=(p_decision).actor_user_id
        and actor.status='active' and actor.tenant_id=(p_decision).target_tenant_id
        and (actor.office_id is null or (p_decision).source='explicit_grant' or exists(
          select 1 from authz.office_closure closure where closure.tenant_id=actor.tenant_id
            and closure.ancestor_office_id=actor.office_id
            and closure.descendant_office_id=p_target_office_id))))
$$;
revoke all on function financial_ops.transfer_decision_covers_context(uuid,uuid,authz.authorization_decision)
  from public,anon,authenticated,service_role;

create function read_api.transfer_permissions(p_actor_user_id uuid,p_transfer_id uuid,p_actor_membership_id uuid)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare target financial_ops.pocket_transfer_requests%rowtype;
  approval authz.authorization_decision; initiation authz.authorization_decision;
  reports authz.authorization_decision; approve_allowed boolean; initiate_allowed boolean;
begin
  select * into target from financial_ops.pocket_transfer_requests where id=p_transfer_id;
  if target.id is null then return jsonb_build_object('read',false); end if;
  initiation := authz.authorize(p_actor_user_id,null,
    case when target.owner_user_id=p_actor_user_id then 'transfer_between_own_pockets'
      else 'transfer_between_pockets_on_behalf' end,
    target.tenant_id,target.office_id,target.membership_id,target.owner_user_id,
    target.wallet_id,target.owner_user_id);
  initiate_allowed := financial_ops.transfer_decision_covers_context(p_actor_membership_id,target.office_id,initiation);
  if target.owner_user_id=p_actor_user_id then
    return jsonb_build_object('read',true,'approve',false,'reject',false,
      'cancel',initiate_allowed and target.status='requested');
  end if;
  approval := authz.authorize(p_actor_user_id,null,'approve_pocket_transfer',target.tenant_id,
    target.office_id,target.membership_id,target.owner_user_id,target.wallet_id,target.owner_user_id);
  reports := authz.authorize(p_actor_user_id,null,'view_scoped_financial_reports',target.tenant_id,
    target.office_id,target.membership_id,target.owner_user_id,target.wallet_id,target.owner_user_id);
  approve_allowed := financial_ops.transfer_decision_covers_context(p_actor_membership_id,target.office_id,approval);
  return jsonb_build_object('read',approve_allowed or initiate_allowed or (reports.decision='ALLOW'
      and financial_ops.transfer_decision_covers_context(p_actor_membership_id,target.office_id,reports)),
    'approve',approve_allowed and target.status='requested',
    'reject',approve_allowed and target.status='requested',
    'cancel',initiate_allowed and target.requested_by_user_id=p_actor_user_id and target.status='requested');
end;
$$;
revoke all on function read_api.transfer_permissions(uuid,uuid,uuid) from public,anon,authenticated,service_role;

create function read_api.pocket_transfers(
  p_actor_user_id uuid,p_actor_membership_id uuid default null,p_status text default null,
  p_before_created_at timestamptz default null,p_before_transfer_id uuid default null,
  p_transfer_id uuid default null,p_search text default null
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare actor public.memberships%rowtype; target financial_ops.pocket_transfer_requests%rowtype;
  permissions jsonb; item jsonb; items jsonb := '[]'::jsonb; cursor_value jsonb := null;
  last_included jsonb; decision authz.authorization_decision; scope_allowed boolean := false;
begin
  perform financial_ops.require_command_actor(p_actor_user_id);
  if not exists(select 1 from public.user_accounts where user_id=p_actor_user_id and status='active') then
    raise exception using errcode='42501',message='transfers require an active account';
  end if;
  if p_status is not null and p_status not in ('requested','completed','cancelled','rejected')
    or (p_before_created_at is null) <> (p_before_transfer_id is null)
    or (p_before_created_at is not null and not isfinite(p_before_created_at))
    or (p_search is not null and length(p_search)>200)
    or (p_transfer_id is not null and (p_status is not null or p_before_created_at is not null or p_search is not null)) then
    raise exception using errcode='22023',message='transfer query is invalid';
  end if;
  if p_actor_membership_id is not null then
    select * into actor from public.memberships where id=p_actor_membership_id;
    perform financial_ops.require_transfer_context(p_actor_user_id,p_actor_membership_id,
      actor.tenant_id,actor.office_id,'00000000-0000-0000-0000-000000000000'::uuid);
    foreach decision in array array[
      authz.authorize(p_actor_user_id,null,'approve_pocket_transfer',actor.tenant_id,actor.office_id),
      authz.authorize(p_actor_user_id,null,'transfer_between_pockets_on_behalf',actor.tenant_id,actor.office_id),
      authz.authorize(p_actor_user_id,null,'view_scoped_financial_reports',actor.tenant_id,actor.office_id)
    ] loop
      scope_allowed := scope_allowed or decision.decision='ALLOW' or
        (decision.decision='STEP_UP_REQUIRED' and decision.reason_code in ('step_up_required','action_confirmation_required'));
    end loop;
  else
    if not exists(select 1 from public.wallets wallet join public.memberships membership
      on membership.user_id=wallet.owner_user_id and membership.status='active'
      join public.tenants tenant on tenant.id=membership.tenant_id and tenant.status='active'
      where wallet.owner_user_id=p_actor_user_id) then
      raise exception using errcode='42501',message='active Wallet membership is required';
    end if;
    scope_allowed := true;
  end if;
  for target in select transfer.* from financial_ops.pocket_transfer_requests transfer
    where (p_actor_membership_id is null and transfer.owner_user_id=p_actor_user_id
      or p_actor_membership_id is not null and transfer.owner_user_id<>p_actor_user_id
        and transfer.tenant_id=actor.tenant_id)
      and (p_status is null or transfer.status::text=p_status)
      and (p_transfer_id is null or transfer.id=p_transfer_id)
      and (p_before_created_at is null or (transfer.created_at,transfer.id)<(p_before_created_at,p_before_transfer_id))
      and (p_search is null or btrim(p_search)='' or strpos(lower(transfer.operation_reference),lower(btrim(p_search)))>0
        or exists(select 1 from public.user_accounts owner where owner.user_id=transfer.owner_user_id
          and strpos(lower(owner.public_uid),lower(btrim(p_search)))>0)
        or exists(select 1 from public.offices office where office.id=transfer.office_id
          and strpos(lower(office.name),lower(btrim(p_search)))>0))
    order by transfer.created_at desc,transfer.id desc
  loop
    permissions := read_api.transfer_permissions(p_actor_user_id,target.id,p_actor_membership_id);
    if not coalesce((permissions->>'read')::boolean,false) then continue; end if;
    scope_allowed := true;
    if jsonb_array_length(items)=50 then cursor_value := last_included; exit; end if;
    select jsonb_build_object('transfer_id',target.id,'reference',target.operation_reference,
      'wallet_uid',owner.public_uid,'tenant_name',tenant.name,'office_name',office.name,
      'membership_id',target.membership_id,'source_ledger_account_id',source.id,
      'destination_ledger_account_id',destination.id,'source_pocket_name',source_pocket.display_name,
      'destination_pocket_name',destination_pocket.display_name,'currency_code',target.currency_code,
      'scale',currency.minor_unit_scale,'amount',target.amount::text,'status',target.status,
      'created_at',target.created_at,'updated_at',target.updated_at,'approved_at',target.approved_at,
      'rejection_reason',target.rejection_reason,'cancellation_reason',target.cancellation_reason,
      'capabilities',permissions-'read') into item
      from public.user_accounts owner join public.tenants tenant on tenant.id=target.tenant_id
      join public.offices office on office.id=target.office_id
      join ledger.ledger_accounts source on source.id=target.source_ledger_account_id
      join ledger.ledger_accounts destination on destination.id=target.destination_ledger_account_id
      join public.pocket_definitions source_pocket on source_pocket.pocket_key=source.pocket_key
      join public.pocket_definitions destination_pocket on destination_pocket.pocket_key=destination.pocket_key
      join ledger.currency_definitions currency on currency.currency_code=target.currency_code
      where owner.user_id=target.owner_user_id;
    if item is null then continue; end if;
    items := items || jsonb_build_array(item);
    last_included := jsonb_build_object('created_at',target.created_at,'transfer_id',target.id);
  end loop;
  if not scope_allowed and p_actor_membership_id is not null then
    select exists(select 1 from financial_ops.pocket_transfer_requests candidate
      where candidate.tenant_id=actor.tenant_id and candidate.owner_user_id<>p_actor_user_id
        and coalesce((read_api.transfer_permissions(p_actor_user_id,candidate.id,p_actor_membership_id)->>'read')::boolean,false))
      into scope_allowed;
  end if;
  return jsonb_build_object('items',items,'next_cursor',cursor_value,'restricted',not scope_allowed);
end;
$$;
revoke all on function read_api.pocket_transfers(uuid,uuid,text,timestamptz,uuid,uuid,text) from public,anon,authenticated;
grant execute on function read_api.pocket_transfers(uuid,uuid,text,timestamptz,uuid,uuid,text) to service_role;

create function read_api.pocket_transfer_choices(
  p_actor_user_id uuid,p_actor_membership_id uuid default null,
  p_after_ledger_account_id uuid default null,p_source_ledger_account_id uuid default null
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare actor public.memberships%rowtype; source ledger.ledger_accounts%rowtype;
  decision authz.authorization_decision; items jsonb := '[]'::jsonb; destinations jsonb;
  cursor_value uuid := null; last_included uuid; item jsonb; allowed boolean; scope_allowed boolean := false;
begin
  perform financial_ops.require_command_actor(p_actor_user_id);
  if not exists(select 1 from public.user_accounts where user_id=p_actor_user_id and status='active') then
    raise exception using errcode='42501',message='transfers require an active account';
  end if;
  if p_after_ledger_account_id is not null and p_source_ledger_account_id is not null then
    raise exception using errcode='22023',message='transfer choice query is invalid';
  end if;
  if p_actor_membership_id is not null then
    select * into actor from public.memberships where id=p_actor_membership_id;
    perform financial_ops.require_transfer_context(p_actor_user_id,p_actor_membership_id,
      actor.tenant_id,actor.office_id,'00000000-0000-0000-0000-000000000000'::uuid);
    decision := authz.authorize(p_actor_user_id,null,'transfer_between_pockets_on_behalf',actor.tenant_id,actor.office_id);
    scope_allowed := decision.decision='ALLOW' or (decision.decision='STEP_UP_REQUIRED'
      and decision.reason_code in ('step_up_required','action_confirmation_required'));
  else
    if not exists(select 1 from public.wallets wallet join public.memberships membership
      on membership.user_id=wallet.owner_user_id and membership.status='active'
      join public.tenants tenant on tenant.id=membership.tenant_id and tenant.status='active'
      where wallet.owner_user_id=p_actor_user_id) then
      raise exception using errcode='42501',message='active Wallet membership is required';
    end if;
    scope_allowed := true;
  end if;
  for source in select account.* from ledger.ledger_accounts account
    join public.pocket_definitions pocket on pocket.pocket_key=account.pocket_key and pocket.transfer_out_allowed
    join public.memberships membership on membership.id=account.membership_id and membership.status='active'
    join public.tenants tenant on tenant.id=account.tenant_id and tenant.status='active'
    join public.offices office on office.id=account.office_id and office.status='active'
    join public.user_accounts owner on owner.user_id=account.owner_user_id and owner.status='active'
    where account.account_class='member_value' and account.pocket_key<>'debt'
      and (p_actor_membership_id is null and account.owner_user_id=p_actor_user_id
        or p_actor_membership_id is not null and account.owner_user_id<>p_actor_user_id
          and account.tenant_id=actor.tenant_id)
      and (p_after_ledger_account_id is null or account.id>p_after_ledger_account_id)
      and (p_source_ledger_account_id is null or account.id=p_source_ledger_account_id)
    order by account.id
  loop
    decision := authz.authorize(p_actor_user_id,null,
      case when source.owner_user_id=p_actor_user_id then 'transfer_between_own_pockets'
        else 'transfer_between_pockets_on_behalf' end,
      source.tenant_id,source.office_id,source.membership_id,source.owner_user_id,source.wallet_id,source.owner_user_id);
    allowed := financial_ops.transfer_decision_covers_context(p_actor_membership_id,source.office_id,decision);
    if not allowed then continue; end if;
    scope_allowed := true;
    select coalesce(jsonb_agg(jsonb_build_object('destination_ledger_account_id',destination.id,
      'pocket_name',pocket.display_name,'pocket_key',pocket.pocket_key,
      'maximum_amount',case when pocket.pocket_key='debt'
        then greatest(-coalesce((select balance from ledger.wallet_balance_projections where ledger_account_id=destination.id),0),0)::text else null end)
      order by pocket.display_name,destination.id),'[]'::jsonb) into destinations
      from ledger.ledger_accounts destination join public.pocket_definitions pocket
        on pocket.pocket_key=destination.pocket_key and pocket.transfer_in_allowed
      where destination.account_class='member_value' and destination.wallet_id=source.wallet_id
        and destination.tenant_id=source.tenant_id and destination.office_id=source.office_id
        and destination.membership_id=source.membership_id and destination.owner_user_id=source.owner_user_id
        and destination.currency_code=source.currency_code and destination.pocket_key<>source.pocket_key;
    if jsonb_array_length(destinations)=0 then continue; end if;
    if jsonb_array_length(items)=50 then cursor_value := last_included; exit; end if;
    select jsonb_build_object('source_ledger_account_id',source.id,'wallet_uid',owner.public_uid,
      'membership_id',source.membership_id,'tenant_name',tenant.name,'office_name',office.name,
      'pocket_name',pocket.display_name,'currency_code',source.currency_code,'scale',currency.minor_unit_scale,
      'posted_balance',coalesce(projection.balance,0)::text,
      'reserved_balance',(coalesce(projection.balance,0)-financial_ops.available_balance(source.id))::text,
      'available_balance',financial_ops.available_balance(source.id)::text,'can_submit',allowed,
      'destinations',destinations) into item
      from public.user_accounts owner join public.tenants tenant on tenant.id=source.tenant_id
      join public.offices office on office.id=source.office_id
      join public.pocket_definitions pocket on pocket.pocket_key=source.pocket_key
      join ledger.currency_definitions currency on currency.currency_code=source.currency_code
      left join ledger.wallet_balance_projections projection on projection.ledger_account_id=source.id
      where owner.user_id=source.owner_user_id;
    items := items || jsonb_build_array(item); last_included := source.id;
  end loop;
  if not scope_allowed and p_actor_membership_id is not null then
    select exists(select 1 from ledger.ledger_accounts candidate
      join public.pocket_definitions pocket on pocket.pocket_key=candidate.pocket_key and pocket.transfer_out_allowed
      join public.memberships membership on membership.id=candidate.membership_id and membership.status='active'
      join public.offices office on office.id=candidate.office_id and office.status='active'
      join public.user_accounts owner on owner.user_id=candidate.owner_user_id and owner.status='active'
      where candidate.account_class='member_value' and candidate.pocket_key<>'debt'
        and candidate.tenant_id=actor.tenant_id and candidate.owner_user_id<>p_actor_user_id
        and financial_ops.transfer_decision_covers_context(p_actor_membership_id,candidate.office_id,
          authz.authorize(p_actor_user_id,null,'transfer_between_pockets_on_behalf',candidate.tenant_id,
            candidate.office_id,candidate.membership_id,candidate.owner_user_id,candidate.wallet_id,candidate.owner_user_id)))
      into scope_allowed;
  end if;
  return jsonb_build_object('items',items,'next_cursor',cursor_value,'restricted',not scope_allowed);
end;
$$;
revoke all on function read_api.pocket_transfer_choices(uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function read_api.pocket_transfer_choices(uuid,uuid,uuid,uuid) to service_role;

-- One durable immutable response per actor-bound, context-bound command key.
create table financial_ops.pocket_transfer_commands (
  idempotency_key uuid primary key,actor_user_id uuid not null references public.user_accounts(user_id),
  request_fingerprint bytea not null check(octet_length(request_fingerprint)=32),
  result financial_ops.financial_operation_result not null,created_at timestamptz not null default clock_timestamp()
);
alter table financial_ops.pocket_transfer_commands enable row level security;
alter table financial_ops.pocket_transfer_commands force row level security;
create policy pocket_transfer_commands_deny_all on financial_ops.pocket_transfer_commands
  as restrictive for all to anon,authenticated using(false) with check(false);
revoke all on financial_ops.pocket_transfer_commands from public,anon,authenticated,service_role;
create function financial_ops.guard_transfer_command() returns trigger language plpgsql security invoker set search_path = '' as $$
begin raise exception using errcode='55000',message='transfer command results are immutable'; end;
$$;
create trigger pocket_transfer_commands_immutable before update or delete on financial_ops.pocket_transfer_commands
  for each row execute function financial_ops.guard_transfer_command();
revoke all on function financial_ops.guard_transfer_command() from public,anon,authenticated,service_role;

create function financial_ops.execute_scoped_transfer(
  p_action text,p_idempotency_key uuid,p_actor_user_id uuid,p_session_id uuid,
  p_actor_membership_id uuid,p_source_ledger_account_id uuid,p_destination_ledger_account_id uuid,
  p_amount numeric,p_transfer_id uuid,p_reason text
) returns financial_ops.financial_operation_result language plpgsql security invoker set search_path = '' as $$
declare source ledger.ledger_accounts%rowtype; target financial_ops.pocket_transfer_requests%rowtype;
  existing financial_ops.pocket_transfer_commands%rowtype; decision authz.authorization_decision;
  fingerprint bytea; result financial_ops.financial_operation_result; permission text;
  tenant_id uuid; office_id uuid; membership_id uuid; owner_id uuid; wallet_id uuid; amount_value numeric;
begin
  perform financial_ops.require_command_actor(p_actor_user_id);
  if not exists(select 1 from public.user_accounts where user_id=p_actor_user_id and status='active') then
    raise exception using errcode='42501',message='transfers require an active account';
  end if;
  if p_idempotency_key is null or p_action is null or p_action not in ('submit','approve','reject','cancel') then
    raise exception using errcode='22023',message='transfer command is invalid';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_idempotency_key::text,0));
  if p_action='submit' then
    if p_source_ledger_account_id is null or p_destination_ledger_account_id is null
      or p_amount is null or p_transfer_id is not null or p_reason is not null then
      raise exception using errcode='22023',message='transfer submission is invalid';
    end if;
    select * into source from ledger.ledger_accounts where id=p_source_ledger_account_id;
    if source.id is null then raise exception using errcode='P0002',message='transfer source is unavailable'; end if;
    tenant_id := source.tenant_id; office_id := source.office_id; membership_id := source.membership_id;
    owner_id := source.owner_user_id; wallet_id := source.wallet_id; amount_value := p_amount;
    permission := case when owner_id=p_actor_user_id then 'transfer_between_own_pockets' else 'transfer_between_pockets_on_behalf' end;
  else
    if p_transfer_id is null or p_source_ledger_account_id is not null or p_destination_ledger_account_id is not null
      or p_amount is not null or (p_action='approve' and p_reason is not null)
      or (p_action in ('reject','cancel') and (coalesce(length(btrim(p_reason)),0)=0 or length(p_reason)>500)) then
      raise exception using errcode='22023',message='transfer review is invalid';
    end if;
    select * into target from financial_ops.pocket_transfer_requests where id=p_transfer_id;
    if target.id is null then raise exception using errcode='P0002',message='transfer is unavailable'; end if;
    tenant_id := target.tenant_id; office_id := target.office_id; membership_id := target.membership_id;
    owner_id := target.owner_user_id; wallet_id := target.wallet_id; amount_value := target.amount;
    if p_action in ('approve','reject') and owner_id=p_actor_user_id or p_action='cancel'
      and p_actor_user_id<>owner_id and p_actor_user_id<>target.requested_by_user_id then
      raise exception using errcode='42501',message='transfer action is not allowed';
    end if;
    permission := case when p_action in ('approve','reject') then 'approve_pocket_transfer'
      when owner_id=p_actor_user_id then 'transfer_between_own_pockets' else 'transfer_between_pockets_on_behalf' end;
  end if;
  perform financial_ops.require_transfer_context(p_actor_user_id,p_actor_membership_id,tenant_id,office_id,owner_id);
  decision := authz.authorize(p_actor_user_id,p_session_id,permission,tenant_id,office_id,membership_id,
    owner_id,wallet_id,owner_id,p_action || '_pocket_transfer',amount_value);
  if not financial_ops.transfer_decision_covers_context(p_actor_membership_id,office_id,decision) then
    raise exception using errcode='42501',message='transfer action is outside your effective workspace scope';
  end if;
  if decision.decision='STEP_UP_REQUIRED' then
    raise exception using errcode='P0401',message=decision.reason_code;
  end if;
  perform financial_ops.enforce_authorization(decision);
  fingerprint := extensions.digest(jsonb_build_object('actor',p_actor_user_id,'workspace',p_actor_membership_id,
    'action',p_action,'source',p_source_ledger_account_id,'destination',p_destination_ledger_account_id,
    'amount',trim_scale(p_amount)::text,'transfer',p_transfer_id,'reason',btrim(p_reason))::text,'sha256');
  select * into existing from financial_ops.pocket_transfer_commands where idempotency_key=p_idempotency_key;
  if found then
    if existing.actor_user_id<>p_actor_user_id or existing.request_fingerprint<>fingerprint then
      raise exception using errcode='23505',message='transfer key already belongs to another command';
    end if;
    result := existing.result; result.reused := true; return result;
  end if;
  case p_action
    when 'submit' then result := financial_ops.submit_pocket_transfer(p_idempotency_key,p_source_ledger_account_id,
      p_destination_ledger_account_id,p_amount,p_actor_user_id,p_session_id);
    when 'approve' then result := financial_ops.approve_pocket_transfer(p_idempotency_key,p_transfer_id,p_actor_user_id,p_session_id);
    when 'reject' then result := financial_ops.reject_pocket_transfer(p_transfer_id,p_reason,p_actor_user_id,p_session_id);
    when 'cancel' then result := financial_ops.cancel_pocket_transfer(p_transfer_id,p_reason,p_actor_user_id,p_session_id);
  end case;
  insert into financial_ops.pocket_transfer_commands(idempotency_key,actor_user_id,request_fingerprint,result)
    values(p_idempotency_key,p_actor_user_id,fingerprint,result);
  return result;
end;
$$;
revoke all on function financial_ops.execute_scoped_transfer(text,uuid,uuid,uuid,uuid,uuid,uuid,numeric,uuid,text)
  from public,anon,authenticated,service_role;

create function command_api.submit_pocket_transfer(p_idempotency_key uuid,p_actor_user_id uuid,p_session_id uuid,
  p_actor_membership_id uuid,p_source_ledger_account_id uuid,p_destination_ledger_account_id uuid,p_amount numeric)
returns financial_ops.financial_operation_result language sql security definer set search_path = '' as $$
  select financial_ops.execute_scoped_transfer('submit',p_idempotency_key,p_actor_user_id,p_session_id,
    p_actor_membership_id,p_source_ledger_account_id,p_destination_ledger_account_id,p_amount,null,null);
$$;
create function command_api.approve_pocket_transfer(p_idempotency_key uuid,p_actor_user_id uuid,p_session_id uuid,
  p_actor_membership_id uuid,p_transfer_id uuid)
returns financial_ops.financial_operation_result language sql security definer set search_path = '' as $$
  select financial_ops.execute_scoped_transfer('approve',p_idempotency_key,p_actor_user_id,p_session_id,
    p_actor_membership_id,null,null,null,p_transfer_id,null);
$$;
create function command_api.reject_pocket_transfer(p_idempotency_key uuid,p_actor_user_id uuid,p_session_id uuid,
  p_actor_membership_id uuid,p_transfer_id uuid,p_reason text)
returns financial_ops.financial_operation_result language sql security definer set search_path = '' as $$
  select financial_ops.execute_scoped_transfer('reject',p_idempotency_key,p_actor_user_id,p_session_id,
    p_actor_membership_id,null,null,null,p_transfer_id,p_reason);
$$;
create function command_api.cancel_pocket_transfer(p_idempotency_key uuid,p_actor_user_id uuid,p_session_id uuid,
  p_actor_membership_id uuid,p_transfer_id uuid,p_reason text)
returns financial_ops.financial_operation_result language sql security definer set search_path = '' as $$
  select financial_ops.execute_scoped_transfer('cancel',p_idempotency_key,p_actor_user_id,p_session_id,
    p_actor_membership_id,null,null,null,p_transfer_id,p_reason);
$$;
revoke all on function command_api.submit_pocket_transfer(uuid,uuid,uuid,uuid,uuid,uuid,numeric) from public,anon,authenticated;
revoke all on function command_api.approve_pocket_transfer(uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function command_api.reject_pocket_transfer(uuid,uuid,uuid,uuid,uuid,text) from public,anon,authenticated;
revoke all on function command_api.cancel_pocket_transfer(uuid,uuid,uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function command_api.submit_pocket_transfer(uuid,uuid,uuid,uuid,uuid,uuid,numeric) to service_role;
grant execute on function command_api.approve_pocket_transfer(uuid,uuid,uuid,uuid,uuid) to service_role;
grant execute on function command_api.reject_pocket_transfer(uuid,uuid,uuid,uuid,uuid,text) to service_role;
grant execute on function command_api.cancel_pocket_transfer(uuid,uuid,uuid,uuid,uuid,text) to service_role;
