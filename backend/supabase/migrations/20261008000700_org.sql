-- Blueprint 02 — B2: networks (tenants), offices, office tree, memberships and
-- the tenant audit log.

create schema org;
create schema authz;
revoke all on schema org, authz from public, anon, authenticated;

create type org.tenant_status as enum ('pending_payment', 'active', 'suspended', 'deactivated');
create type org.office_type as enum ('world_team', 'director', 'team_leader');
create type org.office_status as enum ('active', 'closed');
create type org.role as enum (
  'member', 'team_leader', 'director', 'world_team_member', 'president_team_member'
);
create type org.membership_status as enum ('active', 'suspended', 'ended');

-- World Team > Director > Team Leader. A parent must rank strictly higher (Q2).
create function org.office_rank(p_type org.office_type)
returns int
language sql
immutable
set search_path = ''
as $$
  select case p_type when 'world_team' then 3 when 'director' then 2 else 1 end;
$$;

-- Holding the office kind's leader role makes a membership a leader (Q4).
create function org.leader_role(p_type org.office_type)
returns org.role
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'world_team' then 'world_team_member'::org.role
    when 'director' then 'director'::org.role
    else 'team_leader'::org.role
  end;
$$;

-- ── Tenants ───────────────────────────────────────────────────────────────

create table org.tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 2 and 100),
  short_name text not null check (length(btrim(short_name)) between 1 and 30),
  status org.tenant_status not null default 'pending_payment',
  authz_version bigint not null default 0,
  created_by uuid not null references identity.accounts (user_id) on delete restrict,
  created_at timestamptz not null default now(),
  activated_at timestamptz,
  activated_by uuid references identity.accounts (user_id) on delete restrict,
  activation_source text check (activation_source in ('admin', 'payment')),
  check ((status = 'pending_payment') = (activated_at is null)),
  check ((activated_at is null) = (activation_source is null))
);

-- One network awaiting payment per founder at a time.
create unique index tenants_one_pending_per_founder
  on org.tenants (created_by) where status = 'pending_payment';

-- ── Offices and the office tree ───────────────────────────────────────────

create table org.offices (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  parent_office_id uuid,
  office_type org.office_type not null,
  name text not null check (length(btrim(name)) between 2 and 100),
  status org.office_status not null default 'active',
  created_by uuid not null references identity.accounts (user_id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, parent_office_id) references org.offices (tenant_id, id) on delete restrict,
  check (parent_office_id is distinct from id)
);

create index offices_parent_idx on org.offices (parent_office_id);
create index offices_tenant_name_idx on org.offices (tenant_id, name, id);

-- Every ancestor/descendant pair, including each office with itself (depth 0).
create table org.office_closure (
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  ancestor_id uuid not null references org.offices (id) on delete restrict,
  descendant_id uuid not null references org.offices (id) on delete restrict,
  depth int not null check (depth >= 0),
  primary key (ancestor_id, descendant_id)
);

create index office_closure_descendant_idx on org.office_closure (descendant_id, ancestor_id);

create table org.office_moves (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  office_id uuid not null references org.offices (id) on delete restrict,
  from_parent_id uuid references org.offices (id) on delete restrict,
  to_parent_id uuid references org.offices (id) on delete restrict,
  reason text not null,
  actor_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  at timestamptz not null default now()
);

-- Validates placement (Q2) under a per-tenant lock so concurrent writes see a
-- consistent tree.
create function org.check_office_placement()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  parent org.offices;
begin
  if tg_op = 'UPDATE' then
    if new.tenant_id <> old.tenant_id or new.office_type <> old.office_type then
      perform identity.fail('invariant_violation', jsonb_build_object('table', 'org.offices'));
    end if;
    if new.parent_office_id is not distinct from old.parent_office_id then
      return new;
    end if;
  end if;

  perform org.lock_tree(new.tenant_id);

  if new.parent_office_id is not null then
    select * into parent from org.offices where id = new.parent_office_id;
    if parent.id is null or parent.tenant_id <> new.tenant_id or parent.status <> 'active'
      or org.office_rank(parent.office_type) <= org.office_rank(new.office_type) then
      perform identity.fail('hierarchy_invalid');
    end if;
    if tg_op = 'UPDATE' and exists (
      select 1 from org.office_closure
      where ancestor_id = new.id and descendant_id = new.parent_office_id
    ) then
      perform identity.fail('hierarchy_invalid', jsonb_build_object('reason', 'cycle'));
    end if;
  end if;
  return new;
