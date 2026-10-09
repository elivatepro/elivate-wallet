-- Blueprint 16 — B2: billing rules. Seats (fills org.check_seat_capacity),
-- the paused-network gate (reads stay, writes refused), applying verified
-- payments, the expiry/reminder lifecycle, founder start with the trial and
-- the platform-admin support activation.

alter table billing.subscriptions add column plan_change_at timestamptz;
alter table billing.subscriptions alter column auto_renew set default true;

-- ── Helpers ───────────────────────────────────────────────────────────────

create function billing.subscription(p_tenant_id uuid, p_lock boolean default false)
returns billing.subscriptions
language plpgsql
set search_path = ''
as $$
declare
  s billing.subscriptions;
begin
  if p_lock then
    select * into s from billing.subscriptions where tenant_id = p_tenant_id for update;
  else
    select * into s from billing.subscriptions where tenant_id = p_tenant_id;
  end if;
  if s.tenant_id is null then
    perform identity.fail('not_found');
  end if;
  return s;
end;
$$;

create function billing.plan_by_id(p_plan_id uuid)
returns billing.plans
language sql
stable
set search_path = ''
as $$
  select * from billing.plans where id = p_plan_id;
$$;

create function billing.money(p_amount numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  select round(p_amount, 2)::text;
$$;

-- "12 Jan 2027", the WAT calendar date.
create function billing.day_label(p_at timestamptz)
returns text
language sql
stable
set search_path = ''
as $$
  select to_char((p_at at time zone billing.zone())::date, 'FMDD Mon YYYY');
$$;

-- The last paid day (WAT) of a period that ends at p_end (exclusive).
create function billing.last_day(p_end timestamptz)
returns date
language sql
stable
set search_path = ''
as $$
  select ((p_end - interval '1 microsecond') at time zone billing.zone())::date;
$$;

-- D-10: distinct people with an active or suspended membership.
create function billing.seats_used(p_tenant_id uuid)
returns int
language sql
stable
set search_path = ''
as $$
  select count(distinct user_id)::int from org.memberships
  where tenant_id = p_tenant_id and status in ('active', 'suspended');
$$;

create function billing.counted(p_tenant_id uuid, p_user_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from org.memberships
                 where tenant_id = p_tenant_id and user_id = p_user_id and status in ('active', 'suspended'));
$$;

-- The cap that applies now; null = no cap (development, 1,001+).
create function billing.seat_cap(p_s billing.subscriptions)
returns int
language sql
stable
set search_path = ''
as $$
  select case when p_s.kind = 'development' then null
              else (select seat_cap from billing.plans where id = p_s.plan_id) end;
$$;

-- Proration (owner decision 2026-10-09): price difference × days left in the
-- paid year ÷ 365, half-up to the kobo. Days run from today to the last paid
-- day, in WAT (Paper PL05: 9 Oct 2026 → 13 Mar 2027 = 155 days).
create function billing.days_left(p_period_end timestamptz)
returns int
language sql
stable
set search_path = ''
as $$
  select greatest(0, billing.last_day(p_period_end) - billing.today());
$$;

create function billing.prorate(p_from_price numeric, p_to_price numeric, p_days_left int)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select round((p_to_price - p_from_price) * p_days_left / 365.0, 2);
$$;

-- Who hears about billing (owner answer Q7): the Billing Owner and every
-- active President Team member.
create function billing.recipients(p_tenant_id uuid)
returns setof uuid
language sql
stable
set search_path = ''
as $$
  select o.user_id from billing.owners o
  join identity.accounts a on a.user_id = o.user_id
  where o.tenant_id = p_tenant_id and o.ended_at is null and a.status = 'active'
  union
  select m.user_id from org.memberships m
  join identity.accounts a on a.user_id = m.user_id
  where m.tenant_id = p_tenant_id and m.status = 'active' and m.role = 'president_team_member'
    and a.status = 'active';
$$;

create function billing.notify(
  p_tenant_id uuid,
  p_kind text,
  p_subject_type text,
  p_subject_id uuid,
  p_params jsonb,
  p_dedupe text
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  recipient uuid;
begin
  for recipient in select * from billing.recipients(p_tenant_id) loop
    perform notify.emit(recipient, p_tenant_id, p_kind, p_subject_type, p_subject_id, p_params, p_dedupe, p_params);
  end loop;
end;
$$;

-- Keeps org.tenants.status in step with the subscription. pending → active
-- fires the allocation seed (Blueprint 04).
create function billing.set_tenant_status(
  p_tenant_id uuid,
  p_status org.tenant_status,
  p_source text,
  p_actor_user_id uuid
)
returns void
language plpgsql
set search_path = ''
as $$
begin
  update org.tenants
  set status = p_status,
      activated_at = coalesce(activated_at, now()),
      activated_by = case when activated_at is null then p_actor_user_id else activated_by end,
      activation_source = coalesce(activation_source, p_source)
  where id = p_tenant_id and status is distinct from p_status;
end;
$$;

-- The caller may see and pay for billing: manage_subscription (A-03) or the
-- current Billing Owner (owner answer Q7). Returns whether they may manage.
create function billing.require_actor(p_user_id uuid, p_workspace org.memberships, p_manage boolean)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  can_manage boolean;
  tenant_status org.tenant_status;
begin
  select status into tenant_status from org.tenants where id = p_workspace.tenant_id;
  if tenant_status = 'deactivated' then
    perform identity.fail('network_not_active');
  end if;
  can_manage := coalesce((authz.decide(p_user_id, 'manage_subscription', p_workspace.tenant_id, null, null,
    p_workspace.id)->>'allowed')::boolean, false);
  if p_manage and not can_manage then
    perform identity.fail('authorization_denied');
  end if;
  if not can_manage and not exists (
    select 1 from billing.owners
    where tenant_id = p_workspace.tenant_id and user_id = p_user_id and ended_at is null
  ) then
    perform identity.fail('authorization_denied');
  end if;
  return can_manage;
end;
$$;

-- Withdrawals approved before the pause may still be paid out and reviewed.
create function billing.approved_before_pause(p_tenant_id uuid, p_approved_at timestamptz)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_approved_at is not null and exists (
    select 1 from billing.subscriptions s
    where s.tenant_id = p_tenant_id and s.status = 'paused' and p_approved_at < s.paused_at
  );
$$;

-- ── Seats (D-10, fills the Blueprint 03 hook) ─────────────────────────────

-- Called by org.create_membership after the person lock and before the
-- insert. Serialized per tenant with an advisory lock (never a row lock), so
-- concurrent acceptances can't over-activate.
create or replace function org.check_seat_capacity(p_tenant_id uuid, p_user_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  s billing.subscriptions;
  cap int;
  used int;
begin
  perform pg_advisory_xact_lock(hashtextextended('billing.seats:' || p_tenant_id::text, 0));
  if billing.counted(p_tenant_id, p_user_id) then
    return;
  end if;
  select * into s from billing.subscriptions where tenant_id = p_tenant_id;
  if s.tenant_id is null then
    return;
  end if;
  cap := billing.seat_cap(s);
  if cap is null then
    return;
  end if;
  used := billing.seats_used(p_tenant_id);
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

-- At the cap, new invitations are refused too (owner answer Q8), unless the
-- invited email already holds a counted membership (no new seat).
create function billing.check_invitation_seat()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  s billing.subscriptions;
  cap int;
begin
  if exists (
    select 1 from auth.users u join org.memberships m on m.user_id = u.id
    where lower(btrim(u.email)) = new.email and m.tenant_id = new.tenant_id and m.status in ('active', 'suspended')
  ) then
    return new;
  end if;
  select * into s from billing.subscriptions where tenant_id = new.tenant_id;
  cap := billing.seat_cap(s);
  if s.tenant_id is not null and cap is not null and billing.seats_used(new.tenant_id) >= cap then
    perform identity.fail('conflict', jsonb_build_object('reason', 'seat_limit_reached',
      'used', billing.seats_used(new.tenant_id), 'cap', cap));
  end if;
  return new;
end;
$$;

create trigger invitations_seat_check
before insert on org.invitations
for each row execute function billing.check_invitation_seat();

-- ── Paused network gate (owner answers Q10, 2026-10-09) ───────────────────

-- Reads of a paused network still work; organizational writes don't.
create function org.require_readable_tenant(p_tenant_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if (select status from org.tenants where id = p_tenant_id) not in ('active', 'suspended') then
    perform identity.fail('network_not_active');
  end if;
end;
$$;

-- Permissions that still act on a paused network: own-money reads and
-- statements, reports, personal payout accounts, and paying.
create function authz.paused_allows(p_permission_key text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_permission_key in (
    'view_own_wallet', 'view_own_financials', 'export_own_statement', 'manage_own_payout_accounts',
    'view_managed_wallets', 'view_scoped_financial_reports', 'export_scoped_reports', 'manage_subscription'
  );
$$;

drop function authz.require(uuid, text, uuid, uuid, uuid, uuid);

-- Raises the matching contract error when the resolver denies. Writes on a
-- paused network are refused unless the permission is a paused read or the
-- caller passes p_allow_paused (payouts approved before the pause).
create function authz.require(
  p_actor_user_id uuid,
  p_permission_key text,
  p_tenant_id uuid,
  p_target_office_id uuid default null,
  p_target_user_id uuid default null,
  p_workspace_membership_id uuid default null,
  p_allow_paused boolean default false
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  decision jsonb;
begin
  decision := authz.decide(p_actor_user_id, p_permission_key, p_tenant_id,
    p_target_office_id, p_target_user_id, p_workspace_membership_id);
  if (decision->>'allowed')::boolean then
    if not p_allow_paused and not authz.paused_allows(p_permission_key)
       and (select status from org.tenants where id = p_tenant_id) = 'suspended' then
      perform identity.fail('network_not_active');
    end if;
    return;
  end if;
  case decision->>'reason'
    when 'network_not_active' then perform identity.fail('network_not_active');
    when 'not_found' then perform identity.fail('not_found');
    when 'self_target' then perform identity.fail('self_target_forbidden');
    else perform identity.fail('authorization_denied');
  end case;
end;
$$;

revoke all on function authz.require(uuid, text, uuid, uuid, uuid, uuid, boolean) from public, anon, authenticated;

create or replace function finance.require_approver(p_user_id uuid, p_workspace org.memberships, p_w finance.withdrawals)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform authz.require(p_user_id, 'approve_withdrawal', p_w.tenant_id, p_w.office_id, p_w.owner_user_id,
    p_workspace.id, p_allow_paused => billing.approved_before_pause(p_w.tenant_id, p_w.approved_at));
end;
$$;

create or replace function finance.require_reviewer(p_user_id uuid, p_workspace org.memberships, p_w finance.withdrawals,
  p_payout finance.payouts)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform authz.require(p_user_id, 'review_financial_evidence', p_w.tenant_id, p_w.office_id, p_w.owner_user_id,
    p_workspace.id, p_allow_paused => billing.approved_before_pause(p_w.tenant_id, p_w.approved_at));
  if p_payout.submitted_by = p_user_id
    or exists (select 1 from finance.payout_revisions r where r.payout_id = p_payout.id and r.submitted_by = p_user_id) then
    perform identity.fail('self_target_forbidden');
  end if;
end;
$$;


-- ── Copies with the paused-network change (latest bodies, edited) ─────────

create or replace function authz.decide(
  p_actor_user_id uuid,
  p_permission_key text,
  p_tenant_id uuid,
  p_target_office_id uuid default null,
  p_target_user_id uuid default null,
  p_workspace_membership_id uuid default null
)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  permission authz.permission_catalog;
  tenant_status org.tenant_status;
  explicit_effect text;
begin
  select * into permission from authz.permission_catalog where key = p_permission_key;
  if permission.key is null then
    return jsonb_build_object('allowed', false, 'reason', 'unknown_permission');
  end if;

  select status into tenant_status from org.tenants where id = p_tenant_id;
  if tenant_status is null then
    return jsonb_build_object('allowed', false, 'reason', 'not_found');
  end if;
  -- Blueprint 16: a paused (suspended) network keeps its reads; writes are
  -- refused in authz.require. A network awaiting payment lets only
  -- manage_subscription through, so it can be paid for.
  if tenant_status = 'deactivated'
     or (tenant_status = 'pending_payment' and permission.key <> 'manage_subscription') then
    return jsonb_build_object('allowed', false, 'reason', 'network_not_active');
  end if;

  if p_target_office_id is not null and not exists (
    select 1 from org.offices where id = p_target_office_id and tenant_id = p_tenant_id and status = 'active'
  ) then
    return jsonb_build_object('allowed', false, 'reason', 'not_found');
  end if;

  -- The actor must belong to the network.
  if not exists (
    select 1 from org.memberships
    where tenant_id = p_tenant_id and user_id = p_actor_user_id and status = 'active'
  ) then
    return jsonb_build_object('allowed', false, 'reason', 'no_membership');
  end if;

  -- Self-service rows: the owner only.
  if permission.scope = 'self' then
    if p_target_user_id is distinct from p_actor_user_id then
      return jsonb_build_object('allowed', false, 'reason', 'self_only');
    end if;
    if exists (
      select 1 from org.memberships m
      join authz.role_permissions rp
        on rp.tenant_id = m.tenant_id and rp.role = m.role and rp.permission_key = permission.key
      where m.tenant_id = p_tenant_id and m.user_id = p_actor_user_id and m.status = 'active' and rp.allowed
        and (p_workspace_membership_id is null or m.id = p_workspace_membership_id)
    ) then
      return jsonb_build_object('allowed', true, 'reason', 'ok', 'source', 'role_policy');
    end if;
    return jsonb_build_object('allowed', false, 'reason', 'default_deny');
  end if;

  -- Leadership permissions never target the actor (A-04 self-target guard).
  if p_target_user_id = p_actor_user_id and not permission.can_target_own_wallet then
    return jsonb_build_object('allowed', false, 'reason', 'self_target');
  end if;

  -- Evidence review comes only from a current reviewer assignment.
  if permission.scope = 'assignment' then
    if exists (
      select 1 from authz.reviewer_assignments ra
      join org.memberships m on m.id = ra.membership_id
      where ra.tenant_id = p_tenant_id and ra.ended_at is null
        and m.user_id = p_actor_user_id and m.status = 'active'
        and (p_workspace_membership_id is null or m.id = p_workspace_membership_id)
        -- Within the reviewer's own scope; President Team reviewers cover the network.
        and (m.office_id is null
             or authz.office_covers(m.office_id, p_tenant_id, p_target_office_id, p_target_user_id))
    ) then
      return jsonb_build_object('allowed', true, 'reason', 'ok', 'source', 'reviewer_assignment');
    end if;
    return jsonb_build_object('allowed', false, 'reason', 'default_deny');
  end if;

  -- Explicit rules: deny beats grant.
  select case when bool_or(r.effect = 'deny') then 'deny' when bool_or(r.effect = 'allow') then 'allow' end
  into explicit_effect
  from authz.access_rules r
  join authz.access_assignments a on a.id = r.assignment_id
  where r.tenant_id = p_tenant_id
    and r.subject_user_id = p_actor_user_id
    and r.permission_key = permission.key
    and r.revoked_at is null and a.revoked_at is null
    and r.starts_at <= now()
    and (r.expires_at is null or r.expires_at > now())
    and authz.rule_covers(r, p_target_office_id, p_target_user_id);

  if explicit_effect = 'deny' then
    return jsonb_build_object('allowed', false, 'reason', 'explicit_deny', 'source', 'explicit_deny');
  end if;
  if explicit_effect = 'allow' then
    return jsonb_build_object('allowed', true, 'reason', 'ok', 'source', 'explicit_grant');
  end if;

  -- Exact-role policy over the memberships that cover the target.
  if exists (
    select 1 from org.memberships m
    join authz.role_permissions rp
      on rp.tenant_id = m.tenant_id and rp.role = m.role and rp.permission_key = permission.key
    left join org.offices o on o.id = m.office_id
    where m.tenant_id = p_tenant_id and m.user_id = p_actor_user_id and m.status = 'active'
      and rp.allowed
      and (p_workspace_membership_id is null or m.id = p_workspace_membership_id)
      and (m.office_id is null or o.status = 'active')
      and (
        m.office_id is null                    -- President Team: the whole tenant
        or (permission.scope = 'office'
            and authz.office_covers(m.office_id, p_tenant_id, p_target_office_id, p_target_user_id))
        or (permission.scope = 'tenant')       -- tenant-scoped rows enabled for another role
      )
  ) then
    return jsonb_build_object('allowed', true, 'reason', 'ok', 'source', 'role_policy');
  end if;

  return jsonb_build_object('allowed', false, 'reason', 'default_deny');
end;
$$;

create or replace function org.change_workspace(p_user_id uuid, p_membership_id uuid)
returns org.memberships
language plpgsql
set search_path = ''
as $$
declare
  workspace org.memberships;
begin
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform org.require_readable_tenant(workspace.tenant_id);
  return workspace;
end;
$$;

create or replace function api.list_offices(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_type text default null,
  p_query text default null,
  p_status text default null,
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
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform org.require_readable_tenant(workspace.tenant_id);
  if p_type is not null and p_type not in ('world_team', 'director', 'team_leader') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'type'));
  end if;
  if p_status is not null and p_status not in ('active', 'closed') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'status'));
  end if;
  if p_query is not null and length(p_query) > 100 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'q'));
  end if;
  page_size := org.page_limit(p_limit);
  after := org.decode_cursor(p_cursor);

  select coalesce(jsonb_agg(item order by item->>'name', item->>'id'), '[]'::jsonb) into rows
  from (
    select jsonb_build_object(
      'id', o.id,
      'name', o.name,
      'type', o.office_type,
      'status', o.status,
      'parentOfficeId', o.parent_office_id,
      'leaderCount', (select count(*) from org.memberships l
                      where l.office_id = o.id and l.role = org.leader_role(o.office_type) and l.status = 'active'),
      'memberCount', (select count(distinct l.user_id) from org.office_closure c
                      join org.memberships l on l.office_id = c.descendant_id
                      where c.ancestor_id = o.id and l.status = 'active'),
      'childCount', (select count(*) from org.offices ch where ch.parent_office_id = o.id and ch.status = 'active'),
      'leaders', (select coalesce(jsonb_agg(x.p order by x.started_at, x.id), '[]'::jsonb) from (
                    select org.person(l.user_id) as p, l.started_at, l.id from org.memberships l
                    where l.office_id = o.id and l.role = org.leader_role(o.office_type) and l.status = 'active'
                    order by l.started_at, l.id limit 3) x)
    ) as item
    from org.offices o
    where o.tenant_id = workspace.tenant_id
      and org.office_visible(workspace, o.id)
      and (p_type is null or o.office_type = p_type::org.office_type)
      and (p_status is null or o.status = p_status::org.office_status)
      and (p_query is null or o.name ilike '%' || replace(replace(replace(p_query, '\', '\\'), '%', '\%'), '_', '\_') || '%')
      and (after is null or (o.name, o.id::text) > (after->>'name', after->>'id'))
    order by o.name, o.id
    limit page_size + 1
  ) page;

  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(e) from jsonb_array_elements(rows) with ordinality as x (e, n) where n <= page_size), '[]'::jsonb),
    'nextCursor', case when jsonb_array_length(rows) > page_size
      then org.encode_cursor(jsonb_build_object('name', rows->(page_size - 1)->>'name', 'id', rows->(page_size - 1)->>'id'))
    end
  );
end;
$$;

create or replace function api.my_capabilities(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  tenant_status org.tenant_status;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  select status into tenant_status from org.tenants where id = workspace.tenant_id;

  return jsonb_build_object(
    'membershipId', workspace.id,
    'tenantStatus', tenant_status,
    'billingOwner', exists (select 1 from billing.owners o
                            where o.tenant_id = workspace.tenant_id and o.user_id = p_user_id and o.ended_at is null),
    'permissions', coalesce((
      select jsonb_agg(c.key order by c.key)
      from authz.permission_catalog c
      where (authz.decide(
          p_user_id, c.key, workspace.tenant_id,
          case when c.scope = 'office' then workspace.office_id end,
          case when c.scope = 'self' then p_user_id end,
          workspace.id
        )->>'allowed')::boolean
        -- Held only for specific targets: the server still checks each action.
        or (c.scope in ('office', 'tenant') and exists (
          select 1 from authz.access_rules r
          join authz.access_assignments a on a.id = r.assignment_id
          where r.tenant_id = workspace.tenant_id and r.subject_user_id = p_user_id
            and r.permission_key = c.key and r.effect = 'allow'
            and r.revoked_at is null and a.revoked_at is null
            and r.starts_at <= now() and (r.expires_at is null or r.expires_at > now())
        ))
        or (c.scope = 'assignment' and tenant_status in ('active', 'suspended') and exists (
          select 1 from authz.reviewer_assignments ra
          where ra.membership_id = workspace.id and ra.ended_at is null
        ))
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function api.create_access_assignment(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_subject_uid text,
  p_rules jsonb,
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
  subject_user_id uuid;
  clean_reason text;
  request jsonb;
  replayed jsonb;
  rule jsonb;
  permission authz.permission_catalog;
  scope_type text;
  scope_office_id uuid;
  scope_user_id uuid;
  starts timestamptz;
  expires timestamptz;
  parsed jsonb := '[]'::jsonb;
  assignment_id uuid;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  perform org.require_active_tenant(workspace.tenant_id);
  subject_user_id := identity.account_by_uid(p_subject_uid);
  if subject_user_id = p_user_id then
    perform identity.fail('self_target_forbidden');
  end if;
  if not exists (
    select 1 from org.memberships
    where tenant_id = workspace.tenant_id and user_id = subject_user_id and status = 'active'
  ) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'subject_not_member'));
  end if;
  clean_reason := identity.require_reason(p_reason);
  if p_rules is null or jsonb_typeof(p_rules) <> 'array' or jsonb_array_length(p_rules) not between 1 and 50 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'rules'));
  end if;

  for rule in select value from jsonb_array_elements(p_rules) loop
    if jsonb_typeof(rule) <> 'object' then
      perform identity.fail('validation_error', jsonb_build_object('field', 'rules'));
    end if;
    select * into permission from authz.permission_catalog where key = rule->>'permission';
    if permission.key is null then
      perform identity.fail('validation_error', jsonb_build_object('field', 'rules.permission'));
    end if;
    if permission.protected or not permission.grantable or permission.scope = 'assignment' then
      perform identity.fail('permission_not_grantable', jsonb_build_object('permission', permission.key));
    end if;
    if rule->>'effect' is null or rule->>'effect' not in ('allow', 'deny') then
      perform identity.fail('validation_error', jsonb_build_object('field', 'rules.effect'));
    end if;

    scope_type := rule->>'scopeType';
    scope_office_id := null;
    scope_user_id := null;
    if scope_type = 'office_subtree' then
      begin
        scope_office_id := (rule->>'scopeOfficeId')::uuid;
      exception when others then
        perform identity.fail('validation_error', jsonb_build_object('field', 'rules.scopeOfficeId'));
      end;
      perform org.office_in_tenant(workspace.tenant_id, scope_office_id);
    elsif scope_type = 'member' then
      scope_user_id := identity.account_by_uid(rule->>'scopeUid');
      if not exists (
        select 1 from org.memberships
        where tenant_id = workspace.tenant_id and user_id = scope_user_id and status <> 'ended'
      ) then
        perform identity.fail('not_found');
      end if;
    elsif scope_type is distinct from 'tenant' then
      perform identity.fail('validation_error', jsonb_build_object('field', 'rules.scopeType'));
    end if;

    begin
      starts := coalesce((rule->>'startsAt')::timestamptz, now());
      expires := (rule->>'expiresAt')::timestamptz;
    exception when others then
      perform identity.fail('validation_error', jsonb_build_object('field', 'rules.expiresAt'));
    end;
    if expires is not null and (rule->>'effect' = 'deny' or expires <= greatest(starts, now())) then
      perform identity.fail('validation_error', jsonb_build_object('field', 'rules.expiresAt'));
    end if;

    if not authz.covers_scope(p_user_id, workspace.tenant_id, scope_type, scope_office_id, scope_user_id, workspace.id) then
      perform identity.fail('scope_exceeds_authority', jsonb_build_object('permission', permission.key));
    end if;

    parsed := parsed || jsonb_build_object(
      'permission', permission.key, 'effect', rule->>'effect', 'scopeType', scope_type,
      'scopeOfficeId', scope_office_id, 'scopeUserId', scope_user_id,
      'startsAt', rule->>'startsAt', 'expiresAt', rule->>'expiresAt');
  end loop;

  request := jsonb_build_object('tenantId', workspace.tenant_id, 'subjectUid', upper(btrim(p_subject_uid)),
    'rules', parsed, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'create_access_assignment', request);
  if replayed is not null then
    return replayed;
  end if;

  insert into authz.access_assignments (tenant_id, subject_user_id, created_by, reason)
  values (workspace.tenant_id, subject_user_id, p_user_id, clean_reason)
  returning id into assignment_id;

  insert into authz.access_rules (
    assignment_id, tenant_id, subject_user_id, permission_key, effect, scope_type,
    scope_office_id, scope_user_id, starts_at, expires_at
  )
  select assignment_id, workspace.tenant_id, subject_user_id, r->>'permission', r->>'effect', r->>'scopeType',
    (r->>'scopeOfficeId')::uuid, (r->>'scopeUserId')::uuid,
    coalesce((r->>'startsAt')::timestamptz, now()), (r->>'expiresAt')::timestamptz
  from jsonb_array_elements(parsed) r;

  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'access.assigned', 'access_assignment', assignment_id::text,
    clean_reason, p_safe_after => jsonb_build_object('rules', jsonb_array_length(parsed)), p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'create_access_assignment', request,
    jsonb_build_object('assignmentId', assignment_id));
end;
$$;

create or replace function api.revoke_access_assignment(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_assignment_id uuid,
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
  assignment authz.access_assignments;
  clean_reason text;
  request jsonb;
  replayed jsonb;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  perform org.require_active_tenant(workspace.tenant_id);
  select * into assignment from authz.access_assignments where id = p_assignment_id and tenant_id = workspace.tenant_id;
  if assignment.id is null then
    perform identity.fail('not_found');
  end if;
  if assignment.subject_user_id = p_user_id then
    perform identity.fail('self_target_forbidden');
  end if;
  -- Checked against the person revoking, not the original creator.
  if not authz.covers_assignment(p_user_id, assignment.id, workspace.id) then
    perform identity.fail('scope_exceeds_authority');
  end if;
  clean_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('assignmentId', assignment.id, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'revoke_access_assignment', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into assignment from authz.access_assignments where id = assignment.id for update;
  if assignment.revoked_at is not null then
    return identity.store_result(p_user_id, p_idempotency_key, 'revoke_access_assignment', request,
      jsonb_build_object('assignmentId', assignment.id, 'changed', false));
  end if;

  update authz.access_assignments
  set revoked_at = now(), revoked_by = p_user_id, revoke_reason = clean_reason
  where id = assignment.id;
  update authz.access_rules set revoked_at = now() where assignment_id = assignment.id and revoked_at is null;
  perform org.bump_authz_version(workspace.tenant_id);
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'access.revoked', 'access_assignment', assignment.id::text,
    clean_reason, p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'revoke_access_assignment', request,
    jsonb_build_object('assignmentId', assignment.id, 'changed', true));
end;
$$;

create or replace function payout.workspace(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_write boolean,
  p_step_up boolean
)
returns org.memberships
language plpgsql
set search_path = ''
as $$
declare
  workspace org.memberships;
begin
  if p_write then
    perform org.require_writer(p_user_id, p_session_id, p_step_up => p_step_up);
  else
    perform identity.require_session(p_user_id, p_session_id, p_step_up => p_step_up);
  end if;
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform authz.require(p_user_id, 'manage_own_payout_accounts', workspace.tenant_id, null, p_user_id, workspace.id);
  -- Blueprint 16: payout accounts stay readable on a paused network, not changeable.
  if p_write then
    perform org.require_active_tenant(workspace.tenant_id);
  end if;
  perform ledger.require_wallet(p_user_id);
  return workspace;
end;
$$;

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
    p_workspace.tenant_id, target.office_id, target.user_id, p_workspace.id,
    -- Blueprint 16: payout receipts for withdrawals approved before a pause.
    p_allow_paused => file.purpose = 'payout' and exists (
      select 1 from finance.withdrawals w
      where w.tenant_id = p_workspace.tenant_id and w.membership_id = file.target_membership_id
        and w.approved_by = p_user_id and w.status = 'approved'
        and billing.approved_before_pause(w.tenant_id, w.approved_at)));
  return file;
end;
$$;

-- ── Applying a verified payment ───────────────────────────────────────────

-- Marks the Paystack subscription as needing a sync (create, move or
-- disable) whenever what Paystack should do may have changed.
create function billing.mark_sync(p_tenant_id uuid)
returns void
language sql
set search_path = ''
as $$
  update billing.subscriptions
  set sync_state = 'pending', sync_after = now(), sync_attempts = 0, updated_at = now()
  where tenant_id = p_tenant_id and kind = 'paid'
    and (reusable_card or provider_subscription_code is not null);
$$;

-- A year bought on the subscription (start, renew, reactivate, auto-renewal):
-- the year starts at the end of the current trial or period, or at payment
-- when there is none or the network is paused (owner answers Q3, Q4).
create function billing.apply_year(
  p_s billing.subscriptions,
  p_payment billing.payments,
  p_paid_at timestamptz
)
returns billing.payments
language plpgsql
set search_path = ''
as $$
declare
  bought billing.plans := billing.plan_by_id(p_payment.plan_id);
  current_plan billing.plans := billing.plan_by_id(p_s.plan_id);
  start_at timestamptz;
  end_at timestamptz;
  immediate boolean;
  was billing.status := p_s.status;
begin
  if p_s.status in ('trial', 'active') and p_s.period_end is not null and p_s.period_end > p_paid_at then
    start_at := p_s.period_end;
  else
    start_at := p_paid_at;
  end if;
  end_at := start_at + interval '1 year';
  immediate := start_at = p_paid_at or p_s.status = 'trial';

  update billing.subscriptions
  set status = 'active',
      kind = 'paid',
      paused_at = null,
      period_start = case when immediate then start_at else period_start end,
      period_end = end_at,
      -- A bigger band (or any band during a trial or when starting fresh)
      -- applies now; a smaller one waits for the start of the new year.
      plan_id = case when immediate or bought.rank >= current_plan.rank then bought.id else plan_id end,
      next_plan_id = case when immediate or bought.rank >= current_plan.rank then null else bought.id end,
      plan_change_at = case when immediate or bought.rank >= current_plan.rank then null else start_at end,
      updated_at = now()
  where tenant_id = p_s.tenant_id;

  update billing.payments
  set applied = true, covers_from = start_at, covers_to = end_at, updated_at = now()
  where id = p_payment.id
  returning * into p_payment;

  insert into billing.periods (tenant_id, kind, plan_id, starts_at, ends_at, payment_id, actor_user_id)
  values (p_s.tenant_id, 'paid', bought.id, start_at, end_at, p_payment.id, p_payment.initiated_by);

  if was = 'pending' then
    perform billing.set_tenant_status(p_s.tenant_id, 'active', 'payment', p_payment.initiated_by);
  elsif was = 'paused' then
    perform billing.set_tenant_status(p_s.tenant_id, 'active', 'payment', p_payment.initiated_by);
    perform audit.record_tenant(p_s.tenant_id, p_payment.initiated_by, 'subscription.reactivated', 'subscription',
      p_s.tenant_id::text, p_safe_before => jsonb_build_object('status', 'paused'),
      p_safe_after => jsonb_build_object('status', 'active', 'reference', p_payment.reference));
  end if;
  return p_payment;
end;
$$;

-- Applies a payment whose facts were verified with Paystack server-side.
-- Exactly once: the row is locked and only a not-yet-paid payment moves to
-- paid. Amount and currency must equal the quote, or nothing activates.
create function billing.apply_payment(
  p_payment_id uuid,
  p_amount numeric,
  p_currency text,
  p_paid_at timestamptz,
  p_transaction_id bigint,
  p_customer_code text,
  p_reusable boolean
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  p billing.payments;
  s billing.subscriptions;
  current_plan billing.plans;
  target billing.plans;
  outcome text := 'applied';
begin
  select * into p from billing.payments where id = p_payment_id for update;
  if p.id is null then
    perform identity.fail('not_found');
  end if;
  if p.status = 'paid' then
    return jsonb_build_object('outcome', 'duplicate', 'paymentId', p.id, 'tenantId', p.tenant_id);
  end if;

  if p_currency is distinct from p.currency or p_amount is distinct from p.amount then
    update billing.payments
    set status = 'failed', needs_review = true, review_reason = 'amount_mismatch', updated_at = now()
    where id = p.id;
    perform audit.record_tenant(p.tenant_id, null, 'billing.payment_rejected', 'billing_payment', p.id::text,
      p_safe_after => jsonb_build_object('reference', p.reference, 'reason', 'amount_mismatch'));
    return jsonb_build_object('outcome', 'amount_mismatch', 'paymentId', p.id, 'tenantId', p.tenant_id);
  end if;

  s := billing.subscription(p.tenant_id, true);
  update billing.payments
  set status = 'paid', paid_at = p_paid_at, provider_transaction_id = p_transaction_id,
      authorization_url = null, updated_at = now()
  where id = p.id
  returning * into p;

  if p_customer_code is not null then
    update billing.subscriptions
    set provider_customer_code = p_customer_code,
        reusable_card = coalesce(p_reusable, false) or (reusable_card and provider_customer_code = p_customer_code),
        updated_at = now()
    where tenant_id = s.tenant_id
    returning * into s;
  end if;

  if p.purpose = 'upgrade' then
    current_plan := billing.plan_by_id(s.plan_id);
    target := billing.plan_by_id(p.plan_id);
    if s.status = 'active' and s.kind = 'paid' and s.plan_id = p.from_plan_id and s.period_end > p_paid_at
       and target.rank > current_plan.rank then
      update billing.subscriptions
      set plan_id = target.id, next_plan_id = null, plan_change_at = null, updated_at = now()
      where tenant_id = s.tenant_id;
      update billing.payments
      set applied = true, covers_from = p_paid_at, covers_to = s.period_end, updated_at = now()
      where id = p.id
      returning * into p;
      insert into billing.periods (tenant_id, kind, plan_id, starts_at, ends_at, payment_id, actor_user_id)
      values (s.tenant_id, 'upgrade', target.id, p_paid_at, s.period_end, p.id, p.initiated_by);
    else
      outcome := 'needs_review';
    end if;
  else
    -- Every other purpose buys a year of the paid band; a payment on the
    -- development exception (no end date) starts its year at payment.
    p := billing.apply_year(s, p, p_paid_at);
  end if;

  if outcome = 'needs_review' then
    update billing.payments set needs_review = true, review_reason = 'not_applicable', updated_at = now()
    where id = p.id
    returning * into p;
  end if;

  perform audit.record_tenant(p.tenant_id, p.initiated_by, 'billing.payment_received', 'billing_payment', p.id::text,
    p_safe_after => jsonb_build_object('reference', p.reference, 'amount', billing.money(p.amount),
      'currency', p.currency, 'purpose', p.purpose, 'applied', p.applied));
  perform billing.notify(p.tenant_id, 'billing.payment_received', 'billing_payment', p.id,
    jsonb_build_object('network', notify.network(p.tenant_id), 'amount', billing.money(p.amount),
      'currency', p.currency, 'reference', p.reference, 'path', '/app/billing/payments/' || p.id::text),
    'payment:' || p.id::text);
  perform billing.mark_sync(p.tenant_id);
  return jsonb_build_object('outcome', outcome, 'paymentId', p.id, 'tenantId', p.tenant_id);
end;
$$;

-- ── Lifecycle (pg_cron, every minute) ─────────────────────────────────────

create function billing.pause(p_tenant_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  s billing.subscriptions;
begin
  select * into s from billing.subscriptions where tenant_id = p_tenant_id for update;
  if s.status not in ('trial', 'active') or s.kind = 'development' or s.period_end > now() then
    return;
  end if;
  -- The exact instant: withdrawals approved before it can still be paid out.
  update billing.subscriptions
  set status = 'paused', paused_at = clock_timestamp(), updated_at = now()
  where tenant_id = p_tenant_id;
  perform billing.set_tenant_status(p_tenant_id, 'suspended', null, null);
  insert into billing.periods (tenant_id, kind, plan_id, starts_at)
  values (p_tenant_id, 'paused', s.plan_id, now());
  perform audit.record_tenant(p_tenant_id, null, 'subscription.paused', 'subscription', p_tenant_id::text,
    p_safe_before => jsonb_build_object('status', s.status, 'kind', s.kind),
    p_safe_after => jsonb_build_object('status', 'paused'));
  perform billing.notify(p_tenant_id, 'billing.paused', 'subscription', p_tenant_id,
    jsonb_build_object('network', notify.network(p_tenant_id), 'path', '/app/billing'),
    'paused:' || p_tenant_id::text || ':' || s.period_end::text);
end;
$$;

create function billing.run_lifecycle()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  s billing.subscriptions;
  paused int := 0;
  reminded int := 0;
  days int;
  amount numeric;
begin
  -- Expiry: no grace period (owner decision 2026-10-08).
  for s in
    select * from billing.subscriptions
    where status in ('trial', 'active') and kind <> 'development' and period_end <= now()
    order by period_end
    for update skip locked
  loop
    perform billing.pause(s.tenant_id);
    paused := paused + 1;
  end loop;

  -- A smaller band chosen for the next year starts with that year.
  update billing.subscriptions
  set plan_id = next_plan_id, next_plan_id = null, plan_change_at = null, updated_at = now()
  where plan_change_at is not null and plan_change_at <= now() and next_plan_id is not null;

  -- B02 reminders: 30, 7 and 1 days before a renewal; 3 and 1 before a trial
  -- ends (owner answer Q5). Deduplicated per period and day.
  for s in
    select * from billing.subscriptions
    where status in ('trial', 'active') and kind <> 'development' and period_end > now()
      and billing.last_day(period_end) - billing.today() + 1 in (1, 3, 7, 30)
  loop
    days := billing.last_day(s.period_end) - billing.today() + 1;
    if (s.status = 'trial' and days in (1, 3)) or (s.status = 'active' and days in (1, 7, 30)) then
      amount := (select price from billing.plans where id = coalesce(s.next_plan_id, s.plan_id));
      perform billing.notify(s.tenant_id, 'billing.renewal_reminder', 'subscription', s.tenant_id,
        jsonb_build_object('network', notify.network(s.tenant_id), 'amount', billing.money(amount),
          'currency', 'NGN', 'due', billing.day_label(s.period_end),
          'chip', case when s.status = 'trial' then 'Trial ends soon' else 'Renews soon' end,
          'path', '/app/billing'),
        'renewal:' || s.tenant_id::text || ':' || s.period_end::text || ':' || days::text);
      reminded := reminded + 1;
    end if;
  end loop;

  update billing.payments
  set status = 'abandoned', authorization_url = null, updated_at = now()
  where status = 'open' and created_at < now() - billing.checkout_lifetime();

  return jsonb_build_object('paused', paused, 'reminded', reminded);
end;
$$;

-- cron.schedule upserts by name, so replays never duplicate the job.
select cron.schedule('billing-lifecycle', '* * * * *', 'select billing.run_lifecycle()');

-- The Paystack sync worker (the `billing` function's /worker/sync), woken
-- like the outbox: Vault entries `billing_worker_url` and
-- `billing_worker_secret`; when either is missing the job does nothing.
create function billing.trigger_worker()
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  worker_url text;
  worker_secret text;
begin
  if not exists (select 1 from billing.subscriptions where sync_state = 'pending' and sync_after <= now()) then
    return null;
  end if;
  select decrypted_secret into worker_url from vault.decrypted_secrets where name = 'billing_worker_url';
  select decrypted_secret into worker_secret from vault.decrypted_secrets where name = 'billing_worker_secret';
  if coalesce(worker_url, '') = '' or coalesce(worker_secret, '') = '' then
    return null;
  end if;
  return net.http_post(
    url := worker_url,
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || worker_secret),
    timeout_milliseconds := 55000
  );
end;
$$;

select cron.schedule('billing-sync', '* * * * *', 'select billing.trigger_worker()');

-- ── Founder start (W-19, owner decisions 2026-10-08/09) ───────────────────

drop function api.start_network(uuid, uuid, text, text, text, text);

-- A founder's first network may run a 7-day trial on the smallest band; any
-- other start waits for payment. The founder is the first Billing Owner.
create function api.start_network(
  p_user_id uuid,
  p_session_id uuid,
  p_name text,
  p_short_name text,
  p_idempotency_key text,
  p_request_id text default null,
  p_plan_key text default 'band_400',
  p_trial boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  account_status identity.account_status;
  clean_name text;
  clean_short text;
  plan billing.plans;
  request jsonb;
  replayed jsonb;
  tenant_id uuid;
  president org.memberships;
  trial_end timestamptz;
begin
  account_status := identity.require_session(p_user_id, p_session_id);
  if account_status <> 'active' then
    perform identity.fail('authorization_denied', jsonb_build_object('reason', 'account_not_active'));
  end if;
  clean_name := org.require_text(p_name, 'name', 2, 100);
  clean_short := org.require_text(p_short_name, 'shortName', 1, 30);
  if p_trial is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'trial'));
  end if;
  plan := billing.plan(coalesce(p_plan_key, ''));

  request := jsonb_build_object('name', clean_name, 'shortName', clean_short, 'planKey', plan.key,
    'trial', p_trial);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'start_network', request);
  if replayed is not null then
    return replayed;
  end if;

  if p_trial then
    if plan.key <> 'band_400' then
      perform identity.fail('conflict', jsonb_build_object('reason', 'trial_plan'));
    end if;
    perform pg_advisory_xact_lock(hashtextextended('billing.trial:' || p_user_id::text, 0));
    if exists (select 1 from billing.trials where user_id = p_user_id) then
      perform identity.fail('conflict', jsonb_build_object('reason', 'trial_used'));
    end if;
  end if;

  begin
    insert into org.tenants (name, short_name, created_by)
    values (clean_name, clean_short, p_user_id)
    returning id into tenant_id;
  exception when unique_violation then
    perform identity.fail('conflict', jsonb_build_object('reason', 'pending_network_exists'));
  end;

  if p_trial then
    trial_end := now() + billing.trial_length();
    insert into billing.subscriptions (tenant_id, status, kind, plan_id, period_start, period_end)
    values (tenant_id, 'trial', 'trial', plan.id, now(), trial_end);
    insert into billing.trials (user_id, tenant_id) values (p_user_id, tenant_id);
    insert into billing.periods (tenant_id, kind, plan_id, starts_at, ends_at, actor_user_id)
    values (tenant_id, 'trial', plan.id, now(), trial_end, p_user_id);
  else
    insert into billing.subscriptions (tenant_id, status, kind, plan_id)
    values (tenant_id, 'pending', 'paid', plan.id);
  end if;

  perform authz.seed_role_permissions(tenant_id);
  president := org.create_membership(tenant_id, null, p_user_id, 'president_team_member', p_user_id);
  insert into billing.owners (tenant_id, user_id, membership_id, assigned_by)
  values (tenant_id, p_user_id, president.id, p_user_id);
  if p_trial then
    perform billing.set_tenant_status(tenant_id, 'active', 'trial', p_user_id);
  end if;
  perform audit.record_tenant(tenant_id, p_user_id, 'tenant.created', 'tenant', tenant_id::text,
    p_safe_after => jsonb_build_object('status', case when p_trial then 'active' else 'pending_payment' end,
      'name', clean_name, 'plan', plan.key, 'trial', p_trial),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'start_network', request,
    jsonb_build_object('tenantId', tenant_id,
      'status', case when p_trial then 'active' else 'pending_payment' end,
      'membershipId', president.id, 'trial', p_trial, 'trialEndsAt', trial_end));
end;
$$;

-- ── Support activation (owner answer Q9) ──────────────────────────────────

drop function api.activate_tenant(uuid, uuid, uuid, text, text, text);

-- A platform admin grants a complimentary period until a date (WAT, the last
-- free day), or the development scope exception (no date, no seat cap). It is
-- audited, never a payment, and sends no B01.
create function api.activate_tenant(
  p_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_reason text,
  p_idempotency_key text,
  p_request_id text default null,
  p_until date default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  clean_reason text;
  request jsonb;
  replayed jsonb;
  tenant org.tenants;
  s billing.subscriptions;
  until_at timestamptz;
begin
  perform pg_advisory_xact_lock(hashtextextended('identity.platform_admins', 0));
  perform identity.require_session(p_user_id, p_session_id, p_step_up => true);
  perform identity.require_platform_admin(p_user_id);
  clean_reason := identity.require_reason(p_reason);
  if p_until is not null and p_until < billing.today() then
    perform identity.fail('validation_error', jsonb_build_object('field', 'until'));
  end if;

  request := jsonb_build_object('tenantId', p_tenant_id, 'reason', clean_reason, 'until', p_until);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'activate_tenant', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into tenant from org.tenants where id = p_tenant_id for update;
  if tenant.id is null then
    perform identity.fail('not_found');
  end if;
  if tenant.status = 'deactivated' then
    perform identity.fail('network_not_active');
  end if;
  s := billing.subscription(p_tenant_id, true);
  if s.kind = 'development' and p_until is null then
    perform identity.fail('conflict', jsonb_build_object('reason', 'not_pending'));
  end if;

  if p_until is null then
    update billing.subscriptions
    set status = 'active', kind = 'development', paused_at = null, period_start = now(), period_end = null,
        next_plan_id = null, plan_change_at = null, updated_at = now()
    where tenant_id = p_tenant_id;
    insert into billing.periods (tenant_id, kind, plan_id, starts_at, actor_user_id, reason)
    values (p_tenant_id, 'development', s.plan_id, now(), p_user_id, clean_reason);
  else
    until_at := ((p_until + 1)::timestamp at time zone billing.zone());
    update billing.subscriptions
    set status = 'active', kind = 'complimentary', paused_at = null,
        period_start = case when s.status in ('trial', 'active') and s.period_start is not null
                            then s.period_start else now() end,
        period_end = until_at, updated_at = now()
    where tenant_id = p_tenant_id;
    insert into billing.periods (tenant_id, kind, plan_id, starts_at, ends_at, actor_user_id, reason)
    values (p_tenant_id, 'complimentary', s.plan_id, now(), until_at, p_user_id, clean_reason);
  end if;

  perform billing.set_tenant_status(p_tenant_id, 'active', 'admin', p_user_id);
  perform audit.record_tenant(p_tenant_id, p_user_id, 'tenant.activated', 'tenant', p_tenant_id::text, clean_reason,
    jsonb_build_object('status', tenant.status),
    jsonb_build_object('status', 'active', 'source', 'admin', 'until', p_until), p_request_id);
  perform audit.record('tenant.activated', p_user_id, p_session_id, null, clean_reason,
    p_safe_after => jsonb_build_object('tenantId', p_tenant_id, 'until', p_until), p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'activate_tenant', request,
    jsonb_build_object('tenantId', p_tenant_id, 'status', 'active'));
end;
$$;

revoke all on all functions in schema billing from public, anon, authenticated;
revoke all on all functions in schema authz from public, anon, authenticated;
revoke all on function org.require_readable_tenant(uuid) from public, anon, authenticated;
revoke all on function org.check_seat_capacity(uuid, uuid) from public, anon, authenticated;

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
