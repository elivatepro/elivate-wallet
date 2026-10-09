-- Blueprint 16 — review fixes (PR #51, Greptile 2026-10-09):
-- 1. Sync jobs carry a version: finishing an older job never clears a newer
--    change (turning auto-renew off while a sync runs).
-- 2. A smaller band chosen for next year must keep fitting: a new person
--    beyond it drops an unpaid choice; a paid smaller year caps seats.
-- 3. Reads that share checks with commands (withdrawal detail, review case)
--    keep working on a paused network.

-- ── 1. Sync versions ──────────────────────────────────────────────────────

alter table billing.subscriptions add column sync_version bigint not null default 0;

create or replace function billing.mark_sync(p_tenant_id uuid)
returns void
language sql
set search_path = ''
as $$
  update billing.subscriptions
  set sync_state = 'pending', sync_after = now(), sync_attempts = 0, sync_version = sync_version + 1,
      updated_at = now()
  where tenant_id = p_tenant_id and kind = 'paid'
    and (reusable_card or provider_subscription_code is not null);
$$;

create or replace function api.billing_sync_claim(p_limit int default 10)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  claimed jsonb;
begin
  with due as (
    select tenant_id from billing.subscriptions
    where sync_state = 'pending' and sync_after <= now()
      and (sync_lease_until is null or sync_lease_until < now())
    order by sync_after
    limit greatest(1, least(coalesce(p_limit, 10), 50))
    for update skip locked
  ), leased as (
    update billing.subscriptions s
    set sync_lease_until = now() + interval '2 minutes', sync_attempts = s.sync_attempts + 1
    from due where s.tenant_id = due.tenant_id
    returning s.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'tenantId', l.tenant_id,
    'version', l.sync_version,
    'renew', l.kind = 'paid' and l.status = 'active' and l.auto_renew and l.reusable_card
             and l.provider_customer_code is not null and l.period_end is not null,
    'planId', coalesce(l.next_plan_id, l.plan_id),
    'amountKobo', (select (p.price * 100)::bigint from billing.plans p where p.id = coalesce(l.next_plan_id, l.plan_id)),
    'startDate', l.period_end - billing.renewal_lead(),
    'customerCode', l.provider_customer_code,
    'subscriptionCode', l.provider_subscription_code,
    'emailToken', l.provider_email_token
  )), '[]'::jsonb) into claimed
  from leased l;
  return claimed;
end;
$$;

drop function api.billing_sync_done(uuid, text, text, text, text);

-- What Paystack now holds is always recorded; the queue is cleared only when
-- nothing changed since the job was claimed (otherwise it runs again).
create function api.billing_sync_done(
  p_tenant_id uuid,
  p_version bigint,
  p_outcome text,
  p_subscription_code text default null,
  p_email_token text default null,
  p_plan_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s billing.subscriptions;
  current_job boolean;
begin
  if p_outcome is null or p_outcome not in ('ok', 'failed', 'no_card') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'outcome'));
  end if;
  select * into s from billing.subscriptions where tenant_id = p_tenant_id for update;
  if s.tenant_id is null then
    perform identity.fail('not_found');
  end if;
  current_job := s.sync_version = p_version;
  if p_outcome = 'ok' then
    update billing.subscriptions
    set provider_subscription_code = p_subscription_code, provider_email_token = p_email_token,
        provider_plan_code = p_plan_code,
        sync_state = case when current_job then 'none' else 'pending' end,
        sync_attempts = 0, sync_after = case when current_job then null else now() end,
        sync_lease_until = null, updated_at = now()
    where tenant_id = p_tenant_id;
  elsif p_outcome = 'no_card' then
    update billing.subscriptions
    set reusable_card = false, provider_subscription_code = null, provider_email_token = null,
        provider_plan_code = null,
        sync_state = case when current_job then 'none' else 'pending' end,
        sync_attempts = 0, sync_after = case when current_job then null else now() end,
        sync_lease_until = null, updated_at = now()
    where tenant_id = p_tenant_id;
  else
    update billing.subscriptions
    set sync_state = case when s.sync_attempts >= 6 and current_job then 'failed' else 'pending' end,
        sync_after = now() + make_interval(mins => 5 * greatest(1, s.sync_attempts)),
        sync_lease_until = null, updated_at = now()
    where tenant_id = p_tenant_id;
  end if;
  return jsonb_build_object('tenantId', p_tenant_id, 'outcome', p_outcome, 'current', current_job);
end;
$$;

-- ── 2. Seats against next year's smaller band ─────────────────────────────

