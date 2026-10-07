begin;

create extension if not exists pgtap with schema extensions;

select plan(5);

set local search_path = public, auth, extensions, pg_catalog;

select ok(
  not exists (
    select 1
      from public.user_accounts
     where user_id = '11000000-0000-0000-0000-000000000011'::uuid
  ),
  'provisioning fixture starts without an application account'
);

insert into auth.users (
  id,
  aud,
  role,
  email,
  raw_app_meta_data,
  raw_user_meta_data
)
values (
  '11000000-0000-0000-0000-000000000011'::uuid,
  'authenticated',
  'authenticated',
  'account-provisioning@example.com',
  '{}'::jsonb,
  '{"display_name":"Untrusted Auth Metadata"}'::jsonb
);

set constraints auth_users_provision_user_account immediate;

select ok(
  exists (
    select 1
      from public.user_accounts
     where user_id = '11000000-0000-0000-0000-000000000011'::uuid
       and status = 'active'
       and public_uid like 'EW-%'
  ),
  'Auth signup provisions an active application account with a public UID'
);

select ok(
  exists (
    select 1
      from public.user_profiles
     where user_id = '11000000-0000-0000-0000-000000000011'::uuid
  ),
  'Auth signup provisions an empty editable profile row'
);

select is(
  (
    select display_name
      from public.user_profiles
     where user_id = '11000000-0000-0000-0000-000000000011'::uuid
  ),
  null::text,
  'mutable Auth metadata is not copied into the authoritative profile'
);

insert into public.user_accounts (user_id)
values ('11000000-0000-0000-0000-000000000011'::uuid)
on conflict (user_id) do nothing;

select is(
  (
    select count(*)::integer
      from public.user_accounts
     where user_id = '11000000-0000-0000-0000-000000000011'::uuid
  ),
  1,
  'provisioning is idempotent for a pre-existing account row'
);

select * from finish();
rollback;
