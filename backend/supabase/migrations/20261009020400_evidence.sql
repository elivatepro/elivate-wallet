-- Blueprint 04 — income receipts (E-01, W-08 step 2, owner decision 20):
-- private bucket, server-built paths, signed single-object uploads, byte
-- verification (size, SHA-256, type by magic bytes) before use.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('financial-evidence', 'financial-evidence', false, 10485760,
  array['application/pdf', 'image/jpeg', 'image/png']::text[])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

create function evidence.max_size() returns int
language sql immutable set search_path = '' as $$ select 10485760 $$;
create function evidence.upload_ttl() returns interval
language sql immutable set search_path = '' as $$ select interval '2 hours' $$;
create function evidence.max_open_per_command() returns int
language sql immutable set search_path = '' as $$ select 10 $$;

create table evidence.files (
  id uuid primary key,
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  purpose text not null check (purpose in ('income')),
  uploaded_by uuid not null references identity.accounts (user_id) on delete restrict,
  target_membership_id uuid not null references org.memberships (id) on delete restrict,
  command_key text not null check (command_key ~ '^[A-Za-z0-9_-]{16,100}$'),
  object_path text not null unique
    check (object_path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[a-z_]+/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
  declared_name text not null check (length(btrim(declared_name)) between 1 and 200),
  declared_mime text not null check (declared_mime in ('application/pdf', 'image/jpeg', 'image/png')),
  declared_size int not null check (declared_size between 1 and 10485760),
  declared_sha256 text not null check (declared_sha256 ~ '^[0-9a-f]{64}$'),
  size int check (size between 1 and 10485760),
  sha256 text check (sha256 ~ '^[0-9a-f]{64}$'),
  mime text check (mime in ('application/pdf', 'image/jpeg', 'image/png')),
  status text not null default 'pending'
    check (status in ('pending', 'finalized', 'attached', 'expired', 'cancelled')),
  expires_at timestamptz not null,
  attached_type text check (attached_type in ('income')),
  attached_id uuid,
  created_at timestamptz not null default now(),
  finalized_at timestamptz,
  settled_at timestamptz,
  check (status not in ('finalized', 'attached')
    or (finalized_at is not null and size is not null and sha256 is not null and mime is not null)),
  check ((status = 'attached') = (attached_type is not null and attached_id is not null)),
  check ((status in ('pending', 'finalized')) = (settled_at is null))
);

create index files_command_idx on evidence.files (uploaded_by, command_key);
create index files_attached_idx on evidence.files (attached_type, attached_id);
create index files_tenant_idx on evidence.files (tenant_id, created_at desc);
create index files_target_idx on evidence.files (target_membership_id);

-- pending → finalized → attached; pending/finalized → expired | cancelled.
-- Bindings never change; settled rows are immutable.
create function evidence.guard_file()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not (
      (old.status = 'pending' and new.status in ('finalized', 'expired', 'cancelled'))
      or (old.status = 'finalized' and new.status in ('attached', 'expired', 'cancelled'))
    )
    or new.id <> old.id or new.tenant_id <> old.tenant_id or new.purpose <> old.purpose
    or new.uploaded_by <> old.uploaded_by or new.target_membership_id <> old.target_membership_id
    or new.command_key <> old.command_key or new.object_path <> old.object_path
    or new.declared_name <> old.declared_name or new.declared_mime <> old.declared_mime
    or new.declared_size <> old.declared_size or new.declared_sha256 <> old.declared_sha256
    or new.expires_at <> old.expires_at or new.created_at <> old.created_at
    or (old.status = 'finalized' and (new.size <> old.size or new.sha256 <> old.sha256 or new.mime <> old.mime)) then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'evidence.files'));
  end if;
  if new.status = 'finalized' then
    new.finalized_at := now();
  elsif new.status <> 'finalized' then
    new.settled_at := now();
  end if;
  return new;
end;
$$;

create trigger files_guard
before update on evidence.files
for each row execute function evidence.guard_file();
create trigger files_no_delete
before delete on evidence.files
for each row execute function audit.reject_change();
create trigger files_no_truncate
before truncate on evidence.files
for each statement execute function audit.reject_change();

alter table evidence.files enable row level security;

