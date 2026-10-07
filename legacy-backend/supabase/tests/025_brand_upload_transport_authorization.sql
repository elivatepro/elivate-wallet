begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, auth, extensions, pg_catalog;

select plan(11);

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



set local role service_role;

select is((command_api.request_brand_asset_upload('91000000-0000-0000-0000-000000000701','00000000-0000-0000-0000-000000000701','70000000-0000-0000-0000-000000000701','10000000-0000-0000-0000-000000000701','primary_logo','image/png',128,repeat('a',64),320,80)).storage_bucket_id, 'tenant-brand-assets'::text, 'service role creates a brand intent through exposed transport');

select set_config('test.brand_intent', (command_api.request_brand_asset_upload('91000000-0000-0000-0000-000000000701','00000000-0000-0000-0000-000000000701','70000000-0000-0000-0000-000000000701','10000000-0000-0000-0000-000000000701','primary_logo','image/png',128,repeat('a',64),320,80)).id::text, true);

select is((select count(*) from jsonb_object_keys(command_api.read_brand_asset_upload_intent(current_setting('test.brand_intent')::uuid,'00000000-0000-0000-0000-000000000701','70000000-0000-0000-0000-000000000701'))), 2::bigint, 'lookup returns only the authorized bucket and path');

select throws_ok($$select command_api.read_brand_asset_upload_intent(current_setting('test.brand_intent')::uuid,'00000000-0000-0000-0000-000000000702','70000000-0000-0000-0000-000000000701')$$,'42501',null,'foreign submitter cannot access upload location');

select throws_ok($$select command_api.finalize_brand_asset_upload(current_setting('test.brand_intent')::uuid,'00000000-0000-0000-0000-000000000701','70000000-0000-0000-0000-000000000701',256,repeat('a',64))$$,'23514',null,'mismatched bytes cannot finalize an asset');

select is((command_api.finalize_brand_asset_upload(current_setting('test.brand_intent')::uuid,'00000000-0000-0000-0000-000000000701','70000000-0000-0000-0000-000000000701',128,repeat('a',64))).asset_kind,'primary_logo'::text,'service role finalizes a verified asset');

select is((command_api.finalize_brand_asset_upload(current_setting('test.brand_intent')::uuid,'00000000-0000-0000-0000-000000000701','70000000-0000-0000-0000-000000000701',128,repeat('a',64))).asset_kind,'primary_logo'::text,'authorized finalize retry remains successful');

reset role;

update authz.elevated_sessions set revoked_at=clock_timestamp() where session_id='70000000-0000-0000-0000-000000000701';

set local role service_role;

select throws_ok($$select command_api.read_brand_asset_upload_intent(current_setting('test.brand_intent')::uuid,'00000000-0000-0000-0000-000000000701','70000000-0000-0000-0000-000000000701')$$,'42501',null,'revoked elevation cannot retrieve private upload location');

select throws_ok($$select command_api.request_brand_asset_upload('91000000-0000-0000-0000-000000000701','00000000-0000-0000-0000-000000000701','70000000-0000-0000-0000-000000000701','10000000-0000-0000-0000-000000000701','primary_logo','image/png',128,repeat('a',64),320,80)$$,'42501',null,'revoked elevation cannot replay upload request');

select throws_ok($$select command_api.finalize_brand_asset_upload(current_setting('test.brand_intent')::uuid,'00000000-0000-0000-0000-000000000701','70000000-0000-0000-0000-000000000701',128,repeat('a',64))$$,'42501',null,'revoked elevation cannot replay finalized asset');

reset role;

update authz.elevated_sessions set revoked_at=null where session_id='70000000-0000-0000-0000-000000000701';

update public.user_accounts set status='suspended' where user_id='00000000-0000-0000-0000-000000000701';

set local role service_role;

select throws_ok($$select command_api.request_brand_asset_upload('91000000-0000-0000-0000-000000000701','00000000-0000-0000-0000-000000000701','70000000-0000-0000-0000-000000000701','10000000-0000-0000-0000-000000000701','primary_logo','image/png',128,repeat('a',64),320,80)$$,'42501',null,'suspended actor cannot replay upload request');

reset role;

select is((select count(*) from tenant_config.brand_assets),1::bigint,'retries and rejected calls create exactly one asset');

select * from finish();

rollback;
