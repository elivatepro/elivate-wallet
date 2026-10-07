create schema tenant_config;

create type tenant_config.asset_status as enum ('active', 'retired');

create table tenant_config.brand_assets (
  id uuid primary key default extensions.gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  asset_kind text not null check (asset_kind in (
    'primary_logo', 'square_app_icon', 'light_logo', 'dark_logo'
  )),
  storage_object_path text not null check (
    storage_object_path like tenant_id::text || '/%'
  ),
  mime_type text not null check (
    mime_type in ('image/png', 'image/jpeg', 'image/webp', 'image/svg+xml')
  ),
  byte_size bigint not null check (byte_size > 0 and byte_size <= 5242880),
  checksum_sha256 text not null check (checksum_sha256 ~ '^[0-9a-f]{64}$'),
  width_pixels integer check (width_pixels is null or width_pixels > 0),
  height_pixels integer check (height_pixels is null or height_pixels > 0),
  status tenant_config.asset_status not null default 'active',
  created_by_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  unique (tenant_id, id)
);

create index brand_assets_tenant_kind_status
  on tenant_config.brand_assets (tenant_id, asset_kind, status, created_at desc);

create table tenant_config.configuration_revisions (
  id uuid primary key default extensions.gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  revision_number integer not null check (revision_number > 0),
  team_display_name text not null check (
    length(btrim(team_display_name)) between 1 and 120
  ),
  team_short_name text check (
    team_short_name is null or length(btrim(team_short_name)) between 1 and 40
  ),
  support_contact_name text check (
    support_contact_name is null or length(btrim(support_contact_name)) between 1 and 120
  ),
  support_contact_email text check (
    support_contact_email is null
    or support_contact_email ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
  ),
  support_contact_phone text check (
    support_contact_phone is null or length(btrim(support_contact_phone)) between 3 and 40
  ),
  locale_code text not null check (locale_code ~ '^[a-z]{2}(-[A-Z]{2})?$'),
  timezone_name text not null check (length(btrim(timezone_name)) between 1 and 80),
  primary_logo_asset_id uuid,
  square_app_icon_asset_id uuid,
  light_logo_asset_id uuid,
  dark_logo_asset_id uuid,
  theme_key text check (
    theme_key is null or theme_key ~ '^[a-z][a-z0-9_]{1,39}$'
  ),
  team_slogan text check (
    team_slogan is null or length(btrim(team_slogan)) between 1 and 80
  ),
  support_url text check (
    support_url is null or support_url ~* '^https://[^[:space:]]+$'
  ),
  revision_reason text not null check (length(btrim(revision_reason)) between 1 and 500),
  created_by_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  unique (tenant_id, revision_number),
  unique (tenant_id, id),
  foreign key (tenant_id, primary_logo_asset_id)
    references tenant_config.brand_assets (tenant_id, id) on delete restrict,
  foreign key (tenant_id, square_app_icon_asset_id)
    references tenant_config.brand_assets (tenant_id, id) on delete restrict,
  foreign key (tenant_id, light_logo_asset_id)
    references tenant_config.brand_assets (tenant_id, id) on delete restrict,
  foreign key (tenant_id, dark_logo_asset_id)
    references tenant_config.brand_assets (tenant_id, id) on delete restrict
);

create table tenant_config.active_configuration (
  tenant_id uuid primary key references public.tenants (id) on delete restrict,
  revision_id uuid not null,
  activated_at timestamptz not null default clock_timestamp(),
  foreign key (tenant_id, revision_id)
    references tenant_config.configuration_revisions (tenant_id, id) on delete restrict
);

create table public.tenant_member_branding_read (
  tenant_id uuid primary key references public.tenants (id) on delete restrict,
  revision_id uuid not null,
  revision_number integer not null check (revision_number > 0),
  team_display_name text not null,
  team_short_name text,
  primary_logo_asset_id uuid,
  square_app_icon_asset_id uuid,
  light_logo_asset_id uuid,
  dark_logo_asset_id uuid,
  theme_key text,
  team_slogan text,
  support_url text,
  refreshed_at timestamptz not null default clock_timestamp(),
  foreign key (tenant_id, revision_id)
    references tenant_config.configuration_revisions (tenant_id, id) on delete restrict
);

