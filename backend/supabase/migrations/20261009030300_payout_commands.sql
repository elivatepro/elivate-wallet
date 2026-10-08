-- Blueprint 05 — B4: commands and reads called by the `payout` Edge Function.
-- Order in every command: session gate (step-up where required) → workspace →
-- authorization → idempotent replay → owner lock → state checks → effects.
-- Replays therefore always re-check current session and authority (A-01).

-- ── Helpers ───────────────────────────────────────────────────────────────

-- Session gate, workspace and the self-service permission (A-03). Writes are
-- refused for restricted accounts (org.require_writer).
create function payout.workspace(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_write boolean,
  p_step_up boolean
)
returns org.memberships
language plpgsql
set search_path = ''
as $$
declare
  workspace org.memberships;
begin
  if p_write then
    perform org.require_writer(p_user_id, p_session_id, p_step_up => p_step_up);
  else
    perform identity.require_session(p_user_id, p_session_id, p_step_up => p_step_up);
  end if;
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  perform authz.require(p_user_id, 'manage_own_payout_accounts', workspace.tenant_id, null, p_user_id, workspace.id);
  return workspace;
end;
$$;

-- Shape of the sealed number the Edge Function sends; never the digits.
create function payout.check_sealed_number(
  p_ciphertext text,
  p_key_version int,
  p_fingerprint text,
  p_last4 text
)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_ciphertext is null or p_ciphertext !~ '^[A-Za-z0-9+/]{40,200}={0,2}$'
    or p_key_version is null or p_key_version not between 1 and 32767
    or p_fingerprint is null or p_fingerprint !~ '^[0-9a-f]{64}$'
    or p_last4 is null or p_last4 !~ '^[0-9]{4}$'
  then
    perform identity.fail('validation_error', jsonb_build_object('field', 'accountNumber'));
  end if;
end;
$$;

create function payout.bank_name(p_provider text, p_code text)
returns text
language sql
stable
set search_path = ''
as $$
  select name from payout.banks where provider = p_provider and code = p_code;
$$;

create function payout.account_json(p_account payout.accounts)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'payoutAccountId', p_account.id,
    'bankCode', p_account.bank_code,
    'bankName', p_account.bank_name,
    'accountLast4', p_account.account_last4,
    'accountNumberMasked', '•••• ' || p_account.account_last4,
    'accountName', p_account.account_name,
    'currency', p_account.currency,
    'status', p_account.status,
    'verificationStatus', p_account.verification_status,
    'verificationMethod', p_account.verification_method,
    'nameMatch', p_account.name_match,
    'isPrimary', p_account.is_primary,
    'usableFrom', p_account.usable_from,
    'replacesId', p_account.replaces_id,
    'replacedById', p_account.replaced_by_id,
    'createdAt', p_account.created_at,
    'deactivatedAt', p_account.deactivated_at
  );
$$;

create function payout.lookup_json(p_lookup payout.account_lookups)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'lookupId', p_lookup.id,
    'status', p_lookup.status,
    'bankCode', p_lookup.bank_code,
    'bankName', payout.bank_name(p_lookup.provider, p_lookup.bank_code),
    'accountLast4', p_lookup.account_last4,
    'accountName', p_lookup.resolved_name,
    'nameMatch', p_lookup.name_match,
    'replacesPayoutAccountId', p_lookup.replaces_payout_account_id,
    'expiresAt', p_lookup.expires_at,
    'confirmedPayoutAccountId', p_lookup.confirmed_payout_account_id
  );
$$;

create function payout.active_count(p_user_id uuid)
returns int
language sql
stable
set search_path = ''
as $$
  select count(*)::int from payout.accounts where owner_user_id = p_user_id and status = 'active';
$$;

