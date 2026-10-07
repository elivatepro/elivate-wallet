begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(58);

-- These claims model PostgREST's verified JWT context; no remote Auth data is changed.
insert into auth.users(id,email) values
 ('20000000-0000-0000-0000-000000000001','step-up-owner@example.test'),
 ('20000000-0000-0000-0000-000000000002','step-up-other@example.test');
insert into public.user_accounts(user_id,status) values
 ('20000000-0000-0000-0000-000000000001','active'),
 ('20000000-0000-0000-0000-000000000002','active');
insert into auth.sessions(id,user_id,aal,created_at,updated_at) values
 ('20000000-0000-0000-0000-000000000101','20000000-0000-0000-0000-000000000001','aal2',now(),now()),
 ('20000000-0000-0000-0000-000000000102','20000000-0000-0000-0000-000000000001','aal2',now(),now()),
 ('20000000-0000-0000-0000-000000000103','20000000-0000-0000-0000-000000000002','aal2',now(),now());
select set_config('test.step_up_epoch',floor(extract(epoch from clock_timestamp() - interval '1 minute'))::text,true);

create function pg_temp.step_up_claims(patch jsonb default '{}'::jsonb)
returns text language sql as $$
 select set_config('request.jwt.claims',jsonb_strip_nulls(jsonb_build_object(
  'sub','20000000-0000-0000-0000-000000000001',
  'role','authenticated','aal','aal2',
  'session_id','20000000-0000-0000-0000-000000000101',
  'amr',jsonb_build_array(jsonb_build_object('method','totp','timestamp',current_setting('test.step_up_epoch')::numeric))
 ) || patch)::text,true);
$$;
-- Empty legacy per-claim settings force auth helpers to read the complete claims object.
select set_config('request.jwt.claim.sub','',true);
select set_config('request.jwt.claim.role','',true);

select extensions.is(has_function_privilege('authenticated','public.establish_step_up()','EXECUTE'),true,'authenticated can execute public.establish_step_up()');

select extensions.is(has_function_privilege('authenticated','public.current_step_up()','EXECUTE'),true,'authenticated can execute public.current_step_up()');

select extensions.is(has_function_privilege('anon','public.establish_step_up()','EXECUTE'),false,'anon cannot execute public.establish_step_up()');

select extensions.is(has_function_privilege('anon','public.current_step_up()','EXECUTE'),false,'anon cannot execute public.current_step_up()');

select extensions.is(has_function_privilege('service_role','public.establish_step_up()','EXECUTE'),false,'service_role cannot execute public.establish_step_up()');

select extensions.is(has_function_privilege('service_role','public.current_step_up()','EXECUTE'),false,'service_role cannot execute public.current_step_up()');

select extensions.is(has_function_privilege('authenticated','authz.establish_step_up()','EXECUTE'),false,'authenticated cannot execute private issuer');

select extensions.is(has_function_privilege('anon','authz.establish_step_up()','EXECUTE'),false,'anon cannot execute private issuer');

select extensions.is(has_function_privilege('service_role','authz.establish_step_up()','EXECUTE'),false,'service_role cannot execute private issuer');

set local role anon;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'anonymous role cannot call issuer');

select extensions.throws_ok('select public.current_step_up()', '42501', null, 'anonymous role cannot read elevation');

reset role;
set local role service_role;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'service role cannot mint user verification');

reset role;
select pg_temp.step_up_claims('{"sub":null}'::jsonb);
set local role authenticated;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'missing actor is rejected');

reset role;
select pg_temp.step_up_claims('{"role":null}'::jsonb);
set local role authenticated;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'missing authenticated role is rejected');

reset role;
select pg_temp.step_up_claims('{"role":"service_role"}'::jsonb);
set local role authenticated;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'privileged role claim cannot mint user verification');

reset role;
select pg_temp.step_up_claims('{"aal":"aal1"}'::jsonb);
set local role authenticated;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'password-only JWT is rejected');

reset role;
select pg_temp.step_up_claims('{"aal":null}'::jsonb);
set local role authenticated;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'missing assurance level is rejected');

reset role;
select pg_temp.step_up_claims('{"session_id":null}'::jsonb);
set local role authenticated;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'missing session is rejected');

reset role;
select pg_temp.step_up_claims('{"session_id":"not-a-uuid"}'::jsonb);
set local role authenticated;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'malformed session is rejected');

reset role;
select pg_temp.step_up_claims('{"session_id":"20000000-0000-0000-0000-000000000199"}'::jsonb);
set local role authenticated;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'nonexistent Auth session is rejected');

