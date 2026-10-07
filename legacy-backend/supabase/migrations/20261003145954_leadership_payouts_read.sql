-- Private read helpers share the canonical resolver; none grant command authority.
create function read_api.payout_read_permissions(p_actor_user_id uuid, p_withdrawal_id uuid)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  target financial_ops.withdrawal_requests%rowtype;
  approval authz.authorization_decision;
  reports authz.authorization_decision;
  review authz.authorization_decision;
  approval_allowed boolean;
  reports_allowed boolean;
  review_allowed boolean;
begin
  select * into target from financial_ops.withdrawal_requests where id = p_withdrawal_id;
  if target.id is null or target.owner_user_id = p_actor_user_id then
    return jsonb_build_object('read', false, 'approval', false, 'review', false);
  end if;
  approval := authz.authorize(p_actor_user_id, null, 'approve_withdrawal', target.tenant_id,
    target.office_id, target.membership_id, target.owner_user_id, target.wallet_id, target.owner_user_id);
  reports := authz.authorize(p_actor_user_id, null, 'view_scoped_financial_reports', target.tenant_id,
    target.office_id, target.membership_id, target.owner_user_id, target.wallet_id, target.owner_user_id);
  review := authz.authorize_financial_evidence_review(p_actor_user_id, null, target.tenant_id,
    target.office_id, target.membership_id, target.owner_user_id, target.wallet_id, 'read_payouts');
  -- A missing fresh step-up may allow a masked read, never a financial command.
  approval_allowed := approval.decision = 'ALLOW' or (approval.decision = 'STEP_UP_REQUIRED'
    and approval.reason_code in ('step_up_required', 'action_confirmation_required'));
  reports_allowed := reports.decision = 'ALLOW';
  review_allowed := review.decision = 'ALLOW';
  return jsonb_build_object('read', approval_allowed or reports_allowed or review_allowed,
    'approval', approval_allowed, 'review', review_allowed);
end;
$$;
revoke all on function read_api.payout_read_permissions(uuid,uuid) from public,anon,authenticated,service_role;

create function read_api.payout_read_item(p_actor_user_id uuid, p_withdrawal_id uuid, p_permissions jsonb)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'withdrawal_id', withdrawal.id, 'reference', withdrawal.withdrawal_reference,
    'currency_code', withdrawal.source_currency_code, 'scale', currency.minor_unit_scale,
    'wallet_uid', owner.public_uid, 'office_name', office.name, 'pocket_name', pocket.display_name,
    'requested_amount', withdrawal.requested_amount::text, 'status', withdrawal.status,
    'created_at', withdrawal.created_at, 'updated_at', withdrawal.updated_at,
    'approved_at', withdrawal.approved_at, 'completed_at', withdrawal.completed_at,
    'destination', jsonb_build_object('institution_name', snapshot.institution_name,
      'account_reference_masked', case when length(snapshot.account_reference)>4 then '••••' || right(snapshot.account_reference,4) else '••••' end,
      'account_holder_name', snapshot.account_holder_name, 'payout_currency', snapshot.payout_currency,
      'payout_rail', snapshot.payout_rail, 'country_code', snapshot.country_code),
    'latest_assertion', case when assertion.id is null then null else jsonb_build_object(
      'assertion_id', assertion.id, 'status', assertion.status,
      'current_revision_number', assertion.current_revision_number,
      'revision', jsonb_build_object('wallet_debit_amount', revision.wallet_debit_amount::text,
        'beneficiary_payout_amount', revision.beneficiary_payout_amount::text,
        'provider_fee_amount', revision.provider_fee_amount::text, 'payout_currency', revision.payout_currency,
        'provider', revision.provider, 'provider_reference', revision.provider_reference,
        'paid_at', revision.paid_at, 'notes', revision.notes),
      'evidence', coalesce((select jsonb_agg(jsonb_build_object('evidence_id', evidence.id,
        'original_filename', evidence.original_filename, 'mime_type', evidence.mime_type,
        'file_size_bytes', evidence.file_size_bytes) order by evidence.id)
        from financial_ops.payout_assertion_evidence link
        join evidence.financial_evidence evidence on evidence.id = link.evidence_id
        where link.payout_assertion_revision_id = revision.id), '[]'::jsonb)
    ) end,
    'capabilities', jsonb_build_object(
      'approve', (p_permissions->>'approval')::boolean and withdrawal.status = 'requested',
      'reject', (p_permissions->>'approval')::boolean and withdrawal.status = 'requested',
      'cancel', (p_permissions->>'approval')::boolean and withdrawal.status = 'approved'
        and (assertion.id is null or assertion.status not in ('submitted','correction_required','needs_review')),
      'record', (p_permissions->>'approval')::boolean and withdrawal.status = 'approved'
        and withdrawal.approved_by_user_id = p_actor_user_id
        and (assertion.id is null or assertion.status not in ('submitted','correction_required','needs_review')),
      'correct', coalesce((p_permissions->>'approval')::boolean and withdrawal.status = 'approved'
        and withdrawal.approved_by_user_id = p_actor_user_id and assertion.submitted_by_user_id = p_actor_user_id
        and assertion.status = 'correction_required' and assertion.current_revision_number = 1,false),
      'review', coalesce((p_permissions->>'review')::boolean and assertion.status = 'needs_review'
        and assertion.submitted_by_user_id <> p_actor_user_id,false)
    )
  ) from financial_ops.withdrawal_requests withdrawal
  join ledger.currency_definitions currency on currency.currency_code = withdrawal.source_currency_code
  join public.user_accounts owner on owner.user_id = withdrawal.owner_user_id
  join public.offices office on office.id = withdrawal.office_id and office.tenant_id = withdrawal.tenant_id
  join public.pocket_definitions pocket on pocket.pocket_key = withdrawal.source_pocket_key
  join financial_ops.withdrawal_destination_snapshots snapshot on snapshot.withdrawal_id = withdrawal.id
  left join lateral (select * from financial_ops.payout_completion_assertions candidate
    where candidate.withdrawal_id = withdrawal.id order by candidate.assertion_number desc limit 1) assertion on true
  left join financial_ops.payout_assertion_revisions revision on revision.payout_assertion_id = assertion.id
    and revision.revision_number = assertion.current_revision_number
  where withdrawal.id = p_withdrawal_id;
