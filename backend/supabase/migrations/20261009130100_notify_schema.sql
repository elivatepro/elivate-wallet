-- Blueprint 13 — B1/B2: the in-app bell and the notification catalogue.
-- A bell item is written in the same transaction as the change it reports
-- (F-02, T-03), together with its email when the kind has one. Items are
-- private: people read them only through api.my_notifications.

create schema notify;
revoke all on schema notify from public, anon, authenticated;

-- ── Catalogue ──────────────────────────────────────────────────────────────

-- One row per bell kind. `task` kinds are "needs your action" items: live
-- until notify.task_open says the work is done. `email_template` names the
-- outbox template sent with the item, if any. Rows never change; later slices
-- add rows (B-series billing, statement ready, PIN changed, T02–T05).
create table notify.kinds (
  key text primary key check (key ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
  task boolean not null,
  email_template text references outbox.templates (key) on delete restrict
);

create function notify.reject_kind_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform identity.fail('invariant_violation', jsonb_build_object('table', 'notify.kinds'));
  return null;
end;
$$;

create trigger kinds_immutable
before update or delete or truncate on notify.kinds
for each statement execute function notify.reject_kind_change();

-- Email templates (Paper "Emails — Transactional v2"). Every param is a safe
-- display value; `path` is the in-app link for the button.
insert into outbox.templates (key, version, duplicate_safe, params) values
  ('money.income_posted', 1, true, array['network', 'amount', 'currency', 'reference', 'path']),
  ('money.withdrawal_submitted', 1, true, array['network', 'amount', 'currency', 'reference', 'path']),
  ('money.withdrawal_awaiting_approval', 1, true,
    array['network', 'amount', 'currency', 'reference', 'member', 'office', 'path']),
  ('money.withdrawal_approved', 1, true, array['network', 'amount', 'currency', 'reference', 'path']),
  ('money.withdrawal_not_approved', 1, true, array['network', 'amount', 'currency', 'reference', 'path']),
  ('money.withdrawal_cancelled', 1, true, array['network', 'amount', 'currency', 'reference', 'path']),
  ('money.withdrawal_completed', 1, true,
    array['network', 'amount', 'currency', 'reference', 'firstName', 'path']),
  ('money.payout_correction_required', 1, true, array['network', 'amount', 'currency', 'reference', 'path']),
  ('money.evidence_review_assigned', 1, true,
    array['network', 'amount', 'currency', 'reference', 'subject', 'path']),
  ('money.payout_receipt_rejected', 1, true, array['network', 'amount', 'currency', 'reference', 'path']),
  ('money.pocket_move_done', 1, true,
    array['network', 'amount', 'currency', 'reference', 'from', 'to', 'path']),
  ('money.pocket_move_declined', 1, true, array['network', 'amount', 'currency', 'reference', 'path']),
  ('money.adjustment_posted', 1, true,
    array['network', 'amount', 'currency', 'reference', 'direction', 'actor', 'path']),
  ('money.conversion_posted', 1, true,
    array['network', 'amount', 'currency', 'reference', 'destinationAmount', 'destinationCurrency', 'actor',
      'path']),
  ('money.entry_not_posted', 1, true,
    array['network', 'amount', 'currency', 'reference', 'subject', 'path']),
  ('money.transaction_reversed', 1, true,
    array['network', 'amount', 'currency', 'reference', 'reverses', 'path']),
  ('money.returned_funds', 1, true,
    array['network', 'amount', 'currency', 'reference', 'withdrawal', 'path']),
  ('team.invitation_accepted', 1, true, array['network', 'member', 'firstName', 'office', 'role', 'path']),
  ('account.status_changed', 1, true, array['status', 'path']),
  ('account.role_changed', 1, true, array['network', 'role', 'office', 'actor', 'path']),
  ('account.membership_ended', 1, true, array['network', 'office', 'path']);

insert into notify.kinds (key, task, email_template) values
  -- Money events (M-series).
  ('money.income_posted', false, 'money.income_posted'),
  ('money.withdrawal_submitted', false, 'money.withdrawal_submitted'),
  ('money.withdrawal_approved', false, 'money.withdrawal_approved'),
  ('money.withdrawal_not_approved', false, 'money.withdrawal_not_approved'),
  ('money.withdrawal_cancelled', false, 'money.withdrawal_cancelled'),
  ('money.withdrawal_completed', false, 'money.withdrawal_completed'),
  ('money.payout_receipt_rejected', false, 'money.payout_receipt_rejected'),
  ('money.pocket_move_done', false, 'money.pocket_move_done'),
  ('money.pocket_move_declined', false, 'money.pocket_move_declined'),
  ('money.adjustment_posted', false, 'money.adjustment_posted'),
  ('money.conversion_posted', false, 'money.conversion_posted'),
  ('money.entry_not_posted', false, 'money.entry_not_posted'),
  ('money.transaction_reversed', false, 'money.transaction_reversed'),
  ('money.returned_funds', false, 'money.returned_funds'),
  -- Needs your action.
  ('task.withdrawal_approve', true, 'money.withdrawal_awaiting_approval'),
  ('task.payout_record', true, null),
  ('task.payout_fix', true, 'money.payout_correction_required'),
  ('task.payout_review', true, 'money.evidence_review_assigned'),
  ('task.entry_review', true, 'money.evidence_review_assigned'),
  ('task.transfer_approve', true, null),
  ('task.nin_review', true, null),
  -- Team and account (T01, A10–A12) and the older person emails.
  ('team.invitation_accepted', false, 'team.invitation_accepted'),
  ('account.status_changed', false, 'account.status_changed'),
  ('account.role_changed', false, 'account.role_changed'),
  ('account.membership_ended', false, 'account.membership_ended'),
  ('identity.nin_review_decided', false, null),
  ('payout_account.alert', false, null);

-- ── Items ──────────────────────────────────────────────────────────────────

create table notify.items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references identity.accounts (user_id) on delete restrict,
  -- Null for personal items (payout accounts, account status), shown in every workspace.
  tenant_id uuid references org.tenants (id) on delete restrict,
  kind text not null references notify.kinds (key) on delete restrict,
  task boolean not null,
  subject_type text not null check (subject_type ~ '^[a-z_]{1,40}$'),
  subject_id uuid not null,
  params jsonb not null check (jsonb_typeof(params) = 'object'),
  email_event_id uuid references outbox.events (id) on delete restrict,
  dedupe_key text not null check (length(dedupe_key) between 1 and 200),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  resolved_at timestamptz,
  check (task or resolved_at is null),
  unique (user_id, dedupe_key)
);

