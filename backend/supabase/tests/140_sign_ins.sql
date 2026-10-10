-- Blueprint 14 — sign-in history, unusual sign-ins and A07 (B1, B2, B4).
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(36);

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-000000140001', 'si1@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000140002', 'si2@example.test', 'authenticated', 'authenticated');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('00000000-0000-0000-0000-0000001400a1', '00000000-0000-0000-0000-000000140001', now(), now()),
  ('00000000-0000-0000-0000-0000001400a2', '00000000-0000-0000-0000-000000140001', now(), now()),
  ('00000000-0000-0000-0000-0000001400a3', '00000000-0000-0000-0000-000000140001', now(), now()),
  ('00000000-0000-0000-0000-0000001400a4', '00000000-0000-0000-0000-000000140001', now(), now()),
  ('00000000-0000-0000-0000-0000001400a5', '00000000-0000-0000-0000-000000140001', now(), now()),
  ('00000000-0000-0000-0000-0000001400b1', '00000000-0000-0000-0000-000000140002', now(), now());

create function pg_temp.rec(
  p_session text, p_ip text, p_city text, p_country text, p_device text,
  p_user text default '00000000-0000-0000-0000-000000140001', p_method text default 'password'
) returns jsonb
language sql as $$
  select api.record_sign_in(p_user::uuid, p_session::uuid, p_method, p_ip, p_city, p_country, p_device,
    'Mozilla/5.0 (Macintosh) Chrome/130')
$$;

-- Validation.
select throws_ok($$ select pg_temp.rec('00000000-0000-0000-0000-0000001400a1', '1.2.3.4', 'Lagos', 'NG', 'Mac · Chrome',
  p_method => 'telepathy') $$, 'P0001', 'validation_error', 'unknown method refused');
select throws_ok($$ select pg_temp.rec('00000000-0000-0000-0000-0000001400a1', 'not-an-ip', 'Lagos', 'NG', 'Mac · Chrome') $$,
  'P0001', 'validation_error', 'malformed IP refused');
select throws_ok($$ select pg_temp.rec('00000000-0000-0000-0000-0000001400a1', '10.0.0.0/8', 'Lagos', 'NG', 'Mac · Chrome') $$,
  'P0001', 'validation_error', 'a network range is not an address');
select throws_ok($$ select pg_temp.rec('00000000-0000-0000-0000-0000001400a1', '1.2.3.4', 'Lagos', 'Nigeria', 'Mac · Chrome') $$,
  'P0001', 'validation_error', 'country must be a two-letter code');
select throws_ok($$ select pg_temp.rec('00000000-0000-0000-0000-0000001400a1', '1.2.3.4', E'La\ngos', 'NG', 'Mac · Chrome') $$,
  'P0001', 'validation_error', 'control characters refused in the city');
select throws_ok($$ select pg_temp.rec('00000000-0000-0000-0000-0000001400a1', '1.2.3.4', 'Lagos', 'NG', '') $$,
  'P0001', 'validation_error', 'device label required');
select throws_ok($$ select pg_temp.rec('00000000-0000-0000-0000-0000001400b1', '1.2.3.4', 'Lagos', 'NG', 'Mac · Chrome') $$,
  'P0001', 'authentication_required', 'only the owner of the session can record it');

-- First sign-in: never unusual.
select is(pg_temp.rec('00000000-0000-0000-0000-0000001400a1', '102.89.1.10', 'Lagos', 'NG', 'Mac · Chrome'),
  '{"unusual": false}'::jsonb, 'the first sign-in is never unusual');
select is(pg_temp.rec('00000000-0000-0000-0000-0000001400a1', '9.9.9.9', 'Abuja', 'NG', 'Windows · Edge'),
  '{"unusual": false}'::jsonb, 'a replay for the same session returns the recorded answer');
select is((select count(*)::int from identity.sign_ins where user_id = '00000000-0000-0000-0000-000000140001'),
  1, 'and records nothing new');
select is((select host(ip) from identity.sign_ins where session_id = '00000000-0000-0000-0000-0000001400a1'),
  '102.89.1.10', 'the IP is stored');

-- Same place, same device (city compared without case): not unusual.
select is(pg_temp.rec('00000000-0000-0000-0000-0000001400a2', '2001:db8::1', 'LAGOS', 'NG', 'Mac · Chrome'),
  '{"unusual": false}'::jsonb, 'same city and device is not unusual (IPv6 accepted)');

-- New city, same device.
select is(pg_temp.rec('00000000-0000-0000-0000-0000001400a3', '41.58.1.1', 'Abuja', 'NG', 'Mac · Chrome'),
  '{"unusual": true}'::jsonb, 'a new city is unusual');
select is((select reasons from identity.sign_ins where session_id = '00000000-0000-0000-0000-0000001400a3'),
  array['new_location'], 'reason: new location');

