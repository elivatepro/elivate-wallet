create table internal.organization_command_idempotency (
  idempotency_key uuid primary key,
  command_type text not null check (command_type in (
    'create_invitation',
    'revoke_invitation',
    'accept_invitation',
    'create_membership',
    'activate_membership',
    'suspend_membership',
    'end_membership',
    'move_membership'
  )),
  actor_user_id uuid not null
    references public.user_accounts (user_id) on delete restrict,
  tenant_id uuid not null
    references public.tenants (id) on delete restrict,
  request_fingerprint bytea not null
    check (octet_length(request_fingerprint) = 32),
  result_type text not null check (result_type in ('invitation', 'membership')),
  result_id uuid not null,
  created_at timestamptz not null default clock_timestamp()
);

create index organization_command_idempotency_actor_created
  on internal.organization_command_idempotency (actor_user_id, created_at desc);

create index organization_command_idempotency_tenant_created
  on internal.organization_command_idempotency (tenant_id, created_at desc);

alter table public.memberships
  add constraint memberships_primary_must_be_current
  check (not is_primary or status <> 'ended');

create unique index memberships_one_current_role_per_office
  on public.memberships (tenant_id, user_id, office_id, role_key)
  where status <> 'ended';

alter table public.invitations
  add constraint invitations_acceptance_matches_status
  check (
    (status = 'accepted'
      and accepted_user_id is not null
      and accepted_membership_id is not null)
    or (status <> 'accepted'
      and accepted_user_id is null
      and accepted_membership_id is null)
  );

comment on table internal.organization_command_idempotency is
  'Private replay registry for trusted membership and invitation lifecycle commands.';

comment on index memberships_one_current_role_per_office is
  'Prevents duplicate concurrent memberships for the same user, office, and exact role while preserving ended history.';
