-- Supabase Auth is the identity source; the application account is provisioned
-- from that identity without copying mutable Auth metadata into authoritative
-- profile fields.
create or replace function public.provision_user_account()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  insert into public.user_accounts (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  insert into public.user_profiles (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

revoke all on function public.provision_user_account() from public, anon, authenticated;

create constraint trigger auth_users_provision_user_account
after insert on auth.users
deferrable initially deferred
for each row execute function public.provision_user_account();
