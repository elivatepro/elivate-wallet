create type ledger.post_transaction_result as (
  transaction_id uuid,
  transaction_reference text,
  reused boolean
);

create or replace function ledger.prevent_immutable_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    errcode = '55000',
    message = format('%I.%I is immutable', tg_table_schema, tg_table_name);
end;
$$;

create or replace function ledger.validate_ledger_account_context()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  wallet_owner_user_id uuid;
  membership_user_id uuid;
  membership_office_id uuid;
  membership_role public.role_key;
  membership_state public.membership_status;
  account_state public.account_status;
  tenant_state public.tenant_status;
  office_state public.office_status;
begin
  if new.account_class = 'system_counter' then
    return new;
  end if;

  select w.owner_user_id
    into wallet_owner_user_id
    from public.wallets w
   where w.id = new.wallet_id;

  select m.user_id, m.office_id, m.role_key, m.status
    into membership_user_id, membership_office_id, membership_role, membership_state
    from public.memberships m
   where m.tenant_id = new.tenant_id
     and m.id = new.membership_id;

  select ua.status
    into account_state
    from public.user_accounts ua
   where ua.user_id = new.owner_user_id;

  select t.status
    into tenant_state
    from public.tenants t
   where t.id = new.tenant_id;

  select o.status
    into office_state
    from public.offices o
   where o.tenant_id = new.tenant_id
     and o.id = new.office_id;

  if wallet_owner_user_id is null
     or wallet_owner_user_id <> new.owner_user_id
     or membership_user_id is null
     or membership_user_id <> new.owner_user_id
     or membership_office_id is distinct from new.office_id then
    raise exception using
      errcode = '23514',
      message = 'member-value ledger account context must match wallet ownership and membership provenance';
  end if;

  if membership_role = 'president_team_member' then
    raise exception using
      errcode = '23514',
      message = 'president team memberships cannot own member-value ledger accounts';
  end if;

  if account_state <> 'active'
     or tenant_state <> 'active'
     or office_state <> 'active'
     or membership_state <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'member-value ledger account creation requires active account and organizational context';
  end if;

  return new;
end;
$$;

create trigger ledger_accounts_validate_context
  before insert on ledger.ledger_accounts
  for each row execute function ledger.validate_ledger_account_context();

create trigger currency_definitions_prevent_mutation
  before update or delete on ledger.currency_definitions
  for each row execute function ledger.prevent_immutable_mutation();

create trigger ledger_accounts_prevent_mutation
  before update or delete on ledger.ledger_accounts
  for each row execute function ledger.prevent_immutable_mutation();

create or replace function ledger.validate_financial_transaction_context()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  wallet_owner_user_id uuid;
  membership_user_id uuid;
  membership_office_id uuid;
  membership_state public.membership_status;
  membership_role public.role_key;
  actor_state public.account_status;
  owner_state public.account_status;
  tenant_state public.tenant_status;
  office_state public.office_status;
begin
  select w.owner_user_id
    into wallet_owner_user_id
    from public.wallets w
   where w.id = new.wallet_id;

  select m.user_id, m.office_id, m.status, m.role_key
    into membership_user_id, membership_office_id, membership_state, membership_role
    from public.memberships m
   where m.tenant_id = new.tenant_id
     and m.id = new.membership_id;

  select ua.status into actor_state
    from public.user_accounts ua
   where ua.user_id = new.actor_user_id;

  select ua.status into owner_state
    from public.user_accounts ua
   where ua.user_id = new.owner_user_id;

  select t.status into tenant_state
    from public.tenants t
   where t.id = new.tenant_id;

  select o.status into office_state
    from public.offices o
   where o.tenant_id = new.tenant_id
     and o.id = new.office_id;

  if wallet_owner_user_id is null
     or wallet_owner_user_id <> new.owner_user_id
     or membership_user_id is null
     or membership_user_id <> new.owner_user_id
     or membership_office_id is distinct from new.office_id then
    raise exception using
      errcode = '23514',
      message = 'financial transaction context must match wallet ownership and membership provenance';
  end if;

  if membership_role = 'president_team_member' then
    raise exception using
      errcode = '23514',
      message = 'president team memberships cannot own financial transactions';
  end if;

  if actor_state <> 'active'
     or owner_state <> 'active'
     or tenant_state <> 'active'
     or office_state <> 'active'
     or membership_state <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'financial transaction posting requires active actor and organizational context';
  end if;

  return new;
