-- Blueprint 03 — B2/B3: invitations, their history, email-check requests, the
-- invite-role rule and expiry. Only a digest of each link secret is stored.

create type org.invitation_status as enum ('pending', 'accepted', 'expired', 'revoked');

-- Policy constants (owner decisions 2 and 3, 2026-10-08).
create function org.invitation_ttl() returns interval
language sql immutable set search_path = '' as $$ select interval '7 days' $$;
create function org.invitation_max_issues() returns int
language sql immutable set search_path = '' as $$ select 6 $$; -- first issue + 5 reissues
create function org.invitation_reissue_cooldown() returns interval
language sql immutable set search_path = '' as $$ select interval '60 seconds' $$;
create function org.invitation_hourly_cap() returns int
language sql immutable set search_path = '' as $$ select 50 $$;

create table org.invitations (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique references refs.issued (code) on delete restrict
    check (reference like 'INV-%'),
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  office_id uuid not null,
  role org.role not null check (role <> 'president_team_member'),
  email text not null check (email = lower(btrim(email)) and length(email) between 3 and 254),
  status org.invitation_status not null default 'pending',
  expires_at timestamptz not null,
  token_id uuid not null,
  token_digest bytea not null unique check (length(token_digest) = 32),
  token_key_version smallint not null default 1 check (token_key_version > 0),
  issue_count int not null default 1,
  last_issued_at timestamptz not null default now(),
  invited_by uuid not null references identity.accounts (user_id) on delete restrict,
  inviter_membership_id uuid not null references org.memberships (id) on delete restrict,
  reason text check (reason is null or length(btrim(reason)) between 3 and 500),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  accepted_user_id uuid references identity.accounts (user_id) on delete restrict,
  accepted_membership_id uuid references org.memberships (id) on delete restrict,
  revoked_at timestamptz,
  revoked_by uuid references identity.accounts (user_id) on delete restrict,
  revoke_reason text check (revoke_reason is null or length(btrim(revoke_reason)) between 3 and 500),
  foreign key (tenant_id, office_id) references org.offices (tenant_id, id) on delete restrict,
  check (issue_count between 1 and 6),
  check ((status = 'accepted') = (accepted_at is not null)),
  check ((accepted_at is null) = (accepted_user_id is null)
     and (accepted_at is null) = (accepted_membership_id is null)),
  check ((status = 'revoked') = (revoked_at is not null)),
  check ((revoked_at is null) = (revoked_by is null) and (revoked_at is null) = (revoke_reason is null))
);

-- One live invitation per email, office and role (a second office is fine).
create unique index invitations_one_pending
  on org.invitations (tenant_id, office_id, role, email) where status = 'pending';
create index invitations_tenant_idx on org.invitations (tenant_id, created_at desc, id desc);
create index invitations_office_idx on org.invitations (office_id);
create index invitations_email_idx on org.invitations (email) where status = 'pending';
create index invitations_expiry_idx on org.invitations (expires_at) where status = 'pending';
create index invitations_invited_by_idx on org.invitations (invited_by);
create index invitations_inviter_membership_idx on org.invitations (inviter_membership_id);
create index invitations_accepted_user_idx on org.invitations (accepted_user_id);
create index invitations_accepted_membership_idx on org.invitations (accepted_membership_id);
create index invitations_revoked_by_idx on org.invitations (revoked_by);

-- Identity columns never change; finished invitations never change; the role
-- must fit the office kind (same rule as memberships).
create function org.check_invitation()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  kind org.office_type;
begin
  if tg_op = 'UPDATE' and (
    new.tenant_id <> old.tenant_id or new.office_id <> old.office_id or new.role <> old.role
    or new.email <> old.email or new.reference <> old.reference or new.invited_by <> old.invited_by
    or new.inviter_membership_id <> old.inviter_membership_id or new.created_at <> old.created_at
    or old.status <> 'pending'
  ) then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'org.invitations'));
  end if;

  if new.role <> 'member' then
    select office_type into kind from org.offices where id = new.office_id;
    if org.leader_role(kind) <> new.role then
      perform identity.fail('role_office_mismatch');
    end if;
  end if;
  return new;
end;
$$;

create trigger invitations_check
before insert or update on org.invitations
for each row execute function org.check_invitation();

create trigger invitations_no_delete
before delete on org.invitations
for each row execute function audit.reject_change();
create trigger invitations_no_truncate
before truncate on org.invitations
for each statement execute function audit.reject_change();

create table org.invitation_events (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references org.tenants (id) on delete restrict,
  invitation_id uuid not null references org.invitations (id) on delete restrict,
  action text not null check (action in ('created', 'reissued', 'revoked', 'expired', 'accepted')),
  actor_user_id uuid references identity.accounts (user_id) on delete restrict,
  reason text,
  at timestamptz not null default now(),
  check ((action = 'expired') = (actor_user_id is null))
);

