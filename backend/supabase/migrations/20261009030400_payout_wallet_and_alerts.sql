-- Blueprint 05 — wallet link (slice 04) and owner alerts (slice 03 outbox).
-- Ownership is the stable account/wallet (W-17): every proof and payout
-- account carries the owner's wallet, and every command needs one (no_wallet).

-- ── Wallet link ───────────────────────────────────────────────────────────

alter table payout.account_lookups
  add column wallet_id uuid not null references ledger.wallets (id) on delete restrict;
alter table payout.accounts
  add column wallet_id uuid not null references ledger.wallets (id) on delete restrict;

create index account_lookups_wallet_idx on payout.account_lookups (wallet_id);
create index accounts_wallet_idx on payout.accounts (wallet_id);

-- The wallet is always the owner's own, set on insert and never changed.
create function payout.bind_wallet()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if new.wallet_id <> old.wallet_id then
      perform identity.fail('invariant_violation', jsonb_build_object('table', tg_table_schema || '.' || tg_table_name));
    end if;
    return new;
  end if;
  if new.wallet_id is null then
    new.wallet_id := ledger.require_wallet(new.owner_user_id);
  elsif new.wallet_id is distinct from ledger.wallet_for(new.owner_user_id) then
    perform identity.fail('invariant_violation', jsonb_build_object('field', 'wallet_id'));
  end if;
  return new;
end;
$$;

create trigger account_lookups_wallet
before insert or update of wallet_id on payout.account_lookups
for each row execute function payout.bind_wallet();
create trigger accounts_wallet
before insert or update of wallet_id on payout.accounts
for each row execute function payout.bind_wallet();

-- Session gate, workspace, the self-service permission and the wallet.
create or replace function payout.workspace(
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
  perform ledger.require_wallet(p_user_id);
  return workspace;
end;
$$;

-- ── Owner alerts (W-17, T-03) ─────────────────────────────────────────────

-- Bank name, what changed and when. Never digits, not even the last 4 (P-06).
insert into outbox.templates (key, version, duplicate_safe, params) values
  ('payout_account.alert', 1, true, array['action', 'bankName', 'at']);

create or replace function payout.alert_owner(p_account payout.accounts, p_action text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_action not in ('added', 'replaced', 'deactivated', 'primary_changed', 'name_mismatch') then
    perform identity.fail('invariant_violation', jsonb_build_object('field', 'action'));
  end if;
  if p_account.id is null then
    perform identity.fail('invariant_violation', jsonb_build_object('field', 'account'));
  end if;
  -- Enqueued in the same transaction; delivery failure never undoes the change.
  perform outbox.enqueue_email(
    'payout_account.alert',
    'payout_account:' || p_account.id::text || ':' || p_action || ':' || pg_current_xact_id()::text,
    'payout_account',
    p_account.id,
    null,
    p_account.owner_user_id,
    null,
    jsonb_build_object(
      'action', p_action,
      'bankName', p_account.bank_name,
      'at', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    )
  );
end;
$$;
