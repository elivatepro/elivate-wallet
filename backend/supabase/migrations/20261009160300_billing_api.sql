-- Blueprint 16 — B3: billing reads and commands for the `billing` Edge
-- Function. User routes pass the session; the webhook and sync worker entry
-- points are service-only and trust nothing they did not verify server-side.

-- ── Presentation ──────────────────────────────────────────────────────────

create function billing.plan_json(p_plan billing.plans)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select case when p_plan.id is null then null else jsonb_build_object(
    'key', p_plan.key,
    'name', p_plan.name,
    'seatCap', p_plan.seat_cap,
    'price', billing.money(p_plan.price),
    'currency', p_plan.currency
  ) end;
$$;

create function billing.payment_json(p_payment billing.payments)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_payment.id,
    'reference', p_payment.reference,
    'purpose', p_payment.purpose,
    'status', p_payment.status,
    'amount', billing.money(p_payment.amount),
    'currency', p_payment.currency,
    'plan', billing.plan_json(billing.plan_by_id(p_payment.plan_id)),
    'fromPlan', billing.plan_json(billing.plan_by_id(p_payment.from_plan_id)),
    'coversFrom', p_payment.covers_from,
    'coversTo', p_payment.covers_to,
    'paidAt', p_payment.paid_at,
    'createdAt', p_payment.created_at,
    'applied', p_payment.applied,
    'needsReview', p_payment.needs_review,
    'authorizationUrl', case when p_payment.status = 'open' then p_payment.authorization_url end
  );
$$;

-- What each plan row offers (PL04, PL08d, PL07d): the current band, a paid
-- upgrade with its prorated amount, or a year at full price.
create function billing.plan_offers(p_s billing.subscriptions)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with current_plan as (select * from billing.plans where id = p_s.plan_id),
  used as (select billing.seats_used(p_s.tenant_id) as n)
  select coalesce(jsonb_agg(billing.plan_json(p) || jsonb_build_object(
      'action', case
        when p.id = p_s.plan_id and p_s.status in ('trial', 'active') then 'current'
        when p_s.status = 'active' and p_s.kind = 'paid' and p.rank > c.rank then 'upgrade'
        when p_s.status = 'active' and p_s.kind = 'paid' then null
        else 'choose' end,
      'amount', case
        when p.id = p_s.plan_id and p_s.status = 'active' and p_s.kind = 'paid' then null
        when p_s.status = 'active' and p_s.kind = 'paid' and p.rank > c.rank
          then billing.money(billing.prorate(c.price, p.price, billing.days_left(p_s.period_end)))
        when p_s.status = 'active' and p_s.kind = 'paid' then null
        else billing.money(p.price) end,
      'daysLeft', case when p_s.status = 'active' and p_s.kind = 'paid' and p.rank > c.rank
                       then billing.days_left(p_s.period_end) end,
      'fits', p.seat_cap is null or u.n <= p.seat_cap
    ) order by p.rank), '[]'::jsonb)
  from billing.plans p cross join current_plan c cross join used u
  where p.launch and p.version = (select max(version) from billing.plans x where x.key = p.key and x.launch);
$$;

