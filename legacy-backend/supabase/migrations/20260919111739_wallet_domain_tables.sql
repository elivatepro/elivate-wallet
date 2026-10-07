create table public.wallets (
  id uuid primary key default extensions.gen_random_uuid(),
  owner_user_id uuid not null unique
    references public.user_accounts (user_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp()
);

create table public.pocket_definitions (
  pocket_key text primary key
    check (pocket_key ~ '^[a-z][a-z0-9_]*$'),
  display_name text not null check (length(btrim(display_name)) > 0),
  allows_negative boolean not null default false,
  transfer_in_allowed boolean not null default true,
  transfer_out_allowed boolean not null default true,
  sort_order smallint not null unique check (sort_order >= 0),
  created_at timestamptz not null default clock_timestamp(),
  check (pocket_key = 'debt' or not allows_negative),
  check (
    pocket_key <> 'debt'
    or (allows_negative and transfer_in_allowed and not transfer_out_allowed)
  )
);

insert into public.pocket_definitions (
  pocket_key,
  display_name,
  allows_negative,
  transfer_in_allowed,
  transfer_out_allowed,
  sort_order
)
values ('debt', 'Debt', true, true, false, 900);

create table public.allocation_policy_versions (
  id uuid primary key default extensions.gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  version_number bigint not null check (version_number > 0),
  created_by_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  activated_at timestamptz,
  unique (tenant_id, id),
  unique (tenant_id, version_number),
  check (activated_at is null or activated_at >= created_at)
);

create table public.allocation_policy_rules (
  tenant_id uuid not null,
  policy_version_id uuid not null,
  pocket_key text not null
    references public.pocket_definitions (pocket_key) on delete restrict,
  allocation_basis_points integer not null
    check (allocation_basis_points between 1 and 10000),
  remainder_rank smallint not null check (remainder_rank > 0),
  primary key (policy_version_id, pocket_key),
  unique (policy_version_id, remainder_rank),
  foreign key (tenant_id, policy_version_id)
    references public.allocation_policy_versions (tenant_id, id)
    on delete restrict
);

create table public.tenant_active_allocation_policies (
  tenant_id uuid primary key references public.tenants (id) on delete restrict,
  policy_version_id uuid not null unique,
  activated_by_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  activated_at timestamptz not null default clock_timestamp(),
  foreign key (tenant_id, policy_version_id)
    references public.allocation_policy_versions (tenant_id, id)
    on delete restrict
);

create index allocation_policy_versions_created_by_user_id
  on public.allocation_policy_versions (created_by_user_id);

create index allocation_policy_rules_tenant_version
  on public.allocation_policy_rules (tenant_id, policy_version_id);

create index allocation_policy_rules_pocket_key
  on public.allocation_policy_rules (pocket_key);

create index tenant_active_allocation_policies_activated_by_user_id
  on public.tenant_active_allocation_policies (activated_by_user_id);

create or replace function public.validate_wallet_owner()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  owner_status public.account_status;
begin
  if tg_op = 'UPDATE'
     and (old.id <> new.id or old.owner_user_id <> new.owner_user_id) then
    raise exception using
      errcode = '23514',
      message = 'wallet identity and owner cannot change';
  end if;

  select ua.status
    into owner_status
    from public.user_accounts ua
   where ua.user_id = new.owner_user_id;

  if owner_status is null or owner_status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'wallet owner account must be active at wallet creation';
  end if;

  if not exists (
    select 1
      from public.memberships m
      join public.tenants t on t.id = m.tenant_id
     where m.user_id = new.owner_user_id
       and m.status = 'active'
       and m.role_key <> 'president_team_member'
       and t.status = 'active'
  ) then
    raise exception using
      errcode = '23514',
      message = 'wallet owner must have an active wallet-eligible membership';
  end if;

  return new;
end;
$$;

create trigger wallets_validate_owner
  before insert or update on public.wallets
  for each row execute function public.validate_wallet_owner();

create or replace function public.prevent_wallet_delete()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'wallets preserve stable financial identity and cannot be deleted';
end;
$$;

create trigger wallets_prevent_delete
  before delete on public.wallets
  for each row execute function public.prevent_wallet_delete();

create or replace function public.validate_allocation_policy_activation()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  rule_count integer;
  allocation_total integer;
  minimum_rank integer;
  maximum_rank integer;
begin
  if tg_op = 'INSERT' and new.activated_at is not null then
    raise exception using
      errcode = '23514',
      message = 'allocation policy must be activated after its rules are defined';
  end if;

  if tg_op = 'UPDATE' then
    if old.activated_at is not null then
      raise exception using
        errcode = '55000',
        message = 'activated allocation policy versions are immutable';
    end if;

    if new.tenant_id <> old.tenant_id
       or new.version_number <> old.version_number
       or new.created_by_user_id <> old.created_by_user_id
       or new.created_at <> old.created_at then
      raise exception using
        errcode = '55000',
        message = 'allocation policy version identity is immutable';
    end if;

    if new.activated_at is null then
      return new;
    end if;

    select count(*), coalesce(sum(r.allocation_basis_points), 0),
           min(r.remainder_rank), max(r.remainder_rank)
      into rule_count, allocation_total, minimum_rank, maximum_rank
      from public.allocation_policy_rules r
     where r.tenant_id = new.tenant_id
       and r.policy_version_id = new.id;

    if rule_count = 0 or allocation_total <> 10000 then
      raise exception using
        errcode = '23514',
        message = 'active allocation policy percentages must total exactly 100 percent';
    end if;

    if minimum_rank <> 1 or maximum_rank <> rule_count then
      raise exception using
        errcode = '23514',
        message = 'allocation remainder ranks must be consecutive from one';
    end if;
  end if;

  return new;
end;
$$;

create trigger allocation_policy_versions_validate_activation
  before insert or update on public.allocation_policy_versions
  for each row execute function public.validate_allocation_policy_activation();

create or replace function public.protect_allocation_policy_rules()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  target_policy_version_id uuid;
  policy_activated_at timestamptz;
begin
  target_policy_version_id := case when tg_op = 'DELETE'
    then old.policy_version_id else new.policy_version_id end;

  select v.activated_at
    into policy_activated_at
    from public.allocation_policy_versions v
   where v.id = target_policy_version_id;

  if policy_activated_at is not null then
    raise exception using
      errcode = '55000',
      message = 'rules for an activated allocation policy are immutable';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger allocation_policy_rules_protect_activated
  before insert or update or delete on public.allocation_policy_rules
  for each row execute function public.protect_allocation_policy_rules();

create or replace function public.validate_active_allocation_policy()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  policy_activated_at timestamptz;
begin
  select v.activated_at
    into policy_activated_at
    from public.allocation_policy_versions v
   where v.tenant_id = new.tenant_id
     and v.id = new.policy_version_id;

  if policy_activated_at is null then
    raise exception using
      errcode = '23514',
      message = 'tenant active allocation policy must reference an activated version';
  end if;

  return new;
end;
$$;

create trigger tenant_active_allocation_policies_validate
  before insert or update on public.tenant_active_allocation_policies
  for each row execute function public.validate_active_allocation_policy();

create or replace function public.prevent_active_allocation_policy_delete()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'an active allocation policy must be replaced, not deleted';
end;
$$;

create trigger tenant_active_allocation_policies_prevent_delete
  before delete on public.tenant_active_allocation_policies
  for each row execute function public.prevent_active_allocation_policy_delete();

alter table public.wallets enable row level security;
alter table public.pocket_definitions enable row level security;
alter table public.allocation_policy_versions enable row level security;
alter table public.allocation_policy_rules enable row level security;
alter table public.tenant_active_allocation_policies enable row level security;

revoke all on table public.wallets, public.pocket_definitions,
  public.allocation_policy_versions, public.allocation_policy_rules,
  public.tenant_active_allocation_policies
  from anon, authenticated;

grant select on table public.wallets, public.pocket_definitions,
  public.allocation_policy_versions, public.allocation_policy_rules,
  public.tenant_active_allocation_policies
  to authenticated;