-- Fails when the same bank + number is already active for this person.
create function payout.assert_not_saved(p_user_id uuid, p_bank_code text, p_fingerprint text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if exists (
    select 1 from payout.accounts
    where owner_user_id = p_user_id and bank_code = p_bank_code
      and account_fingerprint = p_fingerprint and status = 'active'
  ) then
    perform identity.fail('payout_account_exists');
  end if;
end;
$$;

-- Q9: lookups per hour and per day, counted under the owner lock.
create function payout.assert_lookup_allowance(p_user_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  window_size interval;
  quota int;
  used int;
  oldest timestamptz;
begin
  foreach window_size in array array[interval '1 hour', interval '24 hours'] loop
    quota := case when window_size = interval '1 hour'
      then payout.lookups_per_hour() else payout.lookups_per_day() end;
    select count(*)::int, min(created_at) into used, oldest
    from payout.account_lookups
    where owner_user_id = p_user_id and created_at > now() - window_size;
    if used >= quota then
      perform identity.fail('rate_limited', jsonb_build_object(
        'retryAfterSeconds', greatest(1, ceil(extract(epoch from (oldest + window_size - now()))))::int
      ));
    end if;
  end loop;
end;
$$;

-- ── Bank list ─────────────────────────────────────────────────────────────

create function api.list_banks(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  newest timestamptz;
begin
  perform identity.require_session(p_user_id, p_session_id);
  select max(refreshed_at) into newest from payout.banks where provider = 'paystack';
  return jsonb_build_object(
    'banks', coalesce((
      select jsonb_agg(jsonb_build_object('code', code, 'name', name) order by name, code)
      from payout.banks where provider = 'paystack' and active
    ), '[]'::jsonb),
    'refreshedAt', newest,
    'stale', newest is null or newest < now() - payout.bank_list_ttl()
  );
end;
$$;

-- Replaces the cached list with the provider's current one. Called by the Edge
-- Function when the cache is stale; concurrent refreshes collapse into one.
create function api.refresh_banks(
  p_user_id uuid,
  p_session_id uuid,
  p_provider text,
  p_banks jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  newest timestamptz;
  bank jsonb;
  saved int;
begin
  perform identity.require_session(p_user_id, p_session_id);
  if p_provider is distinct from 'paystack' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'provider'));
  end if;
  if p_banks is null or jsonb_typeof(p_banks) <> 'array' or jsonb_array_length(p_banks) not between 1 and 2000 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'banks'));
  end if;
  for bank in select value from jsonb_array_elements(p_banks) loop
    if jsonb_typeof(bank) <> 'object'
      or jsonb_typeof(bank->'code') <> 'string' or bank->>'code' !~ '^[0-9A-Z]{3,10}$'
      or jsonb_typeof(bank->'name') <> 'string' or length(btrim(bank->>'name')) not between 1 and 100
      or (bank ? 'slug' and jsonb_typeof(bank->'slug') not in ('string', 'null'))
      or length(bank->>'slug') > 100
    then
      perform identity.fail('validation_error', jsonb_build_object('field', 'banks'));
    end if;
  end loop;

  perform pg_advisory_xact_lock(hashtextextended('payout.banks', 0));
  select max(refreshed_at) into newest from payout.banks where provider = p_provider;
  if newest > now() - interval '1 minute' then
    return jsonb_build_object('refreshed', false);
  end if;

  insert into payout.banks (provider, code, name, slug, active, refreshed_at)
  select distinct on (b->>'code') p_provider, b->>'code', btrim(b->>'name'), b->>'slug', true, now()
  from jsonb_array_elements(p_banks) as x (b)
  order by b->>'code'
  on conflict (provider, code) do update
  set name = excluded.name, slug = excluded.slug, active = true, refreshed_at = excluded.refreshed_at;
  get diagnostics saved = row_count;

  update payout.banks set active = false, refreshed_at = now()
  where provider = p_provider
    and code not in (select b->>'code' from jsonb_array_elements(p_banks) as x (b));

  return jsonb_build_object('refreshed', true, 'count', saved);
end;
$$;

-- ── Lookups ───────────────────────────────────────────────────────────────