reset role;
select pg_temp.step_up_claims('{"session_id":"20000000-0000-0000-0000-000000000103"}'::jsonb);
set local role authenticated;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'another account Auth session is rejected');

reset role;
select pg_temp.step_up_claims('{"amr":null}'::jsonb);
set local role authenticated;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'missing proof is rejected');

reset role;
select pg_temp.step_up_claims('{"amr":{}}'::jsonb);
set local role authenticated;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'non-array proof is rejected');

reset role;
select pg_temp.step_up_claims('{"amr":[]}'::jsonb);
set local role authenticated;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'empty proof is rejected');

reset role;
select pg_temp.step_up_claims('{"amr":[{"method":"password","timestamp":1}]}'::jsonb);
set local role authenticated;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'password proof cannot establish elevation');

reset role;
select pg_temp.step_up_claims('{"amr":[{"method":"totp","timestamp":"123"}]}'::jsonb);
set local role authenticated;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'string proof timestamp is rejected');

reset role;
select pg_temp.step_up_claims(jsonb_build_object('amr',jsonb_build_array(jsonb_build_object('method','totp','timestamp',extract(epoch from clock_timestamp() - interval '6 minutes')))));
set local role authenticated;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'stale TOTP proof is rejected');

reset role;
select pg_temp.step_up_claims(jsonb_build_object('amr',jsonb_build_array(jsonb_build_object('method','totp','timestamp',extract(epoch from clock_timestamp() + interval '1 minute')))));
set local role authenticated;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'future TOTP proof is rejected');

reset role;

select extensions.is((select count(*) from authz.elevated_sessions where user_id='20000000-0000-0000-0000-000000000001'),0::bigint,'rejected proofs create no elevation');
update auth.sessions set aal='aal1' where id='20000000-0000-0000-0000-000000000101';

reset role;
select pg_temp.step_up_claims('{}'::jsonb);
set local role authenticated;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'database session must also have second-factor assurance');
reset role;
update auth.sessions set aal='aal2' where id='20000000-0000-0000-0000-000000000101';

reset role;
select pg_temp.step_up_claims('{}'::jsonb);
set local role authenticated;

select extensions.lives_ok('select public.establish_step_up()', 'verified current session establishes elevation');

select extensions.is((public.current_step_up()->>'verified_at')::timestamptz,to_timestamp(current_setting('test.step_up_epoch')::double precision),'verification time is anchored to Auth proof');

select extensions.is((public.current_step_up()->>'valid_until')::timestamptz,to_timestamp(current_setting('test.step_up_epoch')::double precision)+interval '5 minutes','window ends five minutes after proof, not RPC call');

select extensions.lives_ok('select public.establish_step_up()', 'identical proof retry succeeds idempotently');

select extensions.is((public.current_step_up()->>'valid_until')::timestamptz,to_timestamp(current_setting('test.step_up_epoch')::double precision)+interval '5 minutes','retry does not extend the verification window');
reset role;

select extensions.is((select count(*) from authz.security_audit_events where actor_user_id='20000000-0000-0000-0000-000000000001' and event_type='authentication.step_up_established'),1::bigint,'idempotent retries emit only one audit event');

select extensions.ok(authz.is_elevated_session_valid('20000000-0000-0000-0000-000000000101','20000000-0000-0000-0000-000000000001'),'current session elevation is valid');

select pg_temp.step_up_claims('{"aal":"aal1"}'::jsonb);
set local role authenticated;
select extensions.is(public.current_step_up(),null::jsonb,'older password-only JWT cannot consume upgraded session elevation');
reset role;
select pg_temp.step_up_claims('{}'::jsonb);
update auth.sessions set aal='aal1' where id='20000000-0000-0000-0000-000000000101';
set local role authenticated;
select extensions.is(public.current_step_up(),null::jsonb,'Auth session assurance downgrade invalidates existing elevation');
reset role;
update auth.sessions set aal='aal2' where id='20000000-0000-0000-0000-000000000101';

reset role;
select pg_temp.step_up_claims('{"session_id":"20000000-0000-0000-0000-000000000102"}'::jsonb);
set local role authenticated;

select extensions.is(public.current_step_up(),null::jsonb,'second login cannot read first login elevation');
reset role;

select extensions.is(authz.is_elevated_session_valid('20000000-0000-0000-0000-000000000101','20000000-0000-0000-0000-000000000001'),false,'same-user different JWT session cannot consume first elevation');

reset role;
select pg_temp.step_up_claims('{"sub":"20000000-0000-0000-0000-000000000002","session_id":"20000000-0000-0000-0000-000000000103"}'::jsonb);
set local role authenticated;

