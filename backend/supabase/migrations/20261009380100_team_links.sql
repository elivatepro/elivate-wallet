-- Blueprint 38 — team invite links (owner decisions 2026-10-15). One open
-- link per office; anyone who opens it signs up (or signs in) with their own
-- email and joins that office as a Member at once (seat cap applies). The
-- leader chooses how long it works (1, 7 or 30 days, or no end) and how many
-- people can join (10, 50 or no limit); creating, replacing and turning off
-- need the PIN. A link stops when its creator no longer holds invite_members
-- over the office. Only a digest of each link code is stored (B1).

alter table refs.issued drop constraint issued_type_check;
alter table refs.issued add constraint issued_type_check
  check (type in ('WDR', 'PTR', 'RTN', 'INC', 'CNV', 'ADJ', 'REV', 'RST',
                  'PAY', 'STM', 'RPT', 'INV', 'WRQ', 'LNK'));

alter table audit.tenant_events drop constraint tenant_events_target_type_check;
alter table audit.tenant_events add constraint tenant_events_target_type_check
  check (target_type = any (array['tenant', 'office', 'membership', 'role_permission', 'access_assignment',
    'reviewer_assignment', 'invitation', 'allocation_policy', 'income', 'evidence', 'withdrawal', 'payout',
    'pocket_transfer', 'entry', 'reversal', 'export', 'subscription', 'billing_payment', 'billing_owner',
    'tenant_settings', 'backup', 'restore_request', 'team_link']));

create type org.team_link_status as enum ('active', 'replaced', 'turned_off');

create table org.team_links (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique references refs.issued (code) on delete restrict
    check (reference like 'LNK-%'),
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  office_id uuid not null,
  created_by uuid not null references identity.accounts (user_id) on delete restrict,
  creator_membership_id uuid not null references org.memberships (id) on delete restrict,
  token_id uuid not null,
  token_digest bytea not null unique check (length(token_digest) = 32),
  expires_at timestamptz,
  max_uses int check (max_uses is null or max_uses in (10, 50)),
  uses int not null default 0 check (uses >= 0 and (max_uses is null or uses <= max_uses)),
  status org.team_link_status not null default 'active',
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  ended_by uuid references identity.accounts (user_id) on delete restrict,
  foreign key (tenant_id, office_id) references org.offices (tenant_id, id) on delete restrict,
  check ((status = 'active') = (ended_at is null)),
  check ((ended_at is null) = (ended_by is null))
);

create unique index team_links_one_active on org.team_links (office_id) where status = 'active';
create index team_links_tenant_idx on org.team_links (tenant_id);
create index team_links_created_by_idx on org.team_links (created_by);
create index team_links_creator_membership_idx on org.team_links (creator_membership_id);
create index team_links_ended_by_idx on org.team_links (ended_by);

-- Identity columns never change; an ended link never changes.
create function org.check_team_link()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.tenant_id <> old.tenant_id or new.office_id <> old.office_id or new.reference <> old.reference
    or new.created_by <> old.created_by or new.creator_membership_id <> old.creator_membership_id
    or new.token_id <> old.token_id or new.token_digest <> old.token_digest
    or new.expires_at is distinct from old.expires_at or new.max_uses is distinct from old.max_uses
    or new.created_at <> old.created_at or old.status <> 'active' then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'org.team_links'));
  end if;
  return new;
end;
$$;

create trigger team_links_check
before update on org.team_links
for each row execute function org.check_team_link();
create trigger team_links_no_delete
before delete on org.team_links
for each row execute function audit.reject_change();
create trigger team_links_no_truncate
before truncate on org.team_links
for each statement execute function audit.reject_change();

create table org.team_link_joins (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  team_link_id uuid not null references org.team_links (id) on delete restrict,
  user_id uuid not null references identity.accounts (user_id) on delete restrict,
  membership_id uuid not null references org.memberships (id) on delete restrict,
  at timestamptz not null default now()
);

create index team_link_joins_link_idx on org.team_link_joins (team_link_id, at);
create index team_link_joins_tenant_idx on org.team_link_joins (tenant_id);
create index team_link_joins_user_idx on org.team_link_joins (user_id);
create index team_link_joins_membership_idx on org.team_link_joins (membership_id);

create trigger team_link_joins_append_only
before update or delete on org.team_link_joins
for each row execute function audit.reject_change();
create trigger team_link_joins_no_truncate
before truncate on org.team_link_joins
for each statement execute function audit.reject_change();

alter table org.team_links enable row level security;
alter table org.team_link_joins enable row level security;

-- ── Helpers ───────────────────────────────────────────────────────────────