end;
$$;

create trigger offices_placement
before insert or update on org.offices
for each row execute function org.check_office_placement();

-- Keeps the closure table in step with inserts and re-placements.
create function org.maintain_office_closure()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into org.office_closure (tenant_id, ancestor_id, descendant_id, depth)
    select new.tenant_id, new.id, new.id, 0
    union all
    select new.tenant_id, c.ancestor_id, new.id, c.depth + 1
    from org.office_closure c
    where c.descendant_id = new.parent_office_id;
    return null;
  end if;

  if new.parent_office_id is not distinct from old.parent_office_id then
    return null;
  end if;

  -- Detach the subtree from its old ancestors…
  delete from org.office_closure c
  where c.descendant_id in (select descendant_id from org.office_closure where ancestor_id = new.id)
    and c.ancestor_id not in (select descendant_id from org.office_closure where ancestor_id = new.id);

  -- …and attach it under the new parent's ancestors.
  insert into org.office_closure (tenant_id, ancestor_id, descendant_id, depth)
  select new.tenant_id, above.ancestor_id, below.descendant_id, above.depth + below.depth + 1
  from org.office_closure above
  cross join org.office_closure below
  where above.descendant_id = new.parent_office_id
    and below.ancestor_id = new.id;
  return null;
end;
$$;

create trigger offices_closure
after insert or update of parent_office_id on org.offices
for each row execute function org.maintain_office_closure();

-- ── Memberships ───────────────────────────────────────────────────────────

create table org.memberships (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  office_id uuid,
  user_id uuid not null references identity.accounts (user_id) on delete restrict,
  role org.role not null,
  is_primary boolean not null default false,
  status org.membership_status not null default 'active',
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  ended_reason text,
  replaced_by_id uuid references org.memberships (id) on delete restrict,
  created_by uuid not null references identity.accounts (user_id) on delete restrict,
  foreign key (tenant_id, office_id) references org.offices (tenant_id, id) on delete restrict,
  check ((role = 'president_team_member') = (office_id is null)),
  check ((status = 'ended') = (ended_at is not null)),
  check (not (status = 'ended' and is_primary))
);

create unique index memberships_one_open_per_place
  on org.memberships (tenant_id, user_id, coalesce(office_id, '00000000-0000-0000-0000-000000000000'::uuid), role)
  where status <> 'ended';
create unique index memberships_one_primary
  on org.memberships (tenant_id, user_id) where is_primary;
create index memberships_user_idx on org.memberships (user_id, tenant_id) where status <> 'ended';
create index memberships_office_idx on org.memberships (office_id, role, status);
create index memberships_tenant_role_idx on org.memberships (tenant_id, role, status);

-- Leader roles only in the matching office kind; members anywhere (Q3, Q4).
create function org.check_membership_role()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  kind org.office_type;
begin
  if tg_op = 'UPDATE' and (
    new.tenant_id <> old.tenant_id or new.user_id <> old.user_id or new.role <> old.role
    or new.office_id is distinct from old.office_id or old.status = 'ended'
  ) then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'org.memberships'));
  end if;

  if new.office_id is not null and new.role <> 'member' then
    select office_type into kind from org.offices where id = new.office_id;
    if org.leader_role(kind) <> new.role then
      perform identity.fail('role_office_mismatch');
    end if;
  end if;
  return new;
end;
$$;

