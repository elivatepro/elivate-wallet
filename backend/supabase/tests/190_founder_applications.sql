-- Blueprint 19 — B6 190: founder applications. A public application is
-- reviewed by a platform admin (reason + PIN); approval sends a founder
-- invitation, and only an account that accepted one (or that created a
-- network before the rule) may start a network. Repeat applications get the
-- same reply and no email; a rejection may reapply after 30 days.
begin;
create extension if not exists pgtap with schema extensions;
select plan(74);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('19000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('29000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.k() returns text language sql volatile as
  $$ select 'k' || md5(random()::text || clock_timestamp()::text) $$;
create function pg_temp.dg(t text) returns text language sql immutable as
  $$ select encode(sha256(convert_to(t, 'UTF8')), 'hex') $$;
create function pg_temp.tid(t text) returns uuid language sql immutable as
  $$ select md5(t)::uuid $$;
create function pg_temp.fails(p_sql text) returns text language plpgsql as $$
declare
  msg text;
  det text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  return msg || ':' || coalesce((nullif(det, '')::jsonb)->>'reason', '');
end $$;
create function pg_temp.apply(p_email text, p_team text default 'Harmony Builders', p_rank text default 'ruby_director_4')
returns jsonb language sql volatile as
  $$ select api.submit_founder_application('Adaeze Okafor', p_email, '0803 555 0142', p_team, p_rank) $$;
create function pg_temp.app(p_email text) returns uuid language sql stable as
  $$ select id from founders.applications where email = lower(p_email) order by created_at desc limit 1 $$;
create function pg_temp.decide(p_app uuid, p_decision text, p_token text default null, p_key text default null)
returns jsonb language sql volatile as $$
  select api.admin_decide_founder_application(pg_temp.u(9), pg_temp.s(9), p_app, p_decision, 'Rank confirmed by phone',
    case when p_token is not null then pg_temp.tid(p_token) end,
    case when p_token is not null then pg_temp.dg(p_token) end, coalesce(p_key, pg_temp.k()))
$$;
create function pg_temp.mails(p_template text, p_email text) returns int language sql stable as
  $$ select count(*)::int from outbox.events where template = p_template and recipient_email = lower(p_email) $$;

-- 1 applicant (no PIN yet) · 2 different email · 3 existing founder · 4 plain member · 9 platform admin
insert into auth.users (id, email, aud, role, email_confirmed_at)
select pg_temp.u(n), 'person' || n || '@example.test', 'authenticated', 'authenticated', now()
from unnest(array[1, 2, 3, 4, 9]) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from unnest(array[1, 2, 3, 4, 9]) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from unnest(array[2, 3, 4, 9]) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(9), 'Test admin');
insert into founders.approved (user_id, source) values (pg_temp.u(3), 'existing');

-- ── Applying (14) ──
select is(pg_temp.apply('  Person1@Example.test '), '{"received": true}'::jsonb, 'an application is received');
select is((select row(full_name, email, phone, team_name, rank, status)::text from founders.applications
           where id = pg_temp.app('person1@example.test')),
  '("Adaeze Okafor",person1@example.test,08035550142,"Harmony Builders",ruby_director_4,waiting)',
  'stored cleaned: email lower-cased, phone without spaces, waiting');
select is((select params from outbox.events where template = 'founder.application_received'
           and recipient_email = 'person1@example.test'),
  '{"team": "Harmony Builders"}'::jsonb, 'A19 goes to the applicant with the team name');
select is(pg_temp.apply('person1@example.test', 'Other Team'), '{"received": true}'::jsonb,
  'a second application while one waits gets the same reply');
select is((select count(*)::int from founders.applications where email = 'person1@example.test'), 1,
  '... and stores nothing');
select is(pg_temp.mails('founder.application_received', 'person1@example.test'), 1, '... and sends no email');
select is(pg_temp.apply('person3@example.test'), '{"received": true}'::jsonb,
  'an existing founder gets the same reply');
select is((select count(*)::int from founders.applications where email = 'person3@example.test'), 0,
  '... and nothing is stored or sent');
select is(pg_temp.fails($$ select pg_temp.apply('person5@example.test', 'Team', 'ruby_director_3') $$),
  'validation_error:', 'only Ruby Director 4, 5 or Diamond Director');
select is(pg_temp.fails($$ select api.submit_founder_application('A', 'p@example.test', '0803', 'Team', 'diamond_director') $$),
  'validation_error:', 'a one-letter name is refused');
select is(pg_temp.fails($$ select api.submit_founder_application('Ada Obi', 'p@example.test', 'call me', 'Team', 'diamond_director') $$),
  'validation_error:', 'a phone must be digits');
