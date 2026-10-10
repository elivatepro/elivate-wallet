-- Blueprint 06 — B5: NIN checks, limits, one NIN per account, legal-name lock,
-- leader review authority and decisions.
begin;
create extension if not exists pgtap with schema extensions;
select plan(46);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.uid(n int) returns text language sql stable as
  $$ select uid from identity.accounts where user_id = pg_temp.u(n) $$;
create function pg_temp.k() returns text language sql volatile as
  $$ select 'k' || md5(random()::text || clock_timestamp()::text) $$;
create function pg_temp.fp(n int) returns text language sql immutable as
  $$ select repeat(to_hex(n % 16), 64) $$;
create temp table ids (name text primary key, id uuid not null);
create function pg_temp.id(p_name text) returns uuid language sql stable as
  $$ select id from ids where name = p_name $$;
create function pg_temp.m(n int, p_office uuid default null) returns uuid language sql stable as $$
  select id from org.memberships
  where user_id = pg_temp.u(n) and status = 'active' and office_id is not distinct from p_office
  order by started_at desc, id limit 1
$$;
create function pg_temp.check(n int, p_fp text, p_outcome text, p_given text default 'Adaeze') returns jsonb
language plpgsql as $$
begin
  perform api.prepare_nin_check(pg_temp.u(n), pg_temp.s(n), p_fp, '6789');
  return api.record_nin_check(pg_temp.u(n), pg_temp.s(n), p_fp, '6789', p_outcome, p_given,
    array['Chioma'], 'Okafor', '08031234567');
end $$;

-- 1 President · 2 World Team (W) · 3 Director (D under W) · 4 TL (T under D) · 5 member (T)
-- 6 member (other World Team W2) · 7 World Team (W2) · 8 admin · 9, 10 people
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(1, 10) n;
-- Blueprint 19: only approved founders start networks.
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from generate_series(1, 10) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from generate_series(1, 10) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(8), 'Test admin');
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin perform api.activate_tenant(pg_temp.u(8), pg_temp.s(8), pg_temp.id('tenant'), 'Pilot', pg_temp.k()); end $$;
insert into ids select 'W', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'world_team', 'North', null,
  array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', pg_temp.id('W'),
  array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
insert into ids select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'),
  array[pg_temp.uid(4)], pg_temp.k())->>'officeId')::uuid;
insert into ids select 'W2', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'world_team', 'South', null,
  array[pg_temp.uid(7)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(5), pg_temp.k());
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('W2'), pg_temp.uid(6), pg_temp.k());
end $$;

-- ── Provider check ──
select is(api.my_profile(pg_temp.u(9), pg_temp.s(9))->'identity'->>'status', 'unverified', 'starts unverified');
select is(pg_temp.check(9, pg_temp.fp(1), 'not_found')->>'checksRemaining', '1', 'first miss leaves one check');
select is((select count(*)::int from identity.nin_attempts where user_id = pg_temp.u(9)), 1, 'the failed attempt is kept');
select is(pg_temp.check(9, pg_temp.fp(1), 'not_found')->>'checksRemaining', '0', 'second miss leaves none');
select throws_ok($$ select api.prepare_nin_check(pg_temp.u(9), pg_temp.s(9), pg_temp.fp(1), '6789') $$,
  'P0001', 'nin_review_required', 'after 2 misses only a review is possible');
select throws_ok($$ select api.record_nin_check(pg_temp.u(9), pg_temp.s(9), pg_temp.fp(1), '6789', 'verified',
  'A', null, 'B', null) $$, 'P0001', 'nin_review_required', 'record re-checks the limit');

select is(pg_temp.check(10, pg_temp.fp(2), 'verified')->>'status', 'verified', 'a found record verifies');
select is(identity.legal_name(pg_temp.u(10))->>'given', 'Adaeze', 'legal given name locked');
select is(identity.legal_name(pg_temp.u(10))->'middle', '["Chioma"]'::jsonb, 'middle names locked');
select is(identity.legal_name(pg_temp.u(10))->>'method', 'provider', 'method provider');
select is((select first_name || ' ' || last_name from identity.profiles where user_id = pg_temp.u(10)), 'Adaeze Okafor',
  'display names filled from the legal name');
select is((select phone || '/' || phone_source from identity.profiles where user_id = pg_temp.u(10)), '08031234567/nin',
  'NIN phone stored and marked');