-- Step 1 of W-17: records the bound proof (or returns it for the same key).
-- The Edge Function calls the provider only while it is pending.
create function api.prepare_account_lookup(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_bank_code text,
  p_account_ciphertext text,
  p_key_version int,
  p_account_fingerprint text,
  p_account_last4 text,
  p_replaces_payout_account_id uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  existing payout.account_lookups;
  replaced payout.accounts;
  created payout.account_lookups;
begin
  workspace := payout.workspace(p_user_id, p_session_id, p_membership_id, true, true);
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{16,100}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'idempotencyKey'));
  end if;
  if p_bank_code is null or p_bank_code !~ '^[0-9A-Z]{3,10}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'bankCode'));
  end if;
  perform payout.check_sealed_number(p_account_ciphertext, p_key_version, p_account_fingerprint, p_account_last4);

  perform payout.lock_owner(p_user_id);

  select * into existing from payout.account_lookups
  where owner_user_id = p_user_id and lookup_key = p_idempotency_key;
  if existing.id is not null then
    if existing.bank_code <> p_bank_code or existing.account_fingerprint <> p_account_fingerprint
      or existing.replaces_payout_account_id is distinct from p_replaces_payout_account_id
      or existing.workspace_membership_id <> workspace.id
    then
      perform identity.fail('idempotency_conflict');
    end if;
    -- An unanswered proof can't be answered after it expires.
    if existing.status = 'pending' and now() >= existing.expires_at then
      perform identity.fail('payout_lookup_expired');
    end if;
    return payout.lookup_json(existing) || jsonb_build_object('replayed', true);
  end if;

  if not exists (
    select 1 from payout.banks where provider = 'paystack' and code = p_bank_code and active
  ) then
    perform identity.fail('bank_unknown');
  end if;
  perform payout.assert_lookup_allowance(p_user_id);

  if p_replaces_payout_account_id is not null then
    select * into replaced from payout.accounts
    where id = p_replaces_payout_account_id and owner_user_id = p_user_id;
    if replaced.id is null then
      perform identity.fail('not_found');
    end if;
    if replaced.status <> 'active' then
      perform identity.fail('conflict', jsonb_build_object('reason', 'not_active'));
    end if;
  end if;
  perform payout.assert_not_saved(p_user_id, p_bank_code, p_account_fingerprint);
  if p_replaces_payout_account_id is null and payout.active_count(p_user_id) >= payout.max_active_accounts() then
    perform identity.fail('conflict', jsonb_build_object('reason', 'account_limit'));
  end if;

  insert into payout.account_lookups (
    owner_user_id, workspace_membership_id, lookup_key, provider, bank_code,
    account_ciphertext, key_version, account_fingerprint, account_last4,
    replaces_payout_account_id, created_at, expires_at
  ) values (
    p_user_id, workspace.id, p_idempotency_key, 'paystack', p_bank_code,
    p_account_ciphertext, p_key_version, p_account_fingerprint, p_account_last4,
    p_replaces_payout_account_id, now(), now() + payout.proof_ttl()
  )
  returning * into created;

  return payout.lookup_json(created) || jsonb_build_object('replayed', false);
end;
$$;

