-- Blueprint 44 — withdrawal follow-through (owner decisions 2026-10-17).
--   D1  open withdrawals (requested / approved) show in Home's Recent activity
--       and Activity as their own "pending" list, the amount on hold; never in
--       statements, reports or the month totals (posted movements only).
--   D2  the owner gets a push when their withdrawal is requested.
--   D3  a team setting, off by default: "One open withdrawal at a time". When
--       on, request_withdrawal refuses a second open request of the same
--       owner in the network (`conflict`, reason `open_withdrawal_exists`),
--       serialized per owner so two concurrent requests cannot both pass.

-- ── D2: push for "Withdrawal requested" (notify.push_kinds is insert-only) ──

insert into notify.push_kinds (key) values ('money.withdrawal_submitted') on conflict do nothing;

-- ── D3: the setting and its revisions ──────────────────────────────────────

alter table org.tenant_settings add column one_open_withdrawal boolean not null default false;
alter table org.tenant_setting_revisions add column one_open_withdrawal boolean not null default false;

create or replace function org.snapshot_settings(
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
    support_email, support_phone, help_url, locale, time_zone, logo_key, icon_key, logo_light_key,
    one_open_withdrawal, changed, restored_from, actor_user_id)
  select s.tenant_id, s.revision, t.name, t.short_name, s.theme, s.slogan, s.support_name, s.support_email,
    s.support_phone, s.help_url, s.locale, s.time_zone, s.logo_key, s.icon_key, s.logo_light_key,
    s.one_open_withdrawal, p_changed, p_restored_from, p_actor_user_id
  from org.tenant_settings s join org.tenants t on t.id = s.tenant_id
  where s.tenant_id = p_tenant_id;
$$;

-- "the withdrawal rule" in T05 and the bell.
create or replace function org.settings_summary(p_changed text[])
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
      when 'oneOpenWithdrawal' then 'withdrawal rule'
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

-- As Blueprint 17, plus `oneOpenWithdrawal` (a JSON boolean).
create or replace function org.apply_settings(p_tenant_id uuid, p_fields jsonb)
returns text[]
language plpgsql
set search_path = ''
as $$
declare
  allowed text[] := array['name', 'shortName', 'theme', 'slogan', 'supportName', 'supportEmail', 'supportPhone',
    'helpUrl', 'locale', 'timeZone', 'logoKey', 'iconKey', 'logoLightKey', 'oneOpenWithdrawal'];
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
  -- Blueprint 44 (D3): on or off, nothing else.
  if p_fields ? 'oneOpenWithdrawal' then
    if jsonb_typeof(p_fields->'oneOpenWithdrawal') is distinct from 'boolean' then
      perform identity.fail('validation_error', jsonb_build_object('field', 'oneOpenWithdrawal'));
    end if;
    s.one_open_withdrawal := (p_fields->>'oneOpenWithdrawal')::boolean;
  end if;

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
  if s.one_open_withdrawal is distinct from before_s.one_open_withdrawal then
    changed := array_append(changed, 'oneOpenWithdrawal');
  end if;

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
    one_open_withdrawal = s.one_open_withdrawal, updated_at = now()
  where tenant_id = p_tenant_id;
  return changed;
end;
$$;

create or replace function org.settings_audit(p_r org.tenant_setting_revisions, p_fields text[])
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
    when 'oneOpenWithdrawal' then to_jsonb(p_r.one_open_withdrawal)
    else to_jsonb(p_r.logo_light_key is not null) end), '{}'::jsonb)
  from unnest(p_fields) f;
$$;

create or replace function org.settings_json(p_tenant_id uuid, p_can_edit boolean)
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
      'oneOpenWithdrawal', s.one_open_withdrawal,
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

-- Undo (W-20): an older revision's rule comes back with the rest of it.
create or replace function api.restore_team_settings_revision(
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
    'iconKey', old_r.icon_key, 'logoLightKey', old_r.logo_light_key,
    'oneOpenWithdrawal', old_r.one_open_withdrawal));
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

-- ── D3: enforcement ───────────────────────────────────────────────────────

