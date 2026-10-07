-- Session elevation proves authentication freshness only; domain commands still authorize.
create or replace function authz.is_elevated_session_valid(p_session_id uuid, p_user_id uuid)
returns boolean language sql volatile security definer set search_path = ''
as $$
  select exists (
    select 1 from authz.elevated_sessions elevation
    join auth.sessions session on session.id = elevation.session_id and session.user_id = elevation.user_id
    join public.user_accounts account on account.user_id = elevation.user_id and account.status = 'active'
    where elevation.session_id = p_session_id and elevation.user_id = p_user_id
      and elevation.revoked_at is null and elevation.valid_until > clock_timestamp()
      and elevation.verified_at <= clock_timestamp()
      and session.aal = 'aal2'
      and (session.not_after is null or session.not_after > clock_timestamp())
      and (auth.uid() is null or (
        auth.uid() = p_user_id and auth.jwt()->>'session_id' = p_session_id::text
        and auth.jwt()->>'aal' = 'aal2'
      ))
  );
$$;

create or replace function authz.establish_step_up()
returns jsonb language plpgsql security invoker set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  claims jsonb := auth.jwt();
  current_session uuid;
  verified_epoch numeric;
  verified_time timestamptz;
  expiry timestamptz;
  session_expiry timestamptz;
  saved authz.elevated_sessions%rowtype;
  changed boolean := false;
begin
  if actor is null or auth.role() is distinct from 'authenticated' or claims->>'aal' is distinct from 'aal2'
    or coalesce(claims->>'session_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or jsonb_typeof(claims->'amr') is distinct from 'array' then
    raise exception using errcode = '42501', message = 'Recent authenticator verification is required';
  end if;
  current_session := (claims->>'session_id')::uuid;
  if not exists (select 1 from public.user_accounts where user_id = actor and status = 'active') then
    raise exception using errcode = '42501', message = 'Account is not eligible for verification';
  end if;
  select session.not_after into session_expiry from auth.sessions session
    where session.id = current_session and session.user_id = actor and session.aal = 'aal2'
      and (session.not_after is null or session.not_after > clock_timestamp())
    for key share;
  if not found then
    raise exception using errcode = '42501', message = 'A current authenticated session is required';
  end if;
  select max((method->>'timestamp')::numeric) into verified_epoch
    from jsonb_array_elements(claims->'amr') method
    where method->>'method' = 'totp' and jsonb_typeof(method->'timestamp') = 'number';
  if verified_epoch is null or verified_epoch > extract(epoch from clock_timestamp())
    or verified_epoch <= extract(epoch from clock_timestamp() - interval '5 minutes') then
    raise exception using errcode = '42501', message = 'Recent authenticator verification is required';
  end if;
  verified_time := to_timestamp(verified_epoch::double precision);
  expiry := least(verified_time + interval '5 minutes', session_expiry);

  -- Expiry is anchored to Auth evidence, never to the time this RPC is retried.
  insert into authz.elevated_sessions(session_id,user_id,verified_at,valid_until,factor_method)
    values(current_session,actor,verified_time,expiry,'totp')
    on conflict (session_id) do update set
      verified_at = excluded.verified_at, valid_until = excluded.valid_until,
      factor_method = excluded.factor_method, revoked_at = null
    where authz.elevated_sessions.user_id = excluded.user_id
      and authz.elevated_sessions.verified_at < excluded.verified_at
      and (authz.elevated_sessions.revoked_at is null
        or authz.elevated_sessions.revoked_at < excluded.verified_at)
    returning * into saved;
  changed := found;
  if not changed then
    select * into saved from authz.elevated_sessions where session_id = current_session for update;
    if saved.user_id is distinct from actor or saved.revoked_at is not null
      or saved.verified_at <> verified_time or saved.valid_until <= clock_timestamp() then
      raise exception using errcode = '42501', message = 'Fresh authenticator verification is required';
    end if;
  end if;
  if changed then
    insert into authz.security_audit_events(actor_user_id,session_id,event_type,allowed,reason_code)
      values(actor,current_session,'authentication.step_up_established',true,'recent_totp_verified');
  end if;
  return jsonb_build_object('verified_at',saved.verified_at,'valid_until',saved.valid_until);
end;
$$;
revoke all on function authz.establish_step_up() from public, anon, authenticated, service_role;

-- PostgREST verifies this caller's JWT. No identity/session/timestamp input exists.
create or replace function public.establish_step_up()
returns jsonb language sql volatile security definer set search_path = ''
as $$ select authz.establish_step_up(); $$;
revoke all on function public.establish_step_up() from public, anon, authenticated, service_role;
grant execute on function public.establish_step_up() to authenticated;

create or replace function public.current_step_up()
returns jsonb language sql volatile security definer set search_path = ''
as $$
  select jsonb_build_object('verified_at',elevation.verified_at,'valid_until',elevation.valid_until)
  from authz.elevated_sessions elevation
  where elevation.user_id = auth.uid()
    and elevation.session_id::text = auth.jwt()->>'session_id'
    and authz.is_elevated_session_valid(elevation.session_id,elevation.user_id);
$$;
revoke all on function public.current_step_up() from public, anon, authenticated, service_role;
grant execute on function public.current_step_up() to authenticated;
