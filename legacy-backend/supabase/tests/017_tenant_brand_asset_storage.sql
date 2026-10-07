begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, auth, extensions, pg_catalog;

select plan(14);

insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
values
  (
    '00000000-0000-0000-0000-000000000701', 'authenticated', 'authenticated',
    'brand-admin@example.test', '{}'::jsonb, '{}'::jsonb
  ),
  (
    '00000000-0000-0000-0000-000000000702', 'authenticated', 'authenticated',
    'brand-member@example.test', '{}'::jsonb, '{}'::jsonb
  );

insert into public.user_accounts (user_id)
values
  ('00000000-0000-0000-0000-000000000701'),
  ('00000000-0000-0000-0000-000000000702');

insert into public.tenants (id, name)
values ('10000000-0000-0000-0000-000000000701', 'Brand Storage Tenant');

insert into public.offices (id, tenant_id, office_type, name)
values (
  '20000000-0000-0000-0000-000000000701',
  '10000000-0000-0000-0000-000000000701',
  'world_team', 'Brand Storage World Team'
);

insert into public.offices (
  id, tenant_id, parent_office_id, office_type, name
)
values (
  '20000000-0000-0000-0000-000000000702',
  '10000000-0000-0000-0000-000000000701',
  '20000000-0000-0000-0000-000000000701',
  'director', 'Brand Storage Director'
);

insert into public.offices (
  id, tenant_id, parent_office_id, office_type, name
)
values (
  '20000000-0000-0000-0000-000000000703',
  '10000000-0000-0000-0000-000000000701',
  '20000000-0000-0000-0000-000000000702',
  'team_leader', 'Brand Storage Team'
);

insert into public.memberships (
  id, tenant_id, user_id, office_id, role_key, is_primary
)
values
  (
    '30000000-0000-0000-0000-000000000701',
    '10000000-0000-0000-0000-000000000701',
    '00000000-0000-0000-0000-000000000701',
    null, 'president_team_member', true
  ),
  (
    '30000000-0000-0000-0000-000000000702',
    '10000000-0000-0000-0000-000000000701',
    '00000000-0000-0000-0000-000000000702',
    '20000000-0000-0000-0000-000000000703', 'member', true
  );

select authz.seed_default_role_policy('10000000-0000-0000-0000-000000000701');

insert into authz.elevated_sessions (
  session_id, user_id, verified_at, valid_until, factor_method
)
values (
  '70000000-0000-0000-0000-000000000701',
  '00000000-0000-0000-0000-000000000701',
  clock_timestamp(), clock_timestamp() + interval '4 minutes', 'test_mfa'
);

-- A verified elevation is tied to a real Auth session.
insert into auth.sessions(id,user_id,aal,created_at,updated_at)
select session_id,user_id,'aal2',verified_at,verified_at from authz.elevated_sessions
on conflict (id) do nothing;

select is(
  (select public from storage.buckets where id = 'tenant-brand-assets'),
  false,
  'tenant brand asset bucket is private'
);

select is(
  (select file_size_limit from storage.buckets where id = 'tenant-brand-assets'),
  5242880::bigint,
  'tenant brand asset bucket has a 5 MiB limit'
);

select ok(
  to_regclass('tenant_config.brand_asset_upload_intents') is not null,
  'brand asset upload intents table exists'
);

select ok(
  has_function_privilege(
    'service_role',
    'tenant_config.request_brand_asset_upload(uuid,uuid,uuid,uuid,text,text,bigint,text,integer,integer)',
    'execute'
  ),
  'trusted service role can request brand asset uploads'
);

select is(
  (tenant_config.request_brand_asset_upload(
    '91000000-0000-0000-0000-000000000701',
    '00000000-0000-0000-0000-000000000701',
    '70000000-0000-0000-0000-000000000701',
    '10000000-0000-0000-0000-000000000701',
    'primary_logo', 'image/png', 128, repeat('a', 64), 320, 80
  )).storage_bucket_id,
  'tenant-brand-assets'::text,
  'trusted request creates a tenant brand asset upload intent'
);

select is(
  (select storage_object_path like '10000000-0000-0000-0000-000000000701/%'
     from tenant_config.brand_asset_upload_intents
    where idempotency_key = '91000000-0000-0000-0000-000000000701'),
  true,
  'upload object path is server-scoped to the tenant'
);

select is(
  (tenant_config.request_brand_asset_upload(
    '91000000-0000-0000-0000-000000000701',
    '00000000-0000-0000-0000-000000000701',
    '70000000-0000-0000-0000-000000000701',
    '10000000-0000-0000-0000-000000000701',
    'primary_logo', 'image/png', 128, repeat('a', 64), 320, 80
  )).id,
  (select id from tenant_config.brand_asset_upload_intents
    where idempotency_key = '91000000-0000-0000-0000-000000000701'),
  'same upload request is idempotent'
);

select throws_ok(
  $$select tenant_config.request_brand_asset_upload(
    '91000000-0000-0000-0000-000000000701',
    '00000000-0000-0000-0000-000000000701',
    '70000000-0000-0000-0000-000000000701',
    '10000000-0000-0000-0000-000000000701',
    'primary_logo', 'image/png', 256, repeat('a', 64), 320, 80
  )$$,
  '23505',
  'idempotency key already used with different asset upload data'
);

select throws_ok(
  $$select tenant_config.request_brand_asset_upload(
    '91000000-0000-0000-0000-000000000702',
    '00000000-0000-0000-0000-000000000702',
    '70000000-0000-0000-0000-000000000702',
    '10000000-0000-0000-0000-000000000701',
    'primary_logo', 'image/png', 128, repeat('b', 64), 320, 80
  )$$,
  '42501',
  'no_matching_allow',
  'non-administrator cannot request a protected upload'
);

select throws_ok(
  $$select tenant_config.finalize_brand_asset_upload(
    (select id from tenant_config.brand_asset_upload_intents
      where idempotency_key = '91000000-0000-0000-0000-000000000701'),
    '00000000-0000-0000-0000-000000000701',
    '70000000-0000-0000-0000-000000000701',
    256, repeat('a', 64)
  )$$,
  '23514',
  'uploaded brand asset does not match its upload intent'
);

select is(
  (tenant_config.finalize_brand_asset_upload(
    (select id from tenant_config.brand_asset_upload_intents
      where idempotency_key = '91000000-0000-0000-0000-000000000701'),
    '00000000-0000-0000-0000-000000000701',
    '70000000-0000-0000-0000-000000000701',
    128, repeat('a', 64)
  )).asset_kind,
  'primary_logo'::text,
  'matching object finalizes into immutable brand asset metadata'
);

select is(
  (select status::text from tenant_config.brand_asset_upload_intents
    where idempotency_key = '91000000-0000-0000-0000-000000000701'),
  'finalized'::text,
  'finalization closes the upload intent'
);

select is(
  (tenant_config.finalize_brand_asset_upload(
    (select id from tenant_config.brand_asset_upload_intents
      where idempotency_key = '91000000-0000-0000-0000-000000000701'),
    '00000000-0000-0000-0000-000000000701',
    '70000000-0000-0000-0000-000000000701',
    128, repeat('a', 64)
  )).id,
  (select finalized_asset_id from tenant_config.brand_asset_upload_intents
    where idempotency_key = '91000000-0000-0000-0000-000000000701'),
  'finalization retry returns the original asset'
);

select is(
  (select count(*)::integer from tenant_config.brand_assets
    where tenant_id = '10000000-0000-0000-0000-000000000701'),
  1,
  'finalization does not duplicate brand asset metadata'
);

select * from finish();
rollback;