create index items_user_idx on notify.items (user_id, created_at desc, id desc);
create index items_open_tasks_idx on notify.items (subject_type, subject_id) where task and resolved_at is null;
create index items_email_idx on notify.items (email_event_id);
create index items_tenant_idx on notify.items (tenant_id);
create index items_created_idx on notify.items (created_at);

-- Only the read and resolved marks ever change.
create function notify.guard_item()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id <> old.id or new.user_id <> old.user_id or new.tenant_id is distinct from old.tenant_id
    or new.kind <> old.kind or new.task <> old.task or new.subject_type <> old.subject_type
    or new.subject_id <> old.subject_id or new.params <> old.params
    or new.email_event_id is distinct from old.email_event_id or new.dedupe_key <> old.dedupe_key
    or new.created_at <> old.created_at
    or (old.read_at is not null and new.read_at is distinct from old.read_at)
    or (old.resolved_at is not null and new.resolved_at is distinct from old.resolved_at) then
    perform identity.fail('invariant_violation', jsonb_build_object('table', 'notify.items'));
  end if;
  return new;
end;
$$;

create trigger items_guard
before update on notify.items
for each row execute function notify.guard_item();

alter table notify.kinds enable row level security;
alter table notify.items enable row level security;

-- ── Helpers ────────────────────────────────────────────────────────────────