create trigger memberships_role
before insert or update on org.memberships
for each row execute function org.check_membership_role();

create table org.membership_events (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  membership_id uuid not null references org.memberships (id) on delete restrict,
  action text not null check (action in ('created', 'moved', 'suspended', 'reactivated', 'ended', 'replaced')),
  from_status org.membership_status,
  to_status org.membership_status not null,
  reason text,
  actor_user_id uuid not null references identity.accounts (user_id) on delete restrict,
  at timestamptz not null default now()
);

create index membership_events_membership_idx on org.membership_events (membership_id, at);

-- ── Tenant audit log (D-11) ───────────────────────────────────────────────

create table audit.tenant_events (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  at timestamptz not null default now(),
  actor_user_id uuid not null,
  action text not null check (action ~ '^[a-z_]+(\.[a-z_]+)+$'),
  target_type text check (target_type in ('tenant', 'office', 'membership', 'role_permission', 'access_assignment', 'reviewer_assignment')),
  target_id text,
  reason text,
  safe_before jsonb,
  safe_after jsonb,
  request_id text check (request_id is null or length(request_id) <= 100)
);

create index tenant_events_tenant_idx on audit.tenant_events (tenant_id, id desc);

create trigger tenant_events_append_only
before update or delete on audit.tenant_events
for each row execute function audit.reject_change();
create trigger tenant_events_no_truncate
before truncate on audit.tenant_events
for each statement execute function audit.reject_change();

create trigger membership_events_append_only
before update or delete on org.membership_events
for each row execute function audit.reject_change();
create trigger office_moves_append_only
before update or delete on org.office_moves
for each row execute function audit.reject_change();

create function audit.record_tenant(
  p_tenant_id uuid,
  p_actor_user_id uuid,
  p_action text,
  p_target_type text,
  p_target_id text,
  p_reason text default null,
  p_safe_before jsonb default null,
  p_safe_after jsonb default null,
  p_request_id text default null
)
returns void
language sql
set search_path = ''
as $$
  insert into audit.tenant_events (
    tenant_id, actor_user_id, action, target_type, target_id, reason,
    safe_before, safe_after, request_id
  ) values (
    p_tenant_id, p_actor_user_id, p_action, p_target_type, p_target_id, p_reason,
    p_safe_before, p_safe_after, left(p_request_id, 100)
  );
$$;

alter table org.tenants enable row level security;
alter table org.offices enable row level security;
alter table org.office_closure enable row level security;
alter table org.office_moves enable row level security;
alter table org.memberships enable row level security;
alter table org.membership_events enable row level security;
alter table audit.tenant_events enable row level security;

-- ── Helpers used by commands ──────────────────────────────────────────────

create function org.bump_authz_version(p_tenant_id uuid)
returns void
language sql
set search_path = ''
as $$
  update org.tenants set authz_version = authz_version + 1 where id = p_tenant_id;
$$;

create function org.record_membership_event(
  p_membership org.memberships,
  p_action text,
  p_from_status org.membership_status,
  p_reason text,
  p_actor_user_id uuid
)
returns void
language sql
set search_path = ''
as $$
  insert into org.membership_events (tenant_id, membership_id, action, from_status, to_status, reason, actor_user_id)
  values (p_membership.tenant_id, p_membership.id, p_action, p_from_status, p_membership.status, p_reason, p_actor_user_id);
$$;

-- Serializes primary selection and handover for one person in one network.
create function org.lock_person(p_tenant_id uuid, p_user_id uuid)
returns void
language sql
set search_path = ''
as $$
  select pg_advisory_xact_lock(hashtextextended('org.person:' || p_tenant_id::text || ':' || p_user_id::text, 0));
$$;

-- Serializes changes to one network's office tree. Take it before any office
-- row lock.
create function org.lock_tree(p_tenant_id uuid)
returns void
language sql
set search_path = ''
as $$
  select pg_advisory_xact_lock(hashtextextended('org.offices:' || p_tenant_id::text, 0));