-- Why an active link does not work right now, or null when it does (B1).
-- Ended links (replaced, turned off) are never shown as live.
create function org.team_link_state(p_link org.team_links)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_link.status <> 'active' then p_link.status::text
    when o.status <> 'active' then 'office_closed'
    when t.status <> 'active' then 'network_inactive'
    when p_link.expires_at is not null and p_link.expires_at <= now() then 'expired'
    when p_link.max_uses is not null and p_link.uses >= p_link.max_uses then 'full'
    when m.status is distinct from 'active' then 'creator_left'
    when not coalesce((authz.decide(p_link.created_by, 'invite_members', p_link.tenant_id, p_link.office_id,
        null, p_link.creator_membership_id)->>'allowed')::boolean, false) then 'creator_left'
    else 'live'
  end
  from org.offices o, org.tenants t
  left join org.memberships m on m.id = p_link.creator_membership_id
  where o.id = p_link.office_id and t.id = p_link.tenant_id;
$$;

create function org.team_link_json(p_link org.team_links)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'teamLinkId', p_link.id,
    'reference', p_link.reference,
    -- Turned into the link by the Edge Function; never returned to clients.
    'tokenId', p_link.token_id,
    'officeId', p_link.office_id,
    'expiresAt', p_link.expires_at,
    'maxUses', p_link.max_uses,
    'uses', p_link.uses,
    'createdAt', p_link.created_at,
    'createdBy', org.person(p_link.created_by),
    'state', org.team_link_state(p_link)
  );
$$;

-- The workspace may manage team links for this office: the member-invitation
-- rule of Blueprint 03 (invite_members within scope).
create function org.require_team_link_authority(p_user_id uuid, p_workspace org.memberships, p_office org.offices)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_office.status <> 'active' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'office_closed'));
  end if;
  perform org.require_invite_authority(p_user_id, p_workspace, p_office, 'member');
end;
$$;

-- ── Leader reads and commands ─────────────────────────────────────────────

create function api.team_link(p_user_id uuid, p_session_id uuid, p_membership_id uuid, p_office_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  office org.offices;
  link org.team_links;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  office := org.office_in_tenant(workspace.tenant_id, p_office_id);
  perform authz.require(p_user_id, 'invite_members', workspace.tenant_id, office.id, null, workspace.id);
  select * into link from org.team_links where office_id = office.id and status = 'active';
  return jsonb_build_object('link', case when link.id is not null then org.team_link_json(link) end);
end;
$$;

create function api.create_team_link(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_office_id uuid,
  p_days int,
  p_max_uses int,
  p_token_id uuid,
  p_token_digest text,
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
  office org.offices;
  digest bytea;
  request jsonb;
  replayed jsonb;
  previous org.team_links;
  link org.team_links;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  office := org.office_in_tenant(workspace.tenant_id, p_office_id);
  perform org.require_team_link_authority(p_user_id, workspace, office);
  if p_days is not null and p_days not in (1, 7, 30) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'days'));
  end if;
  if p_max_uses is not null and p_max_uses not in (10, 50) then
    perform identity.fail('validation_error', jsonb_build_object('field', 'maxUses'));
  end if;
  digest := org.token_digest(p_token_digest);
  if p_token_id is null then
    perform identity.fail('validation_error', jsonb_build_object('field', 'token'));
  end if;

  -- The server-generated code is not part of the fingerprint, so a retried
  -- create keeps the first commit's link.
  request := jsonb_build_object('membershipId', workspace.id, 'officeId', office.id, 'days', p_days,
    'maxUses', p_max_uses);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'create_team_link', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into previous from org.team_links where office_id = office.id and status = 'active' for update;
  if previous.id is not null then
    update org.team_links set status = 'replaced', ended_at = now(), ended_by = p_user_id where id = previous.id;
    perform audit.record_tenant(workspace.tenant_id, p_user_id, 'team_link.replaced', 'team_link', previous.id::text,
      p_safe_before => jsonb_build_object('reference', previous.reference, 'status', 'active'),
      p_safe_after => jsonb_build_object('status', 'replaced'), p_request_id => p_request_id);
  end if;

  insert into org.team_links (
    reference, tenant_id, office_id, created_by, creator_membership_id, token_id, token_digest, expires_at, max_uses
  ) values (
    refs.issue('LNK'), workspace.tenant_id, office.id, p_user_id, workspace.id, p_token_id, digest,
    case when p_days is not null then now() + make_interval(days => p_days) end, p_max_uses
  )
  returning * into link;

  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'team_link.created', 'team_link', link.id::text,
    p_safe_after => jsonb_build_object('reference', link.reference, 'officeId', office.id, 'days', p_days,
      'maxUses', p_max_uses), p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'create_team_link', request,
    org.team_link_json(link) || jsonb_build_object('replaced', previous.id is not null));
