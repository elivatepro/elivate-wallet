-- Route only this trusted command; internal stays outside the Data API.
create schema command_api;
revoke all on schema command_api from public, anon, authenticated;
grant usage on schema command_api to service_role;
alter default privileges in schema command_api revoke execute on functions from public;

create function command_api.bootstrap_development_network(
  p_actor_user_id uuid,
  p_setup_token_digest bytea,
  p_network_name text
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select internal.bootstrap_development_network(
    p_actor_user_id, p_setup_token_digest, p_network_name
  );
$$;

revoke all on function command_api.bootstrap_development_network(uuid, bytea, text)
  from public, anon, authenticated;
grant execute on function command_api.bootstrap_development_network(uuid, bytea, text)
  to service_role;

-- Only the narrow transport is callable by the trusted runtime.
revoke execute on function internal.bootstrap_development_network(uuid, bytea, text)
  from service_role;
