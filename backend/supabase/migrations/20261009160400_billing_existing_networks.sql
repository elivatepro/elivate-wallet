-- Blueprint 16 — owner answer Q1 (2026-10-09): networks that existed before
-- billing get a subscription row. Active networks are grandfathered as the
-- W-19 development scope exception (active, no end date, no seat cap, no
-- trial used), each with a period row and a tenant audit row; networks still
-- awaiting payment follow the new rules. The founder becomes Billing Owner.
-- Only tenant ids, statuses, founders and membership ids are read; no
-- existing row is changed and no user or financial data is touched.

insert into billing.subscriptions (tenant_id, status, kind, plan_id, period_start)
select t.id, 'active', 'development', (billing.plan('band_1001_plus')).id, coalesce(t.activated_at, t.created_at)
from org.tenants t
where t.status = 'active'
  and not exists (select 1 from billing.subscriptions s where s.tenant_id = t.id);

insert into billing.subscriptions (tenant_id, status, kind, plan_id)
select t.id, 'pending', 'paid', (billing.plan('band_400')).id
from org.tenants t
where t.status = 'pending_payment'
  and not exists (select 1 from billing.subscriptions s where s.tenant_id = t.id);

insert into billing.periods (tenant_id, kind, plan_id, starts_at, reason)
select s.tenant_id, 'development', s.plan_id, s.period_start, 'Existing network before billing (owner answer Q1)'
from billing.subscriptions s
where s.kind = 'development'
  and not exists (select 1 from billing.periods p where p.tenant_id = s.tenant_id);

insert into billing.owners (tenant_id, user_id, membership_id, assigned_by, assigned_at)
select t.id, t.created_by,
  (select m.id from org.memberships m
   where m.tenant_id = t.id and m.user_id = t.created_by and m.status = 'active'
   order by m.is_primary desc, m.started_at limit 1),
  null, now()
from org.tenants t
join billing.subscriptions s on s.tenant_id = t.id
where not exists (select 1 from billing.owners o where o.tenant_id = t.id and o.ended_at is null);

insert into audit.tenant_events (tenant_id, actor_user_id, action, target_type, target_id, reason, safe_after)
select s.tenant_id, null, 'subscription.grandfathered', 'subscription', s.tenant_id::text,
  'Existing network before billing (owner answer Q1)',
  jsonb_build_object('status', s.status, 'kind', s.kind)
from billing.subscriptions s
where s.kind = 'development';
