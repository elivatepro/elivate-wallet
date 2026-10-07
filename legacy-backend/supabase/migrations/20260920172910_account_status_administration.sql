alter type public.account_status add value if not exists 'restricted';
alter type public.account_status add value if not exists 'deactivated';

create table authz.platform_admin_users (
  user_id uuid primary key references public.user_accounts (user_id) on delete restrict,
  granted_at timestamptz not null default clock_timestamp(),
  granted_by_user_id uuid references public.user_accounts (user_id) on delete restrict,
  revoked_at timestamptz,
  revoked_by_user_id uuid references public.user_accounts (user_id) on delete restrict,
  check ((revoked_at is null and revoked_by_user_id is null)
    or (revoked_at is not null and revoked_by_user_id is not null))
);

create table authz.account_status_command_idempotency (
  idempotency_key uuid primary key,
  actor_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  target_user_id uuid not null references public.user_accounts (user_id) on delete restrict,
  request_fingerprint bytea not null check (octet_length(request_fingerprint) = 32),
  created_at timestamptz not null default clock_timestamp()
);

create index account_status_command_idempotency_actor_created
  on authz.account_status_command_idempotency (actor_user_id, created_at desc);

create or replace function authz.account_status_request_fingerprint(
  p_target_user_id uuid,
  p_new_status public.account_status,
  p_reason text
)
returns bytea
language sql
immutable
security invoker
set search_path = ''
as $$
  select extensions.digest(
    pg_catalog.jsonb_build_object(
      'target_user_id', p_target_user_id,
      'new_status', p_new_status,
      'reason', p_reason
    )::text,
    'sha256'
  );
$$;

create or replace function authz.is_platform_admin(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = 'pg_catalog, public, authz'
as $$
  select exists (
    select 1
      from authz.platform_admin_users admin
     where admin.user_id = p_user_id
       and admin.revoked_at is null
  );
$$;

create or replace function authz.set_account_status(
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_session_id uuid,
  p_target_user_id uuid,
  p_new_status public.account_status,
  p_reason text
)
returns public.user_accounts
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_fingerprint bytea;
  existing_command authz.account_status_command_idempotency%rowtype;
  actor_status public.account_status;
  target_account public.user_accounts%rowtype;
  previous_status public.account_status;
begin
  if p_idempotency_key is null or p_actor_user_id is null
     or p_session_id is null or p_target_user_id is null
     or p_new_status is null or p_reason is null
     or length(btrim(p_reason)) = 0 then
    raise exception using errcode = '22023',
      message = 'account status input is invalid';
  end if;

  if p_new_status not in ('active', 'restricted', 'suspended', 'deactivated') then
    raise exception using errcode = '22023',
      message = 'account status is not administratively assignable';
  end if;

  if auth.uid() is not null and auth.uid() <> p_actor_user_id then
    raise exception using errcode = '42501',
      message = 'account status actor mismatch';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('account-status-command:' || p_idempotency_key::text, 0)
  );

  request_fingerprint := authz.account_status_request_fingerprint(
    p_target_user_id, p_new_status, p_reason
  );

  select command.*
    into existing_command
    from authz.account_status_command_idempotency command
   where command.idempotency_key = p_idempotency_key;

  if found then
    if existing_command.actor_user_id <> p_actor_user_id
       or existing_command.target_user_id <> p_target_user_id
       or existing_command.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '23505',
        message = 'idempotency key already used with different account status data';
    end if;

    select account.* into target_account
      from public.user_accounts account
     where account.user_id = p_target_user_id;
    return target_account;
  end if;

  select account.status into actor_status
    from public.user_accounts account
   where account.user_id = p_actor_user_id;

  if actor_status is null or actor_status <> 'active'
     or not authz.is_platform_admin(p_actor_user_id)
     or not authz.is_elevated_session_valid(p_session_id, p_actor_user_id) then
    insert into authz.security_audit_events (
      actor_user_id, session_id, event_type, permission_key, allowed,
      source, reason_code, target_type, target_id, metadata
    ) values (
      p_actor_user_id, p_session_id, 'account_status_change_denied',
      'manage_account_status', false, 'system_rule', 'platform_admin_step_up_required',
      'user_account', p_target_user_id, '{}'::jsonb
    );
    raise exception using errcode = '42501',
      message = 'platform admin step-up authorization required';
  end if;

  select account.* into target_account
    from public.user_accounts account
   where account.user_id = p_target_user_id
   for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'target account not found';
  end if;

  previous_status := target_account.status;

  update public.user_accounts
     set status = p_new_status
   where user_id = p_target_user_id
  returning * into target_account;

  insert into authz.account_status_command_idempotency (
    idempotency_key, actor_user_id, target_user_id, request_fingerprint
  ) values (
    p_idempotency_key, p_actor_user_id, p_target_user_id, request_fingerprint
  );

  insert into authz.security_audit_events (
    actor_user_id, session_id, event_type, permission_key, allowed,
    source, reason_code, target_type, target_id, metadata
  ) values (
    p_actor_user_id, p_session_id, 'account_status_changed',
    'manage_account_status', true, 'system_rule', 'platform_admin',
    'user_account', p_target_user_id,
    pg_catalog.jsonb_build_object(
      'previous_status', previous_status,
      'new_status', p_new_status,
      'reason', btrim(p_reason)
    )
  );

  return target_account;
end;
$$;

insert into authz.permission_catalog (
  permission_key, area, protected, grantable, wallet_holder_baseline,
  can_target_own_wallet, default_scope_mode, step_up_mode
)
values (
  'manage_account_status', 'Platform Security', true, false, false,
  false, 'not_applicable', 'elevated_and_confirmed'
)
on conflict (permission_key) do nothing;

alter table authz.platform_admin_users enable row level security;
alter table authz.platform_admin_users force row level security;
alter table authz.account_status_command_idempotency enable row level security;
alter table authz.account_status_command_idempotency force row level security;

create policy platform_admin_users_private_deny
  on authz.platform_admin_users as restrictive for all to public
  using (false) with check (false);

create policy account_status_command_idempotency_private_deny
  on authz.account_status_command_idempotency as restrictive for all to public
  using (false) with check (false);

revoke all on table authz.platform_admin_users,
  authz.account_status_command_idempotency from public, anon, authenticated,
  service_role;
revoke all on function authz.account_status_request_fingerprint(
  uuid, public.account_status, text
) from public, anon, authenticated, service_role;
revoke all on function authz.is_platform_admin(uuid)
  from public, anon, authenticated;
revoke all on function authz.set_account_status(
  uuid, uuid, uuid, uuid, public.account_status, text
) from public, anon, authenticated;
grant execute on function authz.set_account_status(
  uuid, uuid, uuid, uuid, public.account_status, text
) to service_role;

comment on table authz.platform_admin_users is
  'Private platform-admin registry. Tenant roles cannot grant account-status authority.';
comment on function authz.set_account_status(uuid, uuid, uuid, uuid, public.account_status, text) is
  'Idempotent, step-up-protected platform-admin account status command.';
