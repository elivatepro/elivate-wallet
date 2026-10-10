-- Blueprint 18 — B3: cross-network reads for the platform Admin app (W-23).
-- Every function checks the caller is an active platform admin (all admins
-- have full access, U-09) and returns only the allowlisted, masked fields the
-- screens show: never PINs, NINs, full account numbers, IP addresses, tokens
-- or evidence. All reads are tenant-aware but span every network.

-- ── Shared helpers ────────────────────────────────────────────────────────

-- One label for a network's commercial and lifecycle state.
create function platform.network_state(p_t org.tenants, p_s billing.subscriptions)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_t.status = 'deactivated' then 'deactivated'
    when p_t.status = 'pending_payment' then 'pending_payment'
    when p_t.status = 'suspended' or p_s.status = 'paused' then 'paused'
    when p_s.status = 'trial' then 'trial'
    else 'active' end
$$;

create function platform.presidents(p_tenant_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(org.person(m.user_id) order by m.started_at, m.id), '[]'::jsonb)
  from org.memberships m
  where m.tenant_id = p_tenant_id and m.role = 'president_team_member' and m.status = 'active';
$$;

create function platform.network_row(p_t org.tenants)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'tenantId', p_t.id,
    'name', p_t.name,
    'shortName', p_t.short_name,
    'state', platform.network_state(p_t, s),
    'kind', s.kind,
    'plan', case when s.plan_id is not null then billing.plan_json(billing.plan_by_id(s.plan_id)) end,
    'periodEnd', s.period_end,
    'seats', jsonb_build_object('used', billing.seats_used(p_t.id), 'cap', case when s.tenant_id is not null
      then billing.seat_cap(s) end),
    'officeCount', (select count(*)::int from org.offices o where o.tenant_id = p_t.id and o.status = 'active'),
    'presidents', platform.presidents(p_t.id),
    'founder', org.person(p_t.created_by),
    'createdAt', p_t.created_at
  )
  from (select 1) one
  left join billing.subscriptions s on s.tenant_id = p_t.id;
$$;