create index invitation_events_invitation_idx on org.invitation_events (invitation_id, at);
create index invitation_events_actor_idx on org.invitation_events (actor_user_id, action, at);
create index invitation_events_tenant_idx on org.invitation_events (tenant_id);

create trigger invitation_events_append_only
before update or delete on org.invitation_events
for each row execute function audit.reject_change();
create trigger invitation_events_no_truncate
before truncate on org.invitation_events
for each statement execute function audit.reject_change();

-- "Email me the sign-in link" requests; rate limits only. No email, no token.
create table org.invitation_verifications (
  id bigint generated always as identity primary key,
  invitation_id uuid not null references org.invitations (id) on delete restrict,
  requested_at timestamptz not null default now()
);

create index invitation_verifications_idx on org.invitation_verifications (invitation_id, requested_at desc);

alter table org.invitations enable row level security;
alter table org.invitation_events enable row level security;
alter table org.invitation_verifications enable row level security;

-- ── Helpers ───────────────────────────────────────────────────────────────

create function org.record_invitation_event(
  p_invitation org.invitations,
  p_action text,
  p_actor_user_id uuid,
  p_reason text default null
)
returns void
language sql
set search_path = ''
as $$
  insert into org.invitation_events (tenant_id, invitation_id, action, actor_user_id, reason)
  values (p_invitation.tenant_id, p_invitation.id, p_action, p_actor_user_id, p_reason);
$$;

-- Status as people see it: an overdue pending invitation is already expired.
create function org.invitation_effective_status(p_invitation org.invitations)
returns org.invitation_status
language sql
stable
set search_path = ''
as $$
  select case
    when p_invitation.status = 'pending' and p_invitation.expires_at <= now() then 'expired'::org.invitation_status
    else p_invitation.status
  end;
$$;

-- Records the expiry of overdue pending invitations (history stays explicit).
-- Locks each row with SKIP LOCKED so it never waits on a live command.
create function org.expire_overdue_invitations(p_limit int default 500)
returns int
language plpgsql
set search_path = ''
as $$
declare
  overdue org.invitations;
  expired_count int := 0;
begin
  for overdue in
    select * from org.invitations
    where status = 'pending' and expires_at <= now()
    order by expires_at
    limit p_limit
    for update skip locked
  loop
    update org.invitations set status = 'expired' where id = overdue.id;
    perform org.record_invitation_event(overdue, 'expired', null);
    expired_count := expired_count + 1;
  end loop;
  return expired_count;
end;
$$;

-- Owner decision 1 (2026-10-08), invite-role matrix B. Members: any
-- `invite_members` holder within scope. Leader roles: additionally only from a
-- leadership workspace (not a plain member seat) and only into offices
-- strictly below its office (org.require_below_own_office, shared with the
-- leader commands; President Team: any office). President Team Member is
-- never invitable.
create function org.require_invite_authority(
  p_actor_user_id uuid,
  p_workspace org.memberships,
  p_office org.offices,
  p_role org.role
)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_role = 'president_team_member' then
    perform identity.fail('role_not_invitable');
  end if;
  if p_role <> 'member' and org.leader_role(p_office.office_type) <> p_role then
    perform identity.fail('role_office_mismatch');
  end if;
  perform authz.require(p_actor_user_id, 'invite_members', p_workspace.tenant_id, p_office.id, null, p_workspace.id);
  if p_role <> 'member' then
    if p_workspace.role = 'member' then
      perform identity.fail('role_not_invitable');
    end if;
    begin
      perform org.require_below_own_office(p_workspace, p_office.id);
    exception when sqlstate 'P0001' then
      perform identity.fail('role_not_invitable');
    end;
  end if;
end;
$$;

-- Session for joining (owner decision 7): a live session of an active account
-- whose gate is `ready` or `pin_setup_required`, with a confirmed email.
-- Returns the account's email (lower-cased).
create function org.require_join_session(p_user_id uuid, p_session_id uuid)
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
    perform identity.require_session(p_user_id, p_session_id);
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

-- Validates a client-derived digest (hex of SHA-256 of the link token).
create function org.token_digest(p_hex text)
returns bytea
language plpgsql
set search_path = ''
as $$
begin
  if p_hex is null or p_hex !~ '^[0-9a-f]{64}$' then
    perform identity.fail('validation_error', jsonb_build_object('field', 'token'));
  end if;
  return decode(p_hex, 'hex');
end;
$$;

-- A pending, unexpired invitation in an active network and office, by digest.
create function org.live_invitation_by_digest(p_digest bytea)
returns org.invitations
language sql
stable
set search_path = ''
as $$
  select i.* from org.invitations i
  join org.tenants t on t.id = i.tenant_id
  join org.offices o on o.id = i.office_id
  where i.token_digest = p_digest and i.status = 'pending' and i.expires_at > now()
    and t.status = 'active' and o.status = 'active';
$$;
