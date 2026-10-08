-- Blueprint 03 — cross-track hooks on membership creation and the
-- `invitation` audit target.

-- Wallet hook (Track B, Blueprint 04 fills it). Created only if absent, never
-- with `create or replace`, so a later slice's body is never overwritten.
-- Runs last in the lock order, inside the caller's transaction.
do $$
begin
  if to_regprocedure('org.on_membership_created(org.memberships)') is null then
    execute $fn$
      create function org.on_membership_created(p_membership org.memberships)
      returns void
      language plpgsql
      set search_path = ''
      as $body$
      begin
        -- No-op until the wallet slice replaces it.
        return;
      end;
      $body$
    $fn$;
  end if;
end;
$$;

-- Seat hook (subscription slice fills it; D-10). Same stub rules. When filled
-- it must use a per-tenant advisory lock, never a tenant row lock.
do $$
begin
  if to_regprocedure('org.check_seat_capacity(uuid, uuid)') is null then
    execute $fn$
      create function org.check_seat_capacity(p_tenant_id uuid, p_user_id uuid)
      returns void
      language plpgsql
      set search_path = ''
      as $body$
      begin
        -- No-op until the subscription slice replaces it.
        return;
      end;
      $body$
    $fn$;
  end if;
end;
$$;

-- Every membership is created here (accept, add, move, leader add/replace,
-- create office, add president, start network). Order: person lock → seat
-- hook → insert → created event → wallet hook (last).
create or replace function org.create_membership(
  p_tenant_id uuid,
  p_office_id uuid,
  p_user_id uuid,
  p_role org.role,
  p_actor_user_id uuid,
  p_primary boolean default null
)
returns org.memberships
language plpgsql
set search_path = ''
as $$
declare
  created org.memberships;
begin
  perform org.lock_person(p_tenant_id, p_user_id);
  if (select status from identity.accounts where user_id = p_user_id) <> 'active' then
    perform identity.fail('conflict', jsonb_build_object('reason', 'account_not_active'));
  end if;

  perform org.check_seat_capacity(p_tenant_id, p_user_id);

  begin
    insert into org.memberships (tenant_id, office_id, user_id, role, is_primary, created_by)
    values (
      p_tenant_id, p_office_id, p_user_id, p_role,
      coalesce(p_primary, not exists (
        select 1 from org.memberships
        where tenant_id = p_tenant_id and user_id = p_user_id and is_primary
      )),
      p_actor_user_id
    )
    returning * into created;
  exception when unique_violation then
    perform identity.fail('membership_exists');
  end;

  perform org.record_membership_event(created, 'created', null, null, p_actor_user_id);
  perform org.on_membership_created(created);
  return created;
end;
$$;

-- Tenant audit targets: the union of every slice's values so far.
alter table audit.tenant_events drop constraint tenant_events_target_type_check;
alter table audit.tenant_events add constraint tenant_events_target_type_check
  check (target_type in ('tenant', 'office', 'membership', 'role_permission', 'access_assignment',
                         'reviewer_assignment', 'invitation'));