create index configuration_revisions_tenant_created
  on tenant_config.configuration_revisions (tenant_id, created_at desc);

create table tenant_config.command_idempotency (
  idempotency_key uuid primary key,
  command_type text not null check (command_type in (
    'register_brand_asset', 'update_team_configuration'
  )),
  request_fingerprint bytea not null check (octet_length(request_fingerprint) = 32),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  actor_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  result_id uuid not null,
  created_at timestamptz not null default clock_timestamp()
);

create index tenant_config_command_idempotency_tenant_created
  on tenant_config.command_idempotency (tenant_id, created_at desc);

create table commercial.tenant_extra_entitlements (
  id uuid primary key default extensions.gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  extra_key text not null references commercial.extra_catalog (extra_key) on delete restrict,
  starts_at timestamptz not null,
  ends_at timestamptz,
  granted_by_user_id uuid references public.user_accounts (user_id) on delete restrict,
  grant_reason text not null check (length(btrim(grant_reason)) > 0),
  created_at timestamptz not null default clock_timestamp(),
  check (ends_at is null or ends_at > starts_at),
  unique (tenant_id, extra_key, starts_at)
);

create index tenant_extra_entitlements_active
  on commercial.tenant_extra_entitlements (tenant_id, extra_key, starts_at, ends_at);

create type tenant_config.custom_domain_status as enum (
  'pending_verification', 'verified', 'active', 'revoked'
);

create table tenant_config.custom_domains (
  id uuid primary key default extensions.gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  hostname text not null check (
    hostname = lower(hostname)
    and hostname ~ '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$'
  ),
  status tenant_config.custom_domain_status not null default 'pending_verification',
  verification_token text not null check (length(btrim(verification_token)) >= 32),
  verified_at timestamptz,
  activated_at timestamptz,
  revoked_at timestamptz,
  created_by_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  unique (tenant_id, hostname),
  check ((status = 'pending_verification' and verified_at is null and activated_at is null)
    or (status = 'verified' and verified_at is not null and activated_at is null)
    or (status = 'active' and verified_at is not null and activated_at is not null)
    or (status = 'revoked' and revoked_at is not null))
);

create unique index custom_domains_one_active_per_tenant
  on tenant_config.custom_domains (tenant_id)
  where status = 'active';

create or replace function commercial.has_active_extra(
  p_tenant_id uuid,
  p_extra_key text,
  p_at timestamptz default clock_timestamp()
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from commercial.tenant_extra_entitlements entitlement
     where entitlement.tenant_id = p_tenant_id
       and entitlement.extra_key = p_extra_key
       and entitlement.starts_at <= p_at
       and (entitlement.ends_at is null or entitlement.ends_at > p_at)
  );
$$;

create or replace function tenant_config.prevent_revision_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception using errcode = '55000', message = 'configuration revisions are immutable';
end;
$$;

create trigger configuration_revisions_prevent_mutation
  before update or delete on tenant_config.configuration_revisions
  for each row execute function tenant_config.prevent_revision_mutation();

create trigger brand_assets_prevent_mutation
  before update or delete on tenant_config.brand_assets
  for each row execute function tenant_config.prevent_revision_mutation();

create or replace function tenant_config.request_fingerprint(
  p_command_type text,
  p_payload jsonb
)
returns bytea
language sql
immutable
security invoker
set search_path = ''
as $$
  select extensions.digest(
    pg_catalog.jsonb_build_object(
      'command_type', p_command_type,
      'payload', p_payload
    )::text,
    'sha256'
  );
$$;

