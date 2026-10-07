create type financial_ops.payout_account_command_result as (
  payout_account_id uuid,
  status financial_ops.payout_account_status,
  reused boolean
);

create table financial_ops.payout_account_command_idempotency (
  idempotency_key uuid primary key,
  command_type text not null check (command_type in (
    'add_payout_account',
    'deactivate_payout_account',
    'set_primary_payout_account'
  )),
  request_fingerprint bytea not null check (octet_length(request_fingerprint) = 32),
  payout_account_id uuid not null
    references financial_ops.payout_accounts (id) on delete restrict,
  actor_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  tenant_id uuid not null references public.tenants (id) on delete restrict,
  result_status financial_ops.payout_account_status not null,
  created_at timestamptz not null default clock_timestamp()
);

create index payout_account_command_idempotency_actor
  on financial_ops.payout_account_command_idempotency (actor_user_id, created_at desc);

create index payout_account_command_idempotency_tenant
  on financial_ops.payout_account_command_idempotency (tenant_id, created_at desc);

create or replace function financial_ops.payout_account_request_fingerprint(
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

create or replace function financial_ops.clear_primary_payout_accounts(
  p_wallet_id uuid,
  p_payout_currency text,
  p_payout_rail text
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  account_record financial_ops.payout_accounts%rowtype;
begin
  for account_record in
    select account.*
      from financial_ops.payout_accounts account
     where account.wallet_id = p_wallet_id
       and account.payout_currency = p_payout_currency
       and account.payout_rail = p_payout_rail
       and account.is_primary
       and account.status = 'active'
     for update
  loop
    perform pg_catalog.set_config(
      'financial_ops.payout_account_transition',
      account_record.id::text,
      true
    );
    update financial_ops.payout_accounts
       set is_primary = false
     where id = account_record.id;
  end loop;
end;
$$;

create or replace function financial_ops.record_payout_account_change(
  p_decision authz.authorization_decision,
  p_session_id uuid,
  p_tenant_id uuid,
  p_account_id uuid,
  p_event_type text,
  p_metadata jsonb
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  insert into authz.security_audit_events (
    actor_user_id,
    session_id,
    tenant_id,
    event_type,
    permission_key,
    target_type,
    target_id,
    allowed,
    source,
    source_id,
    reason_code,
    metadata
  )
  values (
    p_decision.actor_user_id,
    p_session_id,
    p_tenant_id,
    p_event_type,
    'manage_own_payout_accounts',
    'payout_account',
    p_account_id,
    true,
    p_decision.source,
    p_decision.source_id,
    p_decision.reason_code,
    p_metadata
  );

  insert into internal.outbox_events (
    tenant_id,
    aggregate_type,
    aggregate_id,
    event_type,
    payload
  )
  values (
    p_tenant_id,
    'payout_account',
    p_account_id,
    p_event_type,
    pg_catalog.jsonb_strip_nulls(p_metadata || pg_catalog.jsonb_build_object(
      'payout_account_id', p_account_id
    ))
  );
end;
$$;

create or replace function financial_ops.validate_payout_account()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  wallet_owner uuid;
  owner_status public.account_status;
begin
  if tg_op = 'UPDATE'
     and current_setting('financial_ops.payout_account_transition', true)
         is distinct from old.id::text then
    raise exception using
      errcode = '55000',
      message = 'payout-account changes require a trusted lifecycle command';
  end if;

  if tg_op = 'UPDATE'
     and (new.id is distinct from old.id
       or new.wallet_id is distinct from old.wallet_id
       or new.owner_user_id is distinct from old.owner_user_id
       or new.created_at is distinct from old.created_at) then
    raise exception using
      errcode = '55000',
      message = 'payout-account identity and ownership are immutable';
  end if;

  select wallet.owner_user_id
    into wallet_owner
    from public.wallets wallet
   where wallet.id = new.wallet_id;

  select account.status
    into owner_status
    from public.user_accounts account
   where account.user_id = new.owner_user_id;

  if wallet_owner is null
     or wallet_owner <> new.owner_user_id
     or owner_status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'payout account must match an active Wallet owner';
  end if;

  return new;
end;
$$;

create or replace function financial_ops.prevent_payout_account_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'payout accounts are retained as historical destination records';
end;
$$;

drop trigger if exists payout_accounts_validate on financial_ops.payout_accounts;
create trigger payout_accounts_validate
  before insert or update on financial_ops.payout_accounts
  for each row execute function financial_ops.validate_payout_account();

drop trigger if exists payout_accounts_prevent_delete on financial_ops.payout_accounts;
create trigger payout_accounts_prevent_delete
  before delete on financial_ops.payout_accounts
  for each row execute function financial_ops.prevent_payout_account_delete();

create or replace function financial_ops.add_payout_account(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_wallet_id uuid,
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
  account_id uuid;
  account_status financial_ops.payout_account_status;
  wallet_owner uuid;
  membership_id uuid;
  decision authz.authorization_decision;
begin
  if p_idempotency_key is null or p_actor_user_id is null or p_session_id is null
     or p_tenant_id is null or p_wallet_id is null
     or p_country_code !~ '^[A-Z]{2}$'
     or p_payout_currency is null or p_payout_rail !~ '^[a-z][a-z0-9_]*$'
     or length(btrim(p_institution_code)) = 0
     or length(btrim(p_institution_name)) = 0
     or length(btrim(p_account_reference)) = 0
     or length(btrim(p_account_holder_name)) = 0 then
    raise exception using errcode = '22023', message = 'payout-account input is invalid';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'payout-account actor mismatch';
  end if;

  request_fingerprint := financial_ops.payout_account_request_fingerprint(
    'add_payout_account',
    pg_catalog.jsonb_build_object(
      'actor_user_id', p_actor_user_id,
      'tenant_id', p_tenant_id,
      'wallet_id', p_wallet_id,
      'country_code', p_country_code,
      'payout_currency', p_payout_currency,
      'payout_rail', p_payout_rail,
      'institution_code', btrim(p_institution_code),
      'institution_name', btrim(p_institution_name),
      'account_reference', btrim(p_account_reference),
      'account_holder_name', btrim(p_account_holder_name),
      'make_primary', p_make_primary
    )
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('payout-account:' || p_wallet_id::text, 0)
  );

  select command.* into existing_command
    from financial_ops.payout_account_command_idempotency command
   where command.idempotency_key = p_idempotency_key;
  if found then
    if existing_command.command_type <> 'add_payout_account'
       or existing_command.actor_user_id <> p_actor_user_id
       or existing_command.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '23505', message = 'idempotency key already used with different payout-account data';
    end if;
    return (existing_command.payout_account_id, existing_command.result_status, true)::financial_ops.payout_account_command_result;
  end if;

  select wallet.owner_user_id into wallet_owner
    from public.wallets wallet where wallet.id = p_wallet_id for update;
  if wallet_owner is null or wallet_owner <> p_actor_user_id then
    raise exception using errcode = '42501', message = 'payout account must belong to the actor Wallet';
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
    null, membership_id, p_actor_user_id, p_wallet_id, p_actor_user_id,
    'manage_own_payout_accounts', null
  );
  perform financial_ops.enforce_authorization(decision);

  insert into financial_ops.payout_accounts (
    wallet_id, owner_user_id, country_code, payout_currency, payout_rail,
    institution_code, institution_name, account_reference, account_holder_name,
    verification_status, is_primary
  )
  values (
    p_wallet_id, p_actor_user_id, p_country_code, p_payout_currency, p_payout_rail,
    btrim(p_institution_code), btrim(p_institution_name), btrim(p_account_reference),
    btrim(p_account_holder_name), 'pending', false
  ) returning id, status into account_id, account_status;

  if p_make_primary then
    perform financial_ops.clear_primary_payout_accounts(p_wallet_id, p_payout_currency, p_payout_rail);
    perform pg_catalog.set_config('financial_ops.payout_account_transition', account_id::text, true);
    update financial_ops.payout_accounts set is_primary = true where id = account_id;
  end if;

  insert into financial_ops.payout_account_command_idempotency (
    idempotency_key, command_type, request_fingerprint, payout_account_id,
    actor_user_id, tenant_id, result_status
  ) values (
    p_idempotency_key, 'add_payout_account', request_fingerprint, account_id,
    p_actor_user_id, p_tenant_id, account_status
  );

  perform financial_ops.record_payout_account_change(
    decision, p_session_id, p_tenant_id, account_id, 'payout_account_added',
    pg_catalog.jsonb_build_object(
      'payout_currency', p_payout_currency,
      'payout_rail', p_payout_rail,
      'is_primary', p_make_primary,
      'verification_status', 'pending'
    )
  );

  return (account_id, account_status, false)::financial_ops.payout_account_command_result;
end;
$$;

create or replace function financial_ops.deactivate_payout_account(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_payout_account_id uuid
)
returns financial_ops.payout_account_command_result
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.payout_account_command_idempotency%rowtype;
  account_record financial_ops.payout_accounts%rowtype;
  membership_id uuid;
  decision authz.authorization_decision;
begin
  request_fingerprint := financial_ops.payout_account_request_fingerprint(
    'deactivate_payout_account', pg_catalog.jsonb_build_object(
      'actor_user_id', p_actor_user_id, 'tenant_id', p_tenant_id,
      'payout_account_id', p_payout_account_id
    )
  );
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('payout-account:' || p_payout_account_id::text, 0));
  select command.* into existing_command from financial_ops.payout_account_command_idempotency command where command.idempotency_key = p_idempotency_key;
  if found then
    if existing_command.command_type <> 'deactivate_payout_account' or existing_command.actor_user_id <> p_actor_user_id or existing_command.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '23505', message = 'idempotency key already used with different payout-account data';
    end if;
    return (existing_command.payout_account_id, existing_command.result_status, true)::financial_ops.payout_account_command_result;
  end if;
  select account.* into account_record from financial_ops.payout_accounts account where account.id = p_payout_account_id for update;
  if account_record.id is null or account_record.owner_user_id <> p_actor_user_id or account_record.status <> 'active' then
    raise exception using errcode = 'P0002', message = 'active payout account was not found for the actor';
  end if;
  select membership.id into membership_id from public.memberships membership where membership.tenant_id = p_tenant_id and membership.user_id = p_actor_user_id and membership.status = 'active' and membership.role_key <> 'president_team_member' order by membership.is_primary desc, membership.id limit 1;
  if membership_id is null then raise exception using errcode = '42501', message = 'Wallet owner has no active membership in the target tenant'; end if;
  decision := authz.authorize(p_actor_user_id, p_session_id, 'manage_own_payout_accounts', p_tenant_id, null, membership_id, p_actor_user_id, account_record.wallet_id, p_actor_user_id, 'manage_own_payout_accounts', null);
  perform financial_ops.enforce_authorization(decision);
  perform pg_catalog.set_config('financial_ops.payout_account_transition', account_record.id::text, true);
  update financial_ops.payout_accounts set status = 'deactivated', is_primary = false, deactivated_at = clock_timestamp() where id = account_record.id;
  insert into financial_ops.payout_account_command_idempotency values (p_idempotency_key, 'deactivate_payout_account', request_fingerprint, account_record.id, p_actor_user_id, p_tenant_id, 'deactivated');
  perform financial_ops.record_payout_account_change(decision, p_session_id, p_tenant_id, account_record.id, 'payout_account_deactivated', pg_catalog.jsonb_build_object('payout_currency', account_record.payout_currency, 'payout_rail', account_record.payout_rail));
  return (account_record.id, 'deactivated'::financial_ops.payout_account_status, false)::financial_ops.payout_account_command_result;
end;
$$;

create or replace function financial_ops.set_primary_payout_account(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid,
  p_payout_account_id uuid
)
returns financial_ops.payout_account_command_result
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command financial_ops.payout_account_command_idempotency%rowtype;
  account_record financial_ops.payout_accounts%rowtype;
  membership_id uuid;
  decision authz.authorization_decision;
begin
  request_fingerprint := financial_ops.payout_account_request_fingerprint('set_primary_payout_account', pg_catalog.jsonb_build_object('actor_user_id', p_actor_user_id, 'tenant_id', p_tenant_id, 'payout_account_id', p_payout_account_id));
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('payout-account:' || p_payout_account_id::text, 0));
  select command.* into existing_command from financial_ops.payout_account_command_idempotency command where command.idempotency_key = p_idempotency_key;
  if found then
    if existing_command.command_type <> 'set_primary_payout_account' or existing_command.actor_user_id <> p_actor_user_id or existing_command.request_fingerprint <> request_fingerprint then raise exception using errcode = '23505', message = 'idempotency key already used with different payout-account data'; end if;
    return (existing_command.payout_account_id, existing_command.result_status, true)::financial_ops.payout_account_command_result;
  end if;
  select account.* into account_record from financial_ops.payout_accounts account where account.id = p_payout_account_id for update;
  if account_record.id is null or account_record.owner_user_id <> p_actor_user_id or account_record.status <> 'active' or account_record.verification_status <> 'verified' then raise exception using errcode = '23514', message = 'only an active verified payout account may become primary'; end if;
  select membership.id into membership_id from public.memberships membership where membership.tenant_id = p_tenant_id and membership.user_id = p_actor_user_id and membership.status = 'active' and membership.role_key <> 'president_team_member' order by membership.is_primary desc, membership.id limit 1;
  if membership_id is null then raise exception using errcode = '42501', message = 'Wallet owner has no active membership in the target tenant'; end if;
  decision := authz.authorize(p_actor_user_id, p_session_id, 'manage_own_payout_accounts', p_tenant_id, null, membership_id, p_actor_user_id, account_record.wallet_id, p_actor_user_id, 'manage_own_payout_accounts', null);
  perform financial_ops.enforce_authorization(decision);
  perform financial_ops.clear_primary_payout_accounts(account_record.wallet_id, account_record.payout_currency, account_record.payout_rail);
  perform pg_catalog.set_config('financial_ops.payout_account_transition', account_record.id::text, true);
  update financial_ops.payout_accounts set is_primary = true where id = account_record.id;
  insert into financial_ops.payout_account_command_idempotency values (p_idempotency_key, 'set_primary_payout_account', request_fingerprint, account_record.id, p_actor_user_id, p_tenant_id, account_record.status);
  perform financial_ops.record_payout_account_change(decision, p_session_id, p_tenant_id, account_record.id, 'payout_account_primary_changed', pg_catalog.jsonb_build_object('payout_currency', account_record.payout_currency, 'payout_rail', account_record.payout_rail));
  return (account_record.id, account_record.status, false)::financial_ops.payout_account_command_result;
end;
$$;

alter table financial_ops.payout_account_command_idempotency enable row level security;
alter table financial_ops.payout_account_command_idempotency force row level security;
create policy payout_account_command_idempotency_private_deny
  on financial_ops.payout_account_command_idempotency as restrictive for all to public using (false) with check (false);

revoke all on financial_ops.payout_account_command_idempotency from public, anon, authenticated, service_role;
revoke all on function financial_ops.payout_account_request_fingerprint(text, jsonb) from public, anon, authenticated, service_role;
revoke all on function financial_ops.clear_primary_payout_accounts(uuid, text, text) from public, anon, authenticated, service_role;
revoke all on function financial_ops.record_payout_account_change(authz.authorization_decision, uuid, uuid, uuid, text, jsonb) from public, anon, authenticated, service_role;
revoke all on function financial_ops.validate_payout_account() from public, anon, authenticated, service_role;
revoke all on function financial_ops.prevent_payout_account_delete() from public, anon, authenticated, service_role;
revoke all on function financial_ops.add_payout_account(uuid, uuid, uuid, uuid, uuid, text, text, text, text, text, text, text, boolean) from public, anon, authenticated, service_role;
revoke all on function financial_ops.deactivate_payout_account(uuid, uuid, uuid, uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function financial_ops.set_primary_payout_account(uuid, uuid, uuid, uuid, uuid) from public, anon, authenticated, service_role;

comment on table financial_ops.payout_account_command_idempotency is
  'Private replay registry for step-up-protected reusable payout-account lifecycle commands.';
