-- Blueprint 17 — B1/B2: team settings and branding (W-20, D-11). One current
-- settings row per network and an immutable revision for every save; a
-- restore copies an older revision into a new one. Edited only through the
-- new protected President-only permission `manage_team_settings` (owner
-- answer Q4, 2026-10-10), with the PIN. Restore requests (W-24) get their own
-- protected key `request_restore` (World Team and President).

-- ── Permissions (A-03 catalogue: 32 → 34 rows) ─────────────────────────────

do $$
begin
  alter table authz.permission_catalog disable trigger permission_catalog_immutable;
  alter table authz.default_role_permissions disable trigger default_role_permissions_immutable;
  insert into authz.permission_catalog (key, protected, grantable, scope, wallet_holder_baseline, can_target_own_wallet)
  values
    ('manage_team_settings', true, false, 'tenant', false, false),
    ('request_restore', true, false, 'tenant', false, false)
  on conflict (key) do nothing;
  insert into authz.default_role_permissions (role, permission_key, allowed)
  select r, k.key, case k.key
    when 'manage_team_settings' then r = 'president_team_member'
    else r in ('world_team_member', 'president_team_member') end
  from unnest(enum_range(null::org.role)) r
  cross join (values ('manage_team_settings'), ('request_restore')) k (key)
  on conflict do nothing;
  alter table authz.permission_catalog enable trigger permission_catalog_immutable;
  alter table authz.default_role_permissions enable trigger default_role_permissions_immutable;
end;
$$;

insert into authz.role_permissions (tenant_id, role, permission_key, allowed)
select t.id, d.role, d.permission_key, d.allowed
from org.tenants t
cross join authz.default_role_permissions d
where d.permission_key in ('manage_team_settings', 'request_restore')
on conflict (tenant_id, role, permission_key) do nothing;

-- Audit targets for settings, backups and restore requests.
alter table audit.tenant_events drop constraint tenant_events_target_type_check;
alter table audit.tenant_events add constraint tenant_events_target_type_check
  check (target_type = any (array['tenant', 'office', 'membership', 'role_permission', 'access_assignment',
    'reviewer_assignment', 'invitation', 'allocation_policy', 'income', 'evidence', 'withdrawal', 'payout',
    'pocket_transfer', 'entry', 'reversal', 'export', 'subscription', 'billing_payment', 'billing_owner',
    'tenant_settings', 'backup', 'restore_request']));

-- ── Fixed choices (owner answer Q3; applied decisions) ─────────────────────

-- The six team themes (Paper TS01d). Ember is today's coral.
create function org.themes() returns text[]
language sql immutable set search_path = '' as $$
  select array['ember', 'cobalt', 'fern', 'iris', 'saffron', 'rose']
$$;

-- English (Nigeria) and WAT only until the app is translated (Part A).
create function org.locales() returns text[]
language sql immutable set search_path = '' as $$ select array['en-NG'] $$;

create function org.time_zones() returns text[]
language sql immutable set search_path = '' as $$ select array['Africa/Lagos'] $$;

-- ── Settings and revisions ────────────────────────────────────────────────

