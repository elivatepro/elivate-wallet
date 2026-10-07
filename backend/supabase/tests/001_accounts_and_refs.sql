begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, email, aud, role)
values ('00000000-0000-0000-0000-0000000000a1', 'a1@example.test', 'authenticated', 'authenticated');

select ok(
  (select uid ~ '^EW-[1-9][0-9]{4}$' from identity.accounts where user_id = '00000000-0000-0000-0000-0000000000a1'),
  'signup creates an account with a five-digit EW- UID'
);
select is(
  (select status::text from identity.accounts where user_id = '00000000-0000-0000-0000-0000000000a1'),
  'active', 'new accounts are active'
);
select ok(
  exists (select 1 from identity.profiles where user_id = '00000000-0000-0000-0000-0000000000a1'),
  'signup creates a profile'
);
select throws_ok(
  $$ update identity.accounts set uid = 'EW-12345' where user_id = '00000000-0000-0000-0000-0000000000a1' $$,
  'P0001', 'invariant_violation', 'UID cannot change'
);

create temp table generated_refs as
select refs.issue((array['WDR', 'INV', 'WRQ', 'STM'])[1 + i % 4]) as code
from generate_series(1, 1000) i;

select is(
  (select count(*) from generated_refs
   where code ~ '^(WDR|INV|WRQ|STM)-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$')::int,
  1000, 'references use <TYPE>-XXXX-XXXX in Crockford Base32'
);
select is((select count(distinct code) from generated_refs)::int, 1000, 'references are unique');
select is(
  (select count(*) from refs.issued where code in (select code from generated_refs))::int,
  1000, 'every issued reference is kept so none is reused'
);
select throws_ok($$ select refs.issue('ABC') $$, '23514', null, 'unknown reference types are rejected');
select throws_ok(
  $$ delete from audit.security_events $$, 'P0001', 'invariant_violation', 'audit events are append-only'
);

select * from finish();
rollback;
