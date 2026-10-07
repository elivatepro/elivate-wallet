begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, auth, extensions, pg_catalog;

select plan(7);

insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
values (
  '12000000-0000-0000-0000-000000000012',
  'authenticated',
  'authenticated',
  'profile-integrity@example.com',
  '{}'::jsonb,
  '{}'::jsonb
), (
  '12000000-0000-0000-0000-000000000013',
  'authenticated',
  'authenticated',
  'other-profile@example.com',
  '{}'::jsonb,
  '{}'::jsonb
);

set constraints auth_users_provision_user_account immediate;

update public.user_profiles
   set display_name = 'Editable Name',
       first_name = 'Editable'
 where user_id = '12000000-0000-0000-0000-000000000012';

select is(
  (select display_name from public.user_profiles
    where user_id = '12000000-0000-0000-0000-000000000012'),
  'Editable Name'::text,
  'profile presentation fields remain editable'
);

select throws_ok(
  $$update public.user_profiles
       set user_id = '12000000-0000-0000-0000-000000000013'
     where user_id = '12000000-0000-0000-0000-000000000012'$$,
  '23514',
  null,
  'profile identity cannot be reassigned'
);

select throws_ok(
  $$update public.user_profiles
       set created_at = created_at - interval '1 second'
     where user_id = '12000000-0000-0000-0000-000000000012'$$,
  '23514',
  null,
  'profile creation timestamp cannot be rewritten'
);

select is(
  (select count(*)::integer from public.user_profiles
    where user_id = '12000000-0000-0000-0000-000000000012'),
  1,
  'profile row remains intact after rejected immutable-field updates'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '12000000-0000-0000-0000-000000000012',
  true
);

select ok(
  exists (
    select 1 from public.user_profiles
     where user_id = '12000000-0000-0000-0000-000000000012'
  ),
  'RLS allows an authenticated user to read their own profile'
);

update public.user_profiles
   set display_name = 'Authenticated Edit'
 where user_id = '12000000-0000-0000-0000-000000000012';

select is(
  (select display_name from public.user_profiles
    where user_id = '12000000-0000-0000-0000-000000000012'),
  'Authenticated Edit'::text,
  'RLS allows an authenticated user to update their own presentation fields'
);

select is(
  (select count(*)::integer from public.user_profiles),
  1,
  'RLS hides another authenticated user profile'
);

select * from finish();
rollback;
