create or replace function financial_ops.validate_pocket_transfer_request()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  source_account ledger.ledger_accounts%rowtype;
  destination_account ledger.ledger_accounts%rowtype;
begin
  if tg_op = 'INSERT' then
    select * into source_account from ledger.ledger_accounts where id = new.source_ledger_account_id;
    select * into destination_account from ledger.ledger_accounts where id = new.destination_ledger_account_id;
    if source_account.id is null or destination_account.id is null
       or source_account.account_class <> 'member_value'
       or destination_account.account_class <> 'member_value'
       or source_account.tenant_id <> new.tenant_id
       or source_account.office_id <> new.office_id
       or source_account.membership_id <> new.membership_id
       or source_account.wallet_id <> new.wallet_id
       or source_account.owner_user_id <> new.owner_user_id
       or source_account.currency_code <> new.currency_code
       or destination_account.tenant_id <> new.tenant_id
       or destination_account.office_id <> new.office_id
       or destination_account.membership_id <> new.membership_id
       or destination_account.wallet_id <> new.wallet_id
       or destination_account.owner_user_id <> new.owner_user_id
       or destination_account.currency_code <> new.currency_code
       or source_account.pocket_key = 'debt'
       or not exists (
         select 1 from public.pocket_definitions pocket
          where pocket.pocket_key = source_account.pocket_key and pocket.transfer_out_allowed
       )
       or not exists (
         select 1 from public.pocket_definitions pocket
          where pocket.pocket_key = destination_account.pocket_key and pocket.transfer_in_allowed
       ) then
      raise exception using errcode = '23514', message = 'pocket transfer context is invalid';
    end if;
    return new;
  end if;

  if current_setting('financial_ops.pocket_transfer_transition', true) is distinct from old.id::text
     or (to_jsonb(new) - 'status' - 'approved_by_user_id' - 'approved_at'
       - 'rejected_by_user_id' - 'rejected_at' - 'rejection_reason'
       - 'cancelled_by_user_id' - 'cancelled_at' - 'cancellation_reason'
       - 'financial_transaction_id' - 'version' - 'updated_at')
       <> (to_jsonb(old) - 'status' - 'approved_by_user_id' - 'approved_at'
       - 'rejected_by_user_id' - 'rejected_at' - 'rejection_reason'
       - 'cancelled_by_user_id' - 'cancelled_at' - 'cancellation_reason'
       - 'financial_transaction_id' - 'version' - 'updated_at')
     or new.version <> old.version + 1
     or old.status <> 'requested'
     or new.status not in ('approved', 'rejected', 'cancelled') then
    raise exception using errcode = '55000', message = 'pocket transfer lifecycle requires a trusted command';
  end if;
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

create trigger pocket_transfer_requests_validate
  before insert or update on financial_ops.pocket_transfer_requests
  for each row execute function financial_ops.validate_pocket_transfer_request();

create or replace function financial_ops.validate_pocket_transfer_reservation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_transfer financial_ops.pocket_transfer_requests%rowtype;
begin
  if tg_op = 'INSERT' then
    select * into target_transfer from financial_ops.pocket_transfer_requests
     where id = new.pocket_transfer_id;
    if target_transfer.id is null or target_transfer.status <> 'requested'
       or target_transfer.source_ledger_account_id <> new.ledger_account_id
       or target_transfer.amount <> new.amount then
      raise exception using errcode = '23514', message = 'pocket transfer reservation must match its request';
    end if;
    return new;
  end if;
  select * into target_transfer from financial_ops.pocket_transfer_requests
   where id = old.pocket_transfer_id;
  if current_setting('financial_ops.pocket_transfer_transition', true)
       is distinct from old.pocket_transfer_id::text
     or old.status <> 'active' or new.status not in ('consumed', 'released')
     or new.pocket_transfer_id <> old.pocket_transfer_id
     or new.ledger_account_id <> old.ledger_account_id
     or new.amount <> old.amount or new.created_at <> old.created_at then
    raise exception using errcode = '55000', message = 'pocket transfer reservation requires a trusted transition';
  end if;
  return new;
end;
$$;

