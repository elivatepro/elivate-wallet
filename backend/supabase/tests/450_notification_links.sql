-- Blueprint 45 — 450: the owner's own withdrawal news links to that withdrawal
-- (/app/withdrawals/<id>) in the bell and the email; approver and payout tasks
-- keep their queue links.
begin;
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(12);

create function pg_temp.u(n int) returns uuid language sql immutable as
  $$ select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql immutable as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.uid(n int) returns text language sql stable as
  $$ select uid from identity.accounts where user_id = pg_temp.u(n) $$;
create function pg_temp.k() returns text language sql volatile as
  $$ select 'k' || md5(random()::text || clock_timestamp()::text) $$;
create temp table ids (name text primary key, id uuid not null);
create function pg_temp.id(p_name text) returns uuid language sql stable as
  $$ select id from ids where name = p_name $$;
create function pg_temp.m(n int, p_office uuid default null) returns uuid language sql stable as $$
  select id from org.memberships
  where user_id = pg_temp.u(n) and status = 'active' and office_id is not distinct from p_office
  order by started_at desc, id limit 1
$$;
create function pg_temp.ws(n int) returns uuid language sql stable as $$
  select id from org.memberships where user_id = pg_temp.u(n) and status = 'active'
  order by (role = 'member'), started_at limit 1
$$;
create function pg_temp.ct() returns text language sql volatile as
  $$ select encode(extensions.gen_random_bytes(38), 'base64') $$;
create function pg_temp.add_account(n int, p_bank text, p_number text, p_name text) returns uuid
language plpgsql volatile as $$
declare
  lookup uuid;
begin
  lookup := (api.prepare_account_lookup(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_bank, pg_temp.ct(), 1,
    encode(extensions.digest(p_bank || ':' || p_number, 'sha256'), 'hex'), right(p_number, 4), null,
    pg_temp.k())->>'lookupId')::uuid;
  perform api.record_account_lookup(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), lookup, 'resolved', p_name);
  return (api.confirm_payout_account(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), lookup, null, pg_temp.k())
    ->'payoutAccount'->>'payoutAccountId')::uuid;
end $$;
create function pg_temp.income_receipt(n int, p_target uuid, p_key text) returns uuid language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_target, p_key, 'r.pdf',
    'application/pdf', 1000, repeat('b', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 1000, repeat('b', 64),
    'application/pdf');
  return e;
end $$;
create function pg_temp.seg(n int) returns uuid language sql stable as $$
  select b.account_id from ledger.balances b join ledger.pockets p on p.id = b.pocket_id
  where b.owner_user_id = pg_temp.u(n) and p.name = 'Point Value' and b.currency = 'NGN'
$$;
create function pg_temp.wd(n int, p_amount text, p_reason text, p_key text default null) returns jsonb
language sql volatile as $$
  select api.request_withdrawal(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), pg_temp.seg(4), p_amount,
    pg_temp.id('A4'), p_reason, coalesce(p_key, pg_temp.k()))
$$;
-- The error code and details.field a statement fails with.
create function pg_temp.fails(p_sql text) returns text language plpgsql as $$
declare
  msg text;
  detail text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics msg = message_text, detail = pg_exception_detail;
  return msg || ':' || coalesce(detail::jsonb->>'field', '');
end $$;
create function pg_temp.payout_receipt(n int, p_withdrawal uuid, p_key text) returns uuid language plpgsql as $$
declare
  e uuid;
begin
  e := (api.create_payout_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), p_withdrawal, p_key, 'pay.pdf',
    'application/pdf', 2000, repeat('c', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload(pg_temp.u(n), pg_temp.s(n), pg_temp.ws(n), e, 2000, repeat('c', 64),
    'application/pdf');
  return e;
end $$;

-- 1 President · 2 Director (D) · 3 TL (T) · 4 member (T) · 9 admin
insert into auth.users (id, email, aud, role)
select pg_temp.u(n), 'u' || n || '@example.test', 'authenticated', 'authenticated' from unnest(array[1, 2, 3, 4, 9]) n;
insert into founders.approved (user_id, source) select user_id, 'existing' from identity.accounts on conflict do nothing;
insert into auth.sessions (id, user_id, created_at, updated_at)
select pg_temp.s(n), pg_temp.u(n), now(), now() from unnest(array[1, 2, 3, 4, 9]) n;
do $$ begin perform api.set_pin(pg_temp.u(n), pg_temp.s(n), repeat('a', 64)) from unnest(array[1, 2, 3, 4, 9]) n; end $$;
insert into identity.platform_admins (user_id, grant_reason) values (pg_temp.u(9), 'Test admin');
insert into ids
select 'tenant', (api.start_network(pg_temp.u(1), pg_temp.s(1), 'Lagos Network', 'LGN', pg_temp.k())->>'tenantId')::uuid;
do $$ begin
  perform api.activate_tenant(pg_temp.u(9), pg_temp.s(9), pg_temp.id('tenant'), 'Pilot', pg_temp.k());
end $$;
insert into ids
select 'D', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'director', 'Ikeja', null,
  array[pg_temp.uid(2)], pg_temp.k())->>'officeId')::uuid;
insert into ids
select 'T', (api.create_office(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), 'team_leader', 'Team A', pg_temp.id('D'),
  array[pg_temp.uid(3)], pg_temp.k())->>'officeId')::uuid;
do $$ begin
  perform api.add_membership(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.id('T'), pg_temp.uid(4), pg_temp.k());
  perform api.record_income(pg_temp.u(1), pg_temp.s(1), pg_temp.m(1), pg_temp.m(4, pg_temp.id('T')), 'NGN', '10000.00',
    'Fiverr', to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null,
    array[pg_temp.income_receipt(1, pg_temp.m(4, pg_temp.id('T')), 'k-income-0000000001')], 'k-income-0000000001');
