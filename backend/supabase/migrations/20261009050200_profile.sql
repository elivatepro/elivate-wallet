-- Blueprint 06 — B2: the signed-in person's own profile (W-22) and photo key.

create function identity.rank_values() returns text[]
language sql immutable set search_path = '' as $$
  select array['Member', 'Distributor', 'Manager', 'Senior Manager', 'Executive Manager', 'Director',
    'Emerald Director', 'Sapphire Director', 'Ruby Director 1', 'Ruby Director 2', 'Ruby Director 3',
    'Ruby Director 4', 'Ruby Director 5', 'Diamond Director']
$$;

create function identity.profile_view(p_user_id uuid)
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
    'identity', identity.identity_state(a.user_id)
  )
  from identity.accounts a
  join identity.profiles p on p.user_id = a.user_id
  where a.user_id = p_user_id;
$$;

create function api.my_profile(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform identity.require_session(p_user_id, p_session_id);
  return identity.profile_view(p_user_id);
end;
$$;

-- p_changes may hold displayName (string or null), phone (string) and rank
-- (string). Absent keys stay as they are.
create function api.update_profile(
  p_user_id uuid,
  p_session_id uuid,
  p_changes jsonb,
  p_idempotency_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  profile identity.profiles;
  request jsonb;
  replayed jsonb;
  key text;
  new_display text;
  new_phone text;
  new_rank text;
begin
  perform identity.require_session(p_user_id, p_session_id);
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then
    perform identity.fail('validation_error', jsonb_build_object('field', 'changes'));
  end if;
  for key in select jsonb_object_keys(p_changes) loop
    if key not in ('displayName', 'phone', 'rank') then
      perform identity.fail('validation_error', jsonb_build_object('field', key, 'reason', 'unknown_field'));
    end if;
  end loop;

  if p_changes ? 'displayName' then
    if jsonb_typeof(p_changes->'displayName') = 'null' then
      new_display := null;
    elsif jsonb_typeof(p_changes->'displayName') <> 'string'
      or length(btrim(p_changes->>'displayName')) not between 1 and 80 then
      perform identity.fail('validation_error', jsonb_build_object('field', 'displayName'));
    else
      new_display := regexp_replace(btrim(p_changes->>'displayName'), '\s+', ' ', 'g');
    end if;
  end if;
  if p_changes ? 'phone' then
    new_phone := regexp_replace(coalesce(p_changes->>'phone', ''), '[\s-]', '', 'g');
    if jsonb_typeof(p_changes->'phone') <> 'string' or new_phone !~ '^\+?[0-9]{7,15}$' then
      perform identity.fail('validation_error', jsonb_build_object('field', 'phone'));
    end if;
  end if;
  if p_changes ? 'rank' then
    new_rank := p_changes->>'rank';
    if jsonb_typeof(p_changes->'rank') <> 'string' or not (new_rank = any (identity.rank_values())) then
      perform identity.fail('validation_error', jsonb_build_object('field', 'rank'));
    end if;
  end if;

  request := jsonb_build_object('changes', p_changes);
  replayed := identity.replay(p_user_id, p_idempotency_key, 'update_profile', request);
  if replayed is not null then
    return replayed;
  end if;

  select * into profile from identity.profiles where user_id = p_user_id for update;
  if p_changes ? 'phone' and profile.phone_source = 'nin' and new_phone is distinct from profile.phone then
    perform identity.fail('conflict', jsonb_build_object('reason', 'phone_from_nin'));
  end if;

  update identity.profiles
  set display_name = case when p_changes ? 'displayName' then new_display else display_name end,
      phone = case when p_changes ? 'phone' then new_phone else identity.profiles.phone end,
      phone_source = case when p_changes ? 'phone' and profile.phone_source is distinct from 'nin' then 'self'
                          else phone_source end,
      rank = case when p_changes ? 'rank' then new_rank else identity.profiles.rank end,
      updated_at = now()
  where user_id = p_user_id;

  perform audit.record('profile.updated', p_user_id, p_session_id, p_user_id,
    p_safe_after => jsonb_build_object('fields', (select jsonb_agg(k order by k) from jsonb_object_keys(p_changes) k)),
    p_request_id => p_request_id);
  return identity.store_result(p_user_id, p_idempotency_key, 'update_profile', request,
    identity.profile_view(p_user_id));
end;
$$;

-- The object is already stored by the app server; this records its key and
-- returns the previous one so the server can delete it. The key must sit
-- under the caller's own folder (check constraint profiles_photo_key_owner).
create function api.set_profile_photo(
  p_user_id uuid,
  p_session_id uuid,
  p_photo_key text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  previous text;
begin
  perform identity.require_session(p_user_id, p_session_id);
  if p_photo_key is null or p_photo_key !~ ('^photos/' || p_user_id::text
      || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$') then
    perform identity.fail('validation_error', jsonb_build_object('field', 'photoKey'));
  end if;
  select photo_key into previous from identity.profiles where user_id = p_user_id for update;
  update identity.profiles
  set photo_key = p_photo_key, photo_updated_at = now(), updated_at = now()
  where user_id = p_user_id;
  perform audit.record('profile.photo_changed', p_user_id, p_session_id, p_user_id, p_request_id => p_request_id);
  return jsonb_build_object('photoKey', p_photo_key, 'previousPhotoKey', previous);
end;
$$;

revoke all on function
  api.my_profile(uuid, uuid),
  api.update_profile(uuid, uuid, jsonb, text, text),
  api.set_profile_photo(uuid, uuid, text, text)
from public, anon, authenticated;
grant execute on function
  api.my_profile(uuid, uuid),
  api.update_profile(uuid, uuid, jsonb, text, text),
  api.set_profile_photo(uuid, uuid, text, text)
to service_role;
