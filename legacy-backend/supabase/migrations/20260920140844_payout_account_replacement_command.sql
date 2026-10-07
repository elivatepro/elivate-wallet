alter table financial_ops.payout_account_command_idempotency
  drop constraint payout_account_command_idempotency_command_type_check;

alter table financial_ops.payout_account_command_idempotency
  add constraint payout_account_command_idempotency_command_type_check
  check (command_type in (
    'add_payout_account',
    'replace_payout_account',
    'deactivate_payout_account',
    'set_primary_payout_account'
  ));

create or replace function financial_ops.replace_payout_account(
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
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.payout_account_command_idempotency%rowtype;
  old_account financial_ops.payout_accounts%rowtype;
  new_account_id uuid;
  membership_id uuid;
  decision authz.authorization_decision;
  should_be_primary boolean;
begin
  if p_idempotency_key is null or p_actor_user_id is null or p_session_id is null
     or p_tenant_id is null or p_existing_payout_account_id is null
     or p_country_code !~ '^[A-Z]{2}$'
     or p_payout_currency is null or p_payout_rail !~ '^[a-z][a-z0-9_]*$'
     or length(btrim(p_institution_code)) = 0
     or length(btrim(p_institution_name)) = 0
     or length(btrim(p_account_reference)) = 0
     or length(btrim(p_account_holder_name)) = 0 then
    raise exception using errcode = '22023', message = 'payout-account replacement input is invalid';
  end if;
  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'payout-account actor mismatch';
  end if;

  request_fingerprint := financial_ops.payout_account_request_fingerprint(
    'replace_payout_account', pg_catalog.jsonb_build_object(
      'actor_user_id', p_actor_user_id, 'tenant_id', p_tenant_id,
      'existing_payout_account_id', p_existing_payout_account_id,
      'country_code', p_country_code, 'payout_currency', p_payout_currency,
      'payout_rail', p_payout_rail, 'institution_code', btrim(p_institution_code),
      'institution_name', btrim(p_institution_name), 'account_reference', btrim(p_account_reference),
      'account_holder_name', btrim(p_account_holder_name), 'make_primary', p_make_primary
    )
  );
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('payout-account:' || p_existing_payout_account_id::text, 0));

  select command.* into existing_command
    from financial_ops.payout_account_command_idempotency command
   where command.idempotency_key = p_idempotency_key;
  if found then
    if existing_command.command_type <> 'replace_payout_account'
       or existing_command.actor_user_id <> p_actor_user_id
       or existing_command.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '23505', message = 'idempotency key already used with different payout-account data';
    end if;
    return (existing_command.payout_account_id, existing_command.result_status, true)::financial_ops.payout_account_command_result;
  end if;

  select account.* into old_account
    from financial_ops.payout_accounts account
   where account.id = p_existing_payout_account_id
   for update;
  if old_account.id is null or old_account.owner_user_id <> p_actor_user_id or old_account.status <> 'active' then
    raise exception using errcode = 'P0002', message = 'active payout account was not found for the actor';
  end if;

  select membership.id into membership_id
    from public.memberships membership
   where membership.tenant_id = p_tenant_id
     and membership.user_id = p_actor_user_id
     and membership.status = 'active'
     and membership.role_key <> 'president_team_member'
   order by membership.is_primary desc, membership.id
   limit 1;
  if membership_id is null then
    raise exception using errcode = '42501', message = 'Wallet owner has no active membership in the target tenant';
  end if;

  decision := authz.authorize(
    p_actor_user_id, p_session_id, 'manage_own_payout_accounts', p_tenant_id,
    null, membership_id, p_actor_user_id, old_account.wallet_id, p_actor_user_id,
    'manage_own_payout_accounts', null
  );
  perform financial_ops.enforce_authorization(decision);

  should_be_primary := p_make_primary or old_account.is_primary;
  insert into financial_ops.payout_accounts (
    wallet_id, owner_user_id, country_code, payout_currency, payout_rail,
    institution_code, institution_name, account_reference, account_holder_name,
    verification_status, is_primary
  ) values (
    old_account.wallet_id, p_actor_user_id, p_country_code, p_payout_currency, p_payout_rail,
    btrim(p_institution_code), btrim(p_institution_name), btrim(p_account_reference),
    btrim(p_account_holder_name), 'pending', false
  ) returning id into new_account_id;

  perform pg_catalog.set_config('financial_ops.payout_account_transition', old_account.id::text, true);
  update financial_ops.payout_accounts
     set status = 'replaced', is_primary = false,
         replaced_by_account_id = new_account_id,
         deactivated_at = clock_timestamp()
   where id = old_account.id;

  if should_be_primary then
    perform financial_ops.clear_primary_payout_accounts(old_account.wallet_id, p_payout_currency, p_payout_rail);
    perform pg_catalog.set_config('financial_ops.payout_account_transition', new_account_id::text, true);
    update financial_ops.payout_accounts set is_primary = true where id = new_account_id;
  end if;

  insert into financial_ops.payout_account_command_idempotency (
    idempotency_key, command_type, request_fingerprint, payout_account_id,
    actor_user_id, tenant_id, result_status
  ) values (
    p_idempotency_key, 'replace_payout_account', request_fingerprint, new_account_id,
    p_actor_user_id, p_tenant_id, 'active'
  );
  perform financial_ops.record_payout_account_change(
    decision, p_session_id, p_tenant_id, new_account_id, 'payout_account_replaced',
    pg_catalog.jsonb_build_object(
      'replaced_account_id', old_account.id,
      'payout_currency', p_payout_currency,
      'payout_rail', p_payout_rail,
      'is_primary', should_be_primary,
      'verification_status', 'pending'
    )
  );
  return (new_account_id, 'active'::financial_ops.payout_account_status, false)::financial_ops.payout_account_command_result;
end;
$$;

revoke all on function financial_ops.replace_payout_account(
  uuid, uuid, uuid, uuid, uuid, text, text, text, text, text, text, text, boolean
) from public, anon, authenticated, service_role;
