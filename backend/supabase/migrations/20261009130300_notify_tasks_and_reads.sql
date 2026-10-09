-- Blueprint 13 — B2/B3: live tasks, the bell reads and 90-day retention.
-- A "needs your action" item stays open while its work is pending; status
-- triggers on the work itself resolve it in the same transaction, and every
-- read re-checks both the condition and the selected workspace's authority.

-- ── Open conditions ────────────────────────────────────────────────────────

create function notify.task_open(p_kind text, p_subject_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(case p_kind
    when 'task.withdrawal_approve' then exists (
      select 1 from finance.withdrawals where id = p_subject_id and status = 'requested')
    when 'task.payout_record' then exists (
      select 1 from finance.withdrawals w
      where w.id = p_subject_id and w.status = 'approved' and (finance.open_payout(w.id)).id is null)
    when 'task.payout_fix' then exists (
      select 1 from finance.payouts p join finance.withdrawals w on w.id = p.withdrawal_id
      where p.id = p_subject_id and p.status = 'correction_required' and w.status = 'approved')
    when 'task.payout_review' then exists (
      select 1 from finance.payouts p join finance.withdrawals w on w.id = p.withdrawal_id
      where p.id = p_subject_id and p.status = 'needs_review' and w.status = 'approved')
    when 'task.entry_review' then exists (
      select 1 from finance.entries where id = p_subject_id and status = 'needs_review')
    when 'task.transfer_approve' then exists (
      select 1 from finance.pocket_transfers where id = p_subject_id and status = 'requested')
    when 'task.nin_review' then exists (
      select 1 from identity.nin_reviews where id = p_subject_id and status = 'pending')
  end, false);
$$;

-- May this workspace still do the task? Same rules as the commands.
create function notify.can_act(p_item notify.items, p_workspace org.memberships)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_item.tenant_id = p_workspace.tenant_id and coalesce(case p_item.kind
    when 'task.withdrawal_approve' then (
      select finance.can(p_item.user_id, 'approve_withdrawal', w.tenant_id, w.office_id, w.owner_user_id,
        p_workspace.id)
      from finance.withdrawals w where w.id = p_item.subject_id)
    when 'task.payout_record' then (
      select w.approved_by = p_item.user_id
        and finance.can(p_item.user_id, 'approve_withdrawal', w.tenant_id, w.office_id, w.owner_user_id,
          p_workspace.id)
      from finance.withdrawals w where w.id = p_item.subject_id)
    when 'task.payout_fix' then (
      select w.approved_by = p_item.user_id
        and finance.can(p_item.user_id, 'approve_withdrawal', w.tenant_id, w.office_id, w.owner_user_id,
          p_workspace.id)
      from finance.payouts p join finance.withdrawals w on w.id = p.withdrawal_id where p.id = p_item.subject_id)
    when 'task.payout_review' then (
      select finance.can(p_item.user_id, 'review_financial_evidence', w.tenant_id, w.office_id, w.owner_user_id,
          p_workspace.id)
        and p.submitted_by <> p_item.user_id
        and not exists (select 1 from finance.payout_revisions r
                        where r.payout_id = p.id and r.submitted_by = p_item.user_id)
      from finance.payouts p join finance.withdrawals w on w.id = p.withdrawal_id where p.id = p_item.subject_id)
    when 'task.entry_review' then (
      select finance.can(p_item.user_id, 'review_financial_evidence', e.tenant_id, e.office_id, e.owner_user_id,
          p_workspace.id)
        and e.submitted_by <> p_item.user_id
      from finance.entries e where e.id = p_item.subject_id)
    when 'task.transfer_approve' then (
      select finance.can(p_item.user_id, 'approve_pocket_transfer', t.tenant_id, t.office_id, t.owner_user_id,
        p_workspace.id)
      from finance.pocket_transfers t where t.id = p_item.subject_id)
    when 'task.nin_review' then (
      select identity.can_review(p_workspace, r) from identity.nin_reviews r where r.id = p_item.subject_id)
  end, false);
$$;

-- ── Resolution ─────────────────────────────────────────────────────────────

create function notify.refresh_tasks(p_subject_type text, p_subject_id uuid)
returns void
language sql
set search_path = ''
as $$
  update notify.items set resolved_at = now()
  where subject_type = p_subject_type and subject_id = p_subject_id and task and resolved_at is null
    and not notify.task_open(kind, subject_id);
$$;

create function notify.on_withdrawal_status()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  payout_id uuid;
begin
  perform notify.refresh_tasks('withdrawal', new.id);
  for payout_id in select id from finance.payouts where withdrawal_id = new.id loop
    perform notify.refresh_tasks('payout', payout_id);
  end loop;
  return null;
end;
$$;

create trigger withdrawals_notify_tasks
after update of status on finance.withdrawals
for each row when (old.status is distinct from new.status)
execute function notify.on_withdrawal_status();

-- A new or settled payout closes "Payout to record" and the payout's own tasks.
create function notify.on_payout_status()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform notify.refresh_tasks('payout', new.id);
  perform notify.refresh_tasks('withdrawal', new.withdrawal_id);
  return null;
end;
$$;

create trigger payouts_notify_tasks_insert
after insert on finance.payouts
for each row execute function notify.on_payout_status();

create trigger payouts_notify_tasks
after update of status on finance.payouts
for each row when (old.status is distinct from new.status)
execute function notify.on_payout_status();

create function notify.on_subject_status()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform notify.refresh_tasks(tg_argv[0], new.id);
  return null;
end;
$$;

create trigger pocket_transfers_notify_tasks
after update of status on finance.pocket_transfers
for each row when (old.status is distinct from new.status)
execute function notify.on_subject_status('pocket_transfer');

create trigger entries_notify_tasks
after update of status on finance.entries
for each row when (old.status is distinct from new.status)
execute function notify.on_subject_status('entry');

create trigger nin_reviews_notify_tasks
after update of status on identity.nin_reviews
for each row when (old.status is distinct from new.status)
execute function notify.on_subject_status('nin_review');

-- ── What the bell shows ────────────────────────────────────────────────────

-- The selected network's items plus personal ones (owner answer Q5). Open
-- tasks show only when this workspace can act on them; a done task is an
-- ordinary item.
create function notify.visible(p_user_id uuid, p_workspace org.memberships)
returns table (item notify.items, open boolean)
language sql
stable
set search_path = ''
as $$
  select v.item, v.open
  from (
    select i as item, i.task and i.resolved_at is null and notify.task_open(i.kind, i.subject_id) as open
    from notify.items i
    where i.user_id = p_user_id and (i.tenant_id = p_workspace.tenant_id or i.tenant_id is null)
  ) v
  where not v.open or notify.can_act(v.item, p_workspace);
$$;

create function notify.item_json(p_item notify.items, p_open boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_item.id,
    'kind', p_item.kind,
    'open', p_open,
    'subject', jsonb_build_object('type', p_item.subject_type, 'id', p_item.subject_id),
    'params', p_item.params,
    'read', p_item.read_at is not null,
    'createdAt', to_char(p_item.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
  );
$$;

create function notify.unread(p_user_id uuid, p_workspace org.memberships)
returns int
language sql
stable
set search_path = ''
as $$
  select count(*)::int from notify.visible(p_user_id, p_workspace) v where (v.item).read_at is null;
$$;

-- Session check for the badge poll: same gate as identity.require_session,
-- but a background poll never counts as activity (A-05 idle lock).
create function notify.require_quiet_session(p_user_id uuid, p_session_id uuid)
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
end;
$$;

create function api.my_notifications(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_view text,
  p_cursor text,
  p_limit int
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  after_at timestamptz;
  after_id uuid;
  after jsonb;
  page_limit int;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  if p_view is null or p_view not in ('unread', 'all') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'view'));
  end if;
  page_limit := org.page_limit(p_limit);
  after := org.decode_cursor(p_cursor);
  if after is not null then
    begin
      after_at := (after->>'s')::timestamptz;
      after_id := (after->>'id')::uuid;
    exception when others then
      perform identity.fail('validation_error', jsonb_build_object('field', 'cursor'));
    end;
    if after_at is null or after_id is null then
      perform identity.fail('validation_error', jsonb_build_object('field', 'cursor'));
    end if;
  end if;

  return (
    with v as (select * from notify.visible(p_user_id, workspace)),
    page as (
      select v.item, row_number() over (order by (v.item).created_at desc, (v.item).id desc) as n
      from v
      where not v.open
        and (p_view = 'all' or (v.item).read_at is null)
        and (after is null or ((v.item).created_at, (v.item).id) < (after_at, after_id))
      order by (v.item).created_at desc, (v.item).id desc
      limit page_limit + 1
    )
    select jsonb_build_object(
      'actions', case when after is null then coalesce((
        select jsonb_agg(notify.item_json(v.item, true) order by (v.item).created_at desc, (v.item).id desc)
        from v where v.open), '[]'::jsonb) else '[]'::jsonb end,
      'items', coalesce((
        select jsonb_agg(notify.item_json(p.item, false) order by p.n) from page p where p.n <= page_limit),
        '[]'::jsonb),
      'nextCursor', (
        select org.encode_cursor(jsonb_build_object(
          's', to_char((p.item).created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
          'id', (p.item).id))
        from page p where p.n = page_limit and exists (select 1 from page q where q.n > page_limit)),
      'unread', (select count(*)::int from v where (v.item).read_at is null)
    )
  );
end;
$$;

create function api.my_notification_count(p_user_id uuid, p_session_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
begin
  perform notify.require_quiet_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  return jsonb_build_object('unread', notify.unread(p_user_id, workspace));
end;
$$;

-- Marks the caller's own items read: the given ids (1–100), or everything the
-- bell shows in this workspace. Idempotent; never touches another person's.
create function api.mark_notifications_read(
  p_user_id uuid,
  p_session_id uuid,
  p_membership_id uuid,
  p_ids uuid[],
  p_all boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace org.memberships;
  marked int;
begin
  perform identity.require_session(p_user_id, p_session_id);
  workspace := authz.require_workspace(p_user_id, p_membership_id);
  if coalesce(p_all, false) then
    if p_ids is not null then
      perform identity.fail('validation_error', jsonb_build_object('field', 'ids'));
    end if;
    update notify.items i set read_at = now()
    where i.user_id = p_user_id and i.read_at is null
      and i.id in (select (v.item).id from notify.visible(p_user_id, workspace) v);
  else
    if p_ids is null or cardinality(p_ids) not between 1 and 100 or array_position(p_ids, null) is not null then
      perform identity.fail('validation_error', jsonb_build_object('field', 'ids'));
    end if;
    update notify.items i set read_at = now()
    where i.user_id = p_user_id and i.read_at is null and i.id = any (p_ids);
  end if;
  get diagnostics marked = row_count;
  return jsonb_build_object('marked', marked, 'unread', notify.unread(p_user_id, workspace));
end;
$$;

-- ── Retention (owner decision: 90 days) ───────────────────────────────────
-- Run by the outbox worker's housekeeping; an open task is kept until done.

create function notify.prune(p_batch int)
returns int
language sql
set search_path = ''
as $$
  with gone as (
    delete from notify.items
    where id in (
      select id from notify.items
      where created_at < now() - interval '90 days'
        and not (task and resolved_at is null and notify.task_open(kind, subject_id))
      order by created_at
      limit p_batch
    )
    returning 1
  )
  select count(*)::int from gone;
$$;

create or replace function api.outbox_run_maintenance()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  return jsonb_build_object(
    'expiredInvitations', org.expire_overdue_invitations(500),
    'prunedNotifications', notify.prune(1000)
  );
end;
$$;

revoke all on all functions in schema notify from public, anon, authenticated;

do $$
declare
  fn regprocedure;
begin
  for fn in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and p.proname in ('my_notifications', 'my_notification_count',
      'mark_notifications_read', 'outbox_run_maintenance')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end;
$$;