-- The owner's open withdrawal in a network (newest), after taking the
-- per-owner lock that serializes requests while the rule is on: a second
-- request waits for the first to commit, then sees it.
create function finance.lock_open_withdrawal(p_tenant_id uuid, p_owner_user_id uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(
    hashtextextended('finance.one_open_withdrawal:' || p_tenant_id::text || ':' || p_owner_user_id::text, 0));
  return (
    select w.id from finance.withdrawals w
    where w.tenant_id = p_tenant_id and w.owner_user_id = p_owner_user_id and w.status in ('requested', 'approved')
    order by w.created_at desc, w.id desc
    limit 1
  );
end;
$$;

-- The owner's open withdrawal when the network has the rule on (no lock;
-- for reads). Null otherwise.
create function finance.blocking_withdrawal(p_tenant_id uuid, p_owner_user_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('withdrawalId', w.id, 'reference', w.reference, 'status', w.status,
    'currency', w.currency, 'amount', ledger.money(w.amount, w.currency))
  from finance.withdrawals w
  where w.tenant_id = p_tenant_id and w.owner_user_id = p_owner_user_id and w.status in ('requested', 'approved')
    and coalesce((select s.one_open_withdrawal from org.tenant_settings s where s.tenant_id = p_tenant_id), false)
  order by w.created_at desc, w.id desc
  limit 1;
$$;

-- As Blueprint 40, plus the D3 check after the replay (a replay of the first
-- request still answers) and before anything is reserved.
create or replace function api.request_withdrawal(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_account_id uuid,
  p_amount text,
  p_payout_account_id uuid,
  p_reason text,
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
  account ledger.accounts;
  destination payout.accounts;
  v_amount numeric;
  v_reason text;
  request jsonb;
  replayed jsonb;
  v_id uuid := gen_random_uuid();
  v_reference text;
  v_reservation uuid;
  v_open uuid;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  account := finance.withdrawal_source(p_user_id, workspace, p_account_id);
  v_amount := ledger.parse_amount(p_amount, 'NGN', 'amount');
  if p_payout_account_id is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'payoutAccountId'));
  end if;
  v_reason := identity.require_reason(p_reason);

  request := jsonb_build_object('accountId', account.id, 'amount', ledger.money(v_amount, 'NGN'),
    'payoutAccountId', p_payout_account_id, 'reason', v_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'request_withdrawal', request);
  if replayed is not null then
    return replayed;
  end if;

  -- Blueprint 44 (D3): one open withdrawal at a time, whoever places it.
  if coalesce((select s.one_open_withdrawal from org.tenant_settings s where s.tenant_id = account.tenant_id), false)
  then
    v_open := finance.lock_open_withdrawal(account.tenant_id, account.owner_user_id);
    if v_open is not null then
      perform identity.fail('conflict',
        jsonb_build_object('reason', 'open_withdrawal_exists', 'withdrawalId', v_open));
    end if;
  end if;

  -- Lock order: the owner's payout account (share), then the balance.
  destination := payout.eligible_destination(account.owner_user_id, p_payout_account_id);
  v_reservation := ledger.reserve(account.id, v_amount, 'withdrawal', 'withdrawal', v_id, p_user_id);
  v_reference := refs.issue('WDR');

  insert into finance.withdrawals (id, reference, tenant_id, office_id, membership_id, wallet_id, owner_user_id,
    account_id, pocket_id, currency, amount, payout_account_id, bank_code, bank_name, account_last4,
    account_ciphertext, key_version, account_name, requested_by, reservation_id, idempotency_key, reason)
  values (v_id, v_reference, account.tenant_id, account.office_id, account.membership_id, account.wallet_id,
    account.owner_user_id, account.id, account.pocket_id, 'NGN', v_amount, destination.id, destination.bank_code,
    destination.bank_name, destination.account_last4, destination.account_ciphertext, destination.key_version,
    destination.account_name, p_user_id, v_reservation, p_idempotency_key, v_reason);

  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'withdrawal.requested', 'withdrawal', v_id::text,
    v_reason,
    p_safe_after => jsonb_build_object('reference', v_reference, 'amount', ledger.money(v_amount, 'NGN'),
      'membershipId', account.membership_id, 'onBehalf', account.owner_user_id <> p_user_id,
      'payoutAccountId', destination.id),
    p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'request_withdrawal', request,
    finance.withdrawal_json(v_id, p_user_id, workspace.id));