create function billing.owner_json(p_tenant_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select org.person(o.user_id) || jsonb_build_object(
    'membershipId', o.membership_id,
    'since', o.assigned_at,
    'role', (select m.role from org.memberships m
             where m.tenant_id = o.tenant_id and m.user_id = o.user_id and m.status = 'active'
             order by m.is_primary desc, m.started_at limit 1)
  )
  from billing.owners o where o.tenant_id = p_tenant_id and o.ended_at is null;
$$;

create function billing.overview_json(p_tenant_id uuid, p_can_manage boolean)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  s billing.subscriptions;
begin
  select * into s from billing.subscriptions where tenant_id = p_tenant_id;
  return jsonb_build_object(
    'network', notify.network(p_tenant_id),
    'status', s.status,
    'kind', s.kind,
    'plan', billing.plan_json(billing.plan_by_id(s.plan_id)),
    'nextPlan', billing.plan_json(billing.plan_by_id(s.next_plan_id)),
    'planChangeAt', s.plan_change_at,
    'periodStart', s.period_start,
    'periodEnd', s.period_end,
    'lastDay', case when s.period_end is not null then billing.last_day(s.period_end) end,
    'daysLeft', case when s.period_end is not null and s.status in ('trial', 'active')
                     then billing.days_left(s.period_end) end,
    'pausedAt', s.paused_at,
    'seats', jsonb_build_object('used', billing.seats_used(p_tenant_id), 'cap', billing.seat_cap(s)),
    'autoRenew', s.auto_renew,
    'renewsAutomatically', s.kind = 'paid' and s.status = 'active' and s.auto_renew and s.reusable_card
                           and s.provider_subscription_code is not null,
    'cardOnFile', s.reusable_card,
    'owner', billing.owner_json(p_tenant_id),
    'canManage', p_can_manage,
    'plans', billing.plan_offers(s),
    'payments', coalesce((
      select jsonb_agg(billing.payment_json(p) order by p.created_at desc, p.id)
      from (select * from billing.payments
            where tenant_id = p_tenant_id and status in ('paid', 'failed')
            order by created_at desc, id limit 20) p
    ), '[]'::jsonb)
  );
end;
$$;

-- ── Reads ─────────────────────────────────────────────────────────────────

-- Founder setup (PL02/PL11): the plans, whether the founder's one trial is
-- still available, and their networks still awaiting payment.
create function api.billing_setup(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  return jsonb_build_object(
    'trialAvailable', not exists (select 1 from billing.trials where user_id = p_user_id),
    'trialDays', extract(day from billing.trial_length())::int,
    'plans', (select jsonb_agg(billing.plan_json(p) order by p.rank) from billing.plans p
              where p.launch and p.version = (select max(version) from billing.plans x where x.key = p.key)),
    'pending', coalesce((
      select jsonb_agg(jsonb_build_object(
        'tenantId', t.id, 'name', t.name, 'membershipId', m.id,
        'plan', billing.plan_json(billing.plan_by_id(s.plan_id))) order by t.created_at)
      from org.tenants t
      join billing.subscriptions s on s.tenant_id = t.id
      join org.memberships m on m.tenant_id = t.id and m.user_id = p_user_id and m.status = 'active'
      where t.created_by = p_user_id and t.status = 'pending_payment'
    ), '[]'::jsonb)
  );
end;
$$;

create function api.billing_overview(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  can_manage boolean;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  can_manage := billing.require_actor(p_user_id, workspace, false);
  return billing.overview_json(workspace.tenant_id, can_manage);
end;
$$;

-- A payment of the caller's network. While it is still open, `verify`
-- carries what the function needs to check it with Paystack; it is never
-- passed to the client.
create function api.billing_payment(p_user_id uuid, p_session_id uuid, p_membership_id uuid, p_payment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  p billing.payments;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform billing.require_actor(p_user_id, workspace, false);
  select * into p from billing.payments where id = p_payment_id and tenant_id = workspace.tenant_id;
  if p.id is null then
    perform identity.fail('not_found');
  end if;
  return jsonb_build_object(
    'payment', billing.payment_json(p) || jsonb_build_object('network', notify.network(p.tenant_id)),
    'tenantStatus', (select status from org.tenants where id = p.tenant_id),
    'verify', case when p.status <> 'paid' and p.purpose <> 'auto_renewal' then jsonb_build_object(
      'providerReference', p.provider_reference, 'environment', p.environment) end
  );
end;
$$;

create function api.billing_owner_candidates(p_user_id uuid, p_session_id uuid, p_membership_id uuid,
  p_query text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  q text := nullif(btrim(coalesce(p_query, '')), '');
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform billing.require_actor(p_user_id, workspace, true);
  if q is not null and length(q) > 100 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'q'));
  end if;
  return coalesce((
    select jsonb_agg(c.item order by c.name nulls last, c.uid)
    from (
      select distinct on (m.user_id)
        org.person(m.user_id) || jsonb_build_object('membershipId', m.id, 'role', m.role, 'office', o.name,
          'current', exists (select 1 from billing.owners b where b.tenant_id = m.tenant_id
                             and b.user_id = m.user_id and b.ended_at is null)) as item,
        org.person(m.user_id)->>'name' as name, a.uid
      from org.memberships m
      join identity.accounts a on a.user_id = m.user_id and a.status = 'active'
      left join org.offices o on o.id = m.office_id
      where m.tenant_id = workspace.tenant_id and m.status = 'active'
        and (q is null or a.uid ilike '%' || q || '%' or (org.person(m.user_id)->>'name') ilike '%' || q || '%')
      order by m.user_id, m.is_primary desc, m.started_at
      limit 50
    ) c
  ), '[]'::jsonb);
end;
$$;

-- ── Checkout ──────────────────────────────────────────────────────────────

-- Prices a checkout server-side and opens a payment. `year` buys a year of
-- the band (start, renew or reactivate, from the network's state);
-- `upgrade` pays the prorated difference. A free upgrade (the last paid day)
-- applies at once. The function then opens Paystack with the returned
-- amount, email and provider reference.
create function api.billing_checkout(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_plan_key text,
  p_kind text,
  p_environment text,
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
  plan billing.plans;
  current_plan billing.plans;
  request jsonb;
  replayed jsonb;
  s billing.subscriptions;
  v_purpose text;
  v_amount numeric;
  v_days int;
  v_used int;
  payment billing.payments;
  payer_email text;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform billing.require_actor(p_user_id, workspace, false);
  if p_kind is null or p_kind not in ('year', 'upgrade') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'kind'));
  end if;
  if p_environment is null or p_environment not in ('test', 'live') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'environment'));
  end if;
  plan := billing.plan(coalesce(p_plan_key, ''));
  select lower(btrim(email)) into payer_email from auth.users where id = p_user_id;

  request := jsonb_build_object('membershipId', workspace.id, 'planKey', plan.key, 'kind', p_kind);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'billing_checkout', request);
  if replayed is not null then
    select * into payment from billing.payments where id = (replayed->>'paymentId')::uuid;
    return replayed || jsonb_build_object('email', payer_email, 'status', payment.status,
      'authorizationUrl', case when payment.status = 'open' then payment.authorization_url end);
  end if;

  s := billing.subscription(workspace.tenant_id, true);
  current_plan := billing.plan_by_id(s.plan_id);
  v_used := billing.seats_used(workspace.tenant_id);

  if p_kind = 'upgrade' then
    if s.status <> 'active' or s.kind <> 'paid' or plan.rank <= current_plan.rank or s.period_end <= now() then
      perform identity.fail('conflict', jsonb_build_object('reason', 'not_upgradable'));
    end if;
    v_days := billing.days_left(s.period_end);
    v_amount := billing.prorate(current_plan.price, plan.price, v_days);
    v_purpose := 'upgrade';
    if v_amount <= 0 then
      update billing.subscriptions
      set plan_id = plan.id, next_plan_id = null, plan_change_at = null, updated_at = now()
      where tenant_id = s.tenant_id;
      insert into billing.periods (tenant_id, kind, plan_id, starts_at, ends_at, actor_user_id)
      values (s.tenant_id, 'upgrade', plan.id, now(), s.period_end, p_user_id);
      perform audit.record_tenant(s.tenant_id, p_user_id, 'subscription.upgraded', 'subscription', s.tenant_id::text,
        p_safe_before => jsonb_build_object('plan', current_plan.key),
        p_safe_after => jsonb_build_object('plan', plan.key, 'amount', '0.00'), p_request_id => p_request_id);
      perform billing.mark_sync(s.tenant_id);
      return identity.store_result(p_user_id, p_idempotency_key, 'billing_checkout', request,
        jsonb_build_object('paymentId', null, 'applied', true, 'amount', '0.00', 'currency', 'NGN'));
    end if;
  else
    v_purpose := case s.status when 'pending' then 'start' when 'paused' then 'reactivate' else 'renew' end;
    if s.status = 'active' and s.kind = 'paid' then
      if s.auto_renew and s.reusable_card and s.provider_subscription_code is not null then
        perform identity.fail('conflict', jsonb_build_object('reason', 'auto_renew_on'));
      end if;
      if plan.rank > current_plan.rank then
        perform identity.fail('conflict', jsonb_build_object('reason', 'use_upgrade'));
      end if;
    end if;
    if plan.seat_cap is not null and v_used > plan.seat_cap then
      perform identity.fail('conflict', jsonb_build_object('reason', 'seats_exceed_plan', 'used', v_used,
        'cap', plan.seat_cap));
    end if;
    v_amount := plan.price;
  end if;

  update billing.payments
  set status = 'superseded', authorization_url = null, updated_at = now()
  where tenant_id = s.tenant_id and status = 'open' and purpose <> 'auto_renewal';

  insert into billing.payments (tenant_id, reference, purpose, plan_id, from_plan_id, amount, currency, days_left,
    provider_reference, environment, initiated_by, idempotency_key)
  values (s.tenant_id, refs.issue('PAY'), v_purpose, plan.id,
    case when v_purpose = 'upgrade' then current_plan.id end, v_amount, 'NGN',
    case when v_purpose = 'upgrade' then v_days end,
    'ewp_' || replace(gen_random_uuid()::text, '-', ''), p_environment, p_user_id, p_idempotency_key)
  returning * into payment;

  perform audit.record_tenant(s.tenant_id, p_user_id, 'billing.checkout_opened', 'billing_payment', payment.id::text,
    p_safe_after => jsonb_build_object('reference', payment.reference, 'purpose', v_purpose, 'plan', plan.key,
      'amount', billing.money(v_amount), 'currency', 'NGN'),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'billing_checkout', request,
    jsonb_build_object('paymentId', payment.id, 'applied', false, 'reference', payment.reference,
      'purpose', v_purpose, 'amount', billing.money(v_amount), 'currency', 'NGN',
      'amountKobo', (v_amount * 100)::bigint, 'providerReference', payment.provider_reference))
    || jsonb_build_object('email', payer_email, 'status', 'open', 'authorizationUrl', null);