create or replace function org.check_seat_capacity(p_tenant_id uuid, p_user_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  s billing.subscriptions;
  cap int;
  next_cap int;
  used int;
begin
  perform pg_advisory_xact_lock(hashtextextended('billing.seats:' || p_tenant_id::text, 0));
  if billing.counted(p_tenant_id, p_user_id) then
    return;
  end if;
  -- No subscription row lock here (lock order: payments lock it before the
  -- tenant row); the advisory lock serializes seat changes.
  select * into s from billing.subscriptions where tenant_id = p_tenant_id;
  if s.tenant_id is null then
    return;
  end if;
  used := billing.seats_used(p_tenant_id);
  cap := billing.seat_cap(s);

  if s.next_plan_id is not null and s.kind <> 'development' then
    next_cap := (select seat_cap from billing.plans where id = s.next_plan_id);
    if next_cap is not null and used + 1 > next_cap then
      if s.plan_change_at is not null then
        -- Next year is already paid on the smaller band: it caps seats now.
        perform identity.fail('conflict', jsonb_build_object('reason', 'seat_limit_reached', 'used', used,
          'cap', next_cap));
      end if;
      -- An unpaid choice no longer fits: keep the current band next year.
      update billing.subscriptions set next_plan_id = null, updated_at = now() where tenant_id = p_tenant_id;
      insert into billing.periods (tenant_id, kind, plan_id) values (p_tenant_id, 'next_plan', s.plan_id);
      perform audit.record_tenant(p_tenant_id, null, 'subscription.next_plan_dropped', 'subscription',
        p_tenant_id::text, p_safe_after => jsonb_build_object('reason', 'seats_exceed_plan', 'used', used + 1));
      perform billing.mark_sync(p_tenant_id);
    end if;
  end if;

  if cap is null then
    return;
  end if;
  if used >= cap then
    perform identity.fail('conflict', jsonb_build_object('reason', 'seat_limit_reached', 'used', used, 'cap', cap));
  end if;
  if used + 1 >= ceil(cap * billing.seat_warning_share()) then
    perform billing.notify(p_tenant_id, 'billing.seats_almost_full', 'subscription', p_tenant_id,
      jsonb_build_object('network', notify.network(p_tenant_id), 'used', (used + 1)::text, 'cap', cap::text,
        'path', '/app/billing'),
      'seats:' || p_tenant_id::text || ':' || coalesce(s.period_start::text, 'none') || ':' || cap::text);
  end if;
end;
$$;

-- ── 3. Paused-network reads that share command checks ─────────────────────

drop function finance.require_approver(uuid, org.memberships, finance.withdrawals);
drop function finance.require_reviewer(uuid, org.memberships, finance.withdrawals, finance.payouts);
drop function finance.require_entry_reviewer(uuid, org.memberships, finance.entries);

-- p_read: a read (detail, case) that a paused network keeps; commands leave
-- it false and get the pause gate.
create function finance.require_approver(p_user_id uuid, p_workspace org.memberships, p_w finance.withdrawals,
  p_read boolean default false)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform authz.require(p_user_id, 'approve_withdrawal', p_w.tenant_id, p_w.office_id, p_w.owner_user_id,
    p_workspace.id,
    p_allow_paused => p_read or billing.approved_before_pause(p_w.tenant_id, p_w.approved_at));
end;
$$;

create function finance.require_reviewer(p_user_id uuid, p_workspace org.memberships, p_w finance.withdrawals,
  p_payout finance.payouts, p_read boolean default false)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform authz.require(p_user_id, 'review_financial_evidence', p_w.tenant_id, p_w.office_id, p_w.owner_user_id,
    p_workspace.id,
    p_allow_paused => p_read or billing.approved_before_pause(p_w.tenant_id, p_w.approved_at));
  if p_payout.submitted_by = p_user_id
    or exists (select 1 from finance.payout_revisions r where r.payout_id = p_payout.id and r.submitted_by = p_user_id) then
    perform identity.fail('self_target_forbidden');
  end if;
end;
$$;

create function finance.require_entry_reviewer(p_user_id uuid, p_workspace org.memberships, p_entry finance.entries,
  p_read boolean default false)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform authz.require(p_user_id, 'review_financial_evidence', p_entry.tenant_id, p_entry.office_id,
    p_entry.owner_user_id, p_workspace.id, p_allow_paused => p_read);
  if p_entry.submitted_by = p_user_id then
    perform identity.fail('self_target_forbidden');
  end if;
end;
$$;

create or replace function api.withdrawal_detail(p_user_id uuid, p_session_id uuid, p_membership_id uuid, p_withdrawal_id uuid)
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
  perform finance.require_approver(p_user_id, workspace, w, p_read => true);
  -- Approvers see what the receipt check read (C07 "Receipt shows").
  return finance.withdrawal_json(w.id, p_user_id, workspace.id) || jsonb_build_object('payout', (
    select finance.payout_json(p, true) from finance.payouts p
    where p.withdrawal_id = w.id order by p.attempt_no desc limit 1
  ));
end;
$$;

create or replace function api.review_case(p_user_id uuid, p_session_id uuid, p_membership_id uuid, p_payout_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  payout finance.payouts;
  w finance.withdrawals;
  e finance.entries;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  select * into payout from finance.payouts where id = p_payout_id;
  if payout.id is null then
    e := finance.entry_in(workspace.tenant_id, p_payout_id);
    perform finance.require_entry_reviewer(p_user_id, workspace, e, p_read => true);
    return finance.entry_case_json(e.id);
  end if;
  w := finance.withdrawal_in(workspace.tenant_id, payout.withdrawal_id);
  perform finance.require_reviewer(p_user_id, workspace, w, payout, p_read => true);
  return finance.review_case_json(payout.id, p_user_id, workspace.id);
end;
$$;

revoke all on all functions in schema billing from public, anon, authenticated;
revoke all on function finance.require_approver(uuid, org.memberships, finance.withdrawals, boolean) from public, anon, authenticated;
revoke all on function finance.require_reviewer(uuid, org.memberships, finance.withdrawals, finance.payouts, boolean) from public, anon, authenticated;
revoke all on function finance.require_entry_reviewer(uuid, org.memberships, finance.entries, boolean) from public, anon, authenticated;

do $$
declare
  fn regprocedure;
begin
  for fn in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end;
$$;