end;
$$;

create trigger financial_transactions_validate_context
  before insert on ledger.financial_transactions
  for each row execute function ledger.validate_financial_transaction_context();

create or replace function ledger.protect_financial_transaction()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception using
      errcode = '55000',
      message = 'posted financial transactions are immutable';
  end if;

  if old.posted_at is not null
     or new.posted_at is null
     or current_setting('ledger.current_transaction_id', true) is distinct from old.id::text
     or new.id is distinct from old.id
     or new.transaction_reference is distinct from old.transaction_reference
     or new.idempotency_key is distinct from old.idempotency_key
     or new.request_fingerprint is distinct from old.request_fingerprint
     or new.transaction_type is distinct from old.transaction_type
     or new.tenant_id is distinct from old.tenant_id
     or new.office_id is distinct from old.office_id
     or new.membership_id is distinct from old.membership_id
     or new.wallet_id is distinct from old.wallet_id
     or new.owner_user_id is distinct from old.owner_user_id
     or new.actor_user_id is distinct from old.actor_user_id
     or new.metadata is distinct from old.metadata
     or new.created_at is distinct from old.created_at then
    raise exception using
      errcode = '55000',
      message = 'posted financial transactions are immutable';
  end if;

  return new;
end;
$$;

create trigger financial_transactions_protect_mutation
  before update or delete on ledger.financial_transactions
  for each row execute function ledger.protect_financial_transaction();

create or replace function ledger.validate_journal_entry_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  transaction_posted_at timestamptz;
begin
  select ft.posted_at
    into transaction_posted_at
    from ledger.financial_transactions ft
   where ft.id = new.financial_transaction_id;

  if not found
     or transaction_posted_at is not null
     or current_setting('ledger.current_transaction_id', true)
       is distinct from new.financial_transaction_id::text then
    raise exception using
      errcode = '55000',
      message = 'journal entries may only be added by the active trusted posting transaction';
  end if;

  return new;
end;
$$;

create trigger journal_entries_validate_insert
  before insert on ledger.journal_entries
  for each row execute function ledger.validate_journal_entry_insert();

create trigger journal_entries_prevent_mutation
  before update or delete on ledger.journal_entries
  for each row execute function ledger.prevent_immutable_mutation();

create or replace function ledger.validate_journal_posting_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  transaction_id uuid;
  transaction_tenant_id uuid;
  transaction_office_id uuid;
  transaction_membership_id uuid;
  transaction_wallet_id uuid;
  transaction_owner_user_id uuid;
  transaction_posted_at timestamptz;
  journal_currency_code text;
  account_record ledger.ledger_accounts%rowtype;
  currency_scale smallint;
begin
  select je.financial_transaction_id, ft.tenant_id, ft.office_id,
         ft.membership_id, ft.wallet_id, ft.owner_user_id, ft.posted_at,
         je.currency_code
    into transaction_id, transaction_tenant_id, transaction_office_id,
         transaction_membership_id, transaction_wallet_id,
         transaction_owner_user_id, transaction_posted_at,
         journal_currency_code
    from ledger.journal_entries je
    join ledger.financial_transactions ft on ft.id = je.financial_transaction_id
   where je.id = new.journal_entry_id;

  if transaction_id is null
     or transaction_posted_at is not null
     or current_setting('ledger.current_transaction_id', true)
       is distinct from transaction_id::text then
    raise exception using
      errcode = '55000',
      message = 'journal postings may only be added by the active trusted posting transaction';
  end if;

  select * into account_record
    from ledger.ledger_accounts la
   where la.id = new.ledger_account_id;

  if account_record.id is null
     or account_record.currency_code <> journal_currency_code then
    raise exception using
      errcode = '23514',
      message = 'journal posting account currency must match journal currency';
  end if;

  if account_record.account_class = 'member_value'
     and (
       account_record.tenant_id <> transaction_tenant_id
       or account_record.office_id <> transaction_office_id
       or account_record.membership_id <> transaction_membership_id
       or account_record.wallet_id <> transaction_wallet_id
       or account_record.owner_user_id <> transaction_owner_user_id
     ) then
    raise exception using
      errcode = '23514',
      message = 'member-value posting account must match financial transaction provenance';
  end if;

  select cd.minor_unit_scale
    into currency_scale
    from ledger.currency_definitions cd
   where cd.currency_code = journal_currency_code;

  if new.amount <> round(new.amount, currency_scale) then
    raise exception using
      errcode = '22003',
      message = 'posting amount exceeds the currency minor-unit scale';
  end if;

  return new;