-- "Ada N.": first name and last initial, else the display name, else the UID.
create function notify.short_name(p_user_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(
    case when nullif(btrim(p.first_name), '') is not null and nullif(btrim(p.last_name), '') is not null
      then btrim(p.first_name) || ' ' || upper(left(btrim(p.last_name), 1)) || '.' end,
    nullif(btrim(p.display_name), ''),
    nullif(btrim(p.first_name), ''),
    a.uid)
  from identity.accounts a
  left join identity.profiles p on p.user_id = a.user_id
  where a.user_id = p_user_id;
$$;

create function notify.full_name(p_user_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(org.person(p_user_id)->>'name', (select uid from identity.accounts where user_id = p_user_id));
$$;

create function notify.first_name(p_user_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select nullif(btrim(first_name), '') from identity.profiles where user_id = p_user_id;
$$;

-- Active people in a network who may use a permission on a target (A-04:
-- current role policy, explicit grants and reviewer assignments, through the
-- one resolver). The target person is never included.
create function notify.holders(p_tenant_id uuid, p_permission text, p_office_id uuid, p_target_user_id uuid)
returns setof uuid
language sql
stable
set search_path = ''
as $$
  select distinct m.user_id
  from org.memberships m
  where m.tenant_id = p_tenant_id and m.status = 'active'
    and m.user_id is distinct from p_target_user_id
    and (
      exists (select 1 from authz.role_permissions rp
              where rp.tenant_id = m.tenant_id and rp.role = m.role and rp.permission_key = p_permission
                and rp.allowed)
      or exists (select 1 from authz.access_rules r
                 where r.tenant_id = m.tenant_id and r.subject_user_id = m.user_id
                   and r.permission_key = p_permission and r.effect = 'allow' and r.revoked_at is null)
      or exists (select 1 from authz.reviewer_assignments ra where ra.membership_id = m.id and ra.ended_at is null)
    )
    and coalesce((authz.decide(m.user_id, p_permission, p_tenant_id, p_office_id, p_target_user_id, m.id)
      ->>'allowed')::boolean, false);
$$;

-- Writes one bell item and, when the kind has one, its email (one outbox
-- event per recipient). Idempotent per (recipient, dedupe key): a replay
-- returns the existing item. Params must be safe display values: never
-- secrets, tokens, PINs, full account numbers, balances, reasons or evidence.
create function notify.emit(
  p_user_id uuid,
  p_tenant_id uuid,
  p_kind text,
  p_subject_type text,
  p_subject_id uuid,
  p_params jsonb,
  p_dedupe_key text,
  p_email_params jsonb default null
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  kind notify.kinds;
  -- One event may give the same person several kinds (M17 and a new task).
  dedupe text := p_kind || '|' || p_dedupe_key;
  item_id uuid;
  email_id uuid;
begin
  if p_user_id is null then
    return null;
  end if;
  select * into kind from notify.kinds where key = p_kind;
  if kind.key is null then
    perform identity.fail('invariant_violation', jsonb_build_object('reason', 'unknown_notification_kind'));
  end if;

  select id into item_id from notify.items where user_id = p_user_id and dedupe_key = dedupe;
  if item_id is not null then
    return item_id;
  end if;

  if kind.email_template is not null and p_email_params is not null then
    email_id := outbox.enqueue_email(
      kind.email_template,
      'notify:' || dedupe || ':' || p_user_id::text,
      p_subject_type,
      p_subject_id,
      p_tenant_id,
      p_user_id,
      null,
      jsonb_strip_nulls(p_email_params)
    );
  end if;

  insert into notify.items (user_id, tenant_id, kind, task, subject_type, subject_id, params, email_event_id,
    dedupe_key)
  values (p_user_id, p_tenant_id, kind.key, kind.task, p_subject_type, p_subject_id,
    jsonb_strip_nulls(p_params), email_id, dedupe)
  on conflict (user_id, dedupe_key) do nothing
  returning id into item_id;
  return item_id;
end;
$$;

revoke all on all functions in schema notify from public, anon, authenticated;