select ok((select nin_fingerprint = pg_temp.fp(2) and nin_last4 = '6789' from identity.nin_records where user_id = pg_temp.u(10)),
  'only fingerprint and last 4 are kept');
select throws_ok($$ update identity.nin_records set surname = 'X' where user_id = pg_temp.u(10) $$,
  'P0001', null, 'the record is immutable');
select throws_ok($$ select api.prepare_nin_check(pg_temp.u(10), pg_temp.s(10), pg_temp.fp(3), '6789') $$,
  'P0001', 'conflict', 'a verified person cannot check again');

-- One NIN, one account.
select is(api.prepare_nin_check(pg_temp.u(5), pg_temp.s(5), pg_temp.fp(2), '6789')->>'blocked', 'nin_in_use',
  'a NIN verified on another account is blocked');
select is((select outcome from identity.nin_attempts where user_id = pg_temp.u(5) order by id desc limit 1), 'in_use',
  'the blocked attempt is recorded');
select is(identity.nin_failures(pg_temp.u(5)), 0, 'a blocked attempt is not a failed check');

-- ── Review requests ──
select throws_ok($$ select api.request_nin_review(pg_temp.u(5), pg_temp.s(5), pg_temp.m(5, pg_temp.id('T')),
  pg_temp.fp(4), '1234', 'Bola', null, 'Ade', pg_temp.k()) $$, 'P0001', 'conflict', 'review only after a failed check');
do $$ begin perform pg_temp.check(5, pg_temp.fp(4), 'not_found'); end $$;
select throws_ok($$ select api.request_nin_review(pg_temp.u(5), pg_temp.s(5), pg_temp.m(5, pg_temp.id('T')),
  pg_temp.fp(2), '1234', 'Bola', null, 'Ade', pg_temp.k()) $$, 'P0001', 'nin_in_use', 'review refuses a taken NIN');
insert into ids select 'r5', (api.request_nin_review(pg_temp.u(5), pg_temp.s(5), pg_temp.m(5, pg_temp.id('T')),
  pg_temp.fp(4), '1234', ' Bola ', array['Funmi'], 'Ade', pg_temp.k())->>'reviewId')::uuid;
select is(api.my_profile(pg_temp.u(5), pg_temp.s(5))->'identity'->>'status', 'review_pending', 'status review_pending');
select throws_ok($$ select api.prepare_nin_check(pg_temp.u(5), pg_temp.s(5), pg_temp.fp(5), '6789') $$,
  'P0001', 'conflict', 'no checks while a review is pending');
select throws_ok($$ select api.request_nin_review(pg_temp.u(5), pg_temp.s(5), pg_temp.m(5, pg_temp.id('T')),
  pg_temp.fp(4), '1234', 'Bola', null, 'Ade', pg_temp.k()) $$, 'P0001', 'conflict', 'one pending review at a time');

-- ── Reviewer authority (Q4) ──
select is(jsonb_array_length(api.nin_reviews(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1))), 1, 'President Team sees it');
select is(jsonb_array_length(api.nin_reviews(pg_temp.u(2), pg_temp.s(2), pg_temp.m(2, pg_temp.id('W')))), 1,
  'World Team above the office sees it');
select is(jsonb_array_length(api.nin_reviews(pg_temp.u(7), pg_temp.s(7), pg_temp.m(7, pg_temp.id('W2')))), 0,
  'another World Team does not');
select throws_ok($$ select api.nin_reviews(pg_temp.u(3), pg_temp.s(3), pg_temp.m(3, pg_temp.id('D'))) $$,
  'P0001', 'authorization_denied', 'a Director cannot review');
select throws_ok($$ select api.nin_reviews(pg_temp.u(4), pg_temp.s(4), pg_temp.m(4, pg_temp.id('T'))) $$,
  'P0001', 'authorization_denied', 'a Team Leader cannot review');
select is(api.nin_reviews(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1))->0->'legalName'->>'given', 'Bola',
  'the typed name is shown, trimmed');
select is(jsonb_array_length(api.admin_nin_reviews(pg_temp.u(8), pg_temp.s(8))), 1, 'admins see every pending review');
select throws_ok($$ select api.admin_nin_reviews(pg_temp.u(1), pg_temp.s(1)) $$, 'P0001', 'authorization_denied',
  'non-admins cannot use the admin list');
