create table evidence.financial_operation_evidence (
  evidence_id uuid primary key
    references evidence.financial_evidence (id) on delete restrict,
  income_record_id uuid
    references financial_ops.income_records (id) on delete restrict,
  currency_conversion_revision_id uuid
    references financial_ops.currency_conversion_revisions (id) on delete restrict,
  administrative_adjustment_revision_id uuid
    references financial_ops.administrative_adjustment_revisions (id) on delete restrict,
  returned_fund_revision_id uuid
    references financial_ops.returned_fund_revisions (id) on delete restrict,
  linked_at timestamptz not null default clock_timestamp(),
  check (num_nonnulls(
    income_record_id,
    currency_conversion_revision_id,
    administrative_adjustment_revision_id,
    returned_fund_revision_id
  ) = 1)
);

create index financial_operation_evidence_income
  on evidence.financial_operation_evidence (income_record_id)
  where income_record_id is not null;
create index financial_operation_evidence_conversion_revision
  on evidence.financial_operation_evidence (currency_conversion_revision_id)
  where currency_conversion_revision_id is not null;
create index financial_operation_evidence_adjustment_revision
  on evidence.financial_operation_evidence (administrative_adjustment_revision_id)
  where administrative_adjustment_revision_id is not null;
create index financial_operation_evidence_returned_revision
  on evidence.financial_operation_evidence (returned_fund_revision_id)
  where returned_fund_revision_id is not null;

create table evidence.financial_operation_verification_attempts (
  id uuid primary key default extensions.gen_random_uuid(),
  verification_request_id uuid not null unique,
  request_fingerprint bytea not null check (octet_length(request_fingerprint) = 32),
  currency_conversion_revision_id uuid unique
    references financial_ops.currency_conversion_revisions (id) on delete restrict,
  administrative_adjustment_revision_id uuid unique
    references financial_ops.administrative_adjustment_revisions (id) on delete restrict,
  returned_fund_revision_id uuid unique
    references financial_ops.returned_fund_revisions (id) on delete restrict,
  outcome evidence.verification_outcome not null,
  extracted_facts jsonb not null check (jsonb_typeof(extracted_facts) = 'object'),
  mismatch_reasons jsonb not null check (jsonb_typeof(mismatch_reasons) = 'array'),
  verifier_name text not null check (length(btrim(verifier_name)) > 0),
  verifier_version text,
  created_at timestamptz not null default clock_timestamp(),
  check (num_nonnulls(
    currency_conversion_revision_id,
    administrative_adjustment_revision_id,
    returned_fund_revision_id
  ) = 1),
  check (verifier_version is null or length(btrim(verifier_version)) > 0),
  check (
    (outcome = 'match' and jsonb_array_length(mismatch_reasons) = 0)
    or (outcome = 'mismatch' and jsonb_array_length(mismatch_reasons) > 0)
  )
);

create index financial_operation_verification_attempts_created
  on evidence.financial_operation_verification_attempts (created_at desc);

create table evidence.financial_operation_review_decisions (
  id uuid primary key default extensions.gen_random_uuid(),
  currency_conversion_id uuid unique
    references financial_ops.currency_conversions (id) on delete restrict,
  administrative_adjustment_id uuid unique
    references financial_ops.administrative_adjustments (id) on delete restrict,
  returned_fund_id uuid unique
    references financial_ops.returned_funds (id) on delete restrict,
  reviewer_assignment_id uuid not null
    references authz.financial_evidence_reviewer_assignments (id) on delete restrict,
  reviewer_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  decision evidence.review_decision not null,
  review_note text not null check (length(btrim(review_note)) > 0),
  decided_at timestamptz not null default clock_timestamp(),
  check (num_nonnulls(
    currency_conversion_id,
    administrative_adjustment_id,
    returned_fund_id
  ) = 1)
);

create index financial_operation_review_decisions_assignment
  on evidence.financial_operation_review_decisions (
    reviewer_assignment_id,
    decided_at desc
  );
create index financial_operation_review_decisions_reviewer
  on evidence.financial_operation_review_decisions (
    reviewer_user_id,
    decided_at desc
  );

create or replace function evidence.attach_financial_operation_evidence(
  p_tenant_id uuid,
  p_submitted_by_user_id uuid,
  p_evidence_type text,
  p_target_type text,
  p_target_id uuid,
  p_evidence_items jsonb
)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  evidence_item jsonb;
  target_evidence evidence.financial_evidence%rowtype;
  existing_evidence_id uuid;
  superseded_evidence_id uuid;
  attached_count integer := 0;
