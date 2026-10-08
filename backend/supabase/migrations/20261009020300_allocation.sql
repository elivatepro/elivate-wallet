-- Blueprint 04 — B3a/B4: per-network pockets and split, versioned (W-23,
-- F-01.6). The President Team edits them (owner decision 11) through the new
-- protected President-only permission `manage_allocation`.

-- ── Permission (A-03 catalogue) ───────────────────────────────────────────

do $$
begin
  if not exists (select 1 from authz.permission_catalog where key = 'manage_allocation') then
    alter table authz.permission_catalog disable trigger permission_catalog_immutable;
    alter table authz.default_role_permissions disable trigger default_role_permissions_immutable;
    insert into authz.permission_catalog (key, protected, grantable, scope, wallet_holder_baseline, can_target_own_wallet)
    values ('manage_allocation', true, false, 'tenant', false, false);
    insert into authz.default_role_permissions (role, permission_key, allowed)
    select r, 'manage_allocation', r = 'president_team_member'
    from unnest(enum_range(null::org.role)) r;
    alter table authz.permission_catalog enable trigger permission_catalog_immutable;
    alter table authz.default_role_permissions enable trigger default_role_permissions_immutable;
  end if;
end;
$$;

insert into authz.role_permissions (tenant_id, role, permission_key, allowed)
select t.id, d.role, d.permission_key, d.allowed
from org.tenants t
cross join authz.default_role_permissions d
where d.permission_key = 'manage_allocation'
on conflict (tenant_id, role, permission_key) do nothing;

-- ── Default pockets and split (Q1, Q3) ────────────────────────────────────

create table ledger.default_pockets (
  name text primary key,
  sort_order int not null unique check (sort_order > 0),
  basis_points int not null check (basis_points between 0 and 10000)
);

insert into ledger.default_pockets (name, sort_order, basis_points) values
  ('Point Value', 1, 4000),
  ('Business Investment', 2, 1000),
  ('Personal Investment', 3, 1500),
  ('Upkeep', 4, 2500),
  ('Savings', 5, 1000);

create trigger default_pockets_immutable
before insert or update or delete or truncate on ledger.default_pockets
for each statement execute function audit.reject_change();

-- ── Versions ──────────────────────────────────────────────────────────────

create table ledger.allocation_policies (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  version int not null check (version > 0),
  source text not null check (source in ('default', 'president')),
  reason text check (reason is null or length(btrim(reason)) between 3 and 500),
  created_by uuid references identity.accounts (user_id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (tenant_id, version),
  unique (tenant_id, id),
  check ((source = 'president') = (reason is not null and created_by is not null))
);

create table ledger.allocation_policy_lines (
  policy_id uuid not null,
  tenant_id uuid not null,
  pocket_id uuid not null,
  name text not null,
  sort_order int not null check (sort_order > 0),
  basis_points int not null check (basis_points between 0 and 10000),
  primary key (policy_id, pocket_id),
  foreign key (tenant_id, policy_id) references ledger.allocation_policies (tenant_id, id) on delete restrict,
  foreign key (tenant_id, pocket_id) references ledger.pockets (tenant_id, id) on delete restrict
);

create index allocation_policy_lines_pocket_idx on ledger.allocation_policy_lines (pocket_id);
create index allocation_policies_creator_idx on ledger.allocation_policies (created_by);

create table ledger.active_allocation_policies (
  tenant_id uuid primary key references org.tenants (id) on delete restrict,
  policy_id uuid not null,
  version int not null,
  activated_at timestamptz not null default now(),
  activated_by uuid references identity.accounts (user_id) on delete restrict,
  foreign key (tenant_id, policy_id) references ledger.allocation_policies (tenant_id, id) on delete restrict
);

create index active_allocation_policies_policy_idx on ledger.active_allocation_policies (tenant_id, policy_id);

-- Deferred: a version's lines sum to exactly 100% over ordinary pockets.
create function ledger.check_policy_lines()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if coalesce((select sum(basis_points) from ledger.allocation_policy_lines where policy_id = new.id), 0) <> 10000
    or exists (
      select 1 from ledger.allocation_policy_lines l join ledger.pockets p on p.id = l.pocket_id
      where l.policy_id = new.id and p.kind <> 'ordinary'
    ) then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'ledger.allocation_policies'));
  end if;
  return null;
end;
$$;

create constraint trigger allocation_policies_complete
after insert on ledger.allocation_policies
deferrable initially deferred
for each row execute function ledger.check_policy_lines();