create trigger pocket_transfer_reservations_validate
  before insert or update on financial_ops.pocket_transfer_reservations
  for each row execute function financial_ops.validate_pocket_transfer_reservation();

create or replace function financial_ops.validate_evidence_operation_lifecycle()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    return new;
  end if;

  if current_setting('financial_ops.evidence_operation_transition', true) is distinct from old.id::text
     or (to_jsonb(new) - 'status' - 'current_revision_number' - 'accepted_via'
       - 'accepted_at' - 'posted_financial_transaction_id' - 'version' - 'updated_at')
       <> (to_jsonb(old) - 'status' - 'current_revision_number' - 'accepted_via'
       - 'accepted_at' - 'posted_financial_transaction_id' - 'version' - 'updated_at')
     or new.version <> old.version + 1
     or not (
       (old.status = 'submitted' and new.status in ('correction_required', 'needs_review', 'posted'))
       or (old.status = 'correction_required' and new.status = 'submitted'
         and old.current_revision_number = 1 and new.current_revision_number = 2)
       or (old.status = 'needs_review' and new.status in ('rejected', 'posted'))
     ) then
    raise exception using errcode = '55000', message = 'financial evidence lifecycle requires a trusted command';
  end if;
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

create trigger currency_conversions_validate_lifecycle
  before insert or update on financial_ops.currency_conversions
  for each row execute function financial_ops.validate_evidence_operation_lifecycle();
create trigger administrative_adjustments_validate_lifecycle
  before insert or update on financial_ops.administrative_adjustments
  for each row execute function financial_ops.validate_evidence_operation_lifecycle();
create trigger returned_funds_validate_lifecycle
  before insert or update on financial_ops.returned_funds
  for each row execute function financial_ops.validate_evidence_operation_lifecycle();

create or replace function financial_ops.validate_operation_revision()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_status financial_ops.evidence_operation_status;
  target_current_revision smallint;
  target_submitter uuid;
begin
  if tg_table_name = 'currency_conversion_revisions' then
    select status, current_revision_number, submitted_by_user_id
      into target_status, target_current_revision, target_submitter
      from financial_ops.currency_conversions where id = new.currency_conversion_id;
  elsif tg_table_name = 'administrative_adjustment_revisions' then
    select status, current_revision_number, submitted_by_user_id
      into target_status, target_current_revision, target_submitter
      from financial_ops.administrative_adjustments where id = new.administrative_adjustment_id;
  else
    select status, current_revision_number, submitted_by_user_id
      into target_status, target_current_revision, target_submitter
      from financial_ops.returned_funds where id = new.returned_fund_id;
  end if;

  if target_status is null or new.submitted_by_user_id <> target_submitter
     or not (
       (new.revision_number = 1 and target_status = 'submitted' and target_current_revision = 1)
       or (new.revision_number = 2 and target_status = 'correction_required' and target_current_revision = 1)
     ) then
    raise exception using errcode = '23514', message = 'financial operation revision does not match its lifecycle';
  end if;
  return new;
end;
$$;

create trigger currency_conversion_revisions_validate
  before insert on financial_ops.currency_conversion_revisions
  for each row execute function financial_ops.validate_operation_revision();
create trigger administrative_adjustment_revisions_validate
  before insert on financial_ops.administrative_adjustment_revisions
  for each row execute function financial_ops.validate_operation_revision();
create trigger returned_fund_revisions_validate
  before insert on financial_ops.returned_fund_revisions
  for each row execute function financial_ops.validate_operation_revision();

create or replace function evidence.validate_financial_operation_evidence_link()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_tenant_id uuid;
  evidence_tenant_id uuid;