begin
  if p_tenant_id is null
     or p_submitted_by_user_id is null
     or p_evidence_type not in (
       'income',
       'currency_conversion',
       'administrative_adjustment',
       'returned_funds'
     )
     or p_target_type not in (
       'income_record',
       'currency_conversion_revision',
       'administrative_adjustment_revision',
       'returned_fund_revision'
     )
     or p_target_id is null
     or p_evidence_items is null
     or jsonb_typeof(p_evidence_items) <> 'array'
     or jsonb_array_length(p_evidence_items) = 0 then
    raise exception using
      errcode = '22023',
      message = 'financial operation requires at least one valid evidence item';
  end if;

  if (p_evidence_type = 'income' and p_target_type <> 'income_record')
     or (p_evidence_type = 'currency_conversion'
       and p_target_type <> 'currency_conversion_revision')
     or (p_evidence_type = 'administrative_adjustment'
       and p_target_type <> 'administrative_adjustment_revision')
     or (p_evidence_type = 'returned_funds'
       and p_target_type <> 'returned_fund_revision') then
    raise exception using
      errcode = '23514',
      message = 'financial evidence type does not match its target';
  end if;

  for evidence_item in select value from jsonb_array_elements(p_evidence_items)
  loop
    if jsonb_typeof(evidence_item) <> 'object' then
      raise exception using
        errcode = '22023',
        message = 'financial evidence item must be an object';
    end if;

    existing_evidence_id := nullif(evidence_item ->> 'existing_evidence_id', '')::uuid;

    if existing_evidence_id is not null then
      select *
        into target_evidence
        from evidence.financial_evidence item
       where item.id = existing_evidence_id
         and item.tenant_id = p_tenant_id
         and item.submitted_by_user_id = p_submitted_by_user_id
         and item.evidence_type = p_evidence_type;

      if target_evidence.id is null then
        raise exception using
          errcode = '23514',
          message = 'reused financial evidence must belong to the same tenant, type, and submitter';
      end if;
    else
      if coalesce(evidence_item ->> 'storage_bucket_id', '') = ''
         or coalesce(evidence_item ->> 'storage_object_path', '') = ''
         or coalesce(evidence_item ->> 'original_filename', '') = ''
         or coalesce(evidence_item ->> 'mime_type', '') = ''
         or coalesce(evidence_item ->> 'file_size_bytes', '') !~ '^[1-9][0-9]*$'
         or coalesce(evidence_item ->> 'sha256_hex', '') !~ '^[0-9A-Fa-f]{64}$'
         or coalesce(evidence_item ->> 'observed_at', '') = '' then
        raise exception using
          errcode = '22023',
          message = 'financial evidence metadata is incomplete';
      end if;

      superseded_evidence_id :=
        nullif(evidence_item ->> 'supersedes_evidence_id', '')::uuid;

      if superseded_evidence_id is not null
         and not exists (
           select 1
             from evidence.financial_evidence prior
            where prior.id = superseded_evidence_id
              and prior.tenant_id = p_tenant_id
              and prior.evidence_type = p_evidence_type
         ) then
        raise exception using
          errcode = '23514',
          message = 'superseded financial evidence must belong to the same tenant and type';
      end if;

      insert into evidence.financial_evidence (
        tenant_id,
        evidence_type,
        storage_bucket_id,
        storage_object_path,
        original_filename,
        mime_type,
        file_size_bytes,
        sha256,
        submitted_by_user_id,
        provider,
        observed_at,
        provider_reference,
        notes,
        supersedes_evidence_id
      )
      values (
        p_tenant_id,
        p_evidence_type,
        btrim(evidence_item ->> 'storage_bucket_id'),
        btrim(evidence_item ->> 'storage_object_path'),
        btrim(evidence_item ->> 'original_filename'),
        btrim(evidence_item ->> 'mime_type'),
        (evidence_item ->> 'file_size_bytes')::bigint,
        decode(lower(evidence_item ->> 'sha256_hex'), 'hex'),
        p_submitted_by_user_id,
        nullif(btrim(evidence_item ->> 'provider'), ''),
        (evidence_item ->> 'observed_at')::timestamptz,
        nullif(btrim(evidence_item ->> 'provider_reference'), ''),
        nullif(btrim(evidence_item ->> 'notes'), ''),
        superseded_evidence_id
      )
      returning * into target_evidence;
    end if;

    insert into evidence.financial_operation_evidence (
      evidence_id,
      income_record_id,
      currency_conversion_revision_id,
      administrative_adjustment_revision_id,
      returned_fund_revision_id
    )
    values (
      target_evidence.id,
      case when p_target_type = 'income_record' then p_target_id end,
      case when p_target_type = 'currency_conversion_revision' then p_target_id end,
      case when p_target_type = 'administrative_adjustment_revision' then p_target_id end,
      case when p_target_type = 'returned_fund_revision' then p_target_id end
    );

    attached_count := attached_count + 1;
  end loop;

  return attached_count;