end;
$$;

-- Records the Paystack checkout URL for an open payment (the function calls
-- this right after transaction/initialize).
create function api.billing_checkout_opened(p_user_id uuid, p_payment_id uuid, p_authorization_url text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_authorization_url is null or length(p_authorization_url) > 500
     or p_authorization_url !~ '^https?://[^\s]+$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'authorizationUrl'));
  end if;
  update billing.payments
  set authorization_url = p_authorization_url, updated_at = now()
  where id = p_payment_id and initiated_by = p_user_id and status = 'open';
  if not found then
    perform identity.fail('conflict', jsonb_build_object('reason', 'payment_not_open'));
  end if;
  return jsonb_build_object('paymentId', p_payment_id);
end;
$$;

-- ── Verified provider facts (service only) ────────────────────────────────

-- Applies a charge the function verified with Paystack (transaction/verify):
-- amount in kobo, currency, mode, customer. Unknown references change nothing.
create function api.billing_apply_verified(
  p_provider_reference text,
  p_amount_kobo bigint,
  p_currency text,
  p_paid_at timestamptz,
  p_transaction_id bigint,
  p_customer_code text,
  p_reusable boolean,
  p_environment text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  p billing.payments;
begin
  select * into p from billing.payments where provider_reference = p_provider_reference;
  if p.id is null then
    return jsonb_build_object('outcome', 'unknown_reference');
  end if;
  if p.environment is distinct from p_environment then
    return jsonb_build_object('outcome', 'wrong_environment', 'paymentId', p.id);
  end if;
  if p_amount_kobo is null or p_amount_kobo <= 0 or p_paid_at is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'amount'));
  end if;
  return billing.apply_payment(p.id, p_amount_kobo::numeric / 100, upper(p_currency), p_paid_at,
    p_transaction_id, nullif(p_customer_code, ''), p_reusable);