create table org.tenant_settings (
  tenant_id uuid primary key references org.tenants (id) on delete restrict,
  revision int not null check (revision > 0),
  theme text not null default 'ember' check (theme = any (org.themes())),
  slogan text check (slogan is null or length(slogan) between 1 and 60),
  support_name text check (support_name is null or length(support_name) between 1 and 80),
  support_email text check (support_email is null or (length(support_email) <= 254
    and support_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  support_phone text check (support_phone is null or support_phone ~ '^\+[1-9][0-9]{6,14}$'),
  help_url text check (help_url is null or (length(help_url) <= 300
    and help_url ~ '^https://[^/@[:space:]?#]+(/[^[:space:]]*)?$')),
  locale text not null default 'en-NG' check (locale = any (org.locales())),
  time_zone text not null default 'Africa/Lagos' check (time_zone = any (org.time_zones())),
  logo_key text,
  icon_key text,
  logo_light_key text,
  updated_at timestamptz not null default now(),
  check (logo_key is null or logo_key ~ ('^brand/' || tenant_id::text || '/[0-9a-f-]{36}\.(jpg|png|webp)$')),
  check (icon_key is null or icon_key ~ ('^brand/' || tenant_id::text || '/[0-9a-f-]{36}\.(jpg|png|webp)$')),
  check (logo_light_key is null or logo_light_key ~ ('^brand/' || tenant_id::text || '/[0-9a-f-]{36}\.(jpg|png|webp)$'))
);

alter table org.tenant_settings enable row level security;

create table org.tenant_setting_revisions (
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  revision int not null check (revision > 0),
  name text not null,
  short_name text not null,
  theme text not null,
  slogan text,
  support_name text,
  support_email text,
  support_phone text,
  help_url text,
  locale text not null,
  time_zone text not null,
  logo_key text,
  icon_key text,
  logo_light_key text,
  changed text[] not null default '{}',
  restored_from int,
  actor_user_id uuid references identity.accounts (user_id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (tenant_id, revision),
  check (restored_from is null or restored_from < revision),
  check ((revision = 1) = (actor_user_id is null))
);

create index tenant_setting_revisions_actor_idx on org.tenant_setting_revisions (actor_user_id);

alter table org.tenant_setting_revisions enable row level security;

create trigger tenant_setting_revisions_immutable
before update or delete or truncate on org.tenant_setting_revisions
for each statement execute function audit.reject_change();

-- Snapshot of the current settings (plus name and short name) as a revision.
create function org.snapshot_settings(
  p_tenant_id uuid,
  p_changed text[],
  p_restored_from int,
  p_actor_user_id uuid
)
returns void
language sql
set search_path = ''
as $$
  insert into org.tenant_setting_revisions (tenant_id, revision, name, short_name, theme, slogan, support_name,
    support_email, support_phone, help_url, locale, time_zone, logo_key, icon_key, logo_light_key, changed,
    restored_from, actor_user_id)
  select s.tenant_id, s.revision, t.name, t.short_name, s.theme, s.slogan, s.support_name, s.support_email,
    s.support_phone, s.help_url, s.locale, s.time_zone, s.logo_key, s.icon_key, s.logo_light_key, p_changed,
    p_restored_from, p_actor_user_id
  from org.tenant_settings s join org.tenants t on t.id = s.tenant_id
  where s.tenant_id = p_tenant_id;
$$;

-- Every network starts at revision 1: Ember, no logo, no support contact.
create function org.on_tenant_created()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  insert into org.tenant_settings (tenant_id, revision) values (new.id, 1);
  perform org.snapshot_settings(new.id, '{}', null, null);
  return null;
end;
$$;

create trigger tenant_settings_seed
after insert on org.tenants
for each row execute function org.on_tenant_created();

insert into org.tenant_settings (tenant_id, revision)
select id, 1 from org.tenants
on conflict (tenant_id) do nothing;

insert into org.tenant_setting_revisions (tenant_id, revision, name, short_name, theme, locale, time_zone)
select t.id, 1, t.name, t.short_name, s.theme, s.locale, s.time_zone
from org.tenants t join org.tenant_settings s on s.tenant_id = t.id
on conflict do nothing;

-- ── Wire shapes ───────────────────────────────────────────────────────────

-- Safe presentation fields any member of the network may read (W-20). Never
-- storage keys: logos are fetched through the app server.
create function org.brand_json(p_tenant_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'tenantId', t.id,
    'name', t.name,
    'shortName', t.short_name,
    'initial', upper(left(t.name, 1)),
    'theme', s.theme,
    'slogan', s.slogan,
    'revision', s.revision,
    'hasLogo', s.logo_key is not null,
    'hasIcon', s.icon_key is not null,
    'hasLogoLight', s.logo_light_key is not null,
    'support', case when coalesce(s.support_name, s.support_email, s.support_phone, s.help_url) is not null then
      jsonb_build_object('name', s.support_name, 'email', s.support_email, 'phone', s.support_phone,
        'helpUrl', s.help_url) end,
    'locale', s.locale,
    'timeZone', s.time_zone
  )
  from org.tenants t join org.tenant_settings s on s.tenant_id = t.id
  where t.id = p_tenant_id;
$$;

create function org.revision_json(p_r org.tenant_setting_revisions)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'revision', p_r.revision,
    'changed', to_jsonb(p_r.changed),
    'restoredFrom', p_r.restored_from,
    'actor', case when p_r.actor_user_id is not null then org.person(p_r.actor_user_id) end,
    'createdAt', p_r.created_at
  );
$$;

-- "the logo and slogan" for T05 and the bell.
create function org.settings_summary(p_changed text[])
returns text
language sql
immutable
set search_path = ''
as $$
  with labels as (
    select distinct on (label) label, ord
    from unnest(p_changed) with ordinality c (field, ord)
    cross join lateral (select case c.field
      when 'name' then 'team name'
      when 'shortName' then 'short name'
      when 'theme' then 'theme'
      when 'slogan' then 'slogan'
      when 'logoKey' then 'logo'
      when 'iconKey' then 'logo'
      when 'logoLightKey' then 'logo'
      when 'helpUrl' then 'help website'
      when 'locale' then 'language'
      when 'timeZone' then 'time zone'
      else 'support contact' end as label) l
    order by label, ord
  ), ordered as (
    select array_agg(label order by ord) as a from labels
  )
  select 'the ' || case
    when cardinality(a) = 1 then a[1]
    else array_to_string(a[1:cardinality(a) - 1], ', ') || ' and ' || a[cardinality(a)]
  end
  from ordered;
$$;

-- T05 + bell to the President Team (Part A, applied decision).
create function org.notify_branding(p_tenant_id uuid, p_actor_user_id uuid, p_revision int, p_changed text[])
returns void
language plpgsql
set search_path = ''
as $$
declare
  recipient uuid;
  params jsonb := jsonb_build_object(
    'network', notify.network(p_tenant_id),
    'actor', coalesce(org.person(p_actor_user_id)->>'name', org.person(p_actor_user_id)->>'uid'),
    'summary', org.settings_summary(p_changed),
    'revision', p_revision::text,
    'path', '/app/settings');
begin
  for recipient in
    select distinct m.user_id from org.memberships m
    join identity.accounts a on a.user_id = m.user_id
    where m.tenant_id = p_tenant_id and m.status = 'active' and m.role = 'president_team_member'
      and a.status = 'active'
  loop
    perform notify.emit(recipient, p_tenant_id, 'org.branding_changed', 'tenant_settings', p_tenant_id, params,
      p_tenant_id::text || ':' || p_revision::text, params);
  end loop;
end;
$$;

-- ── Validation ────────────────────────────────────────────────────────────

-- Optional text: trimmed; empty means "clear".
create function org.optional_text(p_fields jsonb, p_key text)
returns text
language plpgsql
set search_path = ''
as $$
begin
  if jsonb_typeof(p_fields->p_key) = 'null' then
    return null;
  end if;
  if jsonb_typeof(p_fields->p_key) is distinct from 'string' then
    perform identity.fail('validation_error', jsonb_build_object('field', p_key));
  end if;
  return nullif(btrim(p_fields->>p_key), '');
end;
$$;

-- Applies the listed fields to the current row (locked by the caller) and
-- returns the names that actually changed. Unknown keys are refused.
create function org.apply_settings(p_tenant_id uuid, p_fields jsonb)
returns text[]
language plpgsql
set search_path = ''
as $$
declare
  allowed text[] := array['name', 'shortName', 'theme', 'slogan', 'supportName', 'supportEmail', 'supportPhone',
    'helpUrl', 'locale', 'timeZone', 'logoKey', 'iconKey', 'logoLightKey'];
  k text;
  v text;
  before_s org.tenant_settings;
  before_t org.tenants;
  s org.tenant_settings;
  t org.tenants;
  changed text[] := '{}'::text[];
  key_pattern text := '^brand/' || p_tenant_id::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$';
begin
  if jsonb_typeof(p_fields) is distinct from 'object' or p_fields = '{}'::jsonb then
    perform identity.fail('validation_error', jsonb_build_object('field', 'fields'));
  end if;
  for k in select jsonb_object_keys(p_fields) loop
    if not k = any (allowed) then
      perform identity.fail('validation_error', jsonb_build_object('field', k));
    end if;
  end loop;

  select * into before_s from org.tenant_settings where tenant_id = p_tenant_id;
  select * into before_t from org.tenants where id = p_tenant_id;
  s := before_s;
  t := before_t;

  if p_fields ? 'name' then
    v := org.optional_text(p_fields, 'name');
    if v is null or length(v) not between 2 and 100 then
      perform identity.fail('validation_error', jsonb_build_object('field', 'name'));
    end if;
    t.name := v;
  end if;
  if p_fields ? 'shortName' then
    v := org.optional_text(p_fields, 'shortName');
    if v is null or length(v) not between 1 and 30 then
      perform identity.fail('validation_error', jsonb_build_object('field', 'shortName'));
    end if;
    t.short_name := v;
  end if;
  if p_fields ? 'theme' then
    v := org.optional_text(p_fields, 'theme');
    if v is null or not v = any (org.themes()) then
      perform identity.fail('validation_error', jsonb_build_object('field', 'theme'));
    end if;
    s.theme := v;
  end if;
  if p_fields ? 'slogan' then
    v := org.optional_text(p_fields, 'slogan');
    if v is not null and length(v) > 60 then
      perform identity.fail('validation_error', jsonb_build_object('field', 'slogan'));
    end if;
    s.slogan := v;
  end if;
  if p_fields ? 'supportName' then
    v := org.optional_text(p_fields, 'supportName');
    if v is not null and length(v) > 80 then
      perform identity.fail('validation_error', jsonb_build_object('field', 'supportName'));
    end if;
    s.support_name := v;
  end if;
  if p_fields ? 'supportEmail' then
    v := lower(org.optional_text(p_fields, 'supportEmail'));
    if v is not null and (length(v) > 254 or v !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$') then
      perform identity.fail('validation_error', jsonb_build_object('field', 'supportEmail'));
    end if;
    s.support_email := v;
  end if;
  if p_fields ? 'supportPhone' then
    v := regexp_replace(coalesce(org.optional_text(p_fields, 'supportPhone'), ''), '[[:space:]()-]', '', 'g');
    if v = '' then
      v := null;
    elsif v ~ '^0[0-9]{10}$' then
      v := '+234' || substr(v, 2);
    end if;
    if v is not null and v !~ '^\+[1-9][0-9]{6,14}$' then
      perform identity.fail('validation_error', jsonb_build_object('field', 'supportPhone'));
    end if;
    s.support_phone := v;
  end if;
  if p_fields ? 'helpUrl' then
    v := org.optional_text(p_fields, 'helpUrl');
    if v is not null and (length(v) > 300 or v !~ '^https://[^/@[:space:]?#]+(/[^[:space:]]*)?$') then
      perform identity.fail('validation_error', jsonb_build_object('field', 'helpUrl'));
    end if;
    s.help_url := v;
  end if;
  if p_fields ? 'locale' then
    v := org.optional_text(p_fields, 'locale');
    if v is null or not v = any (org.locales()) then
      perform identity.fail('validation_error', jsonb_build_object('field', 'locale'));
    end if;
    s.locale := v;
  end if;
  if p_fields ? 'timeZone' then
    v := org.optional_text(p_fields, 'timeZone');
    if v is null or not v = any (org.time_zones()) then
      perform identity.fail('validation_error', jsonb_build_object('field', 'timeZone'));
    end if;
    s.time_zone := v;
  end if;
  foreach k in array array['logoKey', 'iconKey', 'logoLightKey'] loop
    if p_fields ? k then
      v := org.optional_text(p_fields, k);
      -- An asset must live under this network's own brand prefix (W-20).
      if v is not null and v !~ key_pattern then
        perform identity.fail('validation_error', jsonb_build_object('field', k));
      end if;
      case k
        when 'logoKey' then s.logo_key := v;
        when 'iconKey' then s.icon_key := v;
        else s.logo_light_key := v;
      end case;
    end if;
  end loop;

  if t.name is distinct from before_t.name then changed := array_append(changed, 'name'); end if;
  if t.short_name is distinct from before_t.short_name then changed := array_append(changed, 'shortName'); end if;
  if s.theme is distinct from before_s.theme then changed := array_append(changed, 'theme'); end if;
  if s.slogan is distinct from before_s.slogan then changed := array_append(changed, 'slogan'); end if;
  if s.support_name is distinct from before_s.support_name then changed := array_append(changed, 'supportName'); end if;
  if s.support_email is distinct from before_s.support_email then changed := array_append(changed, 'supportEmail'); end if;
  if s.support_phone is distinct from before_s.support_phone then changed := array_append(changed, 'supportPhone'); end if;
  if s.help_url is distinct from before_s.help_url then changed := array_append(changed, 'helpUrl'); end if;
  if s.locale is distinct from before_s.locale then changed := array_append(changed, 'locale'); end if;
  if s.time_zone is distinct from before_s.time_zone then changed := array_append(changed, 'timeZone'); end if;
  if s.logo_key is distinct from before_s.logo_key then changed := array_append(changed, 'logoKey'); end if;
  if s.icon_key is distinct from before_s.icon_key then changed := array_append(changed, 'iconKey'); end if;
  if s.logo_light_key is distinct from before_s.logo_light_key then changed := array_append(changed, 'logoLightKey'); end if;

  if cardinality(changed) = 0 then
    perform identity.fail('conflict', jsonb_build_object('reason', 'no_changes'));
  end if;

  if t.name is distinct from before_t.name or t.short_name is distinct from before_t.short_name then
    update org.tenants set name = t.name, short_name = t.short_name where id = p_tenant_id;
  end if;
  update org.tenant_settings set
    revision = revision + 1, theme = s.theme, slogan = s.slogan, support_name = s.support_name,
    support_email = s.support_email, support_phone = s.support_phone, help_url = s.help_url, locale = s.locale,
    time_zone = s.time_zone, logo_key = s.logo_key, icon_key = s.icon_key, logo_light_key = s.logo_light_key,
    updated_at = now()
  where tenant_id = p_tenant_id;
  return changed;
end;
$$;

-- The settings row for a command, locked, after the revision check.
create function org.lock_settings(p_tenant_id uuid, p_expected_revision int)
returns org.tenant_settings
language plpgsql
set search_path = ''
as $$
declare
  s org.tenant_settings;
begin
  if p_expected_revision is null or p_expected_revision < 1 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'expectedRevision'));
  end if;
  select * into s from org.tenant_settings where tenant_id = p_tenant_id for update;
  if s.tenant_id is null then
    perform identity.fail('not_found');
  end if;
  if s.revision <> p_expected_revision then
    perform identity.fail('conflict', jsonb_build_object('reason', 'stale_revision', 'currentRevision', s.revision));
  end if;
  return s;
end;
$$;

-- Safe before/after for the audit log: the changed fields only, never keys.
create function org.settings_audit(p_r org.tenant_setting_revisions, p_fields text[])
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_object_agg(f, case f
    when 'name' then to_jsonb(p_r.name)
    when 'shortName' then to_jsonb(p_r.short_name)
    when 'theme' then to_jsonb(p_r.theme)
    when 'slogan' then to_jsonb(p_r.slogan)
    when 'supportName' then to_jsonb(p_r.support_name)
    when 'supportEmail' then to_jsonb(p_r.support_email)
    when 'supportPhone' then to_jsonb(p_r.support_phone)
    when 'helpUrl' then to_jsonb(p_r.help_url)
    when 'locale' then to_jsonb(p_r.locale)
    when 'timeZone' then to_jsonb(p_r.time_zone)
    when 'logoKey' then to_jsonb(p_r.logo_key is not null)
    when 'iconKey' then to_jsonb(p_r.icon_key is not null)
    else to_jsonb(p_r.logo_light_key is not null) end), '{}'::jsonb)
  from unnest(p_fields) f;