create or replace function tenant_config.update_team_configuration(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_team_display_name text,
  p_team_short_name text,
  p_support_contact_name text,
  p_support_contact_email text,
  p_support_contact_phone text,
  p_locale_code text,
  p_timezone_name text,
  p_primary_logo_asset_id uuid,
  p_square_app_icon_asset_id uuid,
  p_light_logo_asset_id uuid,
  p_dark_logo_asset_id uuid,
  p_theme_key text,
  p_team_slogan text,
  p_support_url text,
  p_revision_reason text
)
returns tenant_config.configuration_revisions
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command tenant_config.command_idempotency%rowtype;
  decision authz.authorization_decision;
  new_revision tenant_config.configuration_revisions%rowtype;
  next_revision_number integer;
begin
  if p_idempotency_key is null or p_actor_user_id is null or p_session_id is null
     or p_tenant_id is null or p_team_display_name is null
     or p_locale_code is null or p_timezone_name is null
     or p_revision_reason is null then
    raise exception using errcode = '22023', message = 'team configuration input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'team configuration actor mismatch';
  end if;

  request_fingerprint := tenant_config.request_fingerprint(
    'update_team_configuration',
    pg_catalog.jsonb_build_object(
      'tenant_id', p_tenant_id,
      'team_display_name', p_team_display_name,
      'team_short_name', p_team_short_name,
      'support_contact_name', p_support_contact_name,
      'support_contact_email', p_support_contact_email,
      'support_contact_phone', p_support_contact_phone,
      'locale_code', p_locale_code,
      'timezone_name', p_timezone_name,
      'primary_logo_asset_id', p_primary_logo_asset_id,
      'square_app_icon_asset_id', p_square_app_icon_asset_id,
      'light_logo_asset_id', p_light_logo_asset_id,
      'dark_logo_asset_id', p_dark_logo_asset_id,
      'theme_key', p_theme_key,
      'team_slogan', p_team_slogan,
      'support_url', p_support_url,
      'revision_reason', p_revision_reason
    )
  );

  select command.* into existing_command
    from tenant_config.command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.command_type <> 'update_team_configuration'
       or existing_command.tenant_id <> p_tenant_id
       or existing_command.actor_user_id <> p_actor_user_id
       or existing_command.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '23505', message = 'idempotency key already used with different team configuration data';
    end if;

    select revision.* into new_revision
      from tenant_config.configuration_revisions revision
     where revision.id = existing_command.result_id;
    return new_revision;
  end if;

  decision := authz.authorize(
    p_actor_user_id, p_session_id, 'manage_tenant_configuration', p_tenant_id,
    null, null, null, null, null, 'update_team_configuration', null
  );

  if decision.decision <> 'ALLOW' then
    insert into authz.security_audit_events (
      actor_user_id, session_id, tenant_id, event_type, permission_key,
      allowed, source, source_id, reason_code, metadata
    ) values (
      p_actor_user_id, p_session_id, p_tenant_id, 'team_configuration_update_denied',
      'manage_tenant_configuration', false, decision.source, decision.source_id,
      decision.reason_code, '{}'::jsonb
    );
    raise exception using errcode = '42501', message = decision.reason_code;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('tenant-configuration:' || p_tenant_id::text, 0)
  );

  if exists (
    select 1
      from tenant_config.brand_assets asset
     where asset.tenant_id = p_tenant_id
       and asset.id in (
         p_primary_logo_asset_id,
         p_square_app_icon_asset_id,
         p_light_logo_asset_id,
         p_dark_logo_asset_id
       )
       and asset.status <> 'active'
  ) then
    raise exception using errcode = '23514', message = 'configuration references a retired brand asset';
  end if;

  if exists (
    select 1
      from unnest(array[
        p_primary_logo_asset_id,
        p_square_app_icon_asset_id,
        p_light_logo_asset_id,
        p_dark_logo_asset_id
      ]) asset_id
     where asset_id is not null
       and not exists (
         select 1 from tenant_config.brand_assets asset
          where asset.tenant_id = p_tenant_id and asset.id = asset_id
       )
  ) then
    raise exception using errcode = '23503', message = 'configuration asset belongs to another tenant';
  end if;

  select coalesce(max(revision_number), 0) + 1
    into next_revision_number
    from tenant_config.configuration_revisions
   where tenant_id = p_tenant_id;

  insert into tenant_config.configuration_revisions (
    tenant_id, revision_number, team_display_name, team_short_name,
    support_contact_name, support_contact_email, support_contact_phone,
    locale_code, timezone_name, primary_logo_asset_id, square_app_icon_asset_id,
    light_logo_asset_id, dark_logo_asset_id, theme_key, team_slogan, support_url,
    revision_reason, created_by_user_id
  ) values (
    p_tenant_id, next_revision_number, btrim(p_team_display_name),
    nullif(btrim(p_team_short_name), ''), nullif(btrim(p_support_contact_name), ''),
    nullif(btrim(p_support_contact_email), ''), nullif(btrim(p_support_contact_phone), ''),
    p_locale_code, btrim(p_timezone_name), p_primary_logo_asset_id,
    p_square_app_icon_asset_id, p_light_logo_asset_id, p_dark_logo_asset_id,
    nullif(btrim(p_theme_key), ''), nullif(btrim(p_team_slogan), ''),
    nullif(btrim(p_support_url), ''), btrim(p_revision_reason), p_actor_user_id
  ) returning * into new_revision;

  insert into tenant_config.active_configuration (tenant_id, revision_id)
  values (p_tenant_id, new_revision.id)
  on conflict (tenant_id) do update
    set revision_id = excluded.revision_id,
        activated_at = clock_timestamp();

  insert into public.tenant_member_branding_read (
    tenant_id, revision_id, revision_number, team_display_name, team_short_name,
    primary_logo_asset_id, square_app_icon_asset_id, light_logo_asset_id,
    dark_logo_asset_id, theme_key, team_slogan, support_url, refreshed_at
  ) values (
    new_revision.tenant_id, new_revision.id, new_revision.revision_number,
    new_revision.team_display_name, new_revision.team_short_name,
    new_revision.primary_logo_asset_id, new_revision.square_app_icon_asset_id,
    new_revision.light_logo_asset_id, new_revision.dark_logo_asset_id,
    new_revision.theme_key, new_revision.team_slogan, new_revision.support_url,
    clock_timestamp()
  )
  on conflict (tenant_id) do update
    set revision_id = excluded.revision_id,
        revision_number = excluded.revision_number,
        team_display_name = excluded.team_display_name,
        team_short_name = excluded.team_short_name,
        primary_logo_asset_id = excluded.primary_logo_asset_id,
        square_app_icon_asset_id = excluded.square_app_icon_asset_id,
        light_logo_asset_id = excluded.light_logo_asset_id,
        dark_logo_asset_id = excluded.dark_logo_asset_id,
        theme_key = excluded.theme_key,
        team_slogan = excluded.team_slogan,
        support_url = excluded.support_url,
        refreshed_at = clock_timestamp();

  insert into tenant_config.command_idempotency (
    idempotency_key, command_type, request_fingerprint, tenant_id,
    actor_user_id, result_id
  ) values (
    p_idempotency_key, 'update_team_configuration', request_fingerprint,
    p_tenant_id, p_actor_user_id, new_revision.id
  );

  insert into authz.security_audit_events (
    actor_user_id, session_id, tenant_id, event_type, permission_key,
    target_type, target_id, allowed, source, source_id, reason_code, metadata
  ) values (
    p_actor_user_id, p_session_id, p_tenant_id, 'team_configuration_updated',
    'manage_tenant_configuration', 'configuration_revision', new_revision.id,
    true, decision.source, decision.source_id, decision.reason_code,
    pg_catalog.jsonb_build_object('revision_number', new_revision.revision_number)
  );

  return new_revision;