end;
$$;

-- Paystack says the checkout failed or was abandoned (PL10d). Only an open
-- payment changes; a later verified charge still applies.
create function api.billing_mark_unpaid(p_provider_reference text, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_status is null or p_status not in ('failed', 'abandoned') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'status'));
  end if;
  update billing.payments
  set status = p_status, authorization_url = null, updated_at = now()
  where provider_reference = p_provider_reference and status = 'open';
  return jsonb_build_object('updated', found);
end;
$$;

-- An automatic renewal charge (Paystack subscription). The network is found
-- by the subscription code, or by the customer + plan pair when exactly one
-- subscription fits; the amount must be that plan's price.
create function api.billing_record_renewal(
  p_provider_reference text,
  p_subscription_code text,
  p_customer_code text,
  p_plan_code text,
  p_amount_kobo bigint,
  p_currency text,
  p_paid_at timestamptz,
  p_transaction_id bigint,
  p_reusable boolean,
  p_environment text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing billing.payments;
  s billing.subscriptions;
  matches int;
  plan billing.plans;
  payment billing.payments;
begin
  if p_provider_reference is null or p_provider_reference !~ '^[A-Za-z0-9._=-]{6,100}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'reference'));
  end if;
  select * into existing from billing.payments where provider_reference = p_provider_reference;
  if existing.id is not null then
    if existing.status = 'paid' then
      return jsonb_build_object('outcome', 'duplicate', 'paymentId', existing.id, 'tenantId', existing.tenant_id);
    end if;
    return billing.apply_payment(existing.id, p_amount_kobo::numeric / 100, upper(p_currency), p_paid_at,
      p_transaction_id, nullif(p_customer_code, ''), p_reusable);
  end if;

  if p_subscription_code is not null then
    select * into s from billing.subscriptions where provider_subscription_code = p_subscription_code;
  end if;
  if s.tenant_id is null and p_customer_code is not null and p_plan_code is not null then
    select count(*) into matches from billing.subscriptions
    where provider_customer_code = p_customer_code and provider_plan_code = p_plan_code;
    if matches = 1 then
      select * into s from billing.subscriptions
      where provider_customer_code = p_customer_code and provider_plan_code = p_plan_code;
    end if;
  end if;
  if s.tenant_id is null or s.kind <> 'paid' then
    return jsonb_build_object('outcome', 'unmatched');
  end if;

  select pl.* into plan from billing.provider_plans pp join billing.plans pl on pl.id = pp.plan_id
  where pp.plan_code = p_plan_code and pp.environment = p_environment;
  if plan.id is null then
    return jsonb_build_object('outcome', 'unknown_plan', 'tenantId', s.tenant_id);
  end if;

  insert into billing.payments (tenant_id, reference, purpose, plan_id, amount, currency, status,
    provider_reference, environment)
  values (s.tenant_id, refs.issue('PAY'), 'auto_renewal', plan.id, plan.price, 'NGN', 'open',
    p_provider_reference, p_environment)
  returning * into payment;
  return billing.apply_payment(payment.id, p_amount_kobo::numeric / 100, upper(p_currency), p_paid_at,
    p_transaction_id, nullif(p_customer_code, ''), p_reusable);
end;
$$;

-- Webhook deduplication: a processed event is a duplicate; one that failed
-- part-way is processed again (every step is idempotent).
create function api.billing_record_event(p_dedupe_key text, p_event text, p_body_sha256 text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  e billing.provider_events;
begin
  insert into billing.provider_events (dedupe_key, event, body_sha256)
  values (p_dedupe_key, p_event, p_body_sha256)
  on conflict (dedupe_key) do nothing;
  select * into e from billing.provider_events where dedupe_key = p_dedupe_key;
  return jsonb_build_object('eventId', e.id, 'duplicate', e.processed_at is not null);
end;
$$;

create function api.billing_event_done(p_event_id bigint, p_outcome text, p_tenant_id uuid default null,
  p_payment_id uuid default null)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  update billing.provider_events
  set outcome = p_outcome, tenant_id = p_tenant_id, payment_id = p_payment_id, processed_at = now()
  where id = p_event_id and processed_at is null;
  select jsonb_build_object('eventId', p_event_id);
$$;

-- subscription.create / disable / not_renew. Events for a subscription the
-- sync worker is replacing are ignored (it disables the old one itself).
create function api.billing_provider_subscription(
  p_event text,
  p_subscription_code text,
  p_email_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s billing.subscriptions;
begin
  select * into s from billing.subscriptions where provider_subscription_code = p_subscription_code for update;
  if s.tenant_id is null then
    return jsonb_build_object('outcome', 'unmatched');
  end if;
  if p_event = 'subscription.create' then
    if s.provider_email_token is null and p_email_token ~ '^[A-Za-z0-9_-]{1,100}$' then
      update billing.subscriptions set provider_email_token = p_email_token, updated_at = now()
      where tenant_id = s.tenant_id;
    end if;
    return jsonb_build_object('outcome', 'recorded', 'tenantId', s.tenant_id);
  end if;
  if p_event in ('subscription.disable', 'subscription.not_renew') then
    if s.sync_state <> 'none' then
      return jsonb_build_object('outcome', 'ignored_syncing', 'tenantId', s.tenant_id);
    end if;
    update billing.subscriptions
    set auto_renew = false,
        provider_subscription_code = case when p_event = 'subscription.disable' then null
                                          else provider_subscription_code end,
        provider_email_token = case when p_event = 'subscription.disable' then null else provider_email_token end,
        updated_at = now()
    where tenant_id = s.tenant_id;
    insert into billing.periods (tenant_id, kind, plan_id) values (s.tenant_id, 'auto_renew', s.plan_id);
    perform audit.record_tenant(s.tenant_id, null, 'subscription.auto_renew_changed', 'subscription',
      s.tenant_id::text, p_safe_after => jsonb_build_object('autoRenew', false, 'source', 'paystack'));
    return jsonb_build_object('outcome', 'auto_renew_off', 'tenantId', s.tenant_id);
  end if;
  return jsonb_build_object('outcome', 'ignored');
end;
$$;

-- ── Paystack subscription sync (worker, service only) ─────────────────────

create function api.billing_plan_codes(p_environment text)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('planId', p.id, 'key', p.key, 'name', p.name,
    'amountKobo', (p.price * 100)::bigint, 'planCode', pp.plan_code) order by p.rank), '[]'::jsonb)
  from billing.plans p
  left join billing.provider_plans pp on pp.plan_id = p.id and pp.environment = p_environment
  where p.launch;
$$;

create function api.billing_set_plan_code(p_plan_id uuid, p_environment text, p_plan_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into billing.provider_plans (plan_id, environment, plan_code)
  values (p_plan_id, p_environment, p_plan_code)
  on conflict (plan_id, environment) do nothing;
  return jsonb_build_object('planCode',
    (select plan_code from billing.provider_plans where plan_id = p_plan_id and environment = p_environment));
end;
$$;

create function api.billing_sync_claim(p_limit int default 10)
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
    'renew', l.kind = 'paid' and l.status = 'active' and l.auto_renew and l.reusable_card
             and l.provider_customer_code is not null and l.period_end is not null,
    'planId', coalesce(l.next_plan_id, l.plan_id),
    'startDate', l.period_end - billing.renewal_lead(),
    'customerCode', l.provider_customer_code,
    'subscriptionCode', l.provider_subscription_code,
    'emailToken', l.provider_email_token
  )), '[]'::jsonb) into claimed
  from leased l;
  return claimed;