-- Step 2: stores the provider's first answer. Later answers never replace it.
create function api.record_account_lookup(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_lookup_id uuid,
  p_outcome text,
  p_account_name text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  lookup payout.account_lookups;
  clean_name text;
begin
  perform payout.workspace(p_user_id, p_session_id, p_membership_id, true, false);
  perform payout.lock_owner(p_user_id);

  select * into lookup from payout.account_lookups
  where id = p_lookup_id and owner_user_id = p_user_id
  for update;
  if lookup.id is null then
    perform identity.fail('not_found');
  end if;
  if lookup.status <> 'pending' then
    return payout.lookup_json(lookup);
  end if;
  if now() >= lookup.expires_at then
    perform identity.fail('payout_lookup_expired');
  end if;

  if p_outcome = 'resolved' then
    clean_name := regexp_replace(btrim(coalesce(p_account_name, '')), '\s+', ' ', 'g');
    if length(clean_name) not between 1 and 160 or clean_name ~ '[[:cntrl:]]' then
      perform identity.fail('validation_error', jsonb_build_object('field', 'accountName'));
    end if;
    update payout.account_lookups
    set status = 'resolved',
        resolved_name = clean_name,
        name_match = payout.name_match(identity.legal_name(p_user_id), clean_name),
        name_rule_version = payout.name_rule_version(),
        resolved_at = now()
    where id = lookup.id
    returning * into lookup;
  elsif p_outcome = 'not_found' then
    update payout.account_lookups set status = 'not_found', resolved_at = now()
    where id = lookup.id
    returning * into lookup;
  else
    perform identity.fail('validation_error', jsonb_build_object('field', 'outcome'));
  end if;

  perform audit.record('payout_account.lookup', p_user_id, p_session_id, p_user_id,
    p_safe_after => jsonb_build_object('lookupId', lookup.id, 'bankCode', lookup.bank_code,
      'status', lookup.status, 'nameMatch', lookup.name_match),
    p_request_id => p_request_id);
  return payout.lookup_json(lookup);
end;
$$;

-- ── Accounts ──────────────────────────────────────────────────────────────

-- Explicit confirmation of a resolved proof (W-17). Creates a verified
-- account; never sets primary except by carrying it over on replacement.
create function api.confirm_payout_account(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_lookup_id uuid,
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
  clean_reason text;
  request jsonb;
  replayed jsonb;
  lookup payout.account_lookups;
  match payout.name_match_result;
  previous payout.accounts;
  replaced payout.accounts;
  created payout.accounts;
  first_account boolean;
begin
  workspace := payout.workspace(p_user_id, p_session_id, p_membership_id, true, true);
  if p_reason is not null then
    clean_reason := identity.require_reason(p_reason);
  end if;

  request := jsonb_build_object('lookupId', p_lookup_id, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'confirm_payout_account', request);
  if replayed is not null then
    return replayed;
  end if;

  perform payout.lock_owner(p_user_id);
  select * into lookup from payout.account_lookups
  where id = p_lookup_id and owner_user_id = p_user_id
  for update;
  if lookup.id is null then
    perform identity.fail('not_found');
  end if;
  if lookup.confirmed_payout_account_id is not null then
    perform identity.fail('conflict', jsonb_build_object('reason', 'already_confirmed'));
  end if;
  if lookup.status = 'not_found' then
    perform identity.fail('account_not_found');
  end if;
  if lookup.status = 'pending' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'lookup_pending'));
  end if;
  if now() >= lookup.expires_at then
    perform identity.fail('payout_lookup_expired');
  end if;
  if lookup.workspace_membership_id <> workspace.id then
    perform identity.fail('conflict', jsonb_build_object('reason', 'workspace_mismatch'));
  end if;

  -- The NIN may have landed since the lookup.
  match := payout.name_match(identity.legal_name(p_user_id), lookup.resolved_name);
  if match = 'mismatched' then
    perform identity.fail('payout_name_mismatch',
      jsonb_build_object('explanation', 'bank_name_does_not_match_nin'));
  end if;

  if lookup.replaces_payout_account_id is not null then
    if clean_reason is null then
      perform identity.fail('validation_error', jsonb_build_object('field', 'reason'));
    end if;
    select * into previous from payout.accounts where id = lookup.replaces_payout_account_id for update;
    if previous.status <> 'active' then
      perform identity.fail('conflict', jsonb_build_object('reason', 'not_active'));
    end if;
  else
    if clean_reason is not null then
      perform identity.fail('validation_error', jsonb_build_object('field', 'reason', 'reason', 'replacement_only'));
    end if;
  end if;
  perform payout.assert_not_saved(p_user_id, lookup.bank_code, lookup.account_fingerprint);
  if lookup.replaces_payout_account_id is null and payout.active_count(p_user_id) >= payout.max_active_accounts() then
    perform identity.fail('conflict', jsonb_build_object('reason', 'account_limit'));
  end if;

  first_account := not exists (select 1 from payout.accounts where owner_user_id = p_user_id);

  insert into payout.accounts (
    owner_user_id, provider, bank_code, bank_name, account_ciphertext, key_version,
    account_fingerprint, account_last4, account_name, verification_status, verification_method,
    lookup_id, verified_at, name_match, name_rule_version, name_checked_at,
    replaces_id, usable_from, created_at
  ) values (
    p_user_id, lookup.provider, lookup.bank_code,
    coalesce(payout.bank_name(lookup.provider, lookup.bank_code), lookup.bank_code),
    lookup.account_ciphertext, lookup.key_version, lookup.account_fingerprint, lookup.account_last4,
    lookup.resolved_name, 'verified', 'nuban_lookup', lookup.id, now(), match,
    payout.name_rule_version(), now(), lookup.replaces_payout_account_id,
    case when first_account then now() else now() + payout.cooling_off() end, now()
  )
  returning * into created;

  update payout.account_lookups set confirmed_payout_account_id = created.id, confirmed_at = now()
  where id = lookup.id;

  if previous.id is not null then
    update payout.accounts set status = 'replaced', replaced_by_id = created.id, is_primary = false
    where id = previous.id
    returning * into replaced;
    if previous.is_primary then
      update payout.accounts set is_primary = true where id = created.id returning * into created;
    end if;
    perform audit.record('payout_account.replaced', p_user_id, p_session_id, p_user_id, clean_reason,
      payout.audit_fields(replaced), payout.audit_fields(created), p_request_id);
    perform payout.alert_owner(created, 'replaced');
  else
    perform audit.record('payout_account.added', p_user_id, p_session_id, p_user_id,
      p_safe_after => payout.audit_fields(created), p_request_id => p_request_id);
    perform payout.alert_owner(created, 'added');
  end if;

  return identity.store_result(p_user_id, p_idempotency_key, 'confirm_payout_account', request,
    jsonb_build_object('payoutAccount', payout.account_json(created),
      'replacedPayoutAccountId', previous.id));
end;
$$;