create function platform.pin_state(p_user_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when c.user_id is null then 'not_set'
    when c.locked_at is not null then 'locked'
    else 'set' end
  from (select 1) one
  left join identity.pin_credentials c on c.user_id = p_user_id;
$$;

create function platform.account_row(p_a identity.accounts)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select org.person(p_a.user_id) || jsonb_build_object(
    'email', org.masked_email(p_a.user_id),
    'status', p_a.status,
    'networks', (
      select coalesce(jsonb_agg(distinct notify.network(m.tenant_id)), '[]'::jsonb)
      from org.memberships m where m.user_id = p_a.user_id and m.status in ('active', 'suspended')
    ),
    'lastSignInAt', (select max(si.created_at) from identity.sign_ins si where si.user_id = p_a.user_id),
    'pin', platform.pin_state(p_a.user_id),
    'isAdmin', exists (select 1 from identity.platform_admins pa where pa.user_id = p_a.user_id and pa.revoked_at is null),
    'createdAt', p_a.created_at
  );
$$;

-- Search text without LIKE wildcards.
create function platform.like_text(p_query text)
returns text
language sql
immutable
set search_path = ''
as $$
  select replace(replace(replace(btrim(p_query), '\', '\\'), '%', '\%'), '_', '\_')
$$;

-- Phone digits match: the last 10 digits when 10+ were typed (so 0801… finds
-- +234801…), otherwise a suffix of at least 6 digits.
create function platform.phone_matches(p_phone text, p_digits text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_phone is not null and p_digits is not null and length(p_digits) >= 6 and case
    when length(p_digits) >= 10
      then right(regexp_replace(p_phone, '[^0-9]', '', 'g'), 10) = right(p_digits, 10)
    else regexp_replace(p_phone, '[^0-9]', '', 'g') like '%' || p_digits end
$$;

create function platform.require_query(p_query text, p_required boolean)
returns text
language plpgsql
set search_path = ''
as $$
begin
  if p_query is null or btrim(p_query) = '' then
    if p_required then
      perform identity.fail('validation_error', jsonb_build_object('field', 'q'));
    end if;
    return null;
  end if;
  if length(btrim(p_query)) > 100 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'q'));
  end if;
  return btrim(p_query);
end;
$$;

-- ── Me and the overview ───────────────────────────────────────────────────

-- Whether the signed-in account is a platform admin (the admin site's gate).
create function api.admin_me(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  return org.person(p_user_id) || jsonb_build_object(
    'isAdmin', exists (select 1 from identity.platform_admins where user_id = p_user_id and revoked_at is null),
    'stepUpExpiresAt', identity.security_state(p_user_id, p_session_id)->'stepUpExpiresAt'
  );
end;
$$;

create function api.admin_overview(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  return jsonb_build_object(
    'networks', (
      select jsonb_build_object(
        'total', count(*)::int,
        'byState', coalesce(jsonb_object_agg(state, n) filter (where state is not null), '{}'::jsonb))
      from (
        select platform.network_state(t, s) as state, count(*)::int as n
        from org.tenants t left join billing.subscriptions s on s.tenant_id = t.id
        group by 1
      ) x
    ),
    'accounts', (
      select jsonb_build_object('total', count(*)::int,
        'byStatus', coalesce(jsonb_object_agg(status, n), '{}'::jsonb))
      from (select a.status::text as status, count(*)::int as n from identity.accounts a group by 1) x
    ),
    'recentNetworks', coalesce((
      select jsonb_agg(platform.network_row(t) order by t.created_at desc, t.id)
      from (select * from org.tenants order by created_at desc, id limit 6) t
    ), '[]'::jsonb),
    'switches', coalesce((
      select jsonb_agg(platform.switch_json(s) order by array_position(platform.switch_keys(), s.key))
      from platform.kill_switches s where s.tenant_id is null
    ), '[]'::jsonb),
    'networkStops', (select count(*)::int from platform.kill_switches where tenant_id is not null and stopped),
    'openRestores', coalesce((
      select jsonb_agg(jsonb_build_object('restoreId', r.id, 'reference', r.reference, 'status', r.status,
        'network', notify.network(r.tenant_id), 'createdAt', r.created_at) order by r.created_at, r.id)
      from backups.restore_requests r
      where r.status in ('requested', 'validating', 'in_review', 'restoring')
    ), '[]'::jsonb),
    'failedEmails', (select count(*)::int from outbox.deliveries where status = 'dead_lettered'),
    'ninReviews', (select count(*)::int from identity.nin_reviews where status = 'pending' and user_id <> p_user_id)
  );
end;
$$;

-- ── Networks ──────────────────────────────────────────────────────────────

create function api.admin_tenants(
  p_user_id uuid,
  p_session_id uuid,
  p_query text default null,
  p_state text default null,
  p_cursor text default null,
  p_limit int default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  q text;
  lim int := org.page_limit(p_limit);
  after jsonb := org.decode_cursor(p_cursor);
  rows jsonb;
  last_key jsonb;
  has_more boolean;
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  q := platform.require_query(p_query, false);
  if p_state is not null and p_state not in ('active', 'trial', 'paused', 'pending_payment', 'deactivated') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'state'));
  end if;

  with found as (
    select t.id, lower(t.name) as sort_name
    from org.tenants t
    left join billing.subscriptions s on s.tenant_id = t.id
    where (p_state is null or platform.network_state(t, s) = p_state)
      and (q is null or t.name ilike '%' || platform.like_text(q) || '%'
           or t.short_name ilike '%' || platform.like_text(q) || '%'
           or exists (
             select 1 from org.memberships m left join identity.profiles p on p.user_id = m.user_id
             where m.tenant_id = t.id and m.role = 'president_team_member' and m.status = 'active'
               and coalesce(p.display_name, concat_ws(' ', p.first_name, p.last_name)) ilike '%' || platform.like_text(q) || '%'))
      and (after is null or (lower(t.name), t.id) > (after->>'n', (after->>'id')::uuid))
    order by lower(t.name), t.id
    limit lim + 1
  ),
  numbered as (
    select f.*, row_number() over (order by f.sort_name, f.id) as rn from found f
  )
  select coalesce(jsonb_agg(platform.network_row(t) order by n.rn) filter (where n.rn <= lim), '[]'::jsonb),
         (array_agg(jsonb_build_object('n', n.sort_name, 'id', n.id) order by n.rn desc) filter (where n.rn <= lim))[1],
         count(*) > lim
  into rows, last_key, has_more
  from numbered n join org.tenants t on t.id = n.id;

  return jsonb_build_object(
    'items', rows,
    'nextCursor', case when has_more then org.encode_cursor(last_key) end,
    'counts', (
      select jsonb_build_object('all', count(*)::int) || coalesce(jsonb_object_agg(state, n) filter (where state is not null), '{}'::jsonb)
      from (
        select platform.network_state(t, s) as state, count(*)::int as n
        from org.tenants t left join billing.subscriptions s on s.tenant_id = t.id group by 1
      ) x
    )
  );
end;
$$;

create function api.admin_tenant(p_user_id uuid, p_session_id uuid, p_tenant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  t org.tenants;
  s billing.subscriptions;
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  select * into t from org.tenants where id = p_tenant_id;
  if t.id is null then
    perform identity.fail('not_found');
  end if;
  select * into s from billing.subscriptions where tenant_id = t.id;
  return platform.network_row(t) || jsonb_build_object(
    'status', t.status,
    'activatedAt', t.activated_at,
    'activationSource', t.activation_source,
    'subscription', case when s.tenant_id is not null then jsonb_build_object(
      'status', s.status, 'kind', s.kind, 'periodStart', s.period_start, 'periodEnd', s.period_end,
      'pausedAt', s.paused_at, 'autoRenew', s.auto_renew, 'owner', billing.owner_json(t.id)) end,
    'organization', jsonb_build_object(
      'offices', (select count(*)::int from org.offices where tenant_id = t.id and status = 'active'),
      'byType', coalesce((
        select jsonb_object_agg(office_type, n) from (
          select office_type::text, count(*)::int as n from org.offices
          where tenant_id = t.id and status = 'active' group by 1) x), '{}'::jsonb),
      'memberships', (select count(*)::int from org.memberships where tenant_id = t.id and status in ('active', 'suspended')),
      'people', billing.seats_used(t.id)),
    'stopped', to_jsonb(platform.stopped_for(t.id)),
    'openRestore', (
      select jsonb_build_object('restoreId', r.id, 'reference', r.reference, 'status', r.status)
      from backups.restore_requests r
      where r.tenant_id = t.id and r.status in ('requested', 'validating', 'in_review', 'restoring')
    )
  );
end;
$$;

-- ── Accounts ──────────────────────────────────────────────────────────────

create function api.admin_accounts(
  p_user_id uuid,
  p_session_id uuid,
  p_query text default null,
  p_status text default null,
  p_cursor text default null,
  p_limit int default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  q text;
  digits text;
  lim int := org.page_limit(p_limit);
  after jsonb := org.decode_cursor(p_cursor);
  page jsonb;
  last_uid text;
  has_more boolean;
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  q := platform.require_query(p_query, false);
  digits := nullif(regexp_replace(coalesce(q, ''), '[^0-9]', '', 'g'), '');
  if p_status is not null and p_status not in ('active', 'restricted', 'suspended', 'deactivated') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'status'));
  end if;

  with found as (
    select a.user_id, a.uid from identity.accounts a
    left join identity.profiles p on p.user_id = a.user_id
    left join auth.users u on u.id = a.user_id
    where (p_status is null or a.status::text = p_status)
      and (q is null
        or a.uid = upper(q)
        or coalesce(p.display_name, '') ilike '%' || platform.like_text(q) || '%'
        or concat_ws(' ', p.first_name, p.last_name) ilike '%' || platform.like_text(q) || '%'
        or (position('@' in q) > 0 and lower(u.email) like lower(platform.like_text(q)) || '%')
        or platform.phone_matches(p.phone, digits))
      and (after is null or a.uid > after->>'uid')
    order by a.uid
    limit lim + 1
  ),
  numbered as (
    select f.*, row_number() over (order by f.uid) as rn from found f
  )
  select coalesce(jsonb_agg(platform.account_row(a) order by n.rn) filter (where n.rn <= lim), '[]'::jsonb),
         max(n.uid) filter (where n.rn <= lim), count(*) > lim
  into page, last_uid, has_more
  from numbered n join identity.accounts a on a.user_id = n.user_id;

  return jsonb_build_object(
    'items', page,
    'nextCursor', case when has_more then org.encode_cursor(jsonb_build_object('uid', last_uid)) end,
    'counts', (
      select jsonb_build_object('all', count(*)::int) || coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
      from (select a.status::text as status, count(*)::int as n from identity.accounts a group by 1) x
    )
  );
end;
$$;

create function api.admin_account(p_user_id uuid, p_session_id uuid, p_uid text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a identity.accounts;
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  select * into a from identity.accounts where uid = upper(btrim(coalesce(p_uid, '')));
  if a.user_id is null then
    perform identity.fail('not_found');
  end if;
  return platform.account_row(a) || jsonb_build_object(
    'phone', org.masked_phone((select phone from identity.profiles where user_id = a.user_id)),
    'memberships', coalesce((
      select jsonb_agg(jsonb_build_object(
        'membershipId', m.id, 'network', notify.network(m.tenant_id), 'tenantId', m.tenant_id,
        'office', case when m.office_id is not null then notify.office(m.office_id) end,
        'role', m.role, 'status', m.status, 'startedAt', m.started_at, 'endedAt', m.ended_at)
        order by (m.status = 'ended'), m.started_at desc, m.id)
      from org.memberships m where m.user_id = a.user_id
    ), '[]'::jsonb),
    'statusHistory', coalesce((
      select jsonb_agg(jsonb_build_object('from', c.from_status, 'to', c.to_status, 'reason', c.reason,
        'actor', org.person(c.actor_user_id), 'at', c.at) order by c.at desc, c.id desc)
      from identity.account_status_changes c where c.user_id = a.user_id
    ), '[]'::jsonb),
    'security', jsonb_build_object(
      'pin', platform.pin_state(a.user_id),
      'activeSessions', (
        select count(*)::int from auth.sessions s
        where s.user_id = a.user_id and (s.not_after is null or s.not_after > now())),
      'lastSignInAt', (select max(created_at) from identity.sign_ins where user_id = a.user_id),
      'unusualSignIns7d', (
        select count(*)::int from identity.sign_ins
        where user_id = a.user_id and unusual and created_at > now() - interval '7 days'))
  );
end;
$$;

-- ── Global search (W-23) ──────────────────────────────────────────────────

-- Bank codes the Edge layer fingerprints a searched account number against
-- (the fingerprint covers bank code and number; the number never reaches SQL).
create function api.admin_bank_codes(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  return coalesce((select jsonb_agg(distinct bank_code) from payout.accounts), '[]'::jsonb);
end;
$$;

-- The object behind a public reference, or null.
create function platform.reference_row(p_code text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  kind text := left(p_code, 3);
  tenant uuid;
  owner uuid;
  status text;
  label text;
begin
  case kind
    when 'WDR' then
      select w.tenant_id, w.owner_user_id, w.status, 'Withdrawal' into tenant, owner, status, label
      from finance.withdrawals w where w.reference = p_code;
    when 'PTR' then
      select t.tenant_id, t.owner_user_id, t.status, 'Pocket move' into tenant, owner, status, label
      from finance.pocket_transfers t where t.reference = p_code;
    when 'CNV', 'ADJ', 'RTN' then
      select e.tenant_id, e.owner_user_id, e.status,
        case e.kind when 'conversion' then 'Conversion' when 'adjustment' then 'Adjustment' else 'Returned funds' end
      into tenant, owner, status, label
      from finance.entries e where e.reference = p_code;
    when 'INC' then
      select i.tenant_id, i.owner_user_id, 'posted', 'Income' into tenant, owner, status, label
      from finance.income_records i where i.reference = p_code;
    when 'REV' then
      select r.tenant_id, null::uuid, 'posted', 'Reversal' into tenant, owner, status, label
      from finance.reversals r where r.reference = p_code;
    when 'RST' then
      select r.tenant_id, r.requested_by, r.status, 'Restore request' into tenant, owner, status, label
      from backups.restore_requests r where r.reference = p_code;
    when 'PAY' then
      select p.tenant_id, null::uuid, p.status, 'Payment' into tenant, owner, status, label
      from billing.payments p where p.reference = p_code;
    when 'INV' then
      select i.tenant_id, null::uuid, i.status::text, 'Invitation' into tenant, owner, status, label
      from org.invitations i where i.reference = p_code;
    else
      return null;
  end case;
  if tenant is null then
    return null;
  end if;
  return jsonb_build_object('reference', p_code, 'kind', label, 'status', status,
    'network', notify.network(tenant), 'tenantId', tenant,
    'owner', case when owner is not null then org.person(owner) end);
end;
$$;

create function api.admin_search(
  p_user_id uuid,
  p_session_id uuid,
  p_query text,
  p_bank_fingerprints text[] default null,
  p_limit int default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  q text;
  digits text;
  lim int := least(coalesce(p_limit, 20), 50);
  ref_code text;
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  q := platform.require_query(p_query, true);
  if length(q) < 2 then
    perform identity.fail('validation_error', jsonb_build_object('field', 'q'));
  end if;
  if p_bank_fingerprints is not null and (cardinality(p_bank_fingerprints) > 500
     or exists (select 1 from unnest(p_bank_fingerprints) f where f !~ '^[0-9a-f]{64}$')) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'bankFingerprints'));
  end if;
  digits := nullif(regexp_replace(q, '[^0-9]', '', 'g'), '');
  ref_code := upper(regexp_replace(q, '\s', '', 'g'));

  return jsonb_build_object(
    'query', q,
    'accounts', coalesce((
      select jsonb_agg(platform.account_row(a) || jsonb_build_object('matchedOn', x.matched) order by x.rank, a.uid)
      from (
        select m.user_id, min(m.rank) as rank, (array_agg(m.matched order by m.rank))[1] as matched
        from (
          select a.user_id, 'uid' as matched, 1 as rank from identity.accounts a where a.uid = upper(q)
          union all
          select p.user_id, 'name', 2 from identity.profiles p
          where coalesce(p.display_name, '') ilike '%' || platform.like_text(q) || '%'
             or concat_ws(' ', p.first_name, p.last_name) ilike '%' || platform.like_text(q) || '%'
          union all
          select u.id, 'email', 3 from auth.users u
          where position('@' in q) > 0 and lower(u.email) like lower(platform.like_text(q)) || '%'
          union all
          select p.user_id, 'phone', 4 from identity.profiles p
          where platform.phone_matches(p.phone, digits)
          union all
          select pa.owner_user_id, 'bank_account', 5 from payout.accounts pa
          where p_bank_fingerprints is not null and pa.account_fingerprint = any (p_bank_fingerprints)
        ) m
        group by m.user_id
        order by min(m.rank)
        limit lim
      ) x
      join identity.accounts a on a.user_id = x.user_id
    ), '[]'::jsonb),
    'bankAccounts', coalesce((
      select jsonb_agg(jsonb_build_object('owner', org.person(pa.owner_user_id), 'bankName', pa.bank_name,
        'last4', pa.account_last4, 'status', pa.status) order by pa.created_at desc)
      from payout.accounts pa
      where p_bank_fingerprints is not null and pa.account_fingerprint = any (p_bank_fingerprints)
    ), '[]'::jsonb),
    'references', coalesce((
      select jsonb_agg(r) from (
        select platform.reference_row(i.code) as r from refs.issued i where i.code = ref_code
      ) x where r is not null
    ), '[]'::jsonb),
    'networks', coalesce((
      select jsonb_agg(platform.network_row(t) order by t.name) from (
        select * from org.tenants
        where name ilike '%' || platform.like_text(q) || '%' or short_name ilike '%' || platform.like_text(q) || '%'
        order by name limit lim) t
    ), '[]'::jsonb),
    'offices', coalesce((
      select jsonb_agg(jsonb_build_object('officeId', o.id, 'name', o.name, 'type', o.office_type,
        'status', o.status, 'network', notify.network(o.tenant_id), 'tenantId', o.tenant_id) order by o.name)
      from (select * from org.offices where name ilike '%' || platform.like_text(q) || '%' order by name limit lim) o
    ), '[]'::jsonb)
  );
end;
$$;

-- ── Platform audit (W-23: immutable, safe fields only) ────────────────────

create index security_events_at_idx on audit.security_events (at desc, id desc);
create index tenant_events_at_idx on audit.tenant_events (at desc, id desc);

create function platform.action_group(p_action text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_action ~ '^(kill_switch|platform_admin|outbox|tenant\.activated|operations)\.' or p_action = 'tenant.activated'
      then 'controls'
    when p_action ~ '^(account|identity|pin|password|session|sign_in|security)' then 'accounts'
    when p_action ~ '^(income|withdrawal|payout|pocket_transfer|entry|conversion|adjustment|returned_funds|reversal)\.'
      then 'money'
    when p_action ~ '^(restore|backup)\.' then 'backups'
    else 'network' end
$$;

create function api.admin_audit(
  p_user_id uuid,
  p_session_id uuid,
  p_query text default null,
  p_group text default null,
  p_actor_uid text default null,
  p_tenant_id uuid default null,
  p_from date default null,
  p_to date default null,
  p_cursor text default null,
  p_limit int default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  q text;
  lim int := org.page_limit(p_limit);
  after jsonb := org.decode_cursor(p_cursor);
  actor uuid;
  page jsonb;
  last_key jsonb;
  has_more boolean;
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  q := platform.require_query(p_query, false);
  if p_group is not null and p_group not in ('controls', 'accounts', 'money', 'backups', 'network') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'group'));
  end if;
  if p_from is not null and p_to is not null and p_to < p_from then
    perform identity.fail('validation_error', jsonb_build_object('field', 'to'));
  end if;
  if p_actor_uid is not null then
    actor := identity.account_by_uid(p_actor_uid);
  end if;

  with events as (
    select 'p' as src, e.id, e.at, e.actor_user_id, e.action, null::uuid as tenant_id,
           case when e.target_user_id is not null then 'account' end as target_type,
           e.target_user_id::text as target_id, e.target_user_id, e.reason, e.safe_before, e.safe_after,
           e.request_id
    from audit.security_events e
    where p_tenant_id is null or (e.safe_after->>'tenantId') = p_tenant_id::text
    union all
    select 'n', e.id, e.at, e.actor_user_id, e.action, e.tenant_id, e.target_type, e.target_id, null, e.reason,
           e.safe_before, e.safe_after, e.request_id
    from audit.tenant_events e
    where p_tenant_id is null or e.tenant_id = p_tenant_id
  ),
  filtered as (
    select * from events ev
    where (actor is null or ev.actor_user_id = actor)
      and (p_group is null or platform.action_group(ev.action) = p_group)
      and (p_from is null or ev.at >= (p_from::timestamp at time zone 'Africa/Lagos'))
      and (p_to is null or ev.at < ((p_to + 1)::timestamp at time zone 'Africa/Lagos'))
      and (q is null or ev.action ilike '%' || platform.like_text(q) || '%'
           or ev.target_id ilike '%' || platform.like_text(q) || '%'
           or ev.reason ilike '%' || platform.like_text(q) || '%'
           or (ev.safe_after->>'reference') = upper(q))
      and (after is null or (ev.at, ev.src, ev.id) < ((after->>'at')::timestamptz, after->>'src', (after->>'id')::bigint))
    order by ev.at desc, ev.src desc, ev.id desc
    limit lim + 1
  ),
  numbered as (
    select f.*, row_number() over (order by f.at desc, f.src desc, f.id desc) as rn from filtered f
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'eventId', n.src || n.id,
      'at', n.at,
      'actor', case when n.actor_user_id is not null then org.person(n.actor_user_id) end,
      'actorIsAdmin', exists (select 1 from identity.platform_admins pa where pa.user_id = n.actor_user_id),
      'action', n.action,
      'group', platform.action_group(n.action),
      'network', case when n.tenant_id is not null then notify.network(n.tenant_id) end,
      'tenantId', n.tenant_id,
      'targetType', n.target_type,
      'targetId', case when n.target_type = 'account' then null else n.target_id end,
      'target', case when n.target_user_id is not null then org.person(n.target_user_id) end,
      'reason', n.reason,
      'before', n.safe_before,
      'after', n.safe_after,
      'requestId', n.request_id
    ) order by n.rn) filter (where n.rn <= lim), '[]'::jsonb),
    (array_agg(jsonb_build_object('at', n.at, 'src', n.src, 'id', n.id) order by n.rn desc)
      filter (where n.rn <= lim))[1],
    count(*) > lim
  into page, last_key, has_more
  from numbered n;

  return jsonb_build_object('items', page,
    'nextCursor', case when has_more then org.encode_cursor(last_key) end);
end;
$$;

-- ── Admins and restores ───────────────────────────────────────────────────

create function api.admin_admins(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  return coalesce((
    select jsonb_agg(org.person(pa.user_id) || jsonb_build_object(
      'grantedBy', case when pa.granted_by is not null then org.person(pa.granted_by) end,
      'grantedAt', pa.granted_at,
      'lastSignInAt', (select max(created_at) from identity.sign_ins where user_id = pa.user_id),
      'isYou', pa.user_id = p_user_id) order by pa.granted_at, pa.id)
    from identity.platform_admins pa where pa.revoked_at is null
  ), '[]'::jsonb);
end;
$$;

create function api.admin_restores(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  perform identity.require_platform_admin(p_user_id);
  return coalesce((
    select jsonb_agg(backups.restore_json(r, p_user_id, false) - 'canCancel' || jsonb_build_object(
      'network', notify.network(r.tenant_id), 'tenantId', r.tenant_id,
      'operator', case when r.operator_user_id is not null then org.person(r.operator_user_id) end,
      'finishedAt', r.finished_at)
      order by (r.status in ('requested', 'validating', 'in_review', 'restoring')) desc, r.created_at desc, r.id)
    from (select * from backups.restore_requests order by created_at desc limit 100) r
  ), '[]'::jsonb);
end;
$$;

-- ── Privileges ────────────────────────────────────────────────────────────

revoke all on all functions in schema platform from public, anon, authenticated;
do $$
declare
  f text;
begin
  foreach f in array array[
    'api.admin_me(uuid, uuid)',
    'api.admin_overview(uuid, uuid)',
    'api.admin_tenants(uuid, uuid, text, text, text, int)',
    'api.admin_tenant(uuid, uuid, uuid)',
    'api.admin_accounts(uuid, uuid, text, text, text, int)',
    'api.admin_account(uuid, uuid, text)',
    'api.admin_bank_codes(uuid, uuid)',
    'api.admin_search(uuid, uuid, text, text[], int)',
    'api.admin_audit(uuid, uuid, text, text, text, uuid, date, date, text, int)',
    'api.admin_admins(uuid, uuid)',
    'api.admin_restores(uuid, uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
