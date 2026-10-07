create type evidence.upload_intent_status as enum (
  'pending',
  'finalized',
  'expired',
  'cancelled'
);

create table evidence.financial_upload_intents (
  id uuid primary key default extensions.gen_random_uuid(),
  idempotency_key uuid not null unique,
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  target_type text not null check (target_type in (
    'income_record',
    'currency_conversion_revision',
    'administrative_adjustment_revision',
    'returned_fund_revision'
  )),
  target_id uuid not null,
  evidence_type text not null check (evidence_type in (
    'income',
    'currency_conversion',
    'administrative_adjustment',
    'returned_funds'
  )),
  submitted_by_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  storage_bucket_id text not null,
  storage_object_path text not null,
  original_filename text not null check (
    length(btrim(original_filename)) between 1 and 255
  ),
  mime_type text not null check (mime_type in (
    'application/pdf',
    'image/jpeg',
    'image/png'
  )),
  file_size_bytes bigint not null check (file_size_bytes between 1 and 52428800),
  sha256 bytea not null check (octet_length(sha256) = 32),
  status evidence.upload_intent_status not null default 'pending',
  expires_at timestamptz not null,
  finalized_evidence_id uuid references evidence.financial_evidence (id)
    on delete restrict,
  finalized_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  unique (storage_bucket_id, storage_object_path),
  check ((status = 'finalized' and finalized_evidence_id is not null
      and finalized_at is not null)
    or (status <> 'finalized' and finalized_evidence_id is null
      and finalized_at is null))
);

create index financial_upload_intents_tenant_created
  on evidence.financial_upload_intents (tenant_id, created_at desc);
create index financial_upload_intents_expiry
  on evidence.financial_upload_intents (expires_at)
  where status = 'pending';