end;
$$;

create function api.billing_sync_done(
  p_tenant_id uuid,
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
begin
  if p_outcome is null or p_outcome not in ('ok', 'failed', 'no_card') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'outcome'));
  end if;
  select * into s from billing.subscriptions where tenant_id = p_tenant_id for update;
  if s.tenant_id is null then
    perform identity.fail('not_found');
  end if;
  if p_outcome = 'ok' then
    update billing.subscriptions
    set provider_subscription_code = p_subscription_code, provider_email_token = p_email_token,
        provider_plan_code = p_plan_code, sync_state = 'none', sync_attempts = 0, sync_after = null,
        sync_lease_until = null, updated_at = now()
    where tenant_id = p_tenant_id;
  elsif p_outcome = 'no_card' then
    update billing.subscriptions
    set reusable_card = false, provider_subscription_code = null, provider_email_token = null,
        provider_plan_code = null, sync_state = 'none', sync_attempts = 0, sync_after = null,
        sync_lease_until = null, updated_at = now()
    where tenant_id = p_tenant_id;
  else
    update billing.subscriptions
    set sync_state = case when s.sync_attempts >= 6 then 'failed' else 'pending' end,
        sync_after = now() + make_interval(mins => 5 * greatest(1, s.sync_attempts)),
        sync_lease_until = null, updated_at = now()
    where tenant_id = p_tenant_id;
  end if;
  return jsonb_build_object('tenantId', p_tenant_id, 'outcome', p_outcome);