select throws_ok($$ select api.decide_nin_review(pg_temp.u(7), pg_temp.s(7), pg_temp.m(7, pg_temp.id('W2')),
  pg_temp.id('r5'), 'approve', 'Checked the card', pg_temp.k()) $$, 'P0001', 'authorization_denied',
  'another World Team cannot decide');
select throws_ok($$ select api.decide_nin_review(pg_temp.u(2), pg_temp.s(2), pg_temp.m(2, pg_temp.id('W')),
  pg_temp.id('r5'), 'approve', '', pg_temp.k()) $$, 'P0001', 'validation_error', 'a decision needs a reason');

-- Step-up: an expired proof is refused.
update identity.session_pin_proofs set verified_at = now() - interval '1 hour' where session_id = pg_temp.s(2);
select throws_ok($$ select api.decide_nin_review(pg_temp.u(2), pg_temp.s(2), pg_temp.m(2, pg_temp.id('W')),
  pg_temp.id('r5'), 'approve', 'Checked the card', pg_temp.k()) $$, 'P0001', 'step_up_required',
  'deciding needs a fresh PIN');
update identity.session_pin_proofs set verified_at = now() where session_id = pg_temp.s(2);

select is(api.decide_nin_review(pg_temp.u(2), pg_temp.s(2), pg_temp.m(2, pg_temp.id('W')), pg_temp.id('r5'),
  'approve', 'Checked the card', pg_temp.k())->>'status', 'approved', 'World Team approves');
select is(identity.legal_name(pg_temp.u(5))->>'method', 'leader_review', 'locked as leader-confirmed');
select is(identity.legal_name(pg_temp.u(5))->>'given', 'Bola', 'with the typed name');
select throws_ok($$ select api.decide_nin_review(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('r5'),
  'reject', 'Too late', pg_temp.k()) $$, 'P0001', 'conflict', 'a decided review stays decided');

-- Rejection by an admin, then a new request is possible.
do $$ begin perform pg_temp.check(6, pg_temp.fp(6), 'not_found'); end $$;
insert into ids select 'r6', (api.request_nin_review(pg_temp.u(6), pg_temp.s(6), pg_temp.m(6, pg_temp.id('W2')),
  pg_temp.fp(6), '4321', 'Tunde', null, 'Bello', pg_temp.k())->>'reviewId')::uuid;
select throws_ok($$ select api.decide_nin_review(pg_temp.u(6), pg_temp.s(6), null, pg_temp.id('r6'), 'approve',
  'Myself', pg_temp.k()) $$, 'P0001', 'authorization_denied', 'not an admin, no workspace: refused');
select is(api.decide_nin_review(pg_temp.u(8), pg_temp.s(8), null, pg_temp.id('r6'), 'reject', 'Name unreadable',
  pg_temp.k())->>'status', 'rejected', 'an admin rejects');
select is(api.my_profile(pg_temp.u(6), pg_temp.s(6))->'identity'->'review'->>'status', 'rejected',
  'the person sees the rejection');
select lives_ok($$ select api.request_nin_review(pg_temp.u(6), pg_temp.s(6), pg_temp.m(6, pg_temp.id('W2')),
  pg_temp.fp(6), '4321', 'Tunde', null, 'Bello', pg_temp.k()) $$, 'a new request after a rejection');

-- ── Outcome email (Paper A14b/A14c) ──
select is((select params->>'decision' from outbox.events
  where template = 'identity.nin_review_decided' and aggregate_id = pg_temp.id('r5')
    and recipient_user_id = pg_temp.u(5)), 'approved', 'the approval emails the person');
select is((select params->>'decision' from outbox.events
  where template = 'identity.nin_review_decided' and aggregate_id = pg_temp.id('r6')
    and recipient_user_id = pg_temp.u(6)), 'rejected', 'the rejection emails the person');
select is((select count(*)::int from outbox.events where template = 'identity.nin_review_decided'), 2,
  'one email per decision; refused decisions and new requests send none');
select ok(not exists (
  select 1 from outbox.events where template = 'identity.nin_review_decided'
    and (params - array['decision', 'network', 'office'] <> '{}'::jsonb
      or params::text ~ '(Bola|Tunde|Bello|1234|4321|Checked|unreadable)')
), 'only decision, network and office: no name, NIN digits or reason');

select * from finish();
rollback;
