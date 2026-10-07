create table tenant_config.brand_asset_upload_intents (
  id uuid primary key default extensions.gen_random_uuid(),
  idempotency_key uuid not null unique,
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  submitted_by_user_id uuid not null references public.user_accounts (user_id)
    on delete restrict,
  asset_kind text not null check (asset_kind in (
    'primary_logo', 'square_app_icon', 'light_logo', 'dark_logo'
  )),
  storage_bucket_id text not null,
  storage_object_path text not null,
  mime_type text not null check (mime_type in (
    'image/png', 'image/jpeg', 'image/webp', 'image/svg+xml'
  )),
  file_size_bytes bigint not null check (file_size_bytes between 1 and 5242880),
  sha256 bytea not null check (octet_length(sha256) = 32),
  width_pixels integer check (width_pixels is null or width_pixels > 0),
  height_pixels integer check (height_pixels is null or height_pixels > 0),
  status evidence.upload_intent_status not null default 'pending',
  expires_at timestamptz not null,
  finalized_asset_id uuid references tenant_config.brand_assets (id)
    on delete restrict,
  finalized_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  unique (storage_bucket_id, storage_object_path),
  check ((status = 'finalized' and finalized_asset_id is not null
      and finalized_at is not null)
    or (status <> 'finalized' and finalized_asset_id is null
      and finalized_at is null))
);

create index brand_asset_upload_intents_tenant_created
  on tenant_config.brand_asset_upload_intents (tenant_id, created_at desc);
create index brand_asset_upload_intents_expiry
  on tenant_config.brand_asset_upload_intents (expires_at)
  where status = 'pending';