create function api.list_payout_accounts(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform payout.workspace(p_user_id, p_session_id, p_membership_id, false, false);
  return jsonb_build_object('items', coalesce((
    select jsonb_agg(payout.account_json(a)
      order by a.is_primary desc, a.status = 'active' desc, a.created_at desc, a.id)
    from payout.accounts a
    where a.owner_user_id = p_user_id
  ), '[]'::jsonb));
end;
$$;

-- Locks the person's accounts that a primary change touches, in id order.
create function payout.lock_for_primary(p_user_id uuid, p_account_id uuid)
returns void
language sql
set search_path = ''
as $$
  select null from payout.accounts
  where owner_user_id = p_user_id and (id = p_account_id or is_primary)
  order by id
  for update;
$$;

create function api.set_primary_payout_account(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_payout_account_id uuid,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  request jsonb;
  replayed jsonb;
  target payout.accounts;
  previous payout.accounts;
begin
  perform payout.workspace(p_user_id, p_session_id, p_membership_id, true, true);
  request := jsonb_build_object('payoutAccountId', p_payout_account_id);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'set_primary_payout_account', request);
  if replayed is not null then
    return replayed;
  end if;

  perform payout.lock_owner(p_user_id);
  perform payout.lock_for_primary(p_user_id, p_payout_account_id);
  select * into target from payout.accounts where id = p_payout_account_id and owner_user_id = p_user_id;
  if target.id is null then
    perform identity.fail('not_found');
  end if;
  if target.status <> 'active' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'not_active'));
  end if;
  if target.verification_status <> 'verified' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'unverified'));
  end if;
  if target.name_match = 'mismatched' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'name_mismatch'));
  end if;

  if not target.is_primary then
    update payout.accounts set is_primary = false
    where owner_user_id = p_user_id and currency = target.currency and rail = target.rail and is_primary
    returning * into previous;
    update payout.accounts set is_primary = true where id = target.id returning * into target;
    perform audit.record('payout_account.primary_changed', p_user_id, p_session_id, p_user_id,
      p_safe_before => case when previous.id is not null then payout.audit_fields(previous) end,
      p_safe_after => payout.audit_fields(target), p_request_id => p_request_id);
    perform payout.alert_owner(target, 'primary_changed');
    return identity.store_result(p_user_id, p_idempotency_key, 'set_primary_payout_account', request,
      jsonb_build_object('payoutAccount', payout.account_json(target), 'changed', true));
  end if;

  return identity.store_result(p_user_id, p_idempotency_key, 'set_primary_payout_account', request,
    jsonb_build_object('payoutAccount', payout.account_json(target), 'changed', false));
end;
$$;

create function api.deactivate_payout_account(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
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
  clean_reason text;
  request jsonb;
  replayed jsonb;
  previous payout.accounts;
  target payout.accounts;
begin
  perform payout.workspace(p_user_id, p_session_id, p_membership_id, true, true);
  clean_reason := identity.require_reason(p_reason);
  request := jsonb_build_object('payoutAccountId', p_payout_account_id, 'reason', clean_reason);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'deactivate_payout_account', request);
  if replayed is not null then
    return replayed;
  end if;

  perform payout.lock_owner(p_user_id);
  select * into previous from payout.accounts
  where id = p_payout_account_id and owner_user_id = p_user_id
  for update;
  if previous.id is null then
    perform identity.fail('not_found');
  end if;
  if previous.status <> 'active' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'not_active'));
  end if;

  update payout.accounts
  set status = 'deactivated', is_primary = false, deactivated_at = now(), deactivated_reason = clean_reason
  where id = previous.id
  returning * into target;

  perform audit.record('payout_account.deactivated', p_user_id, p_session_id, p_user_id, clean_reason,
    payout.audit_fields(previous), payout.audit_fields(target), p_request_id);
  perform payout.alert_owner(target, 'deactivated');

  return identity.store_result(p_user_id, p_idempotency_key, 'deactivate_payout_account', request,
    jsonb_build_object('payoutAccount', payout.account_json(target)));
end;
$$;

-- Owner reveal (W-17). The audit row is written before the ciphertext leaves;
-- the Edge Function decrypts and answers with cache-control: no-store.
create function api.reveal_payout_account(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_payout_account_id uuid,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  account payout.accounts;
begin
  perform payout.workspace(p_user_id, p_session_id, p_membership_id, false, true);
  select * into account from payout.accounts
  where id = p_payout_account_id and owner_user_id = p_user_id;
  if account.id is null then
    perform identity.fail('not_found');
  end if;
  perform audit.record('payout_account.revealed', p_user_id, p_session_id, p_user_id,
    p_safe_after => payout.audit_fields(account), p_request_id => p_request_id);
  return jsonb_build_object(
    'payoutAccountId', account.id,
    'ciphertext', account.account_ciphertext,
    'keyVersion', account.key_version
  );
end;
$$;

-- ── Privileges ────────────────────────────────────────────────────────────

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
