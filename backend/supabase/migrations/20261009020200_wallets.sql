-- Blueprint 04 — wallet creation (D-01): one wallet per account, created at
-- the first non-President membership, kept afterwards. Wired through Track A's
-- membership hook (`org.on_membership_created`); no trigger on org.memberships.

create function ledger.wallet_eligible(p_user_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from org.memberships
    where user_id = p_user_id and status <> 'ended' and role <> 'president_team_member'
  );
$$;

-- Idempotent. Returns the wallet id, or null (creating nothing) when the
-- person holds no non-ended non-President membership. Only a unique insert:
-- safe as the last step while person/office/membership locks are held.
create function ledger.ensure_wallet(p_user_id uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_wallet_id uuid;
begin
  select id into v_wallet_id from ledger.wallets where owner_user_id = p_user_id;
  if v_wallet_id is not null then
    return v_wallet_id;
  end if;
  if not ledger.wallet_eligible(p_user_id) then
    return null;
  end if;
  insert into ledger.wallets (owner_user_id) values (p_user_id)
  on conflict (owner_user_id) do nothing
  returning id into v_wallet_id;
  if v_wallet_id is null then
    select id into v_wallet_id from ledger.wallets where owner_user_id = p_user_id;
  end if;
  return v_wallet_id;
end;
$$;

create function ledger.wallet_for(p_user_id uuid)
returns uuid
language sql
stable
set search_path = ''
as $$
  select id from ledger.wallets where owner_user_id = p_user_id;
$$;

create function ledger.require_wallet(p_user_id uuid)
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_wallet_id uuid;
begin
  v_wallet_id := ledger.wallet_for(p_user_id);
  if v_wallet_id is null then
    perform identity.fail('no_wallet');
  end if;
  return v_wallet_id;
end;
$$;

-- Track A (Blueprint 03) calls this from org.create_membership after the
-- insert, last in lock order. Track A creates a no-op stub only if absent;
-- this body replaces it.
create or replace function org.on_membership_created(p_membership org.memberships)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_membership.role <> 'president_team_member' then
    perform ledger.ensure_wallet(p_membership.user_id);
  end if;
end;
$$;

create function ledger.backfill_wallets()
returns int
language plpgsql
set search_path = ''
as $$
declare
  created int;
begin
  insert into ledger.wallets (owner_user_id)
  select distinct m.user_id from org.memberships m
  where m.status <> 'ended' and m.role <> 'president_team_member'
  on conflict (owner_user_id) do nothing;
  get diagnostics created = row_count;
  return created;
end;
$$;

select ledger.backfill_wallets();