-- New device in a known place.
select is(pg_temp.rec('00000000-0000-0000-0000-0000001400a4', '102.89.1.11', 'Lagos', 'NG', 'Windows · Edge'),
  '{"unusual": true}'::jsonb, 'a new device is unusual');
select is((select reasons from identity.sign_ins where session_id = '00000000-0000-0000-0000-0000001400a4'),
  array['new_device'], 'reason: new device');

-- Unknown location, known device: not unusual.
select is(pg_temp.rec('00000000-0000-0000-0000-0000001400a5', null, null, null, 'Mac · Chrome', p_method => 'email_link'),
  '{"unusual": false}'::jsonb, 'no location and a known device is not unusual');

-- A07 and the bell, personal, with safe values only.
select is((select count(*)::int from outbox.events
           where template = 'security.new_sign_in' and recipient_user_id = '00000000-0000-0000-0000-000000140001'),
  2, 'one A07 per unusual sign-in');
select is((select count(*)::int from notify.items
           where kind = 'security.new_sign_in' and user_id = '00000000-0000-0000-0000-000000140001'
             and tenant_id is null and email_event_id is not null),
  2, 'each has a personal bell item linked to its email');
select is((select params from outbox.events e join identity.sign_ins s on s.id = e.aggregate_id
           where s.session_id = '00000000-0000-0000-0000-0000001400a3'),
  '{"city": "Abuja", "path": "/app/account/devices", "device": "Mac · Chrome", "reason": "new_location", "country": "NG"}'::jsonb,
  'A07 carries the device, city, country and reason');
select is((select params->>'reason' from notify.items i join identity.sign_ins s on s.id = i.subject_id
           where s.session_id = '00000000-0000-0000-0000-0000001400a4'),
  'new_device', 'the bell item says new device');
select is((select count(*)::int from outbox.events where params::text ~ '102\.89|41\.58|2001:db8'), 0,
  'no IP in any email');
select is((select count(*)::int from notify.items where params::text ~ '102\.89|41\.58|2001:db8'), 0,
  'no IP in any bell item');
select is((select count(*)::int from audit.security_events where safe_after::text ~ '102\.89|41\.58|2001:db8'), 0,
  'no IP in the audit');
select is((select count(*)::int from audit.security_events
           where action = 'session.signed_in' and actor_user_id = '00000000-0000-0000-0000-000000140001'),
  5, 'every recorded sign-in is audited once');

-- Devices & sessions shows the location; the overview lists unusual sign-ins.
select is(api.set_pin('00000000-0000-0000-0000-000000140001', '00000000-0000-0000-0000-0000001400a1', repeat('a', 64))->>'gate', 'ready', 'PIN set');
select is(
  (select s->>'city' from jsonb_array_elements(
     api.list_sessions('00000000-0000-0000-0000-000000140001', '00000000-0000-0000-0000-0000001400a1')) s
   where s->>'sessionId' = '00000000-0000-0000-0000-0000001400a3'),
  'Abuja', 'the session list carries the city');
select is(
  (select count(*)::int from jsonb_array_elements(
     api.list_sessions('00000000-0000-0000-0000-000000140001', '00000000-0000-0000-0000-0000001400a1')) s
   where s ? 'ip'),
  0, 'the session list never carries the IP');
delete from auth.sessions where id = '00000000-0000-0000-0000-0000001400a3';
select is(
  jsonb_array_length(api.security_overview('00000000-0000-0000-0000-000000140001',
    '00000000-0000-0000-0000-0000001400a1')->'unusualSignIns'),
  2, 'the overview lists the two unusual sign-ins');
select is(
  (select u->>'signedIn' from jsonb_array_elements(api.security_overview('00000000-0000-0000-0000-000000140001',
    '00000000-0000-0000-0000-0000001400a1')->'unusualSignIns') u where u->>'city' = 'Abuja'),
  'false', 'a signed-out unusual session shows as signed out');
select is(
  (select count(*)::int from jsonb_array_elements(api.security_overview('00000000-0000-0000-0000-000000140001',
    '00000000-0000-0000-0000-0000001400a1')->'unusualSignIns') u where u ? 'ip'),
  0, 'the overview never carries the IP');
select ok(exists (select 1 from identity.sign_ins where session_id = '00000000-0000-0000-0000-0000001400a3'),
  'history outlives the session');

-- Kept for good, and private.
select throws_ok($$ delete from identity.sign_ins where user_id = '00000000-0000-0000-0000-000000140001' $$,
  'P0001', 'invariant_violation', 'sign-ins cannot be deleted');
select throws_ok($$ update identity.sign_ins set city = 'Elsewhere' $$,
  'P0001', 'invariant_violation', 'sign-ins cannot be changed');
select ok(not has_function_privilege('authenticated',
  'api.record_sign_in(uuid, uuid, text, text, text, text, text, text, text)', 'execute'),
  'signed-in clients cannot call record_sign_in directly');
select ok(not has_table_privilege('authenticated', 'identity.sign_ins', 'select'),
  'clients cannot read sign-in history directly');

select * from finish();
rollback;
