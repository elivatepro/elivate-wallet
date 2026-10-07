create extension if not exists pgcrypto with schema extensions;

create schema authz;

create type public.account_status as enum ('active', 'suspended', 'disabled');
create type public.tenant_status as enum ('active', 'suspended', 'deactivated');
create type public.office_type as enum ('world_team', 'director', 'team_leader');
create type public.office_status as enum ('active', 'closed');
create type public.membership_status as enum ('active', 'suspended', 'ended');
create type public.invitation_status as enum ('pending', 'accepted', 'expired', 'revoked');
create type public.role_key as enum (
  'member',
  'team_leader',
  'director',
  'world_team_member',
  'president_team_member'
);

create type authz.access_effect as enum ('allow', 'deny');
create type authz.access_scope_type as enum ('tenant', 'office_subtree', 'member');
create type authz.authorization_decision_state as enum ('ALLOW', 'DENY', 'STEP_UP_REQUIRED');
create type authz.authorization_source as enum (
  'protected_baseline',
  'role_policy',
  'explicit_grant',
  'explicit_deny',
  'system_rule',
  'default_deny'
);
create type authz.required_auth_level as enum ('none', 'elevated', 'elevated_and_confirmed');

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  new.updated_at = clock_timestamp();
  return new;
end;
$$;

create or replace function public.generate_public_uid()
returns text
language sql
volatile
set search_path = pg_catalog, public, extensions
as $$
  select 'EW-' || upper(substr(encode(extensions.gen_random_bytes(8), 'hex'), 1, 12));
$$;

revoke all on schema authz from public, anon, authenticated;
revoke all on function public.generate_public_uid() from public, anon, authenticated;
grant execute on function public.generate_public_uid() to service_role;