end;
$$;

create function api.turn_off_team_link(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_team_link_id uuid,
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
  link org.team_links;
  office org.offices;
  request jsonb;
  replayed jsonb;
begin
  perform org.require_writer(p_user_id, p_session_id, true);
  workspace := org.change_workspace(p_user_id, p_membership_id);
  select * into link from org.team_links where id = p_team_link_id and tenant_id = workspace.tenant_id;
  if link.id is null then
    perform identity.fail('not_found');
  end if;
  office := org.office_in_tenant(workspace.tenant_id, link.office_id);
  perform org.require_invite_authority(p_user_id, workspace, office, 'member');

  request := jsonb_build_object('membershipId', workspace.id, 'teamLinkId', link.id);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'turn_off_team_link', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into link from org.team_links where id = link.id for update;
  if link.status <> 'active' then
    return identity.store_result(p_user_id, p_idempotency_key, 'turn_off_team_link', request,
      jsonb_build_object('teamLinkId', link.id, 'status', link.status, 'changed', false));
  end if;

  update org.team_links set status = 'turned_off', ended_at = now(), ended_by = p_user_id where id = link.id;
  perform audit.record_tenant(workspace.tenant_id, p_user_id, 'team_link.turned_off', 'team_link', link.id::text,
    p_safe_before => jsonb_build_object('reference', link.reference, 'status', 'active'),
    p_safe_after => jsonb_build_object('status', 'turned_off'), p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'turn_off_team_link', request,
    jsonb_build_object('teamLinkId', link.id, 'status', 'turned_off', 'changed', true));
end;
$$;

-- ── Joiner read and command ───────────────────────────────────────────────

-- Owner decision 8 (no session): who invites, to which network and office.
-- Every link that does not work right now gets the same answer.
create function api.team_link_preview(p_token_digest text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  link org.team_links;
begin
  select * into link from org.team_links where token_digest = org.token_digest(p_token_digest);
  if link.id is null or org.team_link_state(link) <> 'live' then
    perform identity.fail('invitation_unavailable');
  end if;
  return (
    select jsonb_build_object('networkName', t.name, 'officeName', o.name,
      'invitedBy', org.person(link.created_by)->>'name')
    from org.tenants t, org.offices o
    where t.id = link.tenant_id and o.id = link.office_id
  );
end;
$$;

-- Owner decisions 2 and 6: a signed-in person with a confirmed email joins the
-- link's office as a Member, at gate `ready` or `pin_setup_required` (Blueprint
-- 03 Q7). Refused when they already belong to the network.
create function api.join_team_link(
  p_user_id uuid,
  p_session_id uuid,
  p_token_digest text,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  link org.team_links;
  request jsonb;
  replayed jsonb;
  created org.memberships;
begin
  perform org.require_join_session(p_user_id, p_session_id);
  select * into link from org.team_links where token_digest = org.token_digest(p_token_digest);
  if link.id is null then
    perform identity.fail('invitation_unavailable');
  end if;

  request := jsonb_build_object('teamLinkId', link.id);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'join_team_link', request);
  if replayed is not null then
    return replayed;
  end if;

  perform org.lock_person(link.tenant_id, p_user_id);
  perform 1 from org.offices where id = link.office_id for no key update;
  select * into link from org.team_links where id = link.id for update;
  if org.team_link_state(link) <> 'live' then
    perform identity.fail('invitation_unavailable');
  end if;
  if exists (select 1 from org.memberships where tenant_id = link.tenant_id and user_id = p_user_id
             and status <> 'ended') then
    perform identity.fail('membership_exists');
  end if;

  created := org.create_membership(link.tenant_id, link.office_id, p_user_id, 'member', p_user_id);
  update org.team_links set uses = uses + 1 where id = link.id;
  insert into org.team_link_joins (tenant_id, team_link_id, user_id, membership_id)
  values (link.tenant_id, link.id, p_user_id, created.id);
  perform org.bump_authz_version(link.tenant_id);
  perform audit.record_tenant(link.tenant_id, p_user_id, 'team_link.joined', 'team_link', link.id::text,
    p_safe_after => jsonb_build_object('reference', link.reference, 'membershipId', created.id,
      'officeId', created.office_id), p_request_id => p_request_id);

  return identity.store_result(p_user_id, p_idempotency_key, 'join_team_link', request,
    jsonb_build_object('membershipId', created.id, 'tenantId', created.tenant_id, 'officeId', created.office_id,
      'role', created.role, 'isPrimary', created.is_primary));
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