insert into storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
)
values (
  'financial-evidence',
  'financial-evidence',
  false,
  52428800,
  array['application/pdf', 'image/jpeg', 'image/png']::text[]
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

create or replace function evidence.resolve_financial_operation_target(
  p_target_type text,
  p_target_id uuid
)
returns table(tenant_id uuid, submitter_user_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_target_type = 'income_record' then
    return query
      select operation.tenant_id, operation.recorded_by_user_id
        from financial_ops.income_records operation
       where operation.id = p_target_id;
  elsif p_target_type = 'currency_conversion_revision' then
    return query
      select operation.tenant_id, operation.submitted_by_user_id
        from financial_ops.currency_conversion_revisions revision
        join financial_ops.currency_conversions operation
          on operation.id = revision.currency_conversion_id
       where revision.id = p_target_id;
  elsif p_target_type = 'administrative_adjustment_revision' then
    return query
      select operation.tenant_id, operation.submitted_by_user_id
        from financial_ops.administrative_adjustment_revisions revision
        join financial_ops.administrative_adjustments operation
          on operation.id = revision.administrative_adjustment_id
       where revision.id = p_target_id;
  elsif p_target_type = 'returned_fund_revision' then
    return query
      select operation.tenant_id, operation.submitted_by_user_id
        from financial_ops.returned_fund_revisions revision
        join financial_ops.returned_funds operation
          on operation.id = revision.returned_fund_id
       where revision.id = p_target_id;
  else
    raise exception using errcode = '22023',
      message = 'financial evidence target type is invalid';
  end if;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'financial evidence target was not found';
  end if;
end;
$$;

create or replace function evidence.financial_upload_request_fingerprint(
  p_target_type text,
  p_target_id uuid,
  p_evidence_type text,
  p_original_filename text,
  p_mime_type text,
  p_file_size_bytes bigint,
  p_sha256_hex text
)
returns bytea
language sql
immutable
security invoker
set search_path = ''
as $$
  select extensions.digest(
    pg_catalog.jsonb_build_object(
      'target_type', p_target_type,
      'target_id', p_target_id,
      'evidence_type', p_evidence_type,
      'original_filename', p_original_filename,
      'mime_type', p_mime_type,
      'file_size_bytes', p_file_size_bytes,
      'sha256_hex', p_sha256_hex
    )::text,
    'sha256'
  );
$$;

create or replace function evidence.request_financial_evidence_upload(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_target_type text,
  p_target_id uuid,
  p_evidence_type text,
  p_original_filename text,
  p_mime_type text,
  p_file_size_bytes bigint,
  p_sha256_hex text
)
returns evidence.financial_upload_intents
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_intent evidence.financial_upload_intents%rowtype;
  target_tenant_id uuid;
  target_submitter_user_id uuid;
  new_intent evidence.financial_upload_intents%rowtype;
begin
  if p_idempotency_key is null or p_actor_user_id is null
     or p_target_id is null or p_evidence_type is null
     or p_original_filename is null or p_mime_type is null
     or p_file_size_bytes is null or p_sha256_hex is null
     or p_sha256_hex !~ '^[0-9A-Fa-f]{64}$'
     or p_file_size_bytes not between 1 and 52428800
     or length(btrim(p_original_filename)) not between 1 and 255
     or p_mime_type not in ('application/pdf', 'image/jpeg', 'image/png') then
    raise exception using errcode = '22023',
      message = 'financial evidence upload input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501',
      message = 'financial evidence upload actor mismatch';
  end if;

  if (p_evidence_type = 'income' and p_target_type <> 'income_record')
     or (p_evidence_type = 'currency_conversion'
       and p_target_type <> 'currency_conversion_revision')
     or (p_evidence_type = 'administrative_adjustment'
       and p_target_type <> 'administrative_adjustment_revision')
     or (p_evidence_type = 'returned_funds'
       and p_target_type <> 'returned_fund_revision') then
    raise exception using errcode = '23514',
      message = 'financial evidence type does not match its target';
  end if;

  request_fingerprint := evidence.financial_upload_request_fingerprint(
    p_target_type, p_target_id, p_evidence_type, btrim(p_original_filename),
    p_mime_type, p_file_size_bytes, lower(p_sha256_hex)
  );

  select intent.* into existing_intent
    from evidence.financial_upload_intents intent
   where intent.idempotency_key = p_idempotency_key;
  if found then
    if existing_intent.tenant_id is null
       or existing_intent.target_type <> p_target_type
       or existing_intent.target_id <> p_target_id
       or existing_intent.evidence_type <> p_evidence_type
       or existing_intent.submitted_by_user_id <> p_actor_user_id
       or evidence.financial_upload_request_fingerprint(
         existing_intent.target_type, existing_intent.target_id,
         existing_intent.evidence_type, existing_intent.original_filename,
         existing_intent.mime_type, existing_intent.file_size_bytes,
         encode(existing_intent.sha256, 'hex')
       ) <> request_fingerprint then
      raise exception using errcode = '23505',
        message = 'idempotency key already used with different upload data';
    end if;
    return existing_intent;
  end if;

  select target.tenant_id, target.submitter_user_id
    into target_tenant_id, target_submitter_user_id
    from evidence.resolve_financial_operation_target(p_target_type, p_target_id)
      target;

  if target_submitter_user_id <> p_actor_user_id then
    raise exception using errcode = '42501',
      message = 'only the operation submitter may upload its evidence';
  end if;

  insert into evidence.financial_upload_intents (
    idempotency_key, tenant_id, target_type, target_id, evidence_type,
    submitted_by_user_id, storage_bucket_id, storage_object_path,
    original_filename, mime_type, file_size_bytes, sha256, expires_at
  ) values (
    p_idempotency_key, target_tenant_id, p_target_type, p_target_id,
    p_evidence_type, p_actor_user_id, 'financial-evidence',
    target_tenant_id::text || '/' || extensions.gen_random_uuid()::text,
    btrim(p_original_filename), p_mime_type, p_file_size_bytes,
    decode(lower(p_sha256_hex), 'hex'), clock_timestamp() + interval '15 minutes'
  ) returning * into new_intent;

  return new_intent;
end;
$$;

create or replace function evidence.finalize_financial_evidence_upload(
  p_intent_id uuid,
  p_actor_user_id uuid,
  p_verified_file_size_bytes bigint,
  p_verified_sha256_hex text,
  p_observed_at timestamptz,
  p_provider text default null,
  p_provider_reference text default null,
  p_notes text default null
)
returns evidence.financial_evidence
language plpgsql
security definer
set search_path = ''
as $$
declare
  intent evidence.financial_upload_intents%rowtype;
  target_evidence evidence.financial_evidence%rowtype;
  attached_count integer;
begin
  if p_intent_id is null or p_actor_user_id is null
     or p_verified_file_size_bytes is null
     or p_verified_sha256_hex !~ '^[0-9A-Fa-f]{64}$'
     or p_observed_at is null then
    raise exception using errcode = '22023',
      message = 'financial evidence finalization input is invalid';
  end if;

  select upload.* into intent
    from evidence.financial_upload_intents upload
   where upload.id = p_intent_id
   for update;
  if not found then
    raise exception using errcode = 'P0002',
      message = 'financial evidence upload intent was not found';
  end if;

  if intent.submitted_by_user_id <> p_actor_user_id then
    raise exception using errcode = '42501',
      message = 'only the upload submitter may finalize evidence';
  end if;
  if intent.status = 'finalized' then
    select evidence.* into target_evidence
      from evidence.financial_evidence evidence
     where evidence.id = intent.finalized_evidence_id;
    return target_evidence;
  end if;
  if intent.status <> 'pending' or intent.expires_at <= clock_timestamp() then
    update evidence.financial_upload_intents
       set status = case when status = 'pending' then 'expired' else status end
     where id = intent.id;
    raise exception using errcode = '40901',
      message = 'financial evidence upload intent is no longer valid';
  end if;

  if p_verified_file_size_bytes <> intent.file_size_bytes
     or decode(lower(p_verified_sha256_hex), 'hex') <> intent.sha256 then
    raise exception using errcode = '23514',
      message = 'uploaded object metadata does not match the upload intent';
  end if;

  select evidence.attach_financial_operation_evidence(
    intent.tenant_id,
    p_actor_user_id,
    intent.evidence_type,
    intent.target_type,
    intent.target_id,
    pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'storage_bucket_id', intent.storage_bucket_id,
        'storage_object_path', intent.storage_object_path,
        'original_filename', intent.original_filename,
        'mime_type', intent.mime_type,
        'file_size_bytes', intent.file_size_bytes,
        'sha256_hex', encode(intent.sha256, 'hex'),
        'observed_at', p_observed_at,
        'provider', p_provider,
        'provider_reference', p_provider_reference,
        'notes', p_notes
      )
    )
  ) into attached_count;

  if attached_count <> 1 then
    raise exception using errcode = 'XX000',
      message = 'financial evidence upload finalization failed';
  end if;

  select evidence.* into target_evidence
    from evidence.financial_evidence evidence
   where evidence.storage_bucket_id = intent.storage_bucket_id
     and evidence.storage_object_path = intent.storage_object_path;

  update evidence.financial_upload_intents
     set status = 'finalized', finalized_evidence_id = target_evidence.id,
         finalized_at = clock_timestamp()
   where id = intent.id;

  return target_evidence;
