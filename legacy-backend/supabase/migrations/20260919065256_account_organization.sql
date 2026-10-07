create table public.user_accounts (
  user_id uuid primary key references auth.users (id) on delete restrict,
  public_uid text not null unique default public.generate_public_uid(),
  status public.account_status not null default 'active',
  authz_version bigint not null default 0 check (authz_version >= 0),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);

create table public.user_profiles (
  user_id uuid primary key references public.user_accounts (user_id) on delete restrict,
  display_name text,
  first_name text,
  last_name text,
  phone_e164 text,
  timezone text,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);

create table public.tenants (
  id uuid primary key default extensions.gen_random_uuid(),
  name text not null check (length(btrim(name)) > 0),
  status public.tenant_status not null default 'active',
  authz_version bigint not null default 0 check (authz_version >= 0),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);

create table public.offices (
  id uuid primary key default extensions.gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  parent_office_id uuid,
  office_type public.office_type not null,
  name text not null check (length(btrim(name)) > 0),
  status public.office_status not null default 'active',
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (tenant_id, id),
  foreign key (tenant_id, parent_office_id)
    references public.offices (tenant_id, id)
    on delete restrict,
  check (parent_office_id is null or parent_office_id <> id),
  check ((office_type = 'world_team' and parent_office_id is null)
    or (office_type <> 'world_team' and parent_office_id is not null))
);

create table public.memberships (
  id uuid primary key default extensions.gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  office_id uuid,
  role_key public.role_key not null,
  status public.membership_status not null default 'active',
  is_primary boolean not null default false,
  starts_at timestamptz not null default clock_timestamp(),
  ended_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (tenant_id, id),
  foreign key (tenant_id, office_id)
    references public.offices (tenant_id, id)
    on delete restrict,
  check ((status = 'ended' and ended_at is not null)
    or (status <> 'ended' and ended_at is null))
);

create table public.invitations (
  id uuid primary key default extensions.gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  office_id uuid,
  role_key public.role_key not null,
  email text not null check (length(btrim(email)) > 3),
  token_digest bytea not null unique,
  status public.invitation_status not null default 'pending',
  expires_at timestamptz not null,
  accepted_user_id uuid references public.user_accounts (user_id) on delete restrict,
  accepted_membership_id uuid,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (tenant_id, id),
  foreign key (tenant_id, office_id)
    references public.offices (tenant_id, id)
    on delete restrict,
  foreign key (tenant_id, accepted_membership_id)
    references public.memberships (tenant_id, id)
    on delete restrict,
  check ((role_key = 'president_team_member' and office_id is null)
    or (role_key <> 'president_team_member' and office_id is not null)),
  check ((status = 'accepted' and accepted_user_id is not null and accepted_membership_id is not null)
    or (status <> 'accepted'))
);

create unique index memberships_one_primary_per_tenant
  on public.memberships (tenant_id, user_id)
  where is_primary;

create index memberships_tenant_user_status
  on public.memberships (tenant_id, user_id, status);

create index memberships_tenant_office_status_role
  on public.memberships (tenant_id, office_id, status, role_key);

create index offices_tenant_parent
  on public.offices (tenant_id, parent_office_id);

create index invitations_tenant_status
  on public.invitations (tenant_id, status);

create unique index invitations_one_pending_per_email
  on public.invitations (tenant_id, lower(email))
  where status = 'pending';

create or replace function public.validate_office_structure()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  parent_type public.office_type;
  parent_tenant_id uuid;
begin
  if tg_op = 'UPDATE' and old.tenant_id <> new.tenant_id then
    raise exception using
      errcode = '23514',
      message = 'office tenant cannot change';
  end if;

  if new.parent_office_id is null then
    if new.office_type <> 'world_team' then
      raise exception using
        errcode = '23514',
        message = 'only a world team office may be a tenant root';
    end if;
    return new;
  end if;

  select office_type, tenant_id
    into parent_type, parent_tenant_id
    from public.offices
   where id = new.parent_office_id;

  if parent_type is null or parent_tenant_id <> new.tenant_id then
    raise exception using
      errcode = '23503',
      message = 'office parent must belong to the same tenant';
  end if;

  if (new.office_type = 'director' and parent_type <> 'world_team')
     or (new.office_type = 'team_leader' and parent_type <> 'director')
     or new.office_type = 'world_team' then
    raise exception using
      errcode = '23514',
      message = 'office hierarchy level is invalid';
  end if;

  return new;
end;
$$;

create trigger offices_validate_structure
  before insert or update on public.offices
  for each row execute function public.validate_office_structure();

create or replace function public.validate_membership_structure()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  membership_office_type public.office_type;
  membership_office_tenant uuid;
begin
  if new.role_key = 'president_team_member' then
    if new.office_id is not null then
      raise exception using
        errcode = '23514',
        message = 'president team members are tenant-scoped and have no office';
    end if;
    return new;
  end if;

  select office_type, tenant_id
    into membership_office_type, membership_office_tenant
    from public.offices
   where id = new.office_id;

  if membership_office_type is null or membership_office_tenant <> new.tenant_id then
    raise exception using
      errcode = '23503',
      message = 'membership office must belong to the same tenant';
  end if;

  if (new.role_key = 'world_team_member' and membership_office_type <> 'world_team')
     or (new.role_key = 'director' and membership_office_type <> 'director')
     or (new.role_key = 'team_leader' and membership_office_type <> 'team_leader')
     or (new.role_key = 'member' and membership_office_type <> 'team_leader') then
    raise exception using
      errcode = '23514',
      message = 'membership role does not match office type';
  end if;

  return new;
end;
$$;

create trigger memberships_validate_structure
  before insert or update on public.memberships
  for each row execute function public.validate_membership_structure();

create trigger invitations_validate_structure
  before insert or update on public.invitations
  for each row execute function public.validate_membership_structure();

create trigger user_accounts_touch_updated_at
  before update on public.user_accounts
  for each row execute function public.touch_updated_at();

create trigger user_profiles_touch_updated_at
  before update on public.user_profiles
  for each row execute function public.touch_updated_at();

create trigger tenants_touch_updated_at
  before update on public.tenants
  for each row execute function public.touch_updated_at();

create trigger offices_touch_updated_at
  before update on public.offices
  for each row execute function public.touch_updated_at();

create trigger memberships_touch_updated_at
  before update on public.memberships
  for each row execute function public.touch_updated_at();

create trigger invitations_touch_updated_at
  before update on public.invitations
  for each row execute function public.touch_updated_at();

alter table public.user_accounts enable row level security;
alter table public.user_profiles enable row level security;
alter table public.tenants enable row level security;
alter table public.offices enable row level security;
alter table public.memberships enable row level security;
alter table public.invitations enable row level security;

revoke all on table public.user_accounts, public.user_profiles, public.tenants,
  public.offices, public.memberships, public.invitations
  from anon, authenticated;

grant select on table public.user_accounts, public.user_profiles, public.tenants,
  public.offices, public.memberships to authenticated;
grant update on table public.user_profiles to authenticated;
