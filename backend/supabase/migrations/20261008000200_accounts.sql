-- Blueprint 01 — accounts, permanent UID and profile, created on Auth signup.

create type identity.account_status as enum ('active', 'restricted', 'suspended', 'deactivated');

create table identity.accounts (
  user_id uuid primary key references auth.users (id) on delete restrict,
  uid text not null unique check (uid ~ '^EW-[1-9][0-9]{4,}$'),
  status identity.account_status not null default 'active',
  created_at timestamptz not null default now()
);

alter table identity.accounts enable row level security;

create function identity.keep_account_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.user_id <> old.user_id or new.uid <> old.uid or new.created_at <> old.created_at then
    perform identity.fail('invariant_violation', jsonb_build_object('field', 'uid'));
  end if;
  return new;
end;
$$;

create trigger accounts_identity_immutable
before update on identity.accounts
for each row execute function identity.keep_account_identity();

-- Self-declared rank (W-02); presentation only, grants nothing.
create table identity.profiles (
  user_id uuid primary key references identity.accounts (user_id) on delete restrict,
  display_name text check (display_name is null or length(btrim(display_name)) between 1 and 80),
  first_name text check (first_name is null or length(btrim(first_name)) between 1 and 80),
  last_name text check (last_name is null or length(btrim(last_name)) between 1 and 80),
  phone text check (phone is null or phone ~ '^\+?[0-9]{7,15}$'),
  timezone text check (timezone is null or length(timezone) <= 64),
  rank text check (rank is null or rank in (
    'Member', 'Distributor', 'Manager', 'Senior Manager', 'Executive Manager', 'Director',
    'Emerald Director', 'Sapphire Director', 'Ruby Director 1', 'Ruby Director 2',
    'Ruby Director 3', 'Ruby Director 4', 'Ruby Director 5', 'Diamond Director'
  )),
  updated_at timestamptz not null default now()
);

alter table identity.profiles enable row level security;

-- UID (D-01): EW- + random digits. Five digits until 70% of that space is issued,
-- then one more digit. Existing UIDs never change.
create function identity.new_uid()
returns text
language plpgsql
set search_path = ''
as $$
declare
  digits int := 5;
  lowest bigint;
  issued bigint;
  draw bigint;
begin
  loop
    lowest := power(10, digits - 1)::bigint;
    select count(*) into issued from identity.accounts where length(uid) = digits + 3;
    exit when issued < (9 * lowest) * 0.7;
    digits := digits + 1;
  end loop;

  draw := ('x' || encode(extensions.gen_random_bytes(8), 'hex'))::bit(64)::bigint
    & 9223372036854775807;
  return 'EW-' || (lowest + draw % (9 * lowest))::text;
end;
$$;

create function identity.on_auth_user_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  attempts int := 0;
begin
  loop
    begin
      insert into identity.accounts (user_id, uid) values (new.id, identity.new_uid());
      exit;
    exception when unique_violation then
      attempts := attempts + 1;
      if attempts >= 5 then
        raise;
      end if;
    end;
  end loop;

  insert into identity.profiles (user_id) values (new.id);
  return null;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function identity.on_auth_user_created();
