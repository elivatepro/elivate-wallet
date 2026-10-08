-- Blueprint 06 — B5: own profile read, updates, rank list, NIN phone lock, photo key.
begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.k() returns text language sql volatile as
  $$ select 'k' || md5(random()::text || clock_timestamp()::text) $$;

insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 3) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 3) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 2) n; end $$;

select ok(api.my_profile(pg_temp.u(1), pg_temp.s(1))->>'uid' ~ '^EW-[1-9][0-9]{4,}$', 'profile carries the UID');
select throws_ok($$ select api.my_profile(pg_temp.u(3), pg_temp.s(3)) $$, 'P0001', 'pin_setup_required',
  'the PIN gate applies');

select is(api.update_profile(pg_temp.u(1), pg_temp.s(1), '{"displayName": "  Ada   O. ", "rank": "Director"}', pg_temp.k())
  ->>'displayName', 'Ada O.', 'display name trimmed and collapsed');
select is(api.my_profile(pg_temp.u(1), pg_temp.s(1))->>'rank', 'Director', 'rank saved');
select throws_ok($$ select api.update_profile(pg_temp.u(1), pg_temp.s(1), '{"rank": "Captain"}', pg_temp.k()) $$,
  'P0001', 'validation_error', 'only the W-02 ranks');
select throws_ok($$ select api.update_profile(pg_temp.u(1), pg_temp.s(1), '{"email": "x@y.z"}', pg_temp.k()) $$,
  'P0001', 'validation_error', 'unknown fields refused');
select throws_ok($$ select api.update_profile(pg_temp.u(1), pg_temp.s(1), '{}', pg_temp.k()) $$,
  'P0001', 'validation_error', 'empty change refused');
select is(api.update_profile(pg_temp.u(1), pg_temp.s(1), '{"phone": "+234 803-123-4567"}', pg_temp.k())->>'phone',
  '+2348031234567', 'manual phone normalised');
select is(api.my_profile(pg_temp.u(1), pg_temp.s(1))->>'phoneSource', 'self', 'manual phone marked self');
select throws_ok($$ select api.update_profile(pg_temp.u(1), pg_temp.s(1), '{"phone": "12"}', pg_temp.k()) $$,
  'P0001', 'validation_error', 'bad phone refused');
select is(api.update_profile(pg_temp.u(1), pg_temp.s(1), '{"displayName": null}', pg_temp.k())->>'displayName', null,
  'display name can be cleared');

-- A NIN-supplied phone is locked.
do $$ begin
  perform api.prepare_nin_check(pg_temp.u(2), pg_temp.s(2), repeat('e', 64), '1111');
  perform api.record_nin_check(pg_temp.u(2), pg_temp.s(2), repeat('e', 64), '1111', 'verified', 'Kemi', null,
    'Adeyemi', '08099999999');
end $$;
select throws_ok($$ select api.update_profile(pg_temp.u(2), pg_temp.s(2), '{"phone": "08011111111"}', pg_temp.k()) $$,
  'P0001', 'conflict', 'the NIN phone cannot be replaced');

-- Photo key must sit under the caller's own folder.
select is(api.set_profile_photo(pg_temp.u(1), pg_temp.s(1),
  'photos/' || pg_temp.u(1) || '/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.webp')->>'previousPhotoKey', null, 'first photo');
select is(api.set_profile_photo(pg_temp.u(1), pg_temp.s(1),
  'photos/' || pg_temp.u(1) || '/aaaaaaaa-bbbb-4ccc-8ddd-ffffffffffff.jpg')->>'previousPhotoKey',
  'photos/' || pg_temp.u(1) || '/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.webp', 'replacing returns the old key');
select throws_ok($$ select api.set_profile_photo(pg_temp.u(1), pg_temp.s(1),
  'photos/' || pg_temp.u(2) || '/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.webp') $$, 'P0001', 'validation_error',
  'another person''s folder is refused');
select throws_ok($$ select api.set_profile_photo(pg_temp.u(1), pg_temp.s(1), 'photos/../x.webp') $$,
  'P0001', 'validation_error', 'malformed keys refused');

select * from finish();
rollback;