end $$;
insert into payout.banks (provider, code, name, active) values ('paystack', '058', 'Guaranty Trust Bank', true);
insert into ids select 'A4', pg_temp.add_account(4, '058', '0123456789', 'ADA OBI');
create function pg_temp.item_path(p_kind text, p_withdrawal uuid, p_user int) returns text language sql stable as $$
  select params->>'path' from notify.items
  where kind = p_kind and subject_id = p_withdrawal and user_id = pg_temp.u(p_user)
$$;
create function pg_temp.mail_path(p_template text, p_withdrawal uuid, p_user int) returns text language sql stable as $$
  select params->>'path' from outbox.events
  where template = p_template and aggregate_id = p_withdrawal and recipient_user_id = pg_temp.u(p_user)
$$;

create temp table w1 as select pg_temp.wd(4, '1500.00', 'School fees for the term') as r;
insert into ids select 'w1', (r->>'withdrawalId')::uuid from w1;
create temp table w2 as select pg_temp.wd(4, '200.00', 'Rent for March') as r;
insert into ids select 'w2', (r->>'withdrawalId')::uuid from w2;
create temp table w3 as select pg_temp.wd(4, '300.00', 'Phone repair') as r;
insert into ids select 'w3', (r->>'withdrawalId')::uuid from w3;

-- ── Requested (4) ──
select is(pg_temp.item_path('money.withdrawal_submitted', pg_temp.id('w1'), 4),
  '/app/withdrawals/' || pg_temp.id('w1'), 'the owner''s bell item opens that withdrawal');
select is(pg_temp.mail_path('money.withdrawal_submitted', pg_temp.id('w1'), 4),
  '/app/withdrawals/' || pg_temp.id('w1'), 'so does M02');
select is(pg_temp.item_path('task.withdrawal_approve', pg_temp.id('w1'), 3),
  '/app/queue?withdrawal=' || pg_temp.id('w1'), 'the approver''s task still opens the queue');
select is(pg_temp.mail_path('money.withdrawal_awaiting_approval', pg_temp.id('w1'), 3),
  '/app/queue?withdrawal=' || pg_temp.id('w1'), 'and so does M03');

-- ── Approved, then completed (3) ──
do $$ begin
  perform api.approve_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w1'), pg_temp.k());
end $$;
select is(pg_temp.item_path('money.withdrawal_approved', pg_temp.id('w1'), 4),
  '/app/withdrawals/' || pg_temp.id('w1'), 'approved opens that withdrawal');
select is(pg_temp.item_path('task.payout_record', pg_temp.id('w1'), 3),
  '/app/queue?withdrawal=' || pg_temp.id('w1'), 'the payout task still opens the queue');
create temp table p1 as select api.record_payout(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w1'),
  '1500.00', null, to_char(now() at time zone 'Africa/Lagos', 'YYYY-MM-DD'), '000014261005', null,
  pg_temp.payout_receipt(3, pg_temp.id('w1'), 'k-payout-000000001'), 'k-payout-000000001') as r;
create temp table claim as select api.claim_payout_checks('test-worker', 10) as r;
do $$ begin
  perform api.finish_payout_check((select (r->0->>'checkId')::uuid from claim),
    (select (r->0->>'leaseToken')::uuid from claim), 'match',
    jsonb_build_object('paymentDate', to_char(now() at time zone 'Africa/Lagos', 'YYYY-MM-DD'),
      'receipt', jsonb_build_object('amount', '1500.00', 'currency', 'NGN', 'recipientAccount', '0123456789',
        'recipientName', 'ADA OBI', 'paymentStatus', 'successful', 'confidence', 'high')),
    '{}'::text[], 'gpt-5-mini', 'strict-single-receipt-v1');
end $$;
select is(pg_temp.item_path('money.withdrawal_completed', pg_temp.id('w1'), 4),
  '/app/withdrawals/' || pg_temp.id('w1'), 'completed opens that withdrawal');

-- ── Not approved and cancelled (3) ──
do $$ begin
  perform api.reject_withdrawal(pg_temp.u(3), pg_temp.s(3), pg_temp.ws(3), pg_temp.id('w2'), 'Wrong pocket',
    pg_temp.k());
  perform api.cancel_withdrawal(pg_temp.u(4), pg_temp.s(4), pg_temp.ws(4), pg_temp.id('w3'), null, pg_temp.k());
end $$;
select is(pg_temp.item_path('money.withdrawal_not_approved', pg_temp.id('w2'), 4),
  '/app/withdrawals/' || pg_temp.id('w2'), 'not approved opens that withdrawal');
select is(pg_temp.mail_path('money.withdrawal_not_approved', pg_temp.id('w2'), 4),
  '/app/withdrawals/' || pg_temp.id('w2'), 'and so does its email');
select is(pg_temp.item_path('money.withdrawal_cancelled', pg_temp.id('w3'), 4),
  '/app/withdrawals/' || pg_temp.id('w3'), 'cancelled opens that withdrawal');

-- ── Shape (2) ──
select is((select count(*)::int from notify.items where user_id = pg_temp.u(4) and kind like 'money.withdrawal_%'
    and params->>'path' !~ '^/app/withdrawals/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'), 0,
  'every new owner item matches the allow-listed detail path');
select is((select count(*)::int from notify.items where user_id <> pg_temp.u(4)
    and params->>'path' like '/app/withdrawals%'), 0, 'no one else gets the owner''s detail link');

select * from finish();
rollback;