select is(pg_temp.fails($$ select api.submit_founder_application('Ada Obi', 'not-an-email', '+2348035550142', 'Team', 'diamond_director') $$),
  'validation_error:', 'an email must look like one');
select lives_ok($$ select api.submit_founder_application('Ada Obi', 'person2@example.test', '+234 803 555 0142', 'Bright Path', 'diamond_director') $$,
  'an international phone with spaces is accepted');
select is((select phone from founders.applications where email = 'person2@example.test'), '+2348035550142',
  '... stored as +234…');

-- ── Hourly cap (1) ──
insert into founders.applications (full_name, email, phone, team_name, rank)
select 'Filler ' || n, 'filler' || n || '@fill.test', '08000000000', 'Fill', 'ruby_director_4'
from generate_series(1, 198) n;
select is(pg_temp.fails($$ select pg_temp.apply('person6@example.test') $$), 'rate_limited:',
  '200 new applications an hour is the platform cap');
select is(pg_temp.fails($$ select pg_temp.apply('person1@example.test') $$), 'rate_limited:',
  '... and a known email gets the same capped reply');
-- Fixture time travel (the guard trigger forbids it in the app).
set session_replication_role = replica;
update founders.applications
set created_at = now() - interval '2 hours' + substring(email from 'filler([0-9]+)')::int * interval '1 second'
where email like 'filler%';
set session_replication_role = origin;

-- ── Admin reads (8) ──
select is(pg_temp.fails($$ select api.admin_founder_applications(pg_temp.u(4), pg_temp.s(4)) $$),
  'authorization_denied:', 'only platform admins read applications');
select is((api.admin_founder_applications(pg_temp.u(9), pg_temp.s(9))->'counts'->>'waiting')::int, 200,
  'waiting count');
select is((api.admin_founder_applications(pg_temp.u(9), pg_temp.s(9), 'waiting', null, 2)->'items'->0->>'email'),
  'filler1@fill.test', 'waiting is oldest first');
select isnt((api.admin_founder_applications(pg_temp.u(9), pg_temp.s(9), 'waiting', null, 2)->>'nextCursor'), null,
  'a cursor for the next page');
select is((api.admin_founder_applications(pg_temp.u(9), pg_temp.s(9), 'waiting',
  api.admin_founder_applications(pg_temp.u(9), pg_temp.s(9), 'waiting', null, 2)->>'nextCursor', 2)->'items'->0->>'email'),
  'filler3@fill.test', 'the next page continues');
select is(pg_temp.fails($$ select api.admin_founder_applications(pg_temp.u(9), pg_temp.s(9), 'maybe') $$),
  'validation_error:', 'unknown status filter');
select is(api.admin_founder_application(pg_temp.u(9), pg_temp.s(9), pg_temp.app('person1@example.test'))->>'earlierApplications',
  '0', 'detail: first application');
select is((api.admin_overview(pg_temp.u(9), pg_temp.s(9))->>'founderApplications')::int, 200,
  'the overview counts waiting applications');

-- ── Deciding (17) ──
update identity.session_pin_proofs set verified_at = now() - interval '6 minutes' where session_id = pg_temp.s(9);
select is(pg_temp.fails(format('select pg_temp.decide(%L, %L, %L)', pg_temp.app('person1@example.test'), 'approve', 'tok-1')),
  'step_up_required:', 'deciding needs a fresh PIN');
update identity.session_pin_proofs set verified_at = now() where session_id = pg_temp.s(9);
select is(pg_temp.fails(format($$ select api.admin_decide_founder_application(pg_temp.u(4), pg_temp.s(4), %L, 'approve',
  'Looks right', pg_temp.tid('x'), pg_temp.dg('x'), pg_temp.k()) $$, pg_temp.app('person1@example.test'))),
  'authorization_denied:', 'only platform admins decide');
select is(pg_temp.fails(format('select pg_temp.decide(%L, %L)', pg_temp.app('person1@example.test'), 'approve')),
  'validation_error:', 'approval needs the invitation token');
select is(pg_temp.fails(format('select pg_temp.decide(%L, %L)', pg_temp.app('person1@example.test'), 'maybe')),
  'validation_error:', 'approve or reject only');
select is(pg_temp.fails(format($$ select api.admin_decide_founder_application(pg_temp.u(9), pg_temp.s(9), %L, 'reject',
  'no', null, null, pg_temp.k()) $$, pg_temp.app('person1@example.test'))),
  'validation_error:', 'a reason of 3+ characters is required');
create temp table approval as select pg_temp.decide(pg_temp.app('person1@example.test'), 'approve', 'tok-1', 'key-approve-0000001') as r;
select is((select r->'application'->>'status' from approval), 'approved', 'approved');
select is((select r->>'replayed' from approval), 'false', 'first run');
select is((pg_temp.decide(pg_temp.app('person1@example.test'), 'approve', 'tok-other', 'key-approve-0000001'))->>'replayed',
  'true', 'the same key replays (the token is not part of the request)');