$$;

create function org.settings_json(p_tenant_id uuid, p_can_edit boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'settings', jsonb_build_object(
      'revision', s.revision,
      'name', t.name,
      'shortName', t.short_name,
      'theme', s.theme,
      'slogan', s.slogan,
      'supportName', s.support_name,
      'supportEmail', s.support_email,
      'supportPhone', s.support_phone,
      'helpUrl', s.help_url,
      'locale', s.locale,
      'timeZone', s.time_zone,
      'hasLogo', s.logo_key is not null,
      'hasIcon', s.icon_key is not null,
      'hasLogoLight', s.logo_light_key is not null,
      'updatedAt', s.updated_at
    ),
    'options', jsonb_build_object('themes', to_jsonb(org.themes()), 'locales', to_jsonb(org.locales()),
      'timeZones', to_jsonb(org.time_zones())),
    'revisions', coalesce((
      select jsonb_agg(org.revision_json(r) order by r.revision desc)
      from (select * from org.tenant_setting_revisions where tenant_id = p_tenant_id
            order by revision desc limit 20) r
    ), '[]'::jsonb),
    'canEdit', p_can_edit
  )
  from org.tenants t join org.tenant_settings s on s.tenant_id = t.id
  where t.id = p_tenant_id;
$$;

-- ── api ───────────────────────────────────────────────────────────────────