$$;
revoke all on function read_api.payout_read_item(uuid,uuid,jsonb) from public,anon,authenticated,service_role;

create function read_api.leadership_payouts(
  p_actor_user_id uuid, p_actor_membership_id uuid,
  p_status text default null, p_before_created_at timestamptz default null,
  p_before_withdrawal_id uuid default null, p_withdrawal_id uuid default null, p_search text default null
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  actor public.memberships%rowtype;
  target financial_ops.withdrawal_requests%rowtype;
  approval authz.authorization_decision;
  reports authz.authorization_decision;
  review authz.authorization_decision;
  permissions jsonb;
  items jsonb := '[]'::jsonb;
  cursor_value jsonb := null;
  last_included jsonb := null;
  scope_authority boolean;
  item jsonb;
begin
  perform financial_ops.require_command_actor(p_actor_user_id);
  if (p_search is not null and length(p_search)>200) or p_status is not null and p_status not in ('requested','approved','completed','cancelled','rejected')
    or (p_before_created_at is null) <> (p_before_withdrawal_id is null)
    or (p_withdrawal_id is not null and (p_status is not null or p_before_created_at is not null or p_search is not null))
    or (p_before_created_at is not null and not isfinite(p_before_created_at)) then
    raise exception using errcode = '22023', message = 'payout read query is invalid';
  end if;
  select membership.* into actor from public.memberships membership
    join public.user_accounts account on account.user_id=membership.user_id and account.status='active'
    join public.tenants tenant on tenant.id=membership.tenant_id and tenant.status='active'
    left join public.offices office on office.id=membership.office_id
   where membership.id=p_actor_membership_id and membership.user_id=p_actor_user_id and membership.status='active'
     and membership.role_key in ('team_leader','director','world_team_member','president_team_member')
     and (membership.office_id is null or office.status='active');
  if actor.id is null then
    raise exception using errcode = '42501', message = 'active leadership workspace is required';
  end if;

  approval := authz.authorize(p_actor_user_id,null,'approve_withdrawal',actor.tenant_id,actor.office_id);
  reports := authz.authorize(p_actor_user_id,null,'view_scoped_financial_reports',actor.tenant_id,actor.office_id);
  review := authz.authorize_financial_evidence_review(p_actor_user_id,null,actor.tenant_id,actor.office_id,
    null,null,null,'read_payouts');
  scope_authority := approval.decision='ALLOW' or reports.decision='ALLOW' or review.decision='ALLOW'
    or (approval.decision='STEP_UP_REQUIRED' and approval.reason_code in ('step_up_required','action_confirmation_required'));
  -- General policy absence cannot preempt a valid member/office scoped grant.
  if not scope_authority then
    select exists(select 1 from financial_ops.withdrawal_requests candidate
      where candidate.tenant_id=actor.tenant_id
        and (actor.office_id is null or exists(select 1 from authz.office_closure closure
          where closure.tenant_id=actor.tenant_id and closure.ancestor_office_id=actor.office_id
            and closure.descendant_office_id=candidate.office_id))
        and (read_api.payout_read_permissions(p_actor_user_id,candidate.id)->>'read')::boolean)
      into scope_authority;
  end if;

  for target in select withdrawal.* from financial_ops.withdrawal_requests withdrawal
    where withdrawal.tenant_id=actor.tenant_id
      and (actor.office_id is null or exists(select 1 from authz.office_closure closure
        where closure.tenant_id=actor.tenant_id and closure.ancestor_office_id=actor.office_id
          and closure.descendant_office_id=withdrawal.office_id))
      and (p_search is null or btrim(p_search)='' or strpos(lower(withdrawal.withdrawal_reference),lower(btrim(p_search)))>0
        or exists(select 1 from public.user_accounts owner where owner.user_id=withdrawal.owner_user_id and strpos(lower(owner.public_uid),lower(btrim(p_search)))>0)
        or exists(select 1 from public.offices office where office.id=withdrawal.office_id and strpos(lower(office.name),lower(btrim(p_search)))>0))
      and (p_status is null or withdrawal.status::text=p_status)
      and (p_withdrawal_id is null or withdrawal.id=p_withdrawal_id)
      and (p_before_created_at is null or (withdrawal.created_at,withdrawal.id)<(p_before_created_at,p_before_withdrawal_id))
    order by withdrawal.created_at desc,withdrawal.id desc
  loop
    permissions := read_api.payout_read_permissions(p_actor_user_id,target.id);
    if not (permissions->>'read')::boolean then continue; end if;
    item := read_api.payout_read_item(p_actor_user_id,target.id,permissions);
    if item is null then continue; end if;
    if jsonb_array_length(items)=50 then cursor_value := last_included; exit; end if;
    items := items || jsonb_build_array(item);
    last_included := jsonb_build_object('created_at',target.created_at,'withdrawal_id',target.id);
  end loop;
  return jsonb_build_object('items',items,'next_cursor',cursor_value,'restricted',not scope_authority);
end;
$$;
revoke all on function read_api.leadership_payouts(uuid,uuid,text,timestamptz,uuid,uuid,text) from public,anon,authenticated;
grant execute on function read_api.leadership_payouts(uuid,uuid,text,timestamptz,uuid,uuid,text) to service_role;