insert into storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
)
values (
  'tenant-brand-assets',
  'tenant-brand-assets',
  false,
  5242880,
  array['image/png', 'image/jpeg', 'image/webp', 'image/svg+xml']::text[]
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

create or replace function tenant_config.request_brand_asset_upload(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_asset_kind text,
  p_mime_type text,
  p_file_size_bytes bigint,
  p_sha256_hex text,
  p_width_pixels integer,
  p_height_pixels integer
)
returns tenant_config.brand_asset_upload_intents
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_intent tenant_config.brand_asset_upload_intents%rowtype;
  decision authz.authorization_decision;
  new_intent tenant_config.brand_asset_upload_intents%rowtype;
begin
  if p_idempotency_key is null or p_actor_user_id is null
     or p_session_id is null or p_tenant_id is null
     or p_asset_kind not in (
       'primary_logo', 'square_app_icon', 'light_logo', 'dark_logo'
     )
     or p_mime_type not in (
       'image/png', 'image/jpeg', 'image/webp', 'image/svg+xml'
     )
     or p_file_size_bytes is null
     or p_file_size_bytes not between 1 and 5242880
     or p_sha256_hex is null
     or p_sha256_hex !~ '^[0-9A-Fa-f]{64}$'
     or (p_width_pixels is not null and p_width_pixels <= 0)
     or (p_height_pixels is not null and p_height_pixels <= 0) then
    raise exception using errcode = '22023',
      message = 'brand asset upload input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501',
      message = 'brand asset upload actor mismatch';
  end if;

  request_fingerprint := tenant_config.request_fingerprint(
    'request_brand_asset_upload',
    pg_catalog.jsonb_build_object(
      'tenant_id', p_tenant_id,
      'asset_kind', p_asset_kind,
      'mime_type', p_mime_type,
      'file_size_bytes', p_file_size_bytes,
      'sha256_hex', lower(p_sha256_hex),
      'width_pixels', p_width_pixels,
      'height_pixels', p_height_pixels
    )
  );

  select intent.* into existing_intent
    from tenant_config.brand_asset_upload_intents intent
   where intent.idempotency_key = p_idempotency_key;
  if found then
    if existing_intent.tenant_id <> p_tenant_id
       or existing_intent.submitted_by_user_id <> p_actor_user_id
       or tenant_config.request_fingerprint(
         'request_brand_asset_upload',
         pg_catalog.jsonb_build_object(
           'tenant_id', existing_intent.tenant_id,
           'asset_kind', existing_intent.asset_kind,
           'mime_type', existing_intent.mime_type,
           'file_size_bytes', existing_intent.file_size_bytes,
           'sha256_hex', encode(existing_intent.sha256, 'hex'),
           'width_pixels', existing_intent.width_pixels,
           'height_pixels', existing_intent.height_pixels
         )
       ) <> request_fingerprint then
      raise exception using errcode = '23505',
        message = 'idempotency key already used with different asset upload data';
    end if;
    return existing_intent;
  end if;

  decision := authz.authorize(
    p_actor_user_id, p_session_id, 'manage_tenant_configuration', p_tenant_id,
    null, null, null, null, null, 'request_brand_asset_upload', null
  );
  if decision.decision <> 'ALLOW' then
    insert into authz.security_audit_events (
      actor_user_id, session_id, tenant_id, event_type, permission_key,
      allowed, source, source_id, reason_code, metadata
    ) values (
      p_actor_user_id, p_session_id, p_tenant_id,
      'brand_asset_upload_request_denied', 'manage_tenant_configuration', false,
      decision.source, decision.source_id, decision.reason_code, '{}'::jsonb
    );
    raise exception using errcode = '42501', message = decision.reason_code;
  end if;

  insert into tenant_config.brand_asset_upload_intents (
    idempotency_key, tenant_id, submitted_by_user_id, asset_kind,
    storage_bucket_id, storage_object_path, mime_type, file_size_bytes, sha256,
    width_pixels, height_pixels, expires_at
  ) values (
    p_idempotency_key, p_tenant_id, p_actor_user_id, p_asset_kind,
    'tenant-brand-assets',
    p_tenant_id::text || '/' || extensions.gen_random_uuid()::text,
    p_mime_type, p_file_size_bytes, decode(lower(p_sha256_hex), 'hex'),
    p_width_pixels, p_height_pixels, clock_timestamp() + interval '15 minutes'
  ) returning * into new_intent;

  return new_intent;
end;
$$;

create or replace function tenant_config.finalize_brand_asset_upload(
  p_intent_id uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_verified_file_size_bytes bigint,
  p_verified_sha256_hex text
)
returns tenant_config.brand_assets
language plpgsql
security definer
set search_path = ''
as $$
declare
  intent tenant_config.brand_asset_upload_intents%rowtype;
  new_asset tenant_config.brand_assets%rowtype;
begin
  if p_intent_id is null or p_actor_user_id is null or p_session_id is null
     or p_verified_file_size_bytes is null
     or p_verified_sha256_hex is null
     or p_verified_sha256_hex !~ '^[0-9A-Fa-f]{64}$' then
    raise exception using errcode = '22023',
      message = 'brand asset finalization input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501',
      message = 'brand asset finalization actor mismatch';
  end if;

  select upload.* into intent
    from tenant_config.brand_asset_upload_intents upload
   where upload.id = p_intent_id
   for update;
  if not found then
    raise exception using errcode = 'P0002',
      message = 'brand asset upload intent was not found';
  end if;

  if intent.submitted_by_user_id <> p_actor_user_id then
    raise exception using errcode = '42501',
      message = 'only the upload submitter may finalize the brand asset';
  end if;
  if intent.status = 'finalized' then
    select asset.* into new_asset
      from tenant_config.brand_assets asset
     where asset.id = intent.finalized_asset_id;
    return new_asset;
  end if;
  if intent.status <> 'pending' or intent.expires_at <= clock_timestamp() then
    raise exception using errcode = '55000',
      message = 'brand asset upload intent is no longer pending';
  end if;
  if p_verified_file_size_bytes <> intent.file_size_bytes
     or lower(p_verified_sha256_hex) <> encode(intent.sha256, 'hex') then
    raise exception using errcode = '23514',
      message = 'uploaded brand asset does not match its upload intent';
  end if;

  select * into new_asset
    from tenant_config.register_brand_asset(
      intent.idempotency_key,
      p_actor_user_id,
      p_session_id,
      intent.tenant_id,
      intent.asset_kind,
      intent.storage_object_path,
      intent.mime_type,
      intent.file_size_bytes,
      encode(intent.sha256, 'hex'),
      intent.width_pixels,
      intent.height_pixels
    );

  update tenant_config.brand_asset_upload_intents
     set status = 'finalized',
         finalized_asset_id = new_asset.id,
         finalized_at = clock_timestamp()
   where id = intent.id;

  return new_asset;
end;
$$;

alter table tenant_config.brand_asset_upload_intents enable row level security;
alter table tenant_config.brand_asset_upload_intents force row level security;

create policy brand_asset_upload_intents_private_deny
  on tenant_config.brand_asset_upload_intents as restrictive for all to public
  using (false) with check (false);

revoke all on table tenant_config.brand_asset_upload_intents
  from public, anon, authenticated, service_role;
revoke all on function tenant_config.request_brand_asset_upload(
  uuid, uuid, uuid, uuid, text, text, bigint, text, integer, integer
) from public, anon, authenticated, service_role;
revoke all on function tenant_config.finalize_brand_asset_upload(
  uuid, uuid, uuid, bigint, text
) from public, anon, authenticated, service_role;
grant usage on schema tenant_config to service_role;
grant execute on function tenant_config.request_brand_asset_upload(
  uuid, uuid, uuid, uuid, text, text, bigint, text, integer, integer
) to service_role;
grant execute on function tenant_config.finalize_brand_asset_upload(
  uuid, uuid, uuid, bigint, text
) to service_role;