begin
  if new.income_record_id is not null then
    select tenant_id into target_tenant_id from financial_ops.income_records where id = new.income_record_id;
  elsif new.currency_conversion_revision_id is not null then
    select operation.tenant_id into target_tenant_id
      from financial_ops.currency_conversion_revisions revision
      join financial_ops.currency_conversions operation on operation.id = revision.currency_conversion_id
     where revision.id = new.currency_conversion_revision_id;
  elsif new.administrative_adjustment_revision_id is not null then
    select operation.tenant_id into target_tenant_id
      from financial_ops.administrative_adjustment_revisions revision
      join financial_ops.administrative_adjustments operation on operation.id = revision.administrative_adjustment_id
     where revision.id = new.administrative_adjustment_revision_id;
  else
    select operation.tenant_id into target_tenant_id
      from financial_ops.returned_fund_revisions revision
      join financial_ops.returned_funds operation on operation.id = revision.returned_fund_id
     where revision.id = new.returned_fund_revision_id;
  end if;
  select tenant_id into evidence_tenant_id from evidence.financial_evidence where id = new.evidence_id;
  if target_tenant_id is null or evidence_tenant_id is null or target_tenant_id <> evidence_tenant_id then
    raise exception using errcode = '23514', message = 'financial evidence must remain inside its operation tenant';
  end if;
  return new;
end;
$$;

create trigger financial_operation_evidence_validate
  before insert on evidence.financial_operation_evidence
  for each row execute function evidence.validate_financial_operation_evidence_link();

create trigger income_records_prevent_mutation
  before update or delete on financial_ops.income_records
  for each row execute function evidence.prevent_evidence_mutation();
create trigger income_allocations_prevent_mutation
  before update or delete on financial_ops.income_allocations
  for each row execute function evidence.prevent_evidence_mutation();
create trigger pocket_transfer_requests_prevent_delete
  before delete on financial_ops.pocket_transfer_requests
  for each row execute function evidence.prevent_evidence_mutation();
create trigger pocket_transfer_reservations_prevent_delete
  before delete on financial_ops.pocket_transfer_reservations
  for each row execute function evidence.prevent_evidence_mutation();
create trigger currency_conversion_revisions_prevent_mutation
  before update or delete on financial_ops.currency_conversion_revisions
  for each row execute function evidence.prevent_evidence_mutation();
create trigger administrative_adjustment_revisions_prevent_mutation
  before update or delete on financial_ops.administrative_adjustment_revisions
  for each row execute function evidence.prevent_evidence_mutation();
create trigger administrative_adjustment_lines_prevent_mutation
  before update or delete on financial_ops.administrative_adjustment_lines
  for each row execute function evidence.prevent_evidence_mutation();
create trigger returned_fund_revisions_prevent_mutation
  before update or delete on financial_ops.returned_fund_revisions
  for each row execute function evidence.prevent_evidence_mutation();
create trigger financial_reversals_prevent_mutation
  before update or delete on financial_ops.financial_reversals
  for each row execute function evidence.prevent_evidence_mutation();
create trigger financial_operation_evidence_prevent_mutation
  before update or delete on evidence.financial_operation_evidence
  for each row execute function evidence.prevent_evidence_mutation();
create trigger financial_operation_verification_prevent_mutation
  before update or delete on evidence.financial_operation_verification_attempts
  for each row execute function evidence.prevent_evidence_mutation();
create trigger financial_operation_reviews_prevent_mutation
  before update or delete on evidence.financial_operation_review_decisions
  for each row execute function evidence.prevent_evidence_mutation();
create trigger currency_conversions_prevent_delete
  before delete on financial_ops.currency_conversions
  for each row execute function evidence.prevent_evidence_mutation();
create trigger administrative_adjustments_prevent_delete
  before delete on financial_ops.administrative_adjustments
  for each row execute function evidence.prevent_evidence_mutation();
create trigger returned_funds_prevent_delete
  before delete on financial_ops.returned_funds
  for each row execute function evidence.prevent_evidence_mutation();

revoke all on all tables in schema financial_ops
  from public, anon, authenticated, service_role;
revoke all on all sequences in schema financial_ops
  from public, anon, authenticated, service_role;
revoke all on all functions in schema financial_ops
  from public, anon, authenticated, service_role;
revoke all on all tables in schema evidence
  from public, anon, authenticated, service_role;
revoke all on all sequences in schema evidence
  from public, anon, authenticated, service_role;
revoke all on all functions in schema evidence
  from public, anon, authenticated, service_role;

alter default privileges in schema financial_ops
  revoke all on tables from public, anon, authenticated, service_role;
alter default privileges in schema financial_ops
  revoke all on sequences from public, anon, authenticated, service_role;
alter default privileges in schema financial_ops
  revoke execute on functions from public, anon, authenticated, service_role;