end;
$$;

create or replace function evidence.validate_financial_operation_verification()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_status financial_ops.evidence_operation_status;
  current_revision smallint;
  attempted_revision smallint;
begin
  if new.currency_conversion_revision_id is not null then
    select operation.status, operation.current_revision_number, revision.revision_number
      into target_status, current_revision, attempted_revision
      from financial_ops.currency_conversion_revisions revision
      join financial_ops.currency_conversions operation
        on operation.id = revision.currency_conversion_id
     where revision.id = new.currency_conversion_revision_id;
  elsif new.administrative_adjustment_revision_id is not null then
    select operation.status, operation.current_revision_number, revision.revision_number
      into target_status, current_revision, attempted_revision
      from financial_ops.administrative_adjustment_revisions revision
      join financial_ops.administrative_adjustments operation
        on operation.id = revision.administrative_adjustment_id
     where revision.id = new.administrative_adjustment_revision_id;
  else
    select operation.status, operation.current_revision_number, revision.revision_number
      into target_status, current_revision, attempted_revision
      from financial_ops.returned_fund_revisions revision
      join financial_ops.returned_funds operation
        on operation.id = revision.returned_fund_id
     where revision.id = new.returned_fund_revision_id;
  end if;

  if target_status is null
     or target_status <> 'submitted'
     or current_revision <> attempted_revision then
    raise exception using
      errcode = '23514',
      message = 'verification attempt must target the submitted current operation revision';
  end if;

  return new;
end;
$$;

create trigger financial_operation_verification_attempts_validate
  before insert on evidence.financial_operation_verification_attempts
  for each row execute function evidence.validate_financial_operation_verification();

create or replace function evidence.validate_financial_operation_review()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_status financial_ops.evidence_operation_status;
  target_tenant_id uuid;
  submitter_user_id uuid;
  assignment_user_id uuid;
begin
  if new.currency_conversion_id is not null then
    select status, tenant_id, submitted_by_user_id
      into target_status, target_tenant_id, submitter_user_id
      from financial_ops.currency_conversions
     where id = new.currency_conversion_id;
  elsif new.administrative_adjustment_id is not null then
    select status, tenant_id, submitted_by_user_id
      into target_status, target_tenant_id, submitter_user_id
      from financial_ops.administrative_adjustments
     where id = new.administrative_adjustment_id;
  else
    select status, tenant_id, submitted_by_user_id
      into target_status, target_tenant_id, submitter_user_id
      from financial_ops.returned_funds
     where id = new.returned_fund_id;
  end if;

  select assignment.reviewer_user_id
    into assignment_user_id
    from authz.financial_evidence_reviewer_assignments assignment
    join public.memberships membership
      on membership.tenant_id = assignment.tenant_id
     and membership.id = assignment.reviewer_membership_id
     and membership.user_id = assignment.reviewer_user_id
   where assignment.id = new.reviewer_assignment_id
     and assignment.tenant_id = target_tenant_id
     and assignment.revoked_at is null
     and membership.status = 'active';

  if target_status is null
     or target_status <> 'needs_review'
     or assignment_user_id is null
     or assignment_user_id <> new.reviewer_user_id
     or submitter_user_id = new.reviewer_user_id then
    raise exception using
      errcode = '23514',
      message = 'financial operation review is outside the active reviewer assignment';
  end if;

  return new;
end;
$$;

create trigger financial_operation_review_decisions_validate
  before insert on evidence.financial_operation_review_decisions
  for each row execute function evidence.validate_financial_operation_review();

alter table evidence.financial_operation_evidence enable row level security;
alter table evidence.financial_operation_verification_attempts enable row level security;
alter table evidence.financial_operation_review_decisions enable row level security;

alter table evidence.financial_operation_evidence force row level security;
alter table evidence.financial_operation_verification_attempts force row level security;
alter table evidence.financial_operation_review_decisions force row level security;

revoke all on all tables in schema evidence
  from public, anon, authenticated, service_role;
revoke all on all sequences in schema evidence
  from public, anon, authenticated, service_role;
revoke all on function evidence.attach_financial_operation_evidence(
  uuid, uuid, text, text, uuid, jsonb
) from public, anon, authenticated, service_role;
revoke all on function evidence.validate_financial_operation_verification()
  from public, anon, authenticated, service_role;
revoke all on function evidence.validate_financial_operation_review()
  from public, anon, authenticated, service_role;