$$;

-- Creates an active membership; it is primary when the person has none open
-- in that network.
create function org.create_membership(
  p_tenant_id uuid,
  p_office_id uuid,
  p_user_id uuid,
  p_role org.role,
  p_actor_user_id uuid,
  p_primary boolean default null
)
returns org.memberships
language plpgsql
set search_path = ''
as $$
declare
  created org.memberships;
begin
  perform org.lock_person(p_tenant_id, p_user_id);
  if (select status from identity.accounts where user_id = p_user_id) <> 'active' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'account_not_active'));
  end if;

  begin
    insert into org.memberships (tenant_id, office_id, user_id, role, is_primary, created_by)
    values (
      p_tenant_id, p_office_id, p_user_id, p_role,
      coalesce(p_primary, not exists (
        select 1 from org.memberships
        where tenant_id = p_tenant_id and user_id = p_user_id and is_primary
      )),
      p_actor_user_id
    )
    returning * into created;
  exception when unique_violation then
    perform identity.fail('membership_exists');
  end;

  perform org.record_membership_event(created, 'created', null, null, p_actor_user_id);
  return created;
end;
$$;

-- Gives the person a primary membership again (the earliest open one) after
-- their primary ended or moved. Ending everything leaves none (W-05).
create function org.ensure_primary(p_tenant_id uuid, p_user_id uuid)
returns void
language sql
set search_path = ''
as $$
  select org.lock_person(p_tenant_id, p_user_id);
  update org.memberships set is_primary = true
  where id = (
    select id from org.memberships
    where tenant_id = p_tenant_id and user_id = p_user_id and status <> 'ended'
    order by started_at, id
    limit 1
  )
  and not exists (
    select 1 from org.memberships
    where tenant_id = p_tenant_id and user_id = p_user_id and is_primary
  );
$$;

-- Ends a membership with a reason, keeping history.
create function org.end_membership(
  p_membership_id uuid,
  p_reason text,
  p_actor_user_id uuid,
  p_action text default 'ended',
  p_replaced_by uuid default null
)
returns org.memberships
language plpgsql
set search_path = ''
as $$
declare
  previous org.memberships;
  ended org.memberships;
begin
  select * into previous from org.memberships where id = p_membership_id;
  perform org.lock_person(previous.tenant_id, previous.user_id);
  select * into previous from org.memberships where id = p_membership_id for update;
  update org.memberships
  set status = 'ended', ended_at = now(), ended_reason = p_reason, is_primary = false,
      replaced_by_id = p_replaced_by
  where id = p_membership_id
  returning * into ended;
  perform org.record_membership_event(ended, p_action, previous.status, p_reason, p_actor_user_id);
  return ended;
end;
$$;

-- An active office keeps at least one active leader (Q4). Call with the office
-- row locked.
create function org.assert_leader_remains(p_office_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  office org.offices;
begin
  select * into office from org.offices where id = p_office_id;
  if office.status = 'active' and not exists (
    select 1 from org.memberships
    where office_id = p_office_id and role = org.leader_role(office.office_type) and status = 'active'
  ) then
    perform identity.fail('last_leader');
  end if;
end;
$$;

-- A network keeps at least one active President Team Member (Q5). Call with the
-- tenant row locked.
create function org.assert_president_remains(p_tenant_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1 from org.memberships
    where tenant_id = p_tenant_id and role = 'president_team_member' and status = 'active'
  ) then
    perform identity.fail('last_president');
  end if;
end;
$$;

-- Seat count (D-10): distinct accounts with an active or suspended membership.
-- Stored now, enforced by the subscription slice.
create function org.billable_accounts(p_tenant_id uuid)
returns int
language sql
stable
set search_path = ''
as $$
  select count(distinct user_id)::int from org.memberships
  where tenant_id = p_tenant_id and status in ('active', 'suspended');
$$;
