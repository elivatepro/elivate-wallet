begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(11);

insert into auth.users (id, email)
values
  ('00000000-0000-0000-0000-000000000101', 'status-admin@example.test'),
  ('00000000-0000-0000-0000-000000000102', 'status-target@example.test')
on conflict (id) do nothing;

insert into public.user_accounts (user_id, status)
values
  ('00000000-0000-0000-0000-000000000101', 'active'),
  ('00000000-0000-0000-0000-000000000102', 'active')
on conflict (user_id) do update set status = excluded.status;

insert into authz.platform_admin_users (user_id, granted_by_user_id)
values (
  '00000000-0000-0000-0000-000000000101',
  '00000000-0000-0000-0000-000000000101'
)
on conflict (user_id) do update set revoked_at = null, revoked_by_user_id = null;

insert into authz.elevated_sessions (
  session_id, user_id, verified_at, valid_until, factor_method
)
values (
  '00000000-0000-0000-0000-000000000111',
  '00000000-0000-0000-0000-000000000101',
  clock_timestamp() - interval '1 minute',
  clock_timestamp() + interval '3 minutes',
  'test-factor'
)
on conflict (session_id) do nothing;

-- A verified elevation is tied to a real Auth session.
insert into auth.sessions(id,user_id,aal,created_at,updated_at)
select session_id,user_id,'aal2',verified_at,verified_at from authz.elevated_sessions
on conflict (id) do nothing;

select extensions.is(
  (select count(*) from pg_enum where enumtypid = 'public.account_status'::regtype
    and enumlabel in ('active', 'restricted', 'suspended', 'deactivated')),
  4::bigint,
  'account status includes the four approved administrative states'
);

select extensions.is(
  authz.is_platform_admin('00000000-0000-0000-0000-000000000101'),
  true,
  'registered platform admin is recognized'
);

select extensions.isnt(
  authz.is_platform_admin('00000000-0000-0000-0000-000000000102'),
  true,
  'ordinary account is not a platform admin'
);

select extensions.isnt(
  has_function_privilege(
    'authenticated',
    'authz.set_account_status(uuid,uuid,uuid,uuid,public.account_status,text)',
    'EXECUTE'
  ),
  true,
  'authenticated cannot call the platform command directly'
);

select extensions.is(
  has_function_privilege(
    'service_role',
    'authz.set_account_status(uuid,uuid,uuid,uuid,public.account_status,text)',
    'EXECUTE'
  ),
  true,
  'trusted transport can call the platform command'
);

select set_config('request.jwt.claim.sub', '', true);
select extensions.is(
  (select status from authz.set_account_status(
    '00000000-0000-0000-0000-000000000121',
    '00000000-0000-0000-0000-000000000101',
    '00000000-0000-0000-0000-000000000111',
    '00000000-0000-0000-0000-000000000102',
    'restricted',
    'risk review'
  )),
  'restricted'::public.account_status,
  'platform admin can restrict an account'
);

select extensions.is(
  (select count(*) from authz.security_audit_events
    where event_type = 'account_status_changed'
      and target_id = '00000000-0000-0000-0000-000000000102'),
  1::bigint,
  'account status change is audited'
);

select extensions.is(
  (select status from authz.set_account_status(
    '00000000-0000-0000-0000-000000000121',
    '00000000-0000-0000-0000-000000000101',
    '00000000-0000-0000-0000-000000000111',
    '00000000-0000-0000-0000-000000000102',
    'restricted',
    'risk review'
  )),
  'restricted'::public.account_status,
  'replaying the same command returns the original result'
);

select extensions.is(
  (select count(*) from authz.security_audit_events
    where event_type = 'account_status_changed'
      and target_id = '00000000-0000-0000-0000-000000000102'),
  1::bigint,
  'idempotent replay does not duplicate the audit event'
);

select extensions.is(
  (select status from public.user_accounts
    where user_id = '00000000-0000-0000-0000-000000000102'),
  'restricted'::public.account_status,
  'restricted status is persisted'
);

select extensions.isnt(
  (select status from public.user_accounts
    where user_id = '00000000-0000-0000-0000-000000000102'),
  'active'::public.account_status,
  'restricted status is not treated as active'
);

select extensions.finish();
rollback;
