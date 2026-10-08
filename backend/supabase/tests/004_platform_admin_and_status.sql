begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-0000000000d1', 'admin@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000d2', 'member@example.test', 'authenticated', 'authenticated');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('00000000-0000-0000-0000-00000000d0a1', '00000000-0000-0000-0000-0000000000d1', now(), now()),
  ('00000000-0000-0000-0000-00000000d0a2', '00000000-0000-0000-0000-0000000000d2', now(), now());

select ok(api.set_pin('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000d0a1', repeat('a', 64)) is not null, 'admin PIN set');
select ok(api.set_pin('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-00000000d0a2', repeat('a', 64)) is not null, 'member PIN set');

create temp table uids as
select (select uid from identity.accounts where user_id = '00000000-0000-0000-0000-0000000000d1') as admin_uid,
       (select uid from identity.accounts where user_id = '00000000-0000-0000-0000-0000000000d2') as member_uid;
grant select on uids to public;

select throws_ok(
  $$ select api.set_account_status('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000d0a1',
       (select member_uid from uids), 'suspended', 'Fraud review', 'key-0000000000000001') $$,
  'P0001', 'authorization_denied', 'non-admins cannot change account status'
);

-- First admin is created by a one-time operation (owner decision 2026-10-08).
insert into identity.platform_admins (user_id, grant_reason)
values ('00000000-0000-0000-0000-0000000000d1', 'Initial platform admin');

select throws_ok(
  $$ select api.set_account_status('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000d0a1',
       (select member_uid from uids), 'suspended', '  ', 'key-0000000000000001') $$,
  'P0001', 'validation_error', 'reason is mandatory'
);
select throws_ok(
  $$ select api.set_account_status('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000d0a1',
       (select admin_uid from uids), 'suspended', 'Self test', 'key-0000000000000002') $$,
  'P0001', 'self_target_forbidden', 'admins cannot change their own status'
);

update identity.session_pin_proofs set verified_at = now() - interval '6 minutes'
where session_id = '00000000-0000-0000-0000-00000000d0a1';
select throws_ok(
  $$ select api.set_account_status('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000d0a1',
       (select member_uid from uids), 'suspended', 'Fraud review', 'key-0000000000000001') $$,
  'P0001', 'step_up_required', 'status change needs a fresh PIN'
);
update identity.session_pin_proofs set verified_at = now()
where session_id = '00000000-0000-0000-0000-00000000d0a1';

select is(
  api.set_account_status('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000d0a1',
    (select lower(member_uid) from uids), 'suspended', 'Fraud review', 'key-0000000000000001')->>'replayed',
  'false', 'status changed (UID matched case-insensitively)'
);
select is(
  (select count(*) from identity.account_status_changes where user_id = '00000000-0000-0000-0000-0000000000d2')::int,
  1, 'change recorded with reason'
);
select is(
  api.set_account_status('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000d0a1',
    (select member_uid from uids), 'suspended', 'Fraud review', 'key-0000000000000001')->>'replayed',
  'true', 'same key replays the stored result'
);
select is(
  (select count(*) from audit.security_events where action = 'account.status_changed')::int,
  1, 'replay does not duplicate the audit event'
);
select throws_ok(
  $$ select api.set_account_status('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000d0a1',
       (select member_uid from uids), 'active', 'Fraud review', 'key-0000000000000001') $$,
  'P0001', 'idempotency_conflict', 'same key with a different payload conflicts'
);
select throws_ok(
  $$ select api.security_state('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-00000000d0a2') $$,
  'P0001', 'account_blocked', 'suspended account is blocked'
);
select is(
  (select count(*) from identity.session_pin_proofs where user_id = '00000000-0000-0000-0000-0000000000d2')::int,
  0, 'suspension closes PIN windows'
);

-- Admin registry.
select throws_ok(
  $$ select api.revoke_platform_admin('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000d0a1',
       (select admin_uid from uids), 'Leaving', 'key-0000000000000003') $$,
  'P0001', 'conflict', 'the last admin cannot be revoked'
);
select is(
  api.grant_platform_admin('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000d0a1',
    (select member_uid from uids), 'Joins operations', 'key-0000000000000004')->>'changed',
  'true', 'admins can add admins with a reason'
);

select * from finish();
rollback;
