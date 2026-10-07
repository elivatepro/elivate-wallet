create or replace function internal.capture_financial_operation_event()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_tenant_id uuid;
  target_aggregate_type text;
  target_event_type text;
  target_payload jsonb;
begin
  if tg_table_name = 'income_records' then
    target_tenant_id := new.tenant_id;
    target_aggregate_type := 'income_record';
    target_event_type := 'income_recorded';
    target_payload := jsonb_build_object(
      'financial_transaction_id', new.financial_transaction_id,
      'income_record_id', new.id,
      'wallet_id', new.wallet_id
    );
  elsif tg_table_name = 'pocket_transfer_requests' then
    target_tenant_id := new.tenant_id;
    target_aggregate_type := 'pocket_transfer';
    target_event_type := 'pocket_transfer_' || new.status::text;
    target_payload := jsonb_build_object(
      'financial_transaction_id', new.financial_transaction_id,
      'pocket_transfer_id', new.id,
      'status', new.status,
      'wallet_id', new.wallet_id
    );
  elsif tg_table_name = 'currency_conversions' then
    target_tenant_id := new.tenant_id;
    target_aggregate_type := 'currency_conversion';
    target_event_type := 'currency_conversion_' || new.status::text;
    target_payload := jsonb_build_object(
      'currency_conversion_id', new.id,
      'financial_transaction_id', new.posted_financial_transaction_id,
      'revision_number', new.current_revision_number,
      'status', new.status,
      'wallet_id', new.wallet_id,
      'withdrawal_id', new.withdrawal_id
    );
  elsif tg_table_name = 'administrative_adjustments' then
    target_tenant_id := new.tenant_id;
    target_aggregate_type := 'administrative_adjustment';
    target_event_type := 'administrative_adjustment_' || new.status::text;
    target_payload := jsonb_build_object(
      'administrative_adjustment_id', new.id,
      'financial_transaction_id', new.posted_financial_transaction_id,
      'revision_number', new.current_revision_number,
      'status', new.status,
      'wallet_id', new.wallet_id
    );
  elsif tg_table_name = 'financial_reversals' then
    target_tenant_id := new.tenant_id;
    target_aggregate_type := 'financial_reversal';
    target_event_type := case when new.reinstates_reversal_id is null
      then 'financial_transaction_reversed'
      else 'financial_transaction_reinstated'
    end;
    target_payload := jsonb_build_object(
      'financial_reversal_id', new.id,
      'original_financial_transaction_id', new.original_financial_transaction_id,
      'reinstates_reversal_id', new.reinstates_reversal_id,
      'reversal_financial_transaction_id', new.reversal_financial_transaction_id
    );
  elsif tg_table_name = 'returned_funds' then
    target_tenant_id := new.tenant_id;
    target_aggregate_type := 'returned_fund';
    target_event_type := 'returned_fund_' || new.status::text;
    target_payload := jsonb_build_object(
      'financial_transaction_id', new.posted_financial_transaction_id,
      'returned_fund_id', new.id,
      'revision_number', new.current_revision_number,
      'status', new.status,
      'wallet_id', new.wallet_id,
      'withdrawal_id', new.withdrawal_id
    );
  else
    raise exception using
      errcode = '0A000',
      message = 'unsupported financial operation outbox source';
  end if;

  insert into internal.outbox_events (
    tenant_id,
    aggregate_type,
    aggregate_id,
    event_type,
    payload
  )
  values (
    target_tenant_id,
    target_aggregate_type,
    new.id,
    target_event_type,
    jsonb_strip_nulls(target_payload)
  );

  return new;
end;
$$;

create trigger income_records_capture_outbox
  after insert on financial_ops.income_records
  for each row execute function internal.capture_financial_operation_event();

create trigger pocket_transfer_requests_capture_outbox
  after insert or update of status on financial_ops.pocket_transfer_requests
  for each row execute function internal.capture_financial_operation_event();

create trigger currency_conversions_capture_outbox
  after insert or update of status on financial_ops.currency_conversions
  for each row execute function internal.capture_financial_operation_event();

create trigger administrative_adjustments_capture_outbox
  after insert or update of status on financial_ops.administrative_adjustments
  for each row execute function internal.capture_financial_operation_event();

create trigger financial_reversals_capture_outbox
  after insert on financial_ops.financial_reversals
  for each row execute function internal.capture_financial_operation_event();

create trigger returned_funds_capture_outbox
  after insert or update of status on financial_ops.returned_funds
  for each row execute function internal.capture_financial_operation_event();

revoke all on function internal.capture_financial_operation_event()
  from public, anon, authenticated, service_role;