end;
$$;

-- ── Commands ──────────────────────────────────────────────────────────────

create function api.billing_set_auto_renew(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_enabled boolean,
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
  request jsonb;
  replayed jsonb;
  s billing.subscriptions;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform billing.require_actor(p_user_id, workspace, true);
  if p_enabled is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'enabled'));
  end if;
  request := jsonb_build_object('membershipId', workspace.id, 'enabled', p_enabled);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'billing_set_auto_renew', request);
  if replayed is not null then
    return replayed;
  end if;
  s := billing.subscription(workspace.tenant_id, true);
  if s.kind <> 'paid' or s.status not in ('active', 'paused') then
    perform identity.fail('conflict', jsonb_build_object('reason', 'not_paid_plan'));
  end if;
  if s.auto_renew <> p_enabled then
    update billing.subscriptions set auto_renew = p_enabled, updated_at = now() where tenant_id = s.tenant_id;
    insert into billing.periods (tenant_id, kind, plan_id, actor_user_id)
    values (s.tenant_id, 'auto_renew', s.plan_id, p_user_id);
    perform audit.record_tenant(s.tenant_id, p_user_id, 'subscription.auto_renew_changed', 'subscription',
      s.tenant_id::text, p_safe_before => jsonb_build_object('autoRenew', s.auto_renew),
      p_safe_after => jsonb_build_object('autoRenew', p_enabled), p_request_id => p_request_id);
    perform billing.mark_sync(s.tenant_id);
  end if;
  return identity.store_result(p_user_id, p_idempotency_key, 'billing_set_auto_renew', request,
    jsonb_build_object('autoRenew', p_enabled));