end;
$$;

create trigger journal_postings_validate_insert
  before insert on ledger.journal_postings
  for each row execute function ledger.validate_journal_posting_insert();

create trigger journal_postings_prevent_mutation
  before update or delete on ledger.journal_postings
  for each row execute function ledger.prevent_immutable_mutation();

create or replace function ledger.protect_balance_projection()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_setting('ledger.projection_write', true) is distinct from 'on' then
    raise exception using
      errcode = '55000',
      message = 'balance projections may only be changed by trusted ledger posting';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger wallet_balance_projections_protect_write
  before insert or update or delete on ledger.wallet_balance_projections
  for each row execute function ledger.protect_balance_projection();

create or replace function ledger.apply_posting_to_projection()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  target_account ledger.ledger_accounts%rowtype;
  allows_negative boolean;
  resulting_balance numeric(38, 18);
  previous_projection_write text;
begin
  select * into target_account
    from ledger.ledger_accounts la
   where la.id = new.ledger_account_id;

  if target_account.account_class = 'system_counter' then
    return new;
  end if;

  select pd.allows_negative
    into allows_negative
    from public.pocket_definitions pd
   where pd.pocket_key = target_account.pocket_key;

  previous_projection_write := current_setting('ledger.projection_write', true);
  perform set_config('ledger.projection_write', 'on', true);

  insert into ledger.wallet_balance_projections (
    ledger_account_id,
    balance,
    version,
    last_posting_id,
    updated_at
  )
  values (
    new.ledger_account_id,
    new.amount,
    1,
    new.id,
    clock_timestamp()
  )
  on conflict (ledger_account_id) do update
    set balance = ledger.wallet_balance_projections.balance + excluded.balance,
        version = ledger.wallet_balance_projections.version + 1,
        last_posting_id = excluded.last_posting_id,
        updated_at = excluded.updated_at
  returning balance into resulting_balance;

  perform set_config(
    'ledger.projection_write',
    coalesce(previous_projection_write, ''),
    true
  );

  if not allows_negative and resulting_balance < 0 then
    raise exception using
      errcode = '23514',
      message = 'ordinary pocket balance cannot become negative';
  end if;

  return new;
end;
$$;

create trigger journal_postings_apply_projection
  after insert on ledger.journal_postings
  for each row execute function ledger.apply_posting_to_projection();

create or replace function ledger.assert_journal_balanced()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  target_journal_entry_id uuid;
  posting_count bigint;
  posting_total numeric;
begin
  target_journal_entry_id := case
    when tg_table_name = 'journal_entries' then
      case when tg_op = 'DELETE' then old.id else new.id end
    else
      case when tg_op = 'DELETE' then old.journal_entry_id else new.journal_entry_id end
  end;

  select count(*), coalesce(sum(jp.amount), 0)
    into posting_count, posting_total
    from ledger.journal_postings jp
   where jp.journal_entry_id = target_journal_entry_id;

  if posting_count < 2 or posting_total <> 0 then
    raise exception using
      errcode = '23514',
      message = 'journal entry must contain at least two postings that balance to zero';
  end if;

  return null;
end;
$$;

create constraint trigger journal_entries_assert_balanced
  after insert or update on ledger.journal_entries
  deferrable initially deferred
  for each row execute function ledger.assert_journal_balanced();

create constraint trigger journal_postings_assert_balanced
  after insert or update or delete on ledger.journal_postings
  deferrable initially deferred
  for each row execute function ledger.assert_journal_balanced();

