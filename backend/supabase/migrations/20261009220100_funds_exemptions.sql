-- Blueprint 22 — B3: "funds not managed" for a director membership. The
-- history is the rows themselves: one open row per membership while the
-- switch is on; clearing it writes the "cleared" columns once. Commands and
-- effects follow in 20261009220300.

create table org.funds_exemptions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  membership_id uuid not null references org.memberships (id) on delete restrict,
  user_id uuid not null references identity.accounts (user_id) on delete restrict,
  set_by uuid not null references identity.accounts (user_id) on delete restrict,
  set_reason text not null check (length(btrim(set_reason)) between 3 and 500),
  set_at timestamptz not null default now(),
  cleared_by uuid references identity.accounts (user_id) on delete restrict,
  cleared_reason text check (cleared_reason is null or length(btrim(cleared_reason)) between 3 and 500),
  cleared_at timestamptz,
  check ((cleared_at is null) = (cleared_by is null)),
  check ((cleared_at is null) = (cleared_reason is null)),
  check (cleared_at is null or cleared_at >= set_at)
);

create unique index funds_exemptions_open_idx on org.funds_exemptions (membership_id) where cleared_at is null;
create index funds_exemptions_tenant_idx on org.funds_exemptions (tenant_id, set_at desc);
create index funds_exemptions_user_idx on org.funds_exemptions (user_id);

alter table org.funds_exemptions enable row level security;
revoke all on table org.funds_exemptions from public, anon, authenticated;

-- Identity and "set" columns never change; the "cleared" columns are written
-- once; nothing is deleted.
create function org.guard_funds_exemption()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE'
    or new.id is distinct from old.id
    or new.tenant_id is distinct from old.tenant_id
    or new.membership_id is distinct from old.membership_id
    or new.user_id is distinct from old.user_id
    or new.set_by is distinct from old.set_by
    or new.set_reason is distinct from old.set_reason
    or new.set_at is distinct from old.set_at
    or old.cleared_at is not null then
    raise exception using errcode = 'P0001', message = 'invariant_violation',
      detail = jsonb_build_object('table', 'org.funds_exemptions')::text;
  end if;
  return new;
end;
$$;

create trigger funds_exemptions_guard
before update or delete on org.funds_exemptions
for each row execute function org.guard_funds_exemption();

create trigger funds_exemptions_no_truncate
before truncate on org.funds_exemptions
for each statement execute function audit.reject_change();

-- Is this membership's money unmanaged (switch on)?
create function org.funds_not_managed(p_membership_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from org.funds_exemptions e
    where e.membership_id = p_membership_id and e.cleared_at is null
  );
$$;

revoke all on function org.guard_funds_exemption() from public, anon, authenticated;
revoke all on function org.funds_not_managed(uuid) from public, anon, authenticated;