end;
$$;

-- New withdrawal (M06) says up front when the rule blocks a new request:
-- `openWithdrawal` is the owner's open one while the rule is on, else null.
create or replace function api.withdrawal_sources(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform authz.require(p_user_id, 'initiate_own_withdrawal', workspace.tenant_id, null, p_user_id, workspace.id);
  return jsonb_build_object(
    'currency', 'NGN',
    'sources', coalesce((
      select jsonb_agg(jsonb_build_object(
        'accountId', b.account_id,
        'membershipId', b.membership_id,
        'office', jsonb_build_object('id', o.id, 'name', o.name),
        'pocket', jsonb_build_object('pocketId', pk.id, 'name', pk.name),
        'posted', ledger.money(b.posted, b.currency),
        'reserved', ledger.money(b.reserved, b.currency),
        'available', ledger.money(b.posted - b.reserved, b.currency)
      ) order by pk.sort_order, pk.id, o.name, b.membership_id)
      from ledger.balances b
      join ledger.pockets pk on pk.id = b.pocket_id
      join org.memberships m on m.id = b.membership_id
      join org.offices o on o.id = b.office_id
      where b.owner_user_id = p_user_id and b.tenant_id = workspace.tenant_id and b.currency = 'NGN'
        and pk.kind = 'ordinary' and pk.status = 'active' and finance.target_eligible(m)
        and (b.posted > 0 or b.reserved > 0)
    ), '[]'::jsonb),
    'payoutAccounts', coalesce((
      select jsonb_agg(payout.account_json(a) || jsonb_build_object(
        'usable', a.verification_status = 'verified' and a.name_match <> 'mismatched' and a.usable_from <= now())
        order by a.is_primary desc, a.created_at desc, a.id)
      from payout.accounts a
      where a.owner_user_id = p_user_id and a.status = 'active'
    ), '[]'::jsonb),
    'openWithdrawal', finance.blocking_withdrawal(workspace.tenant_id, p_user_id)
  );
end;
$$;

-- ── D1: open withdrawals beside the posted activity ───────────────────────

-- The caller's own open withdrawals (requested / approved) in the wallet,
-- newest first, filtered like the activity read: Naira, the pocket, "Money
-- out" or no direction, type withdrawal or none, no status filter (posted /
-- reversed are ledger statuses), the requested date inside the range, and
-- the search (reference, bank, exact amount). Never posted, never totalled.
create function ledger.open_withdrawals(
  p_user_id uuid,
  p_wallet_id uuid,
  p_tenant_id uuid,
  p_currency text default null,
  p_pocket_id uuid default null,
  p_direction text default null,
  p_type text default null,
  p_from text default null,
  p_to text default null,
  p_query text default null,
  p_status text default null,
  p_tz text default null,
  p_limit int default 20
)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  zone text := ledger.time_zone(p_tz);
  from_date date := ledger.date_filter(p_from, 'from');
  to_date date := ledger.date_filter(p_to, 'to');
  query_text text := btrim(p_query);
  query_pattern text;
  query_reference text;
  query_amount numeric;
