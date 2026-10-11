-- Owner feedback (2026-10-11): the setup profile step starts from what the
-- person already told us. A founder gave their full name and rank on the
-- application (/apply); until the profile has its own, the profile read
-- carries them as `suggested` (first word = first name, the rest = last name).
-- Nothing is written: the person still confirms them with Continue.

create function identity.profile_suggestion(p_user_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select nullif(jsonb_strip_nulls(jsonb_build_object(
    'firstName', case when p.first_name is null then split_part(a.full_name, ' ', 1) end,
    'lastName', case when p.last_name is null
      then nullif(btrim(substr(a.full_name, length(split_part(a.full_name, ' ', 1)) + 1)), '') end,
    'rank', case when p.rank is null then case a.rank
      when 'ruby_director_4' then 'Ruby Director 4'
      when 'ruby_director_5' then 'Ruby Director 5'
      when 'diamond_director' then 'Diamond Director'
    end end
  )), '{}'::jsonb)
  from founders.approved f
  join founders.applications a on a.id = f.application_id
  join identity.profiles p on p.user_id = f.user_id
  where f.user_id = p_user_id;
$$;

create or replace function identity.profile_view(p_user_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'uid', a.uid,
    'displayName', p.display_name,
    'firstName', p.first_name,
    'lastName', p.last_name,
    'phone', p.phone,
    'phoneSource', p.phone_source,
    'rank', p.rank,
    'photoKey', p.photo_key,
    'photoUpdatedAt', p.photo_updated_at,
    'identity', identity.identity_state(a.user_id),
    'suggested', identity.profile_suggestion(a.user_id)
  )
  from identity.accounts a
  join identity.profiles p on p.user_id = a.user_id
  where a.user_id = p_user_id;
$$;

revoke all on function identity.profile_suggestion(uuid) from public, anon, authenticated;