end;
$$;

create or replace function tenant_config.register_brand_asset(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_asset_kind text,
  p_storage_object_path text,
  p_mime_type text,
  p_byte_size bigint,
  p_checksum_sha256 text,
  p_width_pixels integer,
  p_height_pixels integer
)
returns tenant_config.brand_assets
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command tenant_config.command_idempotency%rowtype;
  decision authz.authorization_decision;
  new_asset tenant_config.brand_assets%rowtype;
begin
  if p_idempotency_key is null or p_actor_user_id is null or p_session_id is null
     or p_tenant_id is null or p_asset_kind is null
     or p_storage_object_path is null or p_mime_type is null
     or p_byte_size is null or p_checksum_sha256 is null then
    raise exception using errcode = '22023', message = 'brand asset input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'brand asset actor mismatch';
  end if;

  request_fingerprint := tenant_config.request_fingerprint(
    'register_brand_asset',
    pg_catalog.jsonb_build_object(
      'tenant_id', p_tenant_id,
      'asset_kind', p_asset_kind,
      'storage_object_path', p_storage_object_path,
      'mime_type', p_mime_type,
      'byte_size', p_byte_size,
      'checksum_sha256', p_checksum_sha256,
      'width_pixels', p_width_pixels,
      'height_pixels', p_height_pixels
    )
  );

  select command.* into existing_command
    from tenant_config.command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.command_type <> 'register_brand_asset'
       or existing_command.tenant_id <> p_tenant_id
       or existing_command.actor_user_id <> p_actor_user_id
       or existing_command.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '23505', message = 'idempotency key already used with different brand asset data';
    end if;

    select asset.* into new_asset
      from tenant_config.brand_assets asset
     where asset.id = existing_command.result_id;
    return new_asset;
  end if;

  decision := authz.authorize(
    p_actor_user_id, p_session_id, 'manage_tenant_configuration', p_tenant_id,
    null, null, null, null, null, 'register_brand_asset', null
  );

  if decision.decision <> 'ALLOW' then
    insert into authz.security_audit_events (
      actor_user_id, session_id, tenant_id, event_type, permission_key,
      allowed, source, source_id, reason_code, metadata
    ) values (
      p_actor_user_id, p_session_id, p_tenant_id, 'brand_asset_registration_denied',
      'manage_tenant_configuration', false, decision.source, decision.source_id,
      decision.reason_code, '{}'::jsonb
    );
    raise exception using errcode = '42501', message = decision.reason_code;
  end if;

  insert into tenant_config.brand_assets (
    tenant_id, asset_kind, storage_object_path, mime_type, byte_size,
    checksum_sha256, width_pixels, height_pixels, created_by_user_id
  ) values (
    p_tenant_id, p_asset_kind, p_storage_object_path, p_mime_type, p_byte_size,
    lower(p_checksum_sha256), p_width_pixels, p_height_pixels, p_actor_user_id
  ) returning * into new_asset;

  insert into tenant_config.command_idempotency (
    idempotency_key, command_type, request_fingerprint, tenant_id,
    actor_user_id, result_id
  ) values (
    p_idempotency_key, 'register_brand_asset', request_fingerprint,
    p_tenant_id, p_actor_user_id, new_asset.id
  );

  insert into authz.security_audit_events (
    actor_user_id, session_id, tenant_id, event_type, permission_key,
    target_type, target_id, allowed, source, source_id, reason_code, metadata
  ) values (
    p_actor_user_id, p_session_id, p_tenant_id, 'brand_asset_registered',
    'manage_tenant_configuration', 'brand_asset', new_asset.id, true,
    decision.source, decision.source_id, decision.reason_code,
    pg_catalog.jsonb_build_object('asset_kind', new_asset.asset_kind)
  );

  return new_asset;