begin
  if p_status is not null or (p_currency is not null and p_currency <> 'NGN')
    or (p_direction is not null and p_direction <> 'out')
    or (p_type is not null and p_type <> 'withdrawal') then
    return '[]'::jsonb;
  end if;
  query_pattern := '%' || replace(replace(replace(query_text, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  query_reference := upper(regexp_replace(coalesce(query_text, ''), '[^A-Za-z0-9]', '', 'g'));
  query_amount := ledger.search_amount(query_text);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'withdrawalId', x.id,
      'reference', x.reference,
      'status', x.status,
      'currency', x.currency,
      'amount', ledger.money(x.amount, x.currency),
      'title', coalesce(x.bank_name, 'Bank') || ' •• ' || x.account_last4,
      'pocket', jsonb_build_object('pocketId', pk.id, 'name', pk.name),
      'tenantId', x.tenant_id,
      'createdAt', x.created_at,
      'approvedAt', x.approved_at
    ) order by x.created_at desc, x.id desc)
    from (
      select w.* from finance.withdrawals w
      where w.wallet_id = p_wallet_id and w.owner_user_id = p_user_id
        and w.status in ('requested', 'approved')
        and (p_tenant_id is null or w.tenant_id = p_tenant_id)
        and (p_pocket_id is null or w.pocket_id = p_pocket_id)
        and (from_date is null or w.created_at >= from_date::timestamp at time zone zone)
        and (to_date is null or w.created_at < (to_date + 1)::timestamp at time zone zone)
        and (query_text is null
          or (length(query_reference) >= 3 and replace(w.reference, '-', '') like '%' || query_reference || '%')
          or w.bank_name ilike query_pattern
          or (query_amount is not null and w.amount = query_amount))
      order by w.created_at desc, w.id desc
      limit greatest(1, least(coalesce(p_limit, 20), 50))
    ) x
    join ledger.pockets pk on pk.id = x.pocket_id
  ), '[]'::jsonb);
end;
$$;

