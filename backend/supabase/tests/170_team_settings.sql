-- Blueprint 17 — B6 170: team settings and branding (W-20, D-11). The two new
-- protected keys; every network starts on revision 1; only
-- manage_team_settings with a fresh PIN saves; validation; stale revisions;
-- immutable history and restore; audit and T05; paused networks; safe reads.
begin;
create extension if not exists pgtap with schema extensions;
select plan(46);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.uid(n int) returns text language sql stable as
  $$ select uid from identity.accounts where user_id = pg_temp.u(n) $$;
create function pg_temp.k() returns text language sql volatile as
  $$ select 'k' || md5(random()::text || clock_timestamp()::text) $$;
create temp table ids (name text primary key, id uuid not null);
create function pg_temp.id(p_name text) returns uuid language sql stable as
  $$ select id from ids where name = p_name $$;
create function pg_temp.ws(n int) returns uuid language sql stable as $$
  select id from org.memberships where user_id = pg_temp.u(n) and status = 'active'
  order by (role = 'member'), started_at limit 1
$$;
create function pg_temp.fails(p_sql text) returns text language plpgsql as $$
declare
  msg text;
  detail text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics msg = message_text, detail = pg_exception_detail;
  return msg || ':' || coalesce(case when detail like '{%' then detail::jsonb->>'reason' end, '');
end $$;
create function pg_temp.save(n int, p_rev int, p_fields jsonb, p_key text default null) returns jsonb
language sql volatile as $$
  select api.update_team_settings(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_rev, p_fields,
    coalesce(p_key, pg_temp.k()))
$$;
create function pg_temp.rev() returns int language sql stable as
  $$ select revision from org.tenant_settings where tenant_id = pg_temp.id('cedar') $$;

-- 1 President (Cedar) · 2 World Team leader · 3 member · 4 President (Pine) · 9 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 9) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 9) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 9) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(9), 'Test admin');
insert into ids select 'cedar', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Cedar Network', 'CDR', pg_temp.k())
  ->>'tenantId')::uuid;
insert into ids select 'pine', (api.start_network(pg_temp.u(4), pg_temp.s(4), 'Pine Network', 'PIN', pg_temp.k())
  ->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('cedar'), 'Pilot', pg_temp.k());
  perform api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('pine'), 'Pilot', pg_temp.k());
end $$;
insert into ids select 'WT', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), 'world_team', 'World', null,
  array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), pg_temp.id('WT'), pg_temp.uid(3), pg_temp.k());
end $$;

-- ── Catalogue (5) ──
select is((select count(*)::int from authz.permission_catalog), 34, 'A-03 now has 34 rows');
select is((select protected::text || '/' || grantable::text || '/' || scope from authz.permission_catalog
  where key = 'manage_team_settings'), 'true/false/tenant', 'manage_team_settings is protected and not grantable');
select is((select string_agg(role::text, ',' order by role) from authz.default_role_permissions
  where permission_key = 'manage_team_settings' and allowed), 'president_team_member', 'President only (Q4)');
select is((select string_agg(role::text, ',' order by role) from authz.default_role_permissions
  where permission_key = 'request_restore' and allowed), 'world_team_member,president_team_member',
  'World Team and President may request a restore (W-24)');
select is((select count(*)::int from authz.role_permissions where tenant_id = pg_temp.id('cedar')
  and permission_key in ('manage_team_settings', 'request_restore')), 10, 'a new network gets the defaults');

-- ── Revision 1 (4) ──
select is((select revision || '/' || theme || '/' || locale || '/' || time_zone from org.tenant_settings
  where tenant_id = pg_temp.id('cedar')), '1/ember/en-NG/Africa/Lagos', 'every network starts on Ember');
select is((select name || '/' || short_name from org.tenant_setting_revisions
  where tenant_id = pg_temp.id('cedar') and revision = 1), 'Cedar Network/CDR', 'revision 1 is recorded');
select is((api.workspace_brand(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3))->>'theme'), 'ember',
  'every member reads the brand');
select is((select count(*)::int from jsonb_object_keys(api.workspace_brand(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3))) k
  where k like '%Key%'), 0, 'the brand never carries storage keys');

-- ── Who edits (4) ──
select is((api.team_settings(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1))->>'canEdit')::boolean, true,
  'the President edits');
select is(pg_temp.fails($$ select api.team_settings(pg_temp.u(2), pg_temp.s(2), pg_temp.ws(2)) $$),
  'authorization_denied:', 'a World Team leader cannot');
select is(pg_temp.fails($$ select pg_temp.save(3, 1, '{"theme": "cobalt"}') $$), 'authorization_denied:',
  'a member cannot save shared colours (W-20)');
select is(pg_temp.fails($$ select api.brand_upload_key(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), 'png') $$),
  'authorization_denied:', 'nor get an upload key');

-- ── Saving (9) ──
update identity.session_pin_proofs set verified_at = now() - interval '10 minutes' where user_id = pg_temp.u(1);
select is(pg_temp.fails($$ select pg_temp.save(1, 1, '{"theme": "cobalt"}') $$), 'step_up_required:',
  'saving needs a fresh PIN');
update identity.session_pin_proofs set verified_at = now() where user_id = pg_temp.u(1);
create temp table r2 as select pg_temp.save(1, 1, '{"theme": "cobalt", "slogan": "  Grow together, keep more "}',
  'k-settings-0000000001') as r;
select is((select (r->'settings'->>'revision')::int from r2), 2, 'a save makes revision 2');
select is((select r->'settings'->>'slogan' from r2), 'Grow together, keep more', 'text is trimmed');
select is((select changed::text from org.tenant_setting_revisions where tenant_id = pg_temp.id('cedar') and revision = 2),
  '{theme,slogan}', 'the revision lists what changed');