end;
$$;

-- Next year's band (PL09d): a smaller band the current seats fit, or null to
-- keep the current one. Upgrades go through checkout instead.
create function api.billing_set_next_plan(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_plan_key text,
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
  request jsonb;
  replayed jsonb;
  s billing.subscriptions;
  plan billing.plans;
  current_plan billing.plans;
  used int;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform billing.require_actor(p_user_id, workspace, true);
  if p_plan_key is not null then
    plan := billing.plan(p_plan_key);
  end if;
  request := jsonb_build_object('membershipId', workspace.id, 'planKey', plan.key);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'billing_set_next_plan', request);
  if replayed is not null then
    return replayed;
  end if;
  s := billing.subscription(workspace.tenant_id, true);
  current_plan := billing.plan_by_id(s.plan_id);
  if s.kind <> 'paid' or s.status <> 'active' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'not_paid_plan'));
  end if;
  if s.plan_change_at is not null then
    perform identity.fail('conflict', jsonb_build_object('reason', 'next_year_paid'));
  end if;
  if plan.id is not null and plan.id <> current_plan.id then
    if plan.rank >= current_plan.rank then
      perform identity.fail('conflict', jsonb_build_object('reason', 'use_upgrade'));
    end if;
    used := billing.seats_used(s.tenant_id);
    if plan.seat_cap is not null and used > plan.seat_cap then
      perform identity.fail('conflict', jsonb_build_object('reason', 'seats_exceed_plan', 'used', used,
        'cap', plan.seat_cap));
    end if;
  end if;
  update billing.subscriptions
  set next_plan_id = case when plan.id is null or plan.id = current_plan.id then null else plan.id end,
      updated_at = now()
  where tenant_id = s.tenant_id;
  insert into billing.periods (tenant_id, kind, plan_id, actor_user_id)
  values (s.tenant_id, 'next_plan', coalesce(plan.id, current_plan.id), p_user_id);
  perform audit.record_tenant(s.tenant_id, p_user_id, 'subscription.next_plan_changed', 'subscription',
    s.tenant_id::text, p_safe_after => jsonb_build_object('nextPlan', coalesce(plan.key, current_plan.key)),
    p_request_id => p_request_id);
  perform billing.mark_sync(s.tenant_id);
  return identity.store_result(p_user_id, p_idempotency_key, 'billing_set_next_plan', request,
    jsonb_build_object('nextPlan', billing.plan_json(case when plan.id = current_plan.id then null else plan end)));