-- Full editable record and the last 20 revisions (manage_team_settings).
-- Readable on a paused network; editing is not (canEdit false).
create function api.team_settings(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  perform authz.require(p_user_id, 'manage_team_settings', workspace.tenant_id, null, null, workspace.id,
    p_allow_paused => true);
  return org.settings_json(workspace.tenant_id,
    (select status from org.tenants where id = workspace.tenant_id) = 'active');
end;
$$;

-- Safe presentation fields for every member of the selected network.
create function api.workspace_brand(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  return org.brand_json(workspace.tenant_id);
end;
$$;

-- For the app server only (logo streaming): the storage key of one asset.
create function api.brand_asset_key(p_user_id uuid, p_session_id uuid, p_membership_id uuid, p_kind text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  s org.tenant_settings;
  object_key text;
begin
  if p_kind is null or p_kind not in ('logo', 'icon', 'logo-light') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'kind'));
  end if;
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  select * into s from org.tenant_settings where tenant_id = workspace.tenant_id;
  object_key := case p_kind when 'logo' then s.logo_key when 'icon' then s.icon_key else s.logo_light_key end;
  if object_key is null then
    perform identity.fail('not_found');
  end if;
  return jsonb_build_object('objectKey', object_key, 'revision', s.revision);
end;
$$;

-- A new brand asset key for an upload the app server is about to write.
-- Checks authority first so nobody can fill storage without it.
create function api.brand_upload_key(p_user_id uuid, p_session_id uuid, p_membership_id uuid, p_ext text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
begin
  if p_ext is null or p_ext not in ('jpg', 'png', 'webp') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'ext'));
  end if;
  perform org.require_writer(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  perform authz.require(p_user_id, 'manage_team_settings', workspace.tenant_id, null, null, workspace.id);
  return jsonb_build_object('objectKey',
    'brand/' || workspace.tenant_id::text || '/' || gen_random_uuid()::text || '.' || p_ext);
end;
$$;

-- Save (W-20): manage_team_settings + PIN, active network, current revision.
create function api.update_team_settings(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_expected_revision int,
  p_fields jsonb,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  request jsonb;
  replayed jsonb;
  before_r org.tenant_setting_revisions;
  after_r org.tenant_setting_revisions;
  changed text[];
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  perform authz.require(p_user_id, 'manage_team_settings', workspace.tenant_id, null, null, workspace.id);
  request := jsonb_build_object('tenantId', workspace.tenant_id, 'expectedRevision', p_expected_revision,
    'fields', p_fields);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'update_team_settings', request);
  if replayed is not null then
    return replayed;
  end if;

  perform org.lock_settings(workspace.tenant_id, p_expected_revision);
  select * into before_r from org.tenant_setting_revisions
  where tenant_id = workspace.tenant_id and revision = p_expected_revision;
  changed := org.apply_settings(workspace.tenant_id, p_fields);
  perform org.snapshot_settings(workspace.tenant_id, changed, null, p_user_id);
  select * into after_r from org.tenant_setting_revisions
  where tenant_id = workspace.tenant_id and revision = p_expected_revision + 1;

  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'settings.updated', 'tenant_settings',
    after_r.revision::text, null, org.settings_audit(before_r, changed), org.settings_audit(after_r, changed),
    p_request_id);
  perform org.notify_branding(workspace.tenant_id, p_user_id, after_r.revision, changed);

  return identity.store_result(p_user_id, p_idempotency_key, 'update_team_settings', request,
    org.settings_json(workspace.tenant_id, true));