-- The uploader's own file in this workspace's network; its target must
-- still be one the actor may record income for.
create function evidence.require_own_file(
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
  perform authz.require(p_user_id, 'record_income', p_workspace.tenant_id, target.office_id, target.user_id, p_workspace.id);
  return file;
end;
$$;

create function api.create_evidence_upload(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_target_membership_id uuid,
  p_command_key text,
  p_file_name text,
  p_mime_type text,
  p_size int,
  p_sha256 text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  target org.memberships;
  v_id uuid := gen_random_uuid();
  file evidence.files;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  target := org.membership_in_tenant(workspace.tenant_id, p_target_membership_id);
  if target.role = 'president_team_member' then
    perform identity.fail('target_not_eligible');
  end if;
  perform authz.require(p_user_id, 'record_income', workspace.tenant_id, target.office_id, target.user_id, workspace.id);

  if p_command_key is null or p_command_key !~ '^[A-Za-z0-9_-]{16,100}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'idempotencyKey'));
  end if;
  if p_file_name is null or length(btrim(p_file_name)) not between 1 and 200 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'fileName'));
  end if;
  if p_mime_type is null or p_mime_type not in ('application/pdf', 'image/jpeg', 'image/png') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'mimeType'));
  end if;
  if p_size is null or p_size not between 1 and evidence.max_size() then
    perform identity.fail('validation_error', jsonb_build_object('field', 'size'));
  end if;
  if p_sha256 is null or lower(p_sha256) !~ '^[0-9a-f]{64}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'sha256'));
  end if;

  perform pg_advisory_xact_lock(hashtextextended('evidence.command:' || p_user_id::text || ':' || p_command_key, 0));
  if (
    select count(*) from evidence.files
    where uploaded_by = p_user_id and command_key = p_command_key
      and status in ('pending', 'finalized') and expires_at > now()
  ) >= evidence.max_open_per_command() then
    perform identity.fail('rate_limited', jsonb_build_object('retryAfterSeconds', 60));
  end if;

  insert into evidence.files (id, tenant_id, purpose, uploaded_by, target_membership_id, command_key, object_path,
    declared_name, declared_mime, declared_size, declared_sha256, expires_at)
  values (v_id, workspace.tenant_id, 'income', p_user_id, target.id, p_command_key,
    workspace.tenant_id::text || '/income/' || v_id::text,
    btrim(p_file_name), p_mime_type, p_size, lower(p_sha256), now() + evidence.upload_ttl())
  returning * into file;

  return jsonb_build_object('evidenceId', file.id, 'objectPath', file.object_path, 'expiresAt', file.expires_at);
end;
$$;

-- What the Edge Function needs to verify the uploaded bytes. The path is
-- always the server-built one.
create function api.evidence_upload_target(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_evidence_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  file evidence.files;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  file := evidence.require_own_file(p_user_id, workspace, p_evidence_id);
  if file.status not in ('pending', 'finalized') or file.expires_at <= now() then
    perform identity.fail('evidence_invalid', jsonb_build_object('reason', 'not_pending'));
  end if;
  return jsonb_build_object('evidenceId', file.id, 'objectPath', file.object_path, 'status', file.status,
    'maxSize', evidence.max_size());
end;
$$;

-- Records the facts the Edge Function computed from the stored bytes. A
-- mismatch with what the uploader declared cancels the file.
create function api.finalize_evidence_upload(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_evidence_id uuid,
  p_size int,
  p_sha256 text,
  p_mime text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  file evidence.files;
begin
  perform org.require_writer(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  file := evidence.require_own_file(p_user_id, workspace, p_evidence_id, true);

  if file.status = 'finalized' and file.expires_at > now()
    and file.size = p_size and file.sha256 = lower(p_sha256) and file.mime = p_mime then
    return jsonb_build_object('evidenceId', file.id, 'status', 'finalized', 'expiresAt', file.expires_at);
  end if;
  if file.status <> 'pending' or file.expires_at <= now() then
    perform identity.fail('evidence_invalid', jsonb_build_object('reason', 'not_pending'));
  end if;

  if p_size is distinct from file.declared_size or lower(p_sha256) is distinct from file.declared_sha256
    or p_mime is distinct from file.declared_mime then
    update evidence.files set status = 'cancelled' where id = file.id;
    return jsonb_build_object('evidenceId', file.id, 'status', 'cancelled', 'reason', 'content_mismatch');
  end if;

  update evidence.files
  set status = 'finalized', size = p_size, sha256 = lower(p_sha256), mime = p_mime
  where id = file.id
  returning * into file;
  return jsonb_build_object('evidenceId', file.id, 'status', 'finalized', 'expiresAt', file.expires_at);
end;
$$;
