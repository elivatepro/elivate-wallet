-- Service-only API routes delegate to the existing authoritative domain commands.

create function command_api.create_membership(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_target_user_id uuid,
  p_office_id uuid,
  p_role_key public.role_key
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select internal.create_membership(p_idempotency_key, p_actor_user_id, p_session_id, p_tenant_id, p_target_user_id, p_office_id, p_role_key);
$$;

revoke all on function command_api.create_membership(uuid, uuid, uuid, uuid, uuid, uuid, public.role_key) from public, anon, authenticated;
grant execute on function command_api.create_membership(uuid, uuid, uuid, uuid, uuid, uuid, public.role_key) to service_role;

create function command_api.activate_membership(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select internal.activate_membership(p_idempotency_key, p_actor_user_id, p_session_id, p_membership_id);
$$;

revoke all on function command_api.activate_membership(uuid, uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function command_api.activate_membership(uuid, uuid, uuid, uuid) to service_role;

create function command_api.suspend_membership(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select internal.suspend_membership(p_idempotency_key, p_actor_user_id, p_session_id, p_membership_id);
$$;

revoke all on function command_api.suspend_membership(uuid, uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function command_api.suspend_membership(uuid, uuid, uuid, uuid) to service_role;

create function command_api.end_membership(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_replacement_primary_membership_id uuid default null
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select internal.end_membership(p_idempotency_key, p_actor_user_id, p_session_id, p_membership_id, p_replacement_primary_membership_id);
$$;

revoke all on function command_api.end_membership(uuid, uuid, uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function command_api.end_membership(uuid, uuid, uuid, uuid, uuid) to service_role;

create function command_api.move_membership(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_destination_office_id uuid,
  p_destination_role_key public.role_key
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select internal.move_membership(p_idempotency_key, p_actor_user_id, p_session_id, p_membership_id, p_destination_office_id, p_destination_role_key);
$$;

revoke all on function command_api.move_membership(uuid, uuid, uuid, uuid, uuid, public.role_key) from public, anon, authenticated;
grant execute on function command_api.move_membership(uuid, uuid, uuid, uuid, uuid, public.role_key) to service_role;

create function command_api.submit_withdrawal(
  p_idempotency_key uuid,
  p_source_ledger_account_id uuid,
  p_payout_account_id uuid,
  p_requested_amount numeric,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.withdrawal_command_result
language sql
security definer
set search_path = ''
as $$
  select financial_ops.submit_withdrawal(p_idempotency_key, p_source_ledger_account_id, p_payout_account_id, p_requested_amount, p_actor_user_id, p_session_id);
$$;

revoke all on function command_api.submit_withdrawal(uuid, uuid, uuid, numeric, uuid, uuid) from public, anon, authenticated;
grant execute on function command_api.submit_withdrawal(uuid, uuid, uuid, numeric, uuid, uuid) to service_role;

create function command_api.approve_withdrawal(
  p_idempotency_key uuid,
  p_withdrawal_id uuid,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.withdrawal_command_result
language sql
security definer
set search_path = ''
as $$
  select financial_ops.approve_withdrawal(p_idempotency_key, p_withdrawal_id, p_actor_user_id, p_session_id);
$$;

revoke all on function command_api.approve_withdrawal(uuid, uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function command_api.approve_withdrawal(uuid, uuid, uuid, uuid) to service_role;

create function command_api.reject_withdrawal(
  p_idempotency_key uuid,
  p_withdrawal_id uuid,
  p_actor_user_id uuid,
  p_reason text,
  p_session_id uuid default null
)
returns financial_ops.withdrawal_command_result
language sql
security definer
set search_path = ''
as $$
  select financial_ops.reject_withdrawal(p_idempotency_key, p_withdrawal_id, p_actor_user_id, p_reason, p_session_id);
$$;

revoke all on function command_api.reject_withdrawal(uuid, uuid, uuid, text, uuid) from public, anon, authenticated;
grant execute on function command_api.reject_withdrawal(uuid, uuid, uuid, text, uuid) to service_role;

create function command_api.cancel_withdrawal(
  p_idempotency_key uuid,
  p_withdrawal_id uuid,
  p_actor_user_id uuid,
  p_reason text,
  p_session_id uuid default null
)
returns financial_ops.withdrawal_command_result
language sql
security definer
set search_path = ''
as $$
  select financial_ops.cancel_withdrawal(p_idempotency_key, p_withdrawal_id, p_actor_user_id, p_reason, p_session_id);
$$;

revoke all on function command_api.cancel_withdrawal(uuid, uuid, uuid, text, uuid) from public, anon, authenticated;
grant execute on function command_api.cancel_withdrawal(uuid, uuid, uuid, text, uuid) to service_role;

create function command_api.replace_payout_account(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_existing_payout_account_id uuid,
  p_country_code text,
  p_payout_currency text,
  p_payout_rail text,
  p_institution_code text,
  p_institution_name text,
  p_account_reference text,
  p_account_holder_name text,
  p_make_primary boolean default false
)
returns financial_ops.payout_account_command_result
language sql
security definer
set search_path = ''
as $$
  select financial_ops.replace_payout_account(p_idempotency_key, p_actor_user_id, p_session_id, p_tenant_id, p_existing_payout_account_id, p_country_code, p_payout_currency, p_payout_rail, p_institution_code, p_institution_name, p_account_reference, p_account_holder_name, p_make_primary);
$$;

revoke all on function command_api.replace_payout_account(uuid, uuid, uuid, uuid, uuid, text, text, text, text, text, text, text, boolean) from public, anon, authenticated;
grant execute on function command_api.replace_payout_account(uuid, uuid, uuid, uuid, uuid, text, text, text, text, text, text, text, boolean) to service_role;

create function command_api.deactivate_payout_account(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_payout_account_id uuid
)
returns financial_ops.payout_account_command_result
language sql
security definer
set search_path = ''
as $$
  select financial_ops.deactivate_payout_account(p_idempotency_key, p_actor_user_id, p_session_id, p_tenant_id, p_payout_account_id);
$$;

revoke all on function command_api.deactivate_payout_account(uuid, uuid, uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function command_api.deactivate_payout_account(uuid, uuid, uuid, uuid, uuid) to service_role;

create function command_api.set_primary_payout_account(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_payout_account_id uuid
)
returns financial_ops.payout_account_command_result
language sql
security definer
set search_path = ''
as $$
  select financial_ops.set_primary_payout_account(p_idempotency_key, p_actor_user_id, p_session_id, p_tenant_id, p_payout_account_id);
$$;

revoke all on function command_api.set_primary_payout_account(uuid, uuid, uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function command_api.set_primary_payout_account(uuid, uuid, uuid, uuid, uuid) to service_role;

create function command_api.submit_payout_assertion(
  p_idempotency_key uuid,
  p_withdrawal_id uuid,
  p_wallet_debit_amount numeric,
  p_beneficiary_payout_amount numeric,
  p_payout_currency text,
  p_provider text,
  p_paid_at timestamptz,
  p_evidence_items jsonb,
  p_actor_user_id uuid,
  p_provider_fee_amount numeric default 0,
  p_provider_reference text default null,
  p_notes text default null,
  p_session_id uuid default null
)
returns financial_ops.payout_assertion_command_result
language sql
security definer
set search_path = ''
as $$
  select financial_ops.submit_payout_assertion(p_idempotency_key, p_withdrawal_id, p_wallet_debit_amount, p_beneficiary_payout_amount, p_payout_currency, p_provider, p_paid_at, p_evidence_items, p_actor_user_id, p_provider_fee_amount, p_provider_reference, p_notes, p_session_id);
$$;

revoke all on function command_api.submit_payout_assertion(uuid, uuid, numeric, numeric, text, text, timestamptz, jsonb, uuid, numeric, text, text, uuid) from public, anon, authenticated;
grant execute on function command_api.submit_payout_assertion(uuid, uuid, numeric, numeric, text, text, timestamptz, jsonb, uuid, numeric, text, text, uuid) to service_role;

create function command_api.correct_payout_assertion(
  p_idempotency_key uuid,
  p_payout_assertion_id uuid,
  p_wallet_debit_amount numeric,
  p_beneficiary_payout_amount numeric,
  p_payout_currency text,
  p_provider text,
  p_paid_at timestamptz,
  p_evidence_items jsonb,
  p_actor_user_id uuid,
  p_provider_fee_amount numeric default 0,
  p_provider_reference text default null,
  p_notes text default null,
  p_session_id uuid default null
)
returns financial_ops.payout_assertion_command_result
language sql
security definer
set search_path = ''
as $$
  select financial_ops.correct_payout_assertion(p_idempotency_key, p_payout_assertion_id, p_wallet_debit_amount, p_beneficiary_payout_amount, p_payout_currency, p_provider, p_paid_at, p_evidence_items, p_actor_user_id, p_provider_fee_amount, p_provider_reference, p_notes, p_session_id);
$$;

revoke all on function command_api.correct_payout_assertion(uuid, uuid, numeric, numeric, text, text, timestamptz, jsonb, uuid, numeric, text, text, uuid) from public, anon, authenticated;
grant execute on function command_api.correct_payout_assertion(uuid, uuid, numeric, numeric, text, text, timestamptz, jsonb, uuid, numeric, text, text, uuid) to service_role;

create function command_api.review_payout_assertion(
  p_idempotency_key uuid,
  p_payout_assertion_id uuid,
  p_decision evidence.review_decision,
  p_review_note text,
  p_actor_user_id uuid,
  p_session_id uuid default null
)
returns financial_ops.payout_assertion_command_result
language sql
security definer
set search_path = ''
as $$
  select financial_ops.review_payout_assertion(p_idempotency_key, p_payout_assertion_id, p_decision, p_review_note, p_actor_user_id, p_session_id);
$$;

revoke all on function command_api.review_payout_assertion(uuid, uuid, evidence.review_decision, text, uuid, uuid) from public, anon, authenticated;
grant execute on function command_api.review_payout_assertion(uuid, uuid, evidence.review_decision, text, uuid, uuid) to service_role;

create function command_api.update_team_configuration(
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
language sql
security definer
set search_path = ''
as $$
  select tenant_config.update_team_configuration(p_idempotency_key, p_actor_user_id, p_session_id, p_tenant_id, p_team_display_name, p_team_short_name, p_support_contact_name, p_support_contact_email, p_support_contact_phone, p_locale_code, p_timezone_name, p_primary_logo_asset_id, p_square_app_icon_asset_id, p_light_logo_asset_id, p_dark_logo_asset_id, p_theme_key, p_team_slogan, p_support_url, p_revision_reason);
$$;

revoke all on function command_api.update_team_configuration(uuid, uuid, uuid, uuid, text, text, text, text, text, text, text, uuid, uuid, uuid, uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function command_api.update_team_configuration(uuid, uuid, uuid, uuid, text, text, text, text, text, text, text, uuid, uuid, uuid, uuid, text, text, text, text) to service_role;

create function command_api.request_brand_asset_upload(
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
language sql
security definer
set search_path = ''
as $$
  select tenant_config.request_brand_asset_upload(p_idempotency_key, p_actor_user_id, p_session_id, p_tenant_id, p_asset_kind, p_mime_type, p_file_size_bytes, p_sha256_hex, p_width_pixels, p_height_pixels);
$$;

revoke all on function command_api.request_brand_asset_upload(uuid, uuid, uuid, uuid, text, text, bigint, text, integer, integer) from public, anon, authenticated;
grant execute on function command_api.request_brand_asset_upload(uuid, uuid, uuid, uuid, text, text, bigint, text, integer, integer) to service_role;

create function command_api.finalize_brand_asset_upload(
  p_intent_id uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_verified_file_size_bytes bigint,
  p_verified_sha256_hex text
)
returns tenant_config.brand_assets
language sql
security definer
set search_path = ''
as $$
  select tenant_config.finalize_brand_asset_upload(p_intent_id, p_actor_user_id, p_session_id, p_verified_file_size_bytes, p_verified_sha256_hex);
$$;

revoke all on function command_api.finalize_brand_asset_upload(uuid, uuid, uuid, bigint, text) from public, anon, authenticated;
grant execute on function command_api.finalize_brand_asset_upload(uuid, uuid, uuid, bigint, text) to service_role;

create function command_api.request_financial_evidence_upload(
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
language sql
security definer
set search_path = ''
as $$
  select evidence.request_financial_evidence_upload(p_idempotency_key, p_actor_user_id, p_target_type, p_target_id, p_evidence_type, p_original_filename, p_mime_type, p_file_size_bytes, p_sha256_hex);
$$;

revoke all on function command_api.request_financial_evidence_upload(uuid, uuid, text, uuid, text, text, text, bigint, text) from public, anon, authenticated;
grant execute on function command_api.request_financial_evidence_upload(uuid, uuid, text, uuid, text, text, text, bigint, text) to service_role;

create function command_api.finalize_financial_evidence_upload(
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
language sql
security definer
set search_path = ''
as $$
  select evidence.finalize_financial_evidence_upload(p_intent_id, p_actor_user_id, p_verified_file_size_bytes, p_verified_sha256_hex, p_observed_at, p_provider, p_provider_reference, p_notes);
$$;

revoke all on function command_api.finalize_financial_evidence_upload(uuid, uuid, bigint, text, timestamptz, text, text, text) from public, anon, authenticated;
grant execute on function command_api.finalize_financial_evidence_upload(uuid, uuid, bigint, text, timestamptz, text, text, text) to service_role;

create function command_api.set_account_status(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_target_user_id uuid,
  p_new_status public.account_status,
  p_reason text
)
returns public.user_accounts
language sql
security definer
set search_path = ''
as $$
  select authz.set_account_status(p_idempotency_key, p_actor_user_id, p_session_id, p_target_user_id, p_new_status, p_reason);
$$;

revoke all on function command_api.set_account_status(uuid, uuid, uuid, uuid, public.account_status, text) from public, anon, authenticated;
grant execute on function command_api.set_account_status(uuid, uuid, uuid, uuid, public.account_status, text) to service_role;

-- Resolve ownership before the Edge service downloads a private Storage object.
-- No caller can choose a tenant, bucket, or path through these lookups.
create function command_api.read_brand_asset_upload_intent(
  p_intent_id uuid, p_actor_user_id uuid, p_session_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  intent tenant_config.brand_asset_upload_intents%rowtype;
  decision authz.authorization_decision;
begin
  if p_intent_id is null or p_actor_user_id is null or p_session_id is null then
    raise exception using errcode = '22023', message = 'brand asset lookup input is invalid';
  end if;
  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'brand asset lookup actor mismatch';
  end if;
  select upload.* into intent from tenant_config.brand_asset_upload_intents upload
    where upload.id = p_intent_id;
  if not found then
    raise exception using errcode = 'P0002', message = 'brand asset upload intent was not found';
  end if;
  if intent.submitted_by_user_id <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'only the upload submitter may access the brand asset';
  end if;
  decision := authz.authorize(
    p_actor_user_id, p_session_id, 'manage_tenant_configuration', intent.tenant_id,
    null, null, null, null, null, 'finalize_brand_asset_upload', null
  );
  if decision.decision <> 'ALLOW' then
    raise exception using errcode = '42501', message = decision.reason_code;
  end if;
  if intent.status <> 'finalized' and
    (intent.status <> 'pending' or intent.expires_at <= clock_timestamp()) then
    raise exception using errcode = '55000', message = 'brand asset upload intent is no longer pending';
  end if;
  return pg_catalog.jsonb_build_object('storage_bucket_id', intent.storage_bucket_id,
    'storage_object_path', intent.storage_object_path);
end;
$$;
revoke all on function command_api.read_brand_asset_upload_intent(uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function command_api.read_brand_asset_upload_intent(uuid, uuid, uuid) to service_role;

create function command_api.read_financial_upload_intent(
  p_intent_id uuid, p_actor_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  intent evidence.financial_upload_intents%rowtype;
  target_tenant_id uuid;
  target_submitter_user_id uuid;
begin
  if p_intent_id is null or p_actor_user_id is null then
    raise exception using errcode = '22023', message = 'financial upload lookup input is invalid';
  end if;
  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'financial upload lookup actor mismatch';
  end if;
  select upload.* into intent from evidence.financial_upload_intents upload
    where upload.id = p_intent_id;
  if not found then
    raise exception using errcode = 'P0002', message = 'financial evidence upload intent was not found';
  end if;
  if intent.submitted_by_user_id <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'only the upload submitter may access evidence';
  end if;
  select target.tenant_id, target.submitter_user_id into target_tenant_id, target_submitter_user_id
    from evidence.resolve_financial_operation_target(intent.target_type, intent.target_id) target;
  if target_tenant_id <> intent.tenant_id or target_submitter_user_id <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'financial upload target ownership mismatch';
  end if;
  if not exists (select 1 from public.user_accounts account where account.user_id = p_actor_user_id and account.status = 'active')
    or not exists (select 1 from public.tenants tenant where tenant.id = target_tenant_id and tenant.status = 'active')
    or not exists (select 1 from public.memberships membership
      where membership.user_id = p_actor_user_id and membership.tenant_id = target_tenant_id
        and membership.status = 'active' and (membership.office_id is null or exists (
          select 1 from public.offices office where office.id = membership.office_id
            and office.tenant_id = target_tenant_id and office.status = 'active'))) then
    raise exception using errcode = '42501', message = 'financial evidence requires active organizational context';
  end if;
  if intent.status <> 'finalized' and
    (intent.status <> 'pending' or intent.expires_at <= clock_timestamp()) then
    raise exception using errcode = '40901', message = 'financial evidence upload intent is no longer valid';
  end if;
  return pg_catalog.jsonb_build_object('storage_bucket_id', intent.storage_bucket_id,
    'storage_object_path', intent.storage_object_path);
end;
$$;
revoke all on function command_api.read_financial_upload_intent(uuid, uuid)
  from public, anon, authenticated;
grant execute on function command_api.read_financial_upload_intent(uuid, uuid) to service_role;