end;
$$;

insert into authz.permission_catalog (
  permission_key, area, protected, grantable, wallet_holder_baseline,
  can_target_own_wallet, default_scope_mode, step_up_mode
)
values
  ('manage_tenant_configuration', 'Tenant Admin', true, false, false, false, 'entire_tenant', 'elevated')
on conflict (permission_key) do nothing;

insert into authz.default_role_permissions (role_key, permission_key)
values ('president_team_member', 'manage_tenant_configuration')
on conflict do nothing;

alter table tenant_config.brand_assets enable row level security;
alter table tenant_config.configuration_revisions enable row level security;
alter table tenant_config.active_configuration enable row level security;
alter table tenant_config.command_idempotency enable row level security;
alter table commercial.tenant_extra_entitlements enable row level security;
alter table tenant_config.custom_domains enable row level security;
alter table public.tenant_member_branding_read enable row level security;

alter table tenant_config.brand_assets force row level security;
alter table tenant_config.configuration_revisions force row level security;
alter table tenant_config.active_configuration force row level security;
alter table tenant_config.command_idempotency force row level security;
alter table commercial.tenant_extra_entitlements force row level security;
alter table tenant_config.custom_domains force row level security;
alter table public.tenant_member_branding_read force row level security;

create policy tenant_config_brand_assets_private_deny
  on tenant_config.brand_assets as restrictive for all to public
  using (false) with check (false);
