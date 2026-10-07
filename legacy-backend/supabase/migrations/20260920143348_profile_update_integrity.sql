create or replace function public.validate_user_profile_update()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if new.user_id <> old.user_id then
    raise exception using
      errcode = '23514',
      message = 'profile identity cannot change';
  end if;

  if new.created_at <> old.created_at then
    raise exception using
      errcode = '23514',
      message = 'profile creation timestamp cannot change';
  end if;

  return new;
end;
$$;

revoke all on function public.validate_user_profile_update() from public, anon, authenticated;

create trigger user_profiles_validate_update
before update on public.user_profiles
for each row execute function public.validate_user_profile_update();