select is((select token_digest from founders.invitations where application_id = pg_temp.app('person1@example.test')),
  decode(pg_temp.dg('tok-1'), 'hex'), 'only the first token''s digest is stored');
select is((select expires_at - created_at from founders.invitations where application_id = pg_temp.app('person1@example.test')),
  interval '14 days', 'the founder invitation lasts 14 days');
select is((select params->>'team' from outbox.events where template = 'founder.application_approved'
           and recipient_email = 'person1@example.test'), 'Harmony Builders', 'A17 goes out with the team');
select is((select params ? 'reason' from outbox.events where template = 'founder.application_approved'), false,
  'the reason never reaches the email');
select is(pg_temp.fails(format('select pg_temp.decide(%L, %L)', pg_temp.app('person1@example.test'), 'reject')),
  'conflict:already_decided', 'a decided application stays decided');
select is((select count(*)::int from audit.security_events where action = 'founder_application.approved'
           and reason = 'Rank confirmed by phone'), 1, 'approval is audited with the reason');
select is((select platform.action_group('founder_application.approved')), 'accounts', 'audit group: accounts');
select lives_ok(format('select pg_temp.decide(%L, %L)', pg_temp.app('person2@example.test'), 'reject'),
  'a rejection');
select is((select params from outbox.events where template = 'founder.application_rejected'
           and recipient_email = 'person2@example.test'), '{"team": "Bright Path"}'::jsonb, 'A18 goes out with the team');

-- ── Reapplying (4) ──
select is(pg_temp.apply('person2@example.test'), '{"received": true}'::jsonb, 'a rejected applicant gets the same reply');
select is((select count(*)::int from founders.applications where email = 'person2@example.test'), 1,
  '... but nothing new within 30 days');
set session_replication_role = replica;
update founders.applications set decided_at = now() - interval '31 days', created_at = now() - interval '32 days'
where email = 'person2@example.test';
set session_replication_role = origin;
select pg_temp.apply('person2@example.test');
select is((select count(*)::int from founders.applications where email = 'person2@example.test' and status = 'waiting'), 1,
  'after 30 days a new application is stored');
select is(api.admin_founder_application(pg_temp.u(9), pg_temp.s(9), pg_temp.app('person2@example.test'))->>'earlierApplications',
  '1', 'the admin sees it is not the first');

-- ── The link (7) ──
select is(api.founder_invitation_preview(pg_temp.dg('tok-1')),
  '{"email": "person1@example.test", "teamName": "Harmony Builders"}'::jsonb, 'preview shows the bound email');
select is(pg_temp.fails($$ select api.founder_invitation_preview(pg_temp.dg('nope')) $$), 'invitation_unavailable:',
  'an unknown link is unavailable');
select is(api.request_founder_verification(pg_temp.dg('tok-1'))->>'email', 'person1@example.test',
  'a verification email can be requested');
select is(pg_temp.fails($$ select api.request_founder_verification(pg_temp.dg('tok-1')) $$), 'rate_limited:',
  'one a minute');
select is(pg_temp.fails($$ select api.accept_founder_invitation(pg_temp.u(2), pg_temp.s(2), pg_temp.dg('tok-1'), pg_temp.k()) $$),
  'invitation_email_mismatch:', 'another account cannot accept it');
update auth.users set email_confirmed_at = null where id = pg_temp.u(1);
select is(pg_temp.fails($$ select api.accept_founder_invitation(pg_temp.u(1), pg_temp.s(1), pg_temp.dg('tok-1'), pg_temp.k()) $$),
  'email_unverified:', 'the email must be confirmed');
update auth.users set email_confirmed_at = now() where id = pg_temp.u(1);
select is(pg_temp.fails($$ select api.start_network(pg_temp.u(1), pg_temp.s(1), 'Harmony Builders', 'HB', pg_temp.k()) $$),
  'pin_setup_required:', 'no network before the PIN');

-- ── Resend (6) ──
select is(pg_temp.fails(format($$ select api.admin_resend_founder_invitation(pg_temp.u(9), pg_temp.s(9), %L, 'Lost the email',
  pg_temp.tid('tok-2'), pg_temp.dg('tok-2'), pg_temp.k()) $$, pg_temp.app('person2@example.test'))),
  'conflict:not_approved', 'only an approved application can be resent');
select lives_ok(format($$ select api.admin_resend_founder_invitation(pg_temp.u(9), pg_temp.s(9), %L, 'Lost the email',
  pg_temp.tid('tok-2'), pg_temp.dg('tok-2'), pg_temp.k()) $$, pg_temp.app('person1@example.test')),
  'a new link for an approved application');