select extensions.is(public.current_step_up(),null::jsonb,'another account cannot read elevation');
reset role;
update authz.elevated_sessions set revoked_at=to_timestamp(current_setting('test.step_up_epoch')::double precision)+interval '5 seconds' where session_id='20000000-0000-0000-0000-000000000101';

reset role;
select pg_temp.step_up_claims('{}'::jsonb);
set local role authenticated;

select extensions.is(public.current_step_up(),null::jsonb,'revoked elevation is hidden');

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'same proof cannot reactivate revoked elevation');

reset role;
select pg_temp.step_up_claims(jsonb_build_object('amr',jsonb_build_array(jsonb_build_object('method','totp','timestamp',current_setting('test.step_up_epoch')::numeric+3))));
set local role authenticated;
select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'proof newer than prior verification but before revocation cannot reactivate elevation');
reset role;
select set_config('test.step_up_epoch',(current_setting('test.step_up_epoch')::numeric+10)::text,true);

reset role;
select pg_temp.step_up_claims('{}'::jsonb);
set local role authenticated;

select extensions.lives_ok('select public.establish_step_up()', 'newer recent proof can establish a new window');
reset role;

select extensions.is((select count(*) from authz.security_audit_events where actor_user_id='20000000-0000-0000-0000-000000000001' and event_type='authentication.step_up_established'),2::bigint,'new verification emits a second audit event');

reset role;
select pg_temp.step_up_claims(jsonb_build_object('amr',jsonb_build_array(jsonb_build_object('method','totp','timestamp',current_setting('test.step_up_epoch')::numeric-1))));
set local role authenticated;

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'older proof cannot overwrite newer verification');
reset role;
update public.user_accounts set status='suspended' where user_id='20000000-0000-0000-0000-000000000001';

reset role;
select pg_temp.step_up_claims('{}'::jsonb);
set local role authenticated;

select extensions.is(public.current_step_up(),null::jsonb,'suspended account loses existing elevation');

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'suspended account cannot establish elevation');
reset role;
update public.user_accounts set status='active' where user_id='20000000-0000-0000-0000-000000000001';
update auth.sessions set not_after=clock_timestamp()-interval '1 second' where id='20000000-0000-0000-0000-000000000101';

reset role;
select pg_temp.step_up_claims('{}'::jsonb);
set local role authenticated;

select extensions.is(public.current_step_up(),null::jsonb,'expired Auth session invalidates elevation');

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'expired Auth session cannot establish elevation');
reset role;
update auth.sessions set not_after=null where id='20000000-0000-0000-0000-000000000101';
update authz.elevated_sessions set verified_at=statement_timestamp()-interval '7 minutes',valid_until=statement_timestamp()-interval '2 minutes' where session_id='20000000-0000-0000-0000-000000000101';

reset role;
select pg_temp.step_up_claims('{}'::jsonb);
set local role authenticated;

select extensions.is(public.current_step_up(),null::jsonb,'expired five-minute window is not current');
reset role;
-- Restore a valid window so the next check isolates Auth session deletion.
update authz.elevated_sessions
set verified_at=to_timestamp(current_setting('test.step_up_epoch')::double precision),
    valid_until=to_timestamp(current_setting('test.step_up_epoch')::double precision)+interval '5 minutes'
where session_id='20000000-0000-0000-0000-000000000101';
select extensions.ok(authz.is_elevated_session_valid('20000000-0000-0000-0000-000000000101','20000000-0000-0000-0000-000000000001'),'restored unexpired elevation is valid before Auth session deletion');
delete from auth.sessions where id='20000000-0000-0000-0000-000000000101';

reset role;
select pg_temp.step_up_claims('{}'::jsonb);
set local role authenticated;

select extensions.is(public.current_step_up(),null::jsonb,'deleted Auth session cannot expose residual elevation');

select extensions.throws_ok('select public.establish_step_up()', '42501', null, 'deleted Auth session cannot reestablish elevation');
reset role;
update auth.sessions set not_after=to_timestamp(current_setting('test.step_up_epoch')::double precision)+interval '2 minutes' where id='20000000-0000-0000-0000-000000000102';

reset role;
select pg_temp.step_up_claims('{"session_id":"20000000-0000-0000-0000-000000000102"}'::jsonb);
set local role authenticated;

select extensions.lives_ok('select public.establish_step_up()', 'second session can independently establish its own elevation');

select extensions.is((public.current_step_up()->>'valid_until')::timestamptz,to_timestamp(current_setting('test.step_up_epoch')::double precision)+interval '2 minutes','Auth session expiry caps the verification window');

reset role;
select extensions.finish();
rollback;