create trigger allocation_policies_immutable
before update or delete on ledger.allocation_policies
for each row execute function audit.reject_change();
create trigger allocation_policy_lines_immutable
before update or delete on ledger.allocation_policy_lines
for each row execute function audit.reject_change();
create trigger active_allocation_policies_no_delete
before delete on ledger.active_allocation_policies
for each row execute function audit.reject_change();
create trigger allocation_policies_no_truncate before truncate on ledger.allocation_policies
for each statement execute function audit.reject_change();
create trigger allocation_policy_lines_no_truncate before truncate on ledger.allocation_policy_lines
for each statement execute function audit.reject_change();
create trigger active_allocation_policies_no_truncate before truncate on ledger.active_allocation_policies
for each statement execute function audit.reject_change();

alter table ledger.default_pockets enable row level security;
alter table ledger.allocation_policies enable row level security;
alter table ledger.allocation_policy_lines enable row level security;
alter table ledger.active_allocation_policies enable row level security;

-- ── Seeding at activation (Q3) ────────────────────────────────────────────

create function ledger.seed_allocation(p_tenant_id uuid, p_actor_user_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_policy_id uuid;
begin
  if exists (select 1 from ledger.pockets where tenant_id = p_tenant_id) then
    return;
  end if;

  insert into ledger.pockets (tenant_id, kind, name, sort_order)
  select p_tenant_id, 'ordinary', d.name, d.sort_order from ledger.default_pockets d;
  insert into ledger.pockets (tenant_id, kind, name, sort_order)
  values (p_tenant_id, 'debt', 'Debt', ledger.debt_sort_order());

  insert into ledger.allocation_policies (tenant_id, version, source)
  values (p_tenant_id, 1, 'default')
  returning id into v_policy_id;
  insert into ledger.allocation_policy_lines (policy_id, tenant_id, pocket_id, name, sort_order, basis_points)
  select v_policy_id, p_tenant_id, p.id, p.name, p.sort_order, d.basis_points
  from ledger.pockets p join ledger.default_pockets d on d.name = p.name
  where p.tenant_id = p_tenant_id and p.kind = 'ordinary';
  insert into ledger.active_allocation_policies (tenant_id, policy_id, version, activated_by)
  values (p_tenant_id, v_policy_id, 1, p_actor_user_id);
end;
$$;

create function ledger.on_tenant_activated()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform ledger.seed_allocation(new.id, new.activated_by);
  return null;
end;
$$;

create trigger tenants_seed_allocation
after update of status on org.tenants
for each row
when (old.status = 'pending_payment' and new.status = 'active')
execute function ledger.on_tenant_activated();

select ledger.seed_allocation(t.id, t.activated_by) from org.tenants t where t.activated_at is not null;

-- ── Allocation (B3a) ──────────────────────────────────────────────────────

-- Exact split in minor units: floor shares, then leftover units one at a
-- time by largest remainder, ties by display order (Q5).
create function ledger.allocate(p_policy_id uuid, p_currency text, p_amount numeric)
returns table (pocket_id uuid, basis_points int, amount numeric)
language plpgsql
set search_path = ''
as $$
#variable_conflict use_column
declare
  scale smallint;
  units numeric;
  total numeric := 0;
  line record;
begin
  scale := ledger.currency_scale(p_currency);
  units := p_amount * power(10::numeric, scale);
  if units is null or units <= 0 or units <> trunc(units) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'amount'));
  end if;

  for line in
    with l as (
      select pl.pocket_id, pl.basis_points, pl.sort_order,
        floor(units * pl.basis_points / 10000) as base,
        mod(units * pl.basis_points, 10000) as remainder
      from ledger.allocation_policy_lines pl
      where pl.policy_id = p_policy_id
    ),
    t as (select units - sum(l.base) as leftover from l),
    r as (select l.*, row_number() over (order by l.remainder desc, l.sort_order, l.pocket_id) as rank from l)
    select r.pocket_id, r.basis_points, r.sort_order,
      round((r.base + case when r.rank <= t.leftover then 1 else 0 end) / power(10::numeric, scale), scale) as share
    from r cross join t
    order by r.sort_order, r.pocket_id
  loop
    pocket_id := line.pocket_id;
    basis_points := line.basis_points;
    amount := line.share;
    total := total + line.share;
    return next;
  end loop;

  if total <> p_amount then
    perform identity.fail('invariant_violation', jsonb_build_object('reason', 'allocation_total'));
  end if;
end;
$$;

-- ── Reads ─────────────────────────────────────────────────────────────────