create or replace function ledger.assert_transaction_complete()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  journal_count bigint;
  member_posting_count bigint;
begin
  select count(*)
    into journal_count
    from ledger.journal_entries je
   where je.financial_transaction_id = new.id;

  select count(*)
    into member_posting_count
    from ledger.journal_entries je
    join ledger.journal_postings jp on jp.journal_entry_id = je.id
    join ledger.ledger_accounts la on la.id = jp.ledger_account_id
   where je.financial_transaction_id = new.id
     and la.account_class = 'member_value';

  if new.posted_at is null or journal_count = 0 or member_posting_count = 0 then
    raise exception using
      errcode = '23514',
      message = 'financial transaction must be posted with journal and member-value effects';
  end if;

  return null;
end;
$$;

create constraint trigger financial_transactions_assert_complete
  after insert or update on ledger.financial_transactions
  deferrable initially deferred
  for each row execute function ledger.assert_transaction_complete();

create or replace function ledger.post_transaction(
  p_idempotency_key uuid,
  p_request_fingerprint bytea,
  p_transaction_type text,
  p_membership_id uuid,
  p_wallet_id uuid,
  p_actor_user_id uuid,
  p_journals jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns ledger.post_transaction_result
language plpgsql
security invoker
set search_path = ''
as $$
declare
  existing_transaction ledger.financial_transactions%rowtype;
  target_transaction ledger.financial_transactions%rowtype;
  membership_record public.memberships%rowtype;
  wallet_owner_user_id uuid;
  journal_value jsonb;
  posting_value jsonb;
  created_journal_entry_id uuid;
  journal_currency_code text;
  journal_number smallint := 0;
  posting_number smallint;
  posting_count bigint;
  posting_total numeric;
begin
  if p_idempotency_key is null
     or p_request_fingerprint is null
     or octet_length(p_request_fingerprint) <> 32
     or p_transaction_type is null
     or p_transaction_type !~ '^[a-z][a-z0-9_]*$'
     or p_membership_id is null
     or p_wallet_id is null
     or p_actor_user_id is null
     or jsonb_typeof(p_journals) <> 'array'
     or jsonb_array_length(p_journals) = 0
     or jsonb_typeof(p_metadata) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'trusted ledger posting input is invalid';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );

  select * into existing_transaction
    from ledger.financial_transactions ft
   where ft.idempotency_key = p_idempotency_key;

  if found then
    if existing_transaction.request_fingerprint <> p_request_fingerprint then
      raise exception using
        errcode = '23505',
        message = 'idempotency key already used with different command data';
    end if;

    return (
      existing_transaction.id,
      existing_transaction.transaction_reference,
      true
    )::ledger.post_transaction_result;
  end if;

  select * into membership_record
    from public.memberships m
   where m.id = p_membership_id;

  select w.owner_user_id into wallet_owner_user_id
    from public.wallets w
   where w.id = p_wallet_id;

  if membership_record.id is null
     or membership_record.office_id is null
     or membership_record.role_key = 'president_team_member'
     or wallet_owner_user_id is null
     or membership_record.user_id <> wallet_owner_user_id then
    raise exception using
      errcode = '23514',
      message = 'trusted ledger posting context is invalid';
  end if;

  for journal_value in
    select value from jsonb_array_elements(p_journals)
  loop
    if jsonb_typeof(journal_value) <> 'object'
       or jsonb_typeof(journal_value -> 'postings') <> 'array'
       or jsonb_array_length(journal_value -> 'postings') < 2
       or coalesce(journal_value ->> 'currency_code', '') !~ '^[A-Z]{3}$' then
      raise exception using
        errcode = '22023',
        message = 'journal input must contain a currency and at least two postings';
    end if;

    for posting_value in
      select value from jsonb_array_elements(journal_value -> 'postings')
    loop
      if jsonb_typeof(posting_value) <> 'object'
         or not (posting_value ? 'ledger_account_id')
         or not (posting_value ? 'amount') then
        raise exception using
          errcode = '22023',
          message = 'journal posting input is invalid';
      end if;
    end loop;
  end loop;

  perform la.id
    from ledger.ledger_accounts la
    join (
      select distinct (posting.value ->> 'ledger_account_id')::uuid as ledger_account_id
        from jsonb_array_elements(p_journals) journal(value)
        cross join lateral jsonb_array_elements(journal.value -> 'postings') posting(value)
    ) requested_accounts on requested_accounts.ledger_account_id = la.id
   order by la.id
   for update of la;

  insert into ledger.financial_transactions (
    idempotency_key,
    request_fingerprint,
    transaction_type,
    tenant_id,
    office_id,
    membership_id,
    wallet_id,
    owner_user_id,
    actor_user_id,
    metadata
  )
  values (
    p_idempotency_key,
    p_request_fingerprint,
    p_transaction_type,
    membership_record.tenant_id,
    membership_record.office_id,
    membership_record.id,
    p_wallet_id,
    wallet_owner_user_id,
    p_actor_user_id,
    p_metadata
  )
  returning * into target_transaction;

  perform set_config('ledger.current_transaction_id', target_transaction.id::text, true);

  for journal_value in
    select value from jsonb_array_elements(p_journals)
  loop
    journal_number := journal_number + 1;
    journal_currency_code := journal_value ->> 'currency_code';

    insert into ledger.journal_entries (
      financial_transaction_id,
      entry_number,
      currency_code
    )
    values (
      target_transaction.id,
      journal_number,
      journal_currency_code
    )
    returning id into created_journal_entry_id;

    posting_number := 0;

    for posting_value in
      select value from jsonb_array_elements(journal_value -> 'postings')
    loop
      posting_number := posting_number + 1;

      insert into ledger.journal_postings (
        journal_entry_id,
        ledger_account_id,
        line_number,
        amount
      )
      values (
        created_journal_entry_id,
        (posting_value ->> 'ledger_account_id')::uuid,
        posting_number,
        (posting_value ->> 'amount')::numeric
      );
    end loop;

    select count(*), coalesce(sum(jp.amount), 0)
      into posting_count, posting_total
      from ledger.journal_postings jp
     where jp.journal_entry_id = created_journal_entry_id;

    if posting_count < 2 or posting_total <> 0 then
      raise exception using
        errcode = '23514',
        message = 'journal entry must contain at least two postings that balance to zero';
    end if;
  end loop;

  if not exists (
    select 1
      from ledger.journal_entries je
      join ledger.journal_postings jp on jp.journal_entry_id = je.id
      join ledger.ledger_accounts la on la.id = jp.ledger_account_id
     where je.financial_transaction_id = target_transaction.id
       and la.account_class = 'member_value'
  ) then
    raise exception using
      errcode = '23514',
      message = 'financial transaction must affect at least one member-value account';
  end if;

  update ledger.financial_transactions
     set posted_at = clock_timestamp()
   where id = target_transaction.id
  returning * into target_transaction;

  perform set_config('ledger.current_transaction_id', '', true);

  return (
    target_transaction.id,
    target_transaction.transaction_reference,
    false
  )::ledger.post_transaction_result;
end;
$$;

revoke all on function ledger.prevent_immutable_mutation()
  from public, anon, authenticated, service_role;
revoke all on function ledger.validate_ledger_account_context()
  from public, anon, authenticated, service_role;
revoke all on function ledger.validate_financial_transaction_context()
  from public, anon, authenticated, service_role;
revoke all on function ledger.protect_financial_transaction()
  from public, anon, authenticated, service_role;
revoke all on function ledger.validate_journal_entry_insert()
  from public, anon, authenticated, service_role;
revoke all on function ledger.validate_journal_posting_insert()
  from public, anon, authenticated, service_role;
revoke all on function ledger.protect_balance_projection()
  from public, anon, authenticated, service_role;
revoke all on function ledger.apply_posting_to_projection()
  from public, anon, authenticated, service_role;
revoke all on function ledger.assert_journal_balanced()
  from public, anon, authenticated, service_role;
revoke all on function ledger.assert_transaction_complete()
  from public, anon, authenticated, service_role;
revoke all on function ledger.post_transaction(
  uuid, bytea, text, uuid, uuid, uuid, jsonb, jsonb
) from public, anon, authenticated, service_role;