create policy tenant_config_revisions_private_deny
  on tenant_config.configuration_revisions as restrictive for all to public
  using (false) with check (false);
create policy tenant_config_active_private_deny
  on tenant_config.active_configuration as restrictive for all to public
  using (false) with check (false);
create policy tenant_config_idempotency_private_deny
  on tenant_config.command_idempotency as restrictive for all to public
  using (false) with check (false);
create policy tenant_extra_entitlements_private_deny
  on commercial.tenant_extra_entitlements as restrictive for all to public
  using (false) with check (false);
create policy tenant_custom_domains_private_deny
  on tenant_config.custom_domains as restrictive for all to public
  using (false) with check (false);
create policy tenant_member_branding_read_member_select
  on public.tenant_member_branding_read for select to authenticated
  using ((select authz.is_active_member_in_tenant(tenant_id)));
create policy tenant_member_branding_read_no_insert
  on public.tenant_member_branding_read as restrictive for insert to authenticated
  with check (false);
create policy tenant_member_branding_read_no_update
  on public.tenant_member_branding_read as restrictive for update to authenticated
  using (false) with check (false);
create policy tenant_member_branding_read_no_delete
  on public.tenant_member_branding_read as restrictive for delete to authenticated
  using (false);

revoke all on schema tenant_config from public, anon, authenticated, service_role;
revoke all on all tables in schema tenant_config from public, anon, authenticated, service_role;
revoke all on all sequences in schema tenant_config from public, anon, authenticated, service_role;
revoke all on all functions in schema tenant_config from public, anon, authenticated, service_role;
revoke all on table commercial.tenant_extra_entitlements from public, anon, authenticated, service_role;
revoke all on function commercial.has_active_extra(uuid, text, timestamptz) from public, anon, authenticated, service_role;
revoke all on function tenant_config.update_team_configuration(
  uuid, uuid, uuid, uuid, text, text, text, text, text, text, text,
  uuid, uuid, uuid, uuid, text, text, text, text
) from public, anon;
grant execute on function tenant_config.update_team_configuration(
  uuid, uuid, uuid, uuid, text, text, text, text, text, text, text,
  uuid, uuid, uuid, uuid, text, text, text, text
) to authenticated;
revoke all on function tenant_config.register_brand_asset(
  uuid, uuid, uuid, uuid, text, text, text, bigint, text, integer, integer
) from public, anon;
grant execute on function tenant_config.register_brand_asset(
  uuid, uuid, uuid, uuid, text, text, text, bigint, text, integer, integer
) to authenticated;
grant select on public.tenant_member_branding_read to authenticated;
revoke insert, update, delete on public.tenant_member_branding_read from public, anon, authenticated;

insert into commercial.extra_catalog (extra_key, display_name)
values ('white_label_domain', 'White-label domain')
on conflict (extra_key) do nothing;

comment on schema tenant_config is
  'Private tenant-owned configuration, branding asset metadata, immutable revisions, and custom-domain state.';
comment on table tenant_config.brand_assets is
  'Private asset metadata. Storage object paths are never exposed as a client-facing contract.';
comment on table tenant_config.configuration_revisions is
  'Immutable team configuration revisions. Product-facing terms use Team, not Brand, for tenant identity.';
comment on table tenant_config.custom_domains is
  'Optional paid white-label domain state. DNS verification and activation remain trusted operational actions.';