end;
$$;

alter table evidence.financial_upload_intents enable row level security;
alter table evidence.financial_upload_intents force row level security;

create policy financial_upload_intents_private_deny
  on evidence.financial_upload_intents as restrictive for all to public
  using (false) with check (false);

revoke all on table evidence.financial_upload_intents
  from public, anon, authenticated, service_role;
revoke all on function evidence.resolve_financial_operation_target(text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function evidence.financial_upload_request_fingerprint(
  text, uuid, text, text, text, bigint, text
) from public, anon, authenticated, service_role;
revoke all on function evidence.request_financial_evidence_upload(
  uuid, uuid, text, uuid, text, text, text, bigint, text
) from public, anon, authenticated;
revoke all on function evidence.finalize_financial_evidence_upload(
  uuid, uuid, bigint, text, timestamptz, text, text, text
) from public, anon, authenticated;
grant execute on function evidence.request_financial_evidence_upload(
  uuid, uuid, text, uuid, text, text, text, bigint, text
) to service_role;
grant execute on function evidence.finalize_financial_evidence_upload(
  uuid, uuid, bigint, text, timestamptz, text, text, text
) to service_role;

comment on table evidence.financial_upload_intents is
  'Private short-lived upload grants. Tenant ownership is derived from the financial operation target.';