end;
$$;

-- W-19: one current Billing Owner; changing it needs manage_subscription and
-- a fresh step-up (PIN), targets an active member, is serialized on the
-- subscription row and keeps history and audit. The new owner gets B03.
create function api.change_billing_owner(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_target_membership_id uuid,
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
  request jsonb;
  replayed jsonb;
  previous billing.owners;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform billing.require_actor(p_user_id, workspace, true);
  request := jsonb_build_object('membershipId', workspace.id, 'targetMembershipId', p_target_membership_id);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'change_billing_owner', request);
  if replayed is not null then
    return replayed;
  end if;

  perform billing.subscription(workspace.tenant_id, true);
  select m.* into target from org.memberships m
  join identity.accounts a on a.user_id = m.user_id
  where m.id = p_target_membership_id and m.tenant_id = workspace.tenant_id and m.status = 'active'
    and a.status = 'active';
  if target.id is null then
    perform identity.fail('not_found');
  end if;
  select * into previous from billing.owners where tenant_id = workspace.tenant_id and ended_at is null;
  if previous.user_id = target.user_id then
    perform identity.fail('conflict', jsonb_build_object('reason', 'already_owner'));
  end if;

  update billing.owners set ended_at = now(), ended_by = p_user_id where id = previous.id;
  insert into billing.owners (tenant_id, user_id, membership_id, assigned_by)
  values (workspace.tenant_id, target.user_id, target.id, p_user_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'billing.owner_changed', 'billing_owner',
    target.id::text, p_safe_before => jsonb_build_object('owner', org.person(previous.user_id)->>'uid'),
    p_safe_after => jsonb_build_object('owner', org.person(target.user_id)->>'uid'), p_request_id => p_request_id);
  perform notify.emit(target.user_id, workspace.tenant_id, 'billing.owner_assigned', 'billing_owner', target.id,
    jsonb_build_object('network', notify.network(workspace.tenant_id), 'path', '/app/billing'),
    'owner:' || target.id::text || ':' || now()::text,
    jsonb_build_object('network', notify.network(workspace.tenant_id), 'path', '/app/billing'));

  return identity.store_result(p_user_id, p_idempotency_key, 'change_billing_owner', request,
    jsonb_build_object('owner', billing.owner_json(workspace.tenant_id)));
end;
$$;

revoke all on all functions in schema billing from public, anon, authenticated;

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
