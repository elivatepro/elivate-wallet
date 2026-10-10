-- Blueprint 22 — B1/B2: setup by role and the profile gate.
--
-- identity.setup_state(user) says which setup the person owes (wallet, light
-- or none) and the next missing step. The session gate gains
-- `profile_required`, and identity.require_session (every protected read and
-- command) refuses with it until the setup is done.
--
-- The wizard's own calls, joining, account security and the platform Admin
-- app's admin-only calls stay open. Which call is running is read from the
-- call stack: the outermost api.* function (the entry point the Edge called)
-- must be on identity.setup_exempt_functions() or be an api.admin_* read.
-- (A per-function `set` of a custom setting needs superuser on Supabase.)
-- Everything else is gated, including functions added later, unless they are
-- added to the list on purpose (pgTAP 220 pins it).

-- ── Setup state ───────────────────────────────────────────────────────────

-- { level: wallet | light | none, next: identity | profile | bank | null,
--   walletMembershipId }. Only active memberships count. A wallet membership
-- is a non-President membership in an active network and office whose funds
-- are managed; any other active membership, or a founder grant, asks for the
-- light setup (name, photo, rank).
create function identity.setup_state(p_user_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  wallet_membership uuid;
  restricted boolean;
  setup_level text;
  next_step text;
  profile identity.profiles;
begin
  select m.id into wallet_membership
  from org.memberships m
  join org.tenants t on t.id = m.tenant_id
  join org.offices o on o.id = m.office_id
  where m.user_id = p_user_id and m.status = 'active' and m.role <> 'president_team_member'
    and t.status = 'active' and o.status = 'active'
    and not org.funds_not_managed(m.id)
  order by m.is_primary desc, m.started_at, m.id
  limit 1;

  if wallet_membership is not null then
    setup_level := 'wallet';
  elsif exists (select 1 from org.memberships m where m.user_id = p_user_id and m.status = 'active')
     or exists (select 1 from founders.approved f where f.user_id = p_user_id) then
    setup_level := 'light';
  else
    setup_level := 'none';
  end if;

  select * into profile from identity.profiles p where p.user_id = p_user_id;
  restricted := exists (select 1 from identity.accounts a where a.user_id = p_user_id and a.status = 'restricted');
  if setup_level = 'wallet' then
    if not exists (select 1 from identity.nin_records n where n.user_id = p_user_id) then
      next_step := 'identity';
    elsif profile.photo_key is null or profile.phone is null or profile.rank is null then
      next_step := 'profile';
    -- A restricted account cannot add a bank account (no writes), so it is
    -- not asked for one; it cannot move money either (D-02).
    elsif not restricted and not exists (
      select 1 from payout.accounts a where a.owner_user_id = p_user_id and a.status = 'active'
    ) then
      next_step := 'bank';
    end if;
  elsif setup_level = 'light' then
    if profile.first_name is null or profile.last_name is null
      or profile.photo_key is null or profile.rank is null then
      next_step := 'profile';
    end if;
  end if;

  return jsonb_build_object('level', setup_level, 'next', next_step, 'walletMembershipId', wallet_membership);
end;
$$;

-- The entry points that stay open during setup, besides api.admin_*. The
-- list is exact (pgTAP 220 pins it).
create function identity.setup_exempt_functions()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array[
    -- The wizard (W-02): profile, NIN, bank account, which workspace.
    'my_profile', 'update_profile', 'set_profile_photo', 'prepare_nin_check', 'record_nin_check',
    'request_nin_review', 'list_banks', 'refresh_banks', 'prepare_account_lookup',
    'record_account_lookup', 'confirm_payout_account', 'list_payout_accounts', 'my_workspaces',
    'my_invitations',
    -- Account security (W-22).
    'list_sessions', 'revoke_sessions', 'change_pin', 'security_overview',
    'authorize_password_change', 'record_password_change', 'record_sign_in',
    -- Platform Admin app, admin-only commands (Blueprint 18).
    'activate_tenant', 'set_account_status', 'grant_platform_admin', 'revoke_platform_admin',
    'outbox_dead_letters', 'outbox_requeue', 'platform_advance_restore'
  ];
$$;

-- Database sessions of the `postgres` role may turn the setup gate off for
-- themselves with `set local identity.setup_gate = off`: the pgTAP suites
-- written before this slice do, because their fixtures predate setup. API
-- calls arrive through PostgREST (session user `authenticator`) and cannot.
create function identity.setup_gate_off()
returns boolean
language sql
stable
set search_path = ''
as $$
  select session_user = 'postgres' and coalesce(current_setting('identity.setup_gate', true), '') = 'off';
$$;

-- Is the setup gate off for the running call? True when the entry point
-- (the outermost api.* function on the stack) is exempt.
create function identity.setup_exempt()
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare
  stack text;
  entry text;
begin
  if identity.setup_gate_off() then
    return true;
  end if;
  get diagnostics stack = pg_context;
  select r.m[1] into entry
  from regexp_matches(stack, 'function api\.([a-z0-9_]+)\(', 'g') with ordinality as r (m, n)
  order by r.n desc
  limit 1;
  return entry is not null
    and (entry = any (identity.setup_exempt_functions()) or entry like 'admin\_%');
end;
$$;

-- Fails profile_required while the setup is unfinished (unless exempt).
create function identity.require_setup(p_user_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  setup jsonb;
begin
  if identity.setup_exempt() then
    return;
  end if;
  setup := identity.setup_state(p_user_id);
  if setup->>'next' is not null then
    perform identity.fail('profile_required', jsonb_build_object('step', setup->'next', 'level', setup->'level'));
  end if;
end;
$$;

-- ── Session gate ──────────────────────────────────────────────────────────

-- The PIN-only check (the body of require_session before this slice): the
-- join commands use it, because joining is part of setup.
create function identity.require_pin_session(
  p_user_id uuid,
  p_session_id uuid,
  p_step_up boolean default false
)
returns identity.account_status
language plpgsql
set search_path = ''
as $$
declare
  account_status identity.account_status;
  gate text;
  proof_verified_at timestamptz;
begin
  account_status := identity.require_live_session(p_user_id, p_session_id);
  gate := identity.pin_gate(p_user_id, p_session_id);
  if gate <> 'ready' then
    perform identity.fail(gate);
  end if;

  select p.verified_at into proof_verified_at
  from identity.session_pin_proofs p
  where p.session_id = p_session_id;

  update identity.session_pin_proofs
  set last_activity_at = now()
  where session_id = p_session_id
    and last_activity_at < now() - identity.session_touch_interval();

  if p_step_up and proof_verified_at <= now() - identity.step_up_window() then
    perform identity.fail('step_up_required');
  end if;
  return account_status;
end;
$$;

-- Every protected read and command: the PIN gate, then the setup gate, then
-- activity and step-up (as Blueprint 20 left them). Same signature.
create or replace function identity.require_session(
  p_user_id uuid,
  p_session_id uuid,
  p_step_up boolean default false
)
returns identity.account_status
language plpgsql
set search_path = ''
as $$
declare
  account_status identity.account_status;
  gate text;
  proof_verified_at timestamptz;
begin
  account_status := identity.require_live_session(p_user_id, p_session_id);
  gate := identity.pin_gate(p_user_id, p_session_id);
  if gate <> 'ready' then
    perform identity.fail(gate);
  end if;
  perform identity.require_setup(p_user_id);

  select p.verified_at into proof_verified_at
  from identity.session_pin_proofs p
  where p.session_id = p_session_id;

  update identity.session_pin_proofs
  set last_activity_at = now()
  where session_id = p_session_id
    and last_activity_at < now() - identity.session_touch_interval();

  if p_step_up and proof_verified_at <= now() - identity.step_up_window() then
    perform identity.fail('step_up_required');
  end if;
  return account_status;
end;
$$;

-- pin_setup_required | pin_locked | pin_required | profile_required | ready.
create function identity.session_gate(p_user_id uuid, p_session_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when g.pin = 'ready' and not identity.setup_gate_off()
      and identity.setup_state(p_user_id)->>'next' is not null then 'profile_required'
    else g.pin
  end
  from (select identity.pin_gate(p_user_id, p_session_id) as pin) g;
$$;

-- The state now carries the setup gate and the setup itself.
create or replace function identity.security_state(p_user_id uuid, p_session_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'gate', case when g.pin = 'ready' and s.setup->>'next' is not null and not identity.setup_gate_off()
                 then 'profile_required' else g.pin end,
    'uid', a.uid,
    'accountStatus', a.status,
    'attemptsRemaining', identity.pin_max_attempts() - coalesce(c.failed_attempts, 0),
    'stepUpExpiresAt', case
      when p.verified_at > now() - identity.step_up_window()
        then p.verified_at + identity.step_up_window()
    end,
    'setup', s.setup
  )
  from identity.accounts a
  cross join lateral (select identity.pin_gate(p_user_id, p_session_id) as pin) g
  cross join lateral (select identity.setup_state(a.user_id) as setup) s
  left join identity.pin_credentials c on c.user_id = a.user_id
  left join identity.session_pin_proofs p
    on p.session_id = p_session_id and p.user_id = a.user_id
  where a.user_id = p_user_id;
$$;

-- Joining (W-02, Blueprint 19) is part of setup: the PIN-only check.
create or replace function org.require_join_session(p_user_id uuid, p_session_id uuid)
returns text
language plpgsql
set search_path = ''
as $$
declare
  account_status identity.account_status;
  gate text;
  account_email text;
  confirmed_at timestamptz;
begin
  account_status := identity.require_live_session(p_user_id, p_session_id);
  gate := identity.pin_gate(p_user_id, p_session_id);
  if gate = 'ready' then
    perform identity.require_pin_session(p_user_id, p_session_id);
  elsif gate <> 'pin_setup_required' then
    perform identity.fail(gate);
  end if;
  if account_status <> 'active' then
    perform identity.fail('authorization_denied', jsonb_build_object('reason', 'account_not_active'));
  end if;

  select lower(btrim(u.email)), u.email_confirmed_at into account_email, confirmed_at
  from auth.users u where u.id = p_user_id;
  if account_email is null or confirmed_at is null then
    perform identity.fail('email_unverified');
  end if;
  return account_email;
end;
$$;

-- The bell's badge poll: the same gates, never counted as activity.
create or replace function notify.require_quiet_session(p_user_id uuid, p_session_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  gate text;
begin
  perform identity.require_live_session(p_user_id, p_session_id);
  gate := identity.pin_gate(p_user_id, p_session_id);
  if gate <> 'ready' then
    perform identity.fail(gate);
  end if;
  perform identity.require_setup(p_user_id);
end;
$$;

-- ── Profile: names for the light setup ────────────────────────────────────

-- p_changes may also hold firstName and lastName (1–80 characters each).
-- They are refused once a NIN record has locked the legal name.
create or replace function api.update_profile(
  p_user_id uuid,
  p_session_id uuid,
  p_changes jsonb,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  profile identity.profiles;
  request jsonb;
  replayed jsonb;
  key text;
  new_display text;
  new_phone text;
  new_rank text;
  new_first text;
  new_last text;
begin
  perform identity.require_session(p_user_id, p_session_id);
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then
    perform identity.fail('validation_error', jsonb_build_object('field', 'changes'));
  end if;
  for key in select jsonb_object_keys(p_changes) loop
    if key not in ('displayName', 'phone', 'rank', 'firstName', 'lastName') then
      perform identity.fail('validation_error', jsonb_build_object('field', key, 'reason', 'unknown_field'));
    end if;
  end loop;

  if p_changes ? 'displayName' then
    if jsonb_typeof(p_changes->'displayName') = 'null' then
      new_display := null;
    elsif jsonb_typeof(p_changes->'displayName') <> 'string'
      or length(btrim(p_changes->>'displayName')) not between 1 and 80 then
      perform identity.fail('validation_error', jsonb_build_object('field', 'displayName'));
    else
      new_display := regexp_replace(btrim(p_changes->>'displayName'), '\s+', ' ', 'g');
    end if;
  end if;
  if p_changes ? 'firstName' then
    if jsonb_typeof(p_changes->'firstName') <> 'string'
      or length(btrim(p_changes->>'firstName')) not between 1 and 80 then
      perform identity.fail('validation_error', jsonb_build_object('field', 'firstName'));
    end if;
    new_first := regexp_replace(btrim(p_changes->>'firstName'), '\s+', ' ', 'g');
  end if;
  if p_changes ? 'lastName' then
    if jsonb_typeof(p_changes->'lastName') <> 'string'
      or length(btrim(p_changes->>'lastName')) not between 1 and 80 then
      perform identity.fail('validation_error', jsonb_build_object('field', 'lastName'));
    end if;
    new_last := regexp_replace(btrim(p_changes->>'lastName'), '\s+', ' ', 'g');
  end if;
  if p_changes ? 'phone' then
    new_phone := regexp_replace(coalesce(p_changes->>'phone', ''), '[\s-]', '', 'g');
    if jsonb_typeof(p_changes->'phone') <> 'string' or new_phone !~ '^\+?[0-9]{7,15}$' then
      perform identity.fail('validation_error', jsonb_build_object('field', 'phone'));
    end if;
  end if;
  if p_changes ? 'rank' then
    new_rank := p_changes->>'rank';
    if jsonb_typeof(p_changes->'rank') <> 'string' or not (new_rank = any (identity.rank_values())) then
      perform identity.fail('validation_error', jsonb_build_object('field', 'rank'));
    end if;
  end if;

  request := jsonb_build_object('changes', p_changes);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'update_profile', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into profile from identity.profiles where user_id = p_user_id for update;
  if p_changes ? 'phone' and profile.phone_source = 'nin' and new_phone is distinct from profile.phone then
    perform identity.fail('conflict', jsonb_build_object('reason', 'phone_from_nin'));
  end if;
  if (p_changes ? 'firstName' or p_changes ? 'lastName')
    and exists (select 1 from identity.nin_records n where n.user_id = p_user_id) then
    perform identity.fail('conflict', jsonb_build_object('reason', 'name_locked'));
  end if;

  update identity.profiles
  set display_name = case when p_changes ? 'displayName' then new_display else display_name end,
      first_name = case when p_changes ? 'firstName' then new_first else first_name end,
      last_name = case when p_changes ? 'lastName' then new_last else last_name end,
      phone = case when p_changes ? 'phone' then new_phone else identity.profiles.phone end,
      phone_source = case when p_changes ? 'phone' and profile.phone_source is distinct from 'nin' then 'self'
                          else phone_source end,
      rank = case when p_changes ? 'rank' then new_rank else identity.profiles.rank end,
      updated_at = now()
  where user_id = p_user_id;

  perform audit.record('profile.updated', p_user_id, p_session_id, p_user_id,
    p_safe_after => jsonb_build_object('fields', (select jsonb_agg(k order by k) from jsonb_object_keys(p_changes) k)),
    p_request_id => p_request_id);
  return identity.store_result(p_user_id, p_idempotency_key, 'update_profile', request,
    identity.profile_view(p_user_id));
end;
$$;

-- ── Privileges ────────────────────────────────────────────────────────────

revoke all on function identity.setup_state(uuid) from public, anon, authenticated;
revoke all on function identity.setup_gate_off() from public, anon, authenticated;
revoke all on function identity.setup_exempt() from public, anon, authenticated;
revoke all on function identity.require_setup(uuid) from public, anon, authenticated;
revoke all on function identity.require_pin_session(uuid, uuid, boolean) from public, anon, authenticated;
revoke all on function identity.require_session(uuid, uuid, boolean) from public, anon, authenticated;
revoke all on function identity.session_gate(uuid, uuid) from public, anon, authenticated;
revoke all on function identity.security_state(uuid, uuid) from public, anon, authenticated;
revoke all on function identity.setup_exempt_functions() from public, anon, authenticated;
revoke all on function org.require_join_session(uuid, uuid) from public, anon, authenticated;
revoke all on function notify.require_quiet_session(uuid, uuid) from public, anon, authenticated;
revoke all on function api.update_profile(uuid, uuid, jsonb, text, text) from public, anon, authenticated;
grant execute on function api.update_profile(uuid, uuid, jsonb, text, text) to service_role;