-- Activity: the first page also carries `pending` (later pages do not).
create or replace function api.my_activity(
  p_user_id uuid,
  p_session_id uuid,
  p_tenant_id uuid default null,
  p_currency text default null,
  p_pocket_id uuid default null,
  p_direction text default null,
  p_type text default null,
  p_from text default null,
  p_to text default null,
  p_cursor text default null,
  p_limit int default null,
  p_query text default null,
  p_status text default null,
  p_tz text default null,
  p_membership_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet_id uuid;
  v_tenant_id uuid := p_tenant_id;
  result jsonb;
begin
  perform identity.require_session(p_user_id, p_session_id);
  if p_membership_id is not null then
    if p_tenant_id is not null then
      perform identity.fail('validation_error', jsonb_build_object('field', 'tenantId'));
    end if;
    v_tenant_id := (org.own_membership(p_user_id, p_membership_id)).tenant_id;
  end if;
  v_wallet_id := ledger.require_wallet(p_user_id);
  result := ledger.activity(v_wallet_id, v_tenant_id, null, p_currency, p_pocket_id, p_direction, p_type,
    p_from, p_to, p_cursor, p_limit, p_query, p_status, p_tz);
  if p_cursor is null then
    result := result || jsonb_build_object('pending', ledger.open_withdrawals(p_user_id, v_wallet_id, v_tenant_id,
      p_currency, p_pocket_id, p_direction, p_type, p_from, p_to, p_query, p_status, p_tz));
  end if;
  return result;
end;
$$;

-- Home: { network, activity, pending, split }; `pending` is the caller's open
-- withdrawals in this network (five newest), shown above the posted rows.
create or replace function api.home_view(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  membership org.memberships;
  v_wallet_id uuid;
  network jsonb;
  activity jsonb;
  allocation jsonb;
  split jsonb;
  empty constant jsonb := jsonb_build_object('network', null, 'activity', '[]'::jsonb, 'pending', '[]'::jsonb,
    'split', null);
begin
  perform identity.require_session(p_user_id, p_session_id);
  membership := org.own_membership(p_user_id, p_membership_id);
  v_wallet_id := ledger.wallet_for(p_user_id);
  if v_wallet_id is null then
    return empty;
  end if;
  network := ledger.wallet_networks(v_wallet_id, membership.tenant_id)->0;
  if network is null then
    return empty;
  end if;

  activity := ledger.activity(v_wallet_id, membership.tenant_id, null, null, null, null, null, null, null, null, 5,
    p_months => false)->'items';

  begin
    allocation := ledger.allocation_json((authz.require_workspace(p_user_id, p_membership_id)).tenant_id);
    if allocation is not null then
      split := coalesce((
        select jsonb_agg(jsonb_build_object('pocketId', p.value->'pocketId', 'percent', p.value->'percent')
          order by p.ordinality)
        from jsonb_array_elements(allocation->'pockets') with ordinality p
      ), '[]'::jsonb);
    end if;
  exception when others then
    split := null;
  end;

  return jsonb_build_object('network', network, 'activity', activity,
    'pending', ledger.open_withdrawals(p_user_id, v_wallet_id, membership.tenant_id, p_limit => 5),
    'split', split);
end;
$$;

-- ── Backups (F-03): a revision with the rule on says so ────────────────────

create or replace function backups.snapshot(p_tenant_id uuid)
returns table (section text, data jsonb)
language sql
stable
set search_path = ''
as $$
  with people as (
    select distinct m.user_id from org.memberships m where m.tenant_id = p_tenant_id
  ),
  tx as (
    select t.* from ledger.transactions t where t.tenant_id = p_tenant_id
  ),
  acct as (
    select a.* from ledger.accounts a where a.tenant_id = p_tenant_id
  ),
  wd as (
    select w.* from finance.withdrawals w where w.tenant_id = p_tenant_id
  ),
  po as (
    select p.* from finance.payouts p join wd on wd.id = p.withdrawal_id
  )
  select s.section, s.data from (
    select 1 as o, 'network'::text, jsonb_build_object('id', t.id, 'name', t.name, 'shortName', t.short_name,
      'status', t.status, 'createdAt', t.created_at, 'activatedAt', t.activated_at,
      'activationSource', t.activation_source) || jsonb_build_object('settings', org.brand_json(t.id) - 'tenantId'),
      t.id::text as k
    from org.tenants t where t.id = p_tenant_id
    union all
    select 2, 'settings_revisions', backups.pick(to_jsonb(r), array['revision', 'name', 'short_name', 'theme',
      'slogan', 'support_name', 'support_email', 'support_phone', 'help_url', 'locale', 'time_zone', 'changed',
      'restored_from', 'actor_user_id', 'created_at']) || jsonb_build_object('has_logo', r.logo_key is not null)
      -- Blueprint 44: only when on, so archives made before still compare equal (F-03).
      || case when r.one_open_withdrawal then jsonb_build_object('one_open_withdrawal', true) else '{}'::jsonb end,
      lpad(r.revision::text, 10, '0')
    from org.tenant_setting_revisions r where r.tenant_id = p_tenant_id
    union all
    select 3, 'offices', backups.pick(to_jsonb(o), array['id', 'parent_office_id', 'office_type', 'name', 'status',
      'created_by', 'created_at']), o.created_at::text || o.id::text
    from org.offices o where o.tenant_id = p_tenant_id
    union all
    select 4, 'office_moves', backups.pick(to_jsonb(x), array['id', 'office_id', 'from_parent_id', 'to_parent_id',
      'reason', 'actor_user_id', 'at']), x.at::text || x.id::text
    from org.office_moves x where x.tenant_id = p_tenant_id
    union all
    select 5, 'people', jsonb_build_object('user_id', a.user_id, 'uid', a.uid, 'status', a.status,
      'display_name', pr.display_name, 'first_name', pr.first_name, 'last_name', pr.last_name, 'email', u.email,
      'phone', pr.phone, 'rank', pr.rank, 'created_at', a.created_at), a.uid
    from people p
    join identity.accounts a on a.user_id = p.user_id
    left join identity.profiles pr on pr.user_id = p.user_id
    left join auth.users u on u.id = p.user_id
    union all
    select 6, 'memberships', backups.pick(to_jsonb(m), array['id', 'office_id', 'user_id', 'role', 'is_primary',
      'status', 'started_at', 'ended_at', 'ended_reason', 'replaced_by_id', 'created_by']),
      m.started_at::text || m.id::text
    from org.memberships m where m.tenant_id = p_tenant_id
    union all
    select 7, 'membership_events', backups.pick(to_jsonb(x), array['id', 'membership_id', 'action', 'from_status',
      'to_status', 'reason', 'actor_user_id', 'at']), x.at::text || x.id::text
    from org.membership_events x where x.tenant_id = p_tenant_id
    union all
    select 8, 'invitations', backups.pick(to_jsonb(i), array['id', 'reference', 'office_id', 'role', 'email',
      'status', 'expires_at', 'invited_by', 'reason', 'created_at', 'accepted_at', 'accepted_user_id',
      'accepted_membership_id', 'revoked_at', 'revoked_by', 'revoke_reason']), i.created_at::text || i.id::text
    from org.invitations i where i.tenant_id = p_tenant_id
    union all
    select 9, 'invitation_events', backups.pick(to_jsonb(x), array['id', 'invitation_id', 'action', 'actor_user_id',
      'reason', 'at']), x.at::text || x.id::text
    from org.invitation_events x where x.tenant_id = p_tenant_id
    union all
    select 10, 'role_permissions', backups.pick(to_jsonb(x), array['role', 'permission_key', 'allowed', 'updated_by',
      'updated_at']), x.role::text || x.permission_key
    from authz.role_permissions x where x.tenant_id = p_tenant_id
    union all
    select 11, 'access_assignments', backups.pick(to_jsonb(x), array['id', 'subject_user_id', 'created_by', 'reason',
      'created_at', 'revoked_at', 'revoked_by', 'revoke_reason']), x.created_at::text || x.id::text
    from authz.access_assignments x where x.tenant_id = p_tenant_id
    union all
    select 12, 'access_rules', backups.pick(to_jsonb(x), array['id', 'assignment_id', 'subject_user_id',
      'permission_key', 'effect', 'scope_type', 'scope_office_id', 'scope_user_id', 'starts_at', 'expires_at',
      'revoked_at']), x.id::text
    from authz.access_rules x where x.tenant_id = p_tenant_id
    union all
    select 13, 'reviewer_assignments', backups.pick(to_jsonb(x), array['id', 'membership_id', 'assigned_by', 'reason',
      'assigned_at', 'ended_at', 'ended_by', 'end_reason']), x.assigned_at::text || x.id::text
    from authz.reviewer_assignments x where x.tenant_id = p_tenant_id
    union all
    select 14, 'pockets', backups.pick(to_jsonb(x), array['id', 'kind', 'name', 'sort_order', 'status', 'created_by',
      'created_at', 'retired_at']), x.created_at::text || x.id::text
    from ledger.pockets x where x.tenant_id = p_tenant_id
    union all
    select 15, 'allocation_policies', backups.pick(to_jsonb(x), array['id', 'version', 'source', 'reason',
      'created_by', 'created_at']) || jsonb_build_object('lines', (
        select coalesce(jsonb_agg(backups.pick(to_jsonb(l), array['pocket_id', 'name', 'sort_order', 'basis_points'])
          order by l.sort_order), '[]'::jsonb)
        from ledger.allocation_policy_lines l where l.policy_id = x.id)),
      lpad(x.version::text, 10, '0')
    from ledger.allocation_policies x where x.tenant_id = p_tenant_id
    union all
    select 16, 'ledger_accounts', backups.pick(to_jsonb(x), array['id', 'class', 'currency', 'wallet_id',
      'membership_id', 'office_id', 'owner_user_id', 'pocket_id', 'system_key', 'created_at']),
      x.created_at::text || x.id::text
    from acct x
    union all
    select 17, 'balances', backups.pick(to_jsonb(x), array['account_id', 'currency', 'posted', 'reserved', 'version',
      'updated_at']), x.account_id::text
    from ledger.balances x where x.tenant_id = p_tenant_id
    union all
    select 18, 'transactions', backups.pick(to_jsonb(x), array['id', 'reference', 'type', 'office_id',
      'membership_id', 'wallet_id', 'owner_user_id', 'actor_user_id', 'posted_at', 'metadata']),
      x.posted_at::text || x.id::text
    from tx x
    union all
    select 19, 'postings', jsonb_build_object('transaction_id', j.transaction_id, 'entry_no', j.entry_no,
      'currency', j.currency, 'line_no', p.line_no, 'account_id', p.account_id, 'amount', p.amount),
      j.transaction_id::text || lpad(j.entry_no::text, 6, '0') || lpad(p.line_no::text, 6, '0')
    from tx join ledger.journals j on j.transaction_id = tx.id join ledger.postings p on p.journal_id = j.id
    union all
    select 20, 'reservations', backups.pick(to_jsonb(x), array['id', 'account_id', 'amount', 'purpose',
      'source_type', 'source_id', 'status', 'consumed_amount', 'consumed_by_transaction_id', 'release_reason',
      'actor_user_id', 'created_at', 'settled_at']), x.created_at::text || x.id::text
    from ledger.reservations x join acct on acct.id = x.account_id
    union all
    select 21, 'income_records', backups.pick(to_jsonb(x), array['id', 'reference', 'office_id', 'membership_id',
      'wallet_id', 'owner_user_id', 'currency', 'amount', 'source', 'received_on', 'provider_reference', 'notes',
      'fee_amount', 'fee_currency', 'policy_id', 'transaction_id', 'recorded_by', 'recorded_at']) || jsonb_build_object(
        'allocations', (select coalesce(jsonb_agg(backups.pick(to_jsonb(l), array['pocket_id', 'pocket_name',
          'sort_order', 'basis_points', 'amount', 'account_id']) order by l.sort_order), '[]'::jsonb)
          from finance.income_allocations l where l.income_id = x.id)),
      x.recorded_at::text || x.id::text
    from finance.income_records x where x.tenant_id = p_tenant_id
    union all
    select 22, 'entries', backups.pick(to_jsonb(x), array['id', 'reference', 'kind', 'office_id', 'membership_id',
      'wallet_id', 'owner_user_id', 'currency', 'amount', 'direction', 'pocket_id', 'account_id', 'reservation_id',
      'destination_currency', 'destination_amount', 'quoted_rate', 'provider', 'observed_at', 'external_reference',
      'reason', 'notes', 'withdrawal_id', 'policy_id', 'status', 'submitted_by', 'reviewer_user_id',
      'reviewer_membership_id', 'review_reason', 'decided_at', 'transaction_id', 'created_at']) || jsonb_build_object(
        'lines', (select coalesce(jsonb_agg(backups.pick(to_jsonb(l), array['pocket_id', 'pocket_name', 'sort_order',
          'basis_points', 'amount', 'account_id']) order by l.sort_order), '[]'::jsonb)
          from finance.entry_lines l where l.entry_id = x.id)),
      x.created_at::text || x.id::text
    from finance.entries x where x.tenant_id = p_tenant_id
    union all
    select 23, 'pocket_transfers', backups.pick(to_jsonb(x), array['id', 'reference', 'office_id', 'membership_id',
      'wallet_id', 'owner_user_id', 'currency', 'source_account_id', 'destination_account_id', 'source_pocket_id',
      'destination_pocket_id', 'amount', 'reservation_id', 'requested_by', 'status', 'decided_by', 'decided_at',
      'decision_reason', 'transaction_id', 'created_at']), x.created_at::text || x.id::text
    from finance.pocket_transfers x where x.tenant_id = p_tenant_id
    union all
    select 24, 'reversals', backups.pick(to_jsonb(x), array['id', 'reference', 'original_transaction_id',
      'transaction_id', 'category', 'note', 'reversed_by', 'created_at']), x.created_at::text || x.id::text
    from finance.reversals x where x.tenant_id = p_tenant_id
    union all
    select 25, 'withdrawals', backups.pick(to_jsonb(x), array['id', 'reference', 'office_id', 'membership_id',
      'wallet_id', 'owner_user_id', 'account_id', 'pocket_id', 'currency', 'amount', 'payout_account_id', 'bank_code',
      'bank_name', 'account_last4', 'account_name', 'requested_by', 'status', 'reservation_id', 'approved_by',
      'approved_at', 'decided_by', 'decided_at', 'decision_reason', 'completed_at', 'transaction_id', 'created_at'])
      || case when x.reason is null then '{}'::jsonb else jsonb_build_object('reason', x.reason) end,
      x.created_at::text || x.id::text
    from wd x
    union all
    select 26, 'payouts', backups.pick(to_jsonb(x), array['id', 'withdrawal_id', 'attempt_no', 'status', 'revision',
      'submitted_by', 'created_at', 'settled_at']), x.created_at::text || x.id::text
    from po x
    union all
    select 27, 'payout_revisions', backups.pick(to_jsonb(x), array['id', 'payout_id', 'revision', 'amount',
      'fee_amount', 'paid_on', 'bank_reference', 'notes', 'evidence_id', 'submitted_by', 'created_at']),
      x.created_at::text || x.id::text
    from finance.payout_revisions x join po on po.id = x.payout_id
    union all
    select 28, 'payout_checks', backups.pick(to_jsonb(x), array['id', 'payout_id', 'revision_id', 'status', 'cycle',
      'outcome', 'reasons', 'model', 'policy_version', 'created_at', 'finished_at']), x.created_at::text || x.id::text
    from finance.payout_checks x join po on po.id = x.payout_id
    union all
    select 29, 'payout_reviews', backups.pick(to_jsonb(x), array['payout_id', 'reviewer_user_id',
      'reviewer_membership_id', 'decision', 'reason', 'decided_at']), x.decided_at::text || x.payout_id::text
    from finance.payout_reviews x join po on po.id = x.payout_id
    union all
    select 30, 'evidence', backups.pick(to_jsonb(x), array['id', 'purpose', 'uploaded_by', 'target_membership_id',
      'declared_name', 'size', 'sha256', 'mime', 'status', 'attached_type', 'attached_id', 'created_at',
      'finalized_at', 'settled_at']), x.created_at::text || x.id::text
    from evidence.files x where x.tenant_id = p_tenant_id
    union all
    select 31, 'subscription', jsonb_build_object('status', s.status, 'kind', s.kind, 'plan', p.key,
      'period_start', s.period_start, 'period_end', s.period_end, 'paused_at', s.paused_at, 'auto_renew', s.auto_renew,
      'next_plan', np.key, 'created_at', s.created_at, 'updated_at', s.updated_at), s.tenant_id::text
    from billing.subscriptions s join billing.plans p on p.id = s.plan_id
    left join billing.plans np on np.id = s.next_plan_id
    where s.tenant_id = p_tenant_id
    union all
    select 32, 'billing_periods', backups.pick(to_jsonb(x), array['id', 'kind', 'plan_id', 'starts_at', 'ends_at',
      'payment_id', 'actor_user_id', 'reason', 'created_at']), x.created_at::text || x.id::text
    from billing.periods x where x.tenant_id = p_tenant_id
    union all
    select 33, 'billing_payments', backups.pick(to_jsonb(x), array['id', 'reference', 'purpose', 'plan_id',
      'from_plan_id', 'amount', 'currency', 'days_left', 'status', 'applied', 'needs_review', 'initiated_by',
      'covers_from', 'covers_to', 'paid_at', 'created_at']), x.created_at::text || x.id::text
    from billing.payments x where x.tenant_id = p_tenant_id
    union all
    select 34, 'billing_owners', backups.pick(to_jsonb(x), array['id', 'user_id', 'membership_id', 'assigned_by',
      'assigned_at', 'ended_at', 'ended_by']), x.assigned_at::text || x.id::text
    from billing.owners x where x.tenant_id = p_tenant_id
    union all
    select 35, 'audit', backups.pick(to_jsonb(x), array['id', 'at', 'actor_user_id', 'action', 'target_type',
      'target_id', 'reason', 'safe_before', 'safe_after']), x.at::text || lpad(x.id::text, 20, '0')
    from audit.tenant_events x where x.tenant_id = p_tenant_id
  ) s (o, section, data, k)
  order by o, k;
$$;

-- ── Privileges ────────────────────────────────────────────────────────────

revoke all on function finance.lock_open_withdrawal(uuid, uuid) from public, anon, authenticated;
revoke all on function finance.blocking_withdrawal(uuid, uuid) from public, anon, authenticated;
revoke all on function ledger.open_withdrawals(uuid, uuid, uuid, text, uuid, text, text, text, text, text, text, text,
  int) from public, anon, authenticated;
do $$
declare
  f text;
begin
  foreach f in array array[
    'api.request_withdrawal(uuid, uuid, uuid, uuid, text, uuid, text, text, text)',
    'api.withdrawal_sources(uuid, uuid, uuid)',
    'api.restore_team_settings_revision(uuid, uuid, uuid, int, int, text, text)',
    'api.my_activity(uuid, uuid, uuid, text, uuid, text, text, text, text, text, int, text, text, text, uuid)',
    'api.home_view(uuid, uuid, uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