create function ledger.policy_json(p_policy_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'policyId', ap.id,
    'version', ap.version,
    'source', ap.source,
    'createdAt', ap.created_at,
    'pockets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'pocketId', l.pocket_id,
        'name', l.name,
        'kind', 'ordinary',
        'basisPoints', l.basis_points,
        'percent', round(l.basis_points::numeric / 100, 2)::text
      ) order by l.sort_order, l.pocket_id)
      from ledger.allocation_policy_lines l where l.policy_id = ap.id
    ), '[]'::jsonb)
  )
  from ledger.allocation_policies ap
  where ap.id = p_policy_id;
$$;

-- Current pockets and split of a network; null when none.
create function ledger.allocation_json(p_tenant_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select ledger.policy_json(a.policy_id)
    || jsonb_build_object(
      'activatedAt', a.activated_at,
      'debt', (
        select jsonb_build_object('pocketId', p.id, 'name', p.name, 'kind', 'debt')
        from ledger.pockets p where p.tenant_id = a.tenant_id and p.kind = 'debt'
      )
    )
  from ledger.active_allocation_policies a
  where a.tenant_id = p_tenant_id;
$$;

create function ledger.allocation_versions_json(p_tenant_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(
    ledger.policy_json(ap.id) || jsonb_build_object(
      'reason', ap.reason,
      'createdBy', case when ap.created_by is not null then org.person(ap.created_by) end
    ) order by ap.version desc), '[]'::jsonb)
  from ledger.allocation_policies ap
  where ap.tenant_id = p_tenant_id;
$$;

create function api.allocation_policy(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  current jsonb;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  current := ledger.allocation_json(workspace.tenant_id);
  if current is null then
    perform identity.fail('allocation_policy_missing');
  end if;
  return current;
end;
$$;

create function api.allocation_versions(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
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
  return jsonb_build_object('items', ledger.allocation_versions_json(workspace.tenant_id));
end;
$$;

-- Elivate admins may view any network's versions (owner decision 14).
create function api.admin_allocation_versions(p_user_id uuid, p_session_id uuid, p_tenant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  if not exists (select 1 from org.tenants where id = p_tenant_id) then
    perform identity.fail('not_found');
  end if;
  return jsonb_build_object('items', ledger.allocation_versions_json(p_tenant_id));
end;
$$;

-- ── Change pockets and split (owner decision 11) ──────────────────────────

-- p_pockets: ordered list (display order) of {pocketId?, name, basisPoints}.
-- Listed ids keep their pocket (rename, reorder, new %); entries without an id
-- add a pocket; active ordinary pockets left out are retired, only at zero
-- balance in every currency. Debt is fixed and can't be listed.
create function api.set_allocation(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_expected_version int,
  p_pockets jsonb,
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
  clean_reason text;
  item jsonb;
  v_pos bigint;
  parsed jsonb := '[]'::jsonb;
  v_pocket_id uuid;
  v_name text;
  v_bps int;
  request jsonb;
  replayed jsonb;
  active ledger.active_allocation_policies;
  pocket ledger.pockets;
  final_ids uuid[] := '{}'::uuid[];
  retired int := 0;
  added int := 0;
  v_policy_id uuid;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  perform authz.require(p_user_id, 'manage_allocation', workspace.tenant_id, null, null, workspace.id);
  clean_reason := identity.require_reason(p_reason);
  if p_expected_version is null or p_expected_version < 1 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'expectedVersion'));
  end if;
  if jsonb_typeof(p_pockets) is distinct from 'array' or jsonb_array_length(p_pockets) not between 1 and 12 then
    perform identity.fail('policy_invalid', jsonb_build_object('reason', 'pocket_count'));
  end if;

  for item, v_pos in select value, ordinality from jsonb_array_elements(p_pockets) with ordinality loop
    if jsonb_typeof(item) <> 'object' then
      perform identity.fail('validation_error', jsonb_build_object('field', 'pockets'));
    end if;
    v_pocket_id := null;
    if item->>'pocketId' is not null then
      begin
        v_pocket_id := (item->>'pocketId')::uuid;
      exception when others then
        perform identity.fail('validation_error', jsonb_build_object('field', 'pockets.pocketId'));
      end;
    end if;
    v_name := btrim(item->>'name');
    if v_name is null or length(v_name) not between 1 and 40 then
      perform identity.fail('validation_error', jsonb_build_object('field', 'pockets.name'));
    end if;
    if jsonb_typeof(item->'basisPoints') is distinct from 'number'
      or (item->>'basisPoints')::numeric <> trunc((item->>'basisPoints')::numeric)
      or (item->>'basisPoints')::numeric not between 0 and 10000 then
      perform identity.fail('validation_error', jsonb_build_object('field', 'pockets.basisPoints'));
    end if;
    v_bps := (item->>'basisPoints')::int;
    parsed := parsed || jsonb_build_object('pocketId', v_pocket_id, 'name', v_name, 'basisPoints', v_bps);
  end loop;

  if (select count(distinct lower(e->>'name')) from jsonb_array_elements(parsed) e) <> jsonb_array_length(parsed) then
    perform identity.fail('policy_invalid', jsonb_build_object('reason', 'duplicate_name'));
  end if;
  if (select count(distinct e->>'pocketId') <> count(e->>'pocketId') from jsonb_array_elements(parsed) e) then
    perform identity.fail('policy_invalid', jsonb_build_object('reason', 'duplicate_pocket'));
  end if;
  if (select sum((e->>'basisPoints')::int) from jsonb_array_elements(parsed) e) <> 10000 then
    perform identity.fail('policy_invalid', jsonb_build_object('reason', 'total'));
  end if;

  request := jsonb_build_object('tenantId', workspace.tenant_id, 'expectedVersion', p_expected_version,
    'pockets', parsed, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'set_allocation', request);
  if replayed is not null then
    return replayed;
  end if;

  -- Lock order step 6: no income can post while the split changes.
  select * into active from ledger.active_allocation_policies where tenant_id = workspace.tenant_id for update;
  if active.tenant_id is null then
    perform identity.fail('allocation_policy_missing');
  end if;
  if active.version <> p_expected_version then
    perform identity.fail('conflict', jsonb_build_object('reason', 'version_changed', 'currentVersion', active.version));
  end if;

  for item in select value from jsonb_array_elements(parsed) loop
    if item->>'pocketId' is not null then
      select * into pocket from ledger.pockets
      where id = (item->>'pocketId')::uuid and tenant_id = workspace.tenant_id
      for update;
      if pocket.kind = 'debt' then
        perform identity.fail('policy_invalid', jsonb_build_object('reason', 'debt_fixed'));
      end if;
      if pocket.id is null or pocket.status <> 'active' then
        perform identity.fail('policy_invalid', jsonb_build_object('reason', 'unknown_pocket'));
      end if;
    end if;
  end loop;

  -- Retire what was left out, only at zero in every currency.
  for pocket in
    select * from ledger.pockets
    where tenant_id = workspace.tenant_id and kind = 'ordinary' and status = 'active'
      and id::text not in (select e->>'pocketId' from jsonb_array_elements(parsed) e where e->>'pocketId' is not null)
    order by id
    for update
  loop
    if exists (
      select 1 from ledger.balances b where b.pocket_id = pocket.id and (b.posted <> 0 or b.reserved <> 0)
    ) then
      perform identity.fail('conflict', jsonb_build_object('reason', 'pocket_not_empty', 'pocketId', pocket.id));
    end if;
    update ledger.pockets set status = 'retired', retired_at = now() where id = pocket.id;
    retired := retired + 1;
  end loop;

  for item, v_pos in select value, ordinality from jsonb_array_elements(parsed) with ordinality loop
    if item->>'pocketId' is null then
      insert into ledger.pockets (tenant_id, kind, name, sort_order, created_by)
      values (workspace.tenant_id, 'ordinary', item->>'name', v_pos, p_user_id)
      returning id into v_pocket_id;
      added := added + 1;
    else
      v_pocket_id := (item->>'pocketId')::uuid;
      update ledger.pockets set name = item->>'name', sort_order = v_pos
      where id = v_pocket_id and (name <> item->>'name' or sort_order <> v_pos);
    end if;
    final_ids := final_ids || v_pocket_id;
  end loop;

  insert into ledger.allocation_policies (tenant_id, version, source, reason, created_by)
  values (workspace.tenant_id, active.version + 1, 'president', clean_reason, p_user_id)
  returning id into v_policy_id;
  insert into ledger.allocation_policy_lines (policy_id, tenant_id, pocket_id, name, sort_order, basis_points)
  select v_policy_id, workspace.tenant_id, final_ids[x.n], x.e->>'name', x.n, (x.e->>'basisPoints')::int
  from jsonb_array_elements(parsed) with ordinality as x (e, n);
  update ledger.active_allocation_policies
  set policy_id = v_policy_id, version = active.version + 1, activated_at = now(), activated_by = p_user_id
  where tenant_id = workspace.tenant_id;

  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'allocation.changed', 'allocation_policy',
    v_policy_id::text, clean_reason,
    jsonb_build_object('version', active.version),
    jsonb_build_object('version', active.version + 1, 'pockets', jsonb_array_length(parsed),
      'added', added, 'retired', retired),
    p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'set_allocation', request,
    ledger.allocation_json(workspace.tenant_id));
end;
$$;