select is(pg_temp.fails($$ select api.founder_invitation_preview(pg_temp.dg('tok-1')) $$), 'invitation_unavailable:',
  'the old link stops working');
select is(pg_temp.mails('founder.application_approved', 'person1@example.test'), 2, 'a fresh A17 goes out');
select is((select count(*)::int from outbox.events e where e.template = 'founder.application_approved'
           and outbox.is_relevant(e)), 1, 'only the current link''s email is still worth sending');
select is((select count(*)::int from audit.security_events where action = 'founder_application.invitation_resent'), 1,
  'the resend is audited');

-- ── Resend limit (2) ──
create temp table limited as select pg_temp.apply('person7@example.test');
select pg_temp.decide(pg_temp.app('person7@example.test'), 'approve', 'tok-7');
update founders.invitations set issue_count = 6 where application_id = pg_temp.app('person7@example.test');
select is(pg_temp.fails(format($$ select api.admin_resend_founder_invitation(pg_temp.u(9), pg_temp.s(9), %L, 'Again',
  pg_temp.tid('tok-8'), pg_temp.dg('tok-8'), pg_temp.k()) $$, pg_temp.app('person7@example.test'))),
  'conflict:resend_limit', 'at most 5 resends');
update founders.invitations set expires_at = now() - interval '1 minute'
where application_id = pg_temp.app('person7@example.test');
select pg_temp.apply('person7@example.test');
select is((select count(*)::int from founders.applications where email = 'person7@example.test' and status = 'waiting'), 1,
  'once the last link expires the founder may apply again');

-- ── Accepting (9) ──
select is(pg_temp.fails($$ select api.accept_founder_invitation(pg_temp.u(1), pg_temp.s(1), pg_temp.dg('tok-1'), pg_temp.k()) $$),
  'invitation_unavailable:', 'the replaced link cannot be accepted');
create temp table accepted as
  select api.accept_founder_invitation(pg_temp.u(1), pg_temp.s(1), pg_temp.dg('tok-2'), 'key-accept-00000001') as r;
select is((select r->>'founder' from accepted), 'true', 'accepted at gate pin_setup_required');
select is((select source from founders.approved where user_id = pg_temp.u(1)), 'application', 'the account is now a founder');
select is((select status from founders.invitations where application_id = pg_temp.app('person1@example.test')), 'accepted',
  'the invitation is accepted');
select is(api.accept_founder_invitation(pg_temp.u(1), pg_temp.s(1), pg_temp.dg('tok-2'), pg_temp.k())->>'founder', 'true',
  'accepting again from the same account is fine');
select is(pg_temp.fails(format($$ select api.admin_resend_founder_invitation(pg_temp.u(9), pg_temp.s(9), %L, 'Lost the email',
  pg_temp.tid('tok-3'), pg_temp.dg('tok-3'), pg_temp.k()) $$, pg_temp.app('person1@example.test'))),
  'conflict:already_accepted', 'an accepted invitation is not resent');
select is((select count(*)::int from outbox.events e where e.template = 'founder.application_approved'
           and outbox.is_relevant(e)), 0, 'an accepted invitation''s emails are no longer sent');
select is(pg_temp.apply('person1@example.test'), '{"received": true}'::jsonb, 'a founder applying again gets the same reply');
select is((select count(*)::int from founders.applications where email = 'person1@example.test'), 1, '... and nothing new');

-- ── Starting a network (4) ──
do $$ begin perform api.set_pin(pg_temp.u(1), pg_temp.s(1), repeat('a', 64)); end $$;
select is((api.start_network(pg_temp.u(1), pg_temp.s(1), 'Harmony Builders', 'HB', pg_temp.k(), null, 'band_400', true))->>'status',
  'active', 'an approved founder starts their trial');
select is(pg_temp.fails($$ select api.start_network(pg_temp.u(4), pg_temp.s(4), 'Side Network', 'SN', pg_temp.k()) $$),
  'authorization_denied:founder_not_approved', 'anyone else cannot start a network, paid or not');
select is(api.billing_setup(pg_temp.u(4), pg_temp.s(4))->>'founderApproved', 'false', 'setup says not approved');
select is((api.start_network(pg_temp.u(3), pg_temp.s(3), 'Older Network', 'ON', pg_temp.k()))->>'status',
  'pending_payment', 'a founder from before the rule still starts networks');

-- ── Guards and privileges (1) ──
select is(pg_temp.fails($$ update founders.applications set email = 'x@example.test' where email = 'person1@example.test' $$),
  'invariant_violation:', 'a decided application never changes');

select * from finish();
rollback;