select is((pg_temp.save(1, 1, '{"theme": "cobalt", "slogan": "  Grow together, keep more "}',
  'k-settings-0000000001')->>'replayed')::boolean, true, 'the same key replays');
select is(pg_temp.rev(), 2, 'a replay changes nothing');
select is(pg_temp.fails($$ select pg_temp.save(1, 1, '{"slogan": "Late"}') $$), 'conflict:stale_revision',
  'a save on an old revision is refused');
select is(pg_temp.fails($$ select pg_temp.save(1, 2, '{"theme": "cobalt"}') $$), 'conflict:no_changes',
  'a save with no changes is refused');
select is((select count(*)::int from notify.items where kind = 'org.branding_changed' and user_id = pg_temp.u(1)), 1,
  'T05 and a bell item go to the President Team');

-- ── Validation (8) ──
select is(pg_temp.fails($$ select pg_temp.save(1, 2, '{"theme": "neon"}') $$), 'validation_error:',
  'only the six themes (Q3)');
select is(pg_temp.fails($$ select pg_temp.save(1, 2, '{"css": "body{}"}') $$), 'validation_error:',
  'unknown fields are refused');
select is(pg_temp.fails($$ select pg_temp.save(1, 2, jsonb_build_object('slogan', repeat('x', 61))) $$),
  'validation_error:', 'slogans stop at 60 characters');
select is(pg_temp.fails($$ select pg_temp.save(1, 2, '{"helpUrl": "http://help.example"}') $$), 'validation_error:',
  'the help website must be HTTPS');
select is(pg_temp.fails($$ select pg_temp.save(1, 2, '{"helpUrl": "https://user:pw@help.example"}') $$),
  'validation_error:', 'and carry no credentials');
select is(pg_temp.fails($$ select pg_temp.save(1, 2, jsonb_build_object('logoKey',
  'brand/' || pg_temp.id('pine') || '/' || gen_random_uuid() || '.png')) $$), 'validation_error:',
  'an asset of another network is refused');
select is(pg_temp.fails($$ select pg_temp.save(1, 2, '{"timeZone": "Europe/London"}') $$), 'validation_error:',
  'WAT only for now');
select is(pg_temp.save(1, 2, '{"supportPhone": "0801 234 2210", "supportEmail": "Help@Cedar.Example"}')
  ->'settings'->>'supportPhone', '+2348012342210', 'a local number is stored in full');

-- ── Logos and audit (6) ──
insert into ids values ('logo', gen_random_uuid());
select is((pg_temp.save(1, 3, jsonb_build_object('logoKey', 'brand/' || pg_temp.id('cedar') || '/'
  || pg_temp.id('logo') || '.png', 'name', 'Cedar Network Ltd'))->'settings'->>'hasLogo')::boolean, true,
  'a logo of this network is accepted');
select is((select name from org.tenants where id = pg_temp.id('cedar')), 'Cedar Network Ltd', 'the name changes');
select is(api.brand_asset_key(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), 'logo')->>'objectKey',
  'brand/' || pg_temp.id('cedar') || '/' || pg_temp.id('logo') || '.png', 'the app server gets the key for a member');
select is(pg_temp.fails($$ select api.brand_asset_key(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), 'icon') $$),
  'not_found:', 'no icon yet');
select is((select safe_after->>'logoKey' from audit.tenant_events where tenant_id = pg_temp.id('cedar')
  and action = 'settings.updated' order by id desc limit 1), 'true', 'the audit says a logo exists, never where');
select is((select count(*)::int from audit.tenant_events where tenant_id = pg_temp.id('cedar')
  and action = 'settings.updated'), 3, 'every save is audited');

-- ── History and restore (5) ──
select throws_ok($$ update org.tenant_setting_revisions set theme = 'rose' where tenant_id = pg_temp.id('cedar') $$,
  'P0001', 'invariant_violation', 'revisions are immutable');
create temp table rr as select api.restore_team_settings_revision(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), 4, 1,
  pg_temp.k()) as r;
select is((select r->'settings'->>'theme' || '/' || (r->'settings'->>'revision') || '/' || (r->'settings'->>'name') from rr),
  'ember/5/Cedar Network', 'restoring revision 1 makes revision 5 with its values');
select is((select restored_from from org.tenant_setting_revisions where tenant_id = pg_temp.id('cedar') and revision = 5),
  1, 'it records where it came from');
select is((select count(*)::int from org.tenant_setting_revisions where tenant_id = pg_temp.id('cedar')), 5,
  'nothing is overwritten');
select is(pg_temp.fails($$ select api.restore_team_settings_revision(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1), 5, 5,
  pg_temp.k()) $$), 'not_found:', 'only an older revision can be restored');

-- ── Paused networks and isolation (5) ──
update org.tenants set status = 'suspended' where id = pg_temp.id('cedar');
select is((api.team_settings(pg_temp.u(1), pg_temp.s(1), pg_temp.ws(1))->>'canEdit')::boolean, false,
  'a paused network shows settings read-only');
select is(pg_temp.fails($$ select pg_temp.save(1, 5, '{"theme": "rose"}') $$), 'network_not_active:',
  'and refuses changes');
select is(api.workspace_brand(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3))->>'theme', 'ember',
  'members still see the brand');
update org.tenants set status = 'active' where id = pg_temp.id('cedar');
select is(api.workspace_brand(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4))->>'name', 'Pine Network',
  'each network reads its own brand');
select is(pg_temp.fails($$ select api.workspace_brand(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(1)) $$),
  'workspace_invalid:', 'never another network''s');

select * from finish();
rollback;