end;
$$;

-- Undo (W-20): copies an older revision into a new one. Nothing is erased.
create function api.restore_team_settings_revision(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_expected_revision int,
  p_revision int,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  request jsonb;
  replayed jsonb;
  old_r org.tenant_setting_revisions;
  before_r org.tenant_setting_revisions;
  after_r org.tenant_setting_revisions;
  changed text[];
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  perform authz.require(p_user_id, 'manage_team_settings', workspace.tenant_id, null, null, workspace.id);
  request := jsonb_build_object('tenantId', workspace.tenant_id, 'expectedRevision', p_expected_revision,
    'revision', p_revision);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'restore_team_settings_revision', request);
  if replayed is not null then
    return replayed;
  end if;

  perform org.lock_settings(workspace.tenant_id, p_expected_revision);
  select * into old_r from org.tenant_setting_revisions where tenant_id = workspace.tenant_id and revision = p_revision;
  if old_r.tenant_id is null or p_revision >= p_expected_revision then
    perform identity.fail('not_found');
  end if;
  select * into before_r from org.tenant_setting_revisions
  where tenant_id = workspace.tenant_id and revision = p_expected_revision;

  changed := org.apply_settings(workspace.tenant_id, jsonb_build_object(
    'name', old_r.name, 'shortName', old_r.short_name, 'theme', old_r.theme, 'slogan', old_r.slogan,
    'supportName', old_r.support_name, 'supportEmail', old_r.support_email, 'supportPhone', old_r.support_phone,
    'helpUrl', old_r.help_url, 'locale', old_r.locale, 'timeZone', old_r.time_zone, 'logoKey', old_r.logo_key,
    'iconKey', old_r.icon_key, 'logoLightKey', old_r.logo_light_key));
  perform org.snapshot_settings(workspace.tenant_id, changed, p_revision, p_user_id);
  select * into after_r from org.tenant_setting_revisions
  where tenant_id = workspace.tenant_id and revision = p_expected_revision + 1;

  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'settings.restored', 'tenant_settings',
    after_r.revision::text, null, org.settings_audit(before_r, changed),
    org.settings_audit(after_r, changed) || jsonb_build_object('restoredFrom', p_revision), p_request_id);
  perform org.notify_branding(workspace.tenant_id, p_user_id, after_r.revision, changed);

  return identity.store_result(p_user_id, p_idempotency_key, 'restore_team_settings_revision', request,
    org.settings_json(workspace.tenant_id, true));
end;
$$;

-- ── Files: the network header gets the theme and support contact (B4) ──────

create or replace function exports.network_json(p_tenant_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('tenantId', b->'tenantId', 'name', b->'name', 'initial', b->'initial',
    'theme', b->'theme', 'hasLogo', b->'hasLogo', 'support', b->'support')
  from org.brand_json(p_tenant_id) b;
$$;

-- Worker step: the logo key for a leased file's network (or null).
create function api.export_brand(p_export_id uuid, p_worker text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  f exports.files;
begin
  select * into f from exports.files where id = p_export_id;
  if f.id is null then
    perform identity.fail('not_found');
  end if;
  if f.status <> 'rendering' or f.lease_owner is distinct from p_worker or f.lease_expires_at < now() then
    perform identity.fail('conflict', jsonb_build_object('reason', 'lease_lost'));
  end if;
  return jsonb_build_object('logoKey', (select logo_key from org.tenant_settings where tenant_id = f.tenant_id));
end;
$$;

-- ── T05 catalogue ─────────────────────────────────────────────────────────

insert into outbox.templates (key, version, duplicate_safe, params) values
  ('team.branding_changed', 1, true, array['network', 'actor', 'summary', 'revision', 'path']);

insert into notify.kinds (key, task, email_template) values
  ('org.branding_changed', false, 'team.branding_changed');

revoke all on all functions in schema org from public, anon, authenticated;
revoke all on org.tenant_settings, org.tenant_setting_revisions from public, anon, authenticated;

do $$
declare
  fn regprocedure;
begin
  for fn in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end;
$$;
