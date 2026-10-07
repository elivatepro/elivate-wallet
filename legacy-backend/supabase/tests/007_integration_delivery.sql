begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

create temporary table integration_test_ids (
  key text primary key,
  id uuid not null
);

insert into internal.outbox_events (
  id,
  aggregate_type,
  aggregate_id,
  event_type,
  payload,
  occurred_at,
  available_at
)
values (
  'f0000000-0000-4000-8000-000000000001',
  'integration_test',
  'f1000000-0000-4000-8000-000000000001',
  'integration_delivery_requested',
  jsonb_build_object('safe_reference', 'first'),
  '2000-01-01 00:00:00+00',
  '2000-01-01 00:00:00+00'
);

select is(
  (
    select status
      from internal.outbox_delivery_state
     where outbox_event_id = 'f0000000-0000-4000-8000-000000000001'
  ),
  'pending'::internal.integration_delivery_status,
  'new outbox events receive pending delivery state transactionally'
);

create temporary table current_claim as
select *
  from internal.claim_outbox_deliveries(
    'fa000000-0000-4000-8000-000000000001',
    1,
    60,
    '2000-01-01 00:00:00+00'
  );

insert into integration_test_ids (key, id)
select 'first_lease', lease_token from current_claim;

select is(
  (select count(*) from current_claim),
  1::bigint,
  'a ready outbox event is claimed once'
);
select is(
  (select idempotency_key from current_claim),
  'outbox:f0000000-0000-4000-8000-000000000001',
  'the downstream idempotency key is stable by outbox event identity'
);
select is(
  (
    select status
      from internal.outbox_delivery_state
     where outbox_event_id = 'f0000000-0000-4000-8000-000000000001'
  ),
  'processing'::internal.integration_delivery_status,
  'claiming creates an active processing lease'
);
select is(
  (
    select count(*)
      from internal.claim_outbox_deliveries(
        'fa000000-0000-4000-8000-000000000002',
        1,
        60,
        '2000-01-01 00:00:30+00'
      )
  ),
  0::bigint,
  'an active lease cannot be claimed by another worker'
);

select is(
  internal.fail_outbox_delivery(
    'f0000000-0000-4000-8000-000000000001',
    (select id from integration_test_ids where key = 'first_lease'),
    'test_provider',
    'provider_unavailable',
    true,
    null,
    503,
    25,
    '2000-01-01 00:00:01+00'
  ),
  'retry_scheduled'::internal.integration_delivery_status,
  'retryable failures schedule another delivery attempt'
);
select is(
  (
    select next_attempt_at
      from internal.outbox_delivery_state
     where outbox_event_id = 'f0000000-0000-4000-8000-000000000001'
  ),
  '2000-01-01 00:00:16+00'::timestamptz,
  'retry backoff is deterministic from the completed attempt number'
);
select is(
  (
    select count(*)
      from internal.claim_outbox_deliveries(
        'fa000000-0000-4000-8000-000000000002',
        1,
        60,
        '2000-01-01 00:00:15+00'
      )
  ),
  0::bigint,
  'retry-scheduled work cannot be claimed before it is due'
);

truncate table current_claim;
insert into current_claim
select *
  from internal.claim_outbox_deliveries(
    'fa000000-0000-4000-8000-000000000002',
    1,
    60,
    '2000-01-01 00:00:16+00'
  );
insert into integration_test_ids (key, id)
select 'second_lease', lease_token from current_claim;

select is(
  (select attempt_number from current_claim),
  2,
  'a due retry increments the attempt number'
);
select ok(
  internal.complete_outbox_delivery(
    'f0000000-0000-4000-8000-000000000001',
    (select id from integration_test_ids where key = 'second_lease'),
    'test_provider',
    'provider-message-1',
    202,
    30,
    '2000-01-01 00:00:17+00'
  ),
  'an active lease can complete its outbox delivery'
);
select is(
  internal.complete_outbox_delivery(
    'f0000000-0000-4000-8000-000000000001',
    (select id from integration_test_ids where key = 'second_lease'),
    'test_provider',
    'provider-message-1',
    202,
    30,
    '2000-01-01 00:00:18+00'
  ),
  false,
  'completion acknowledgement is idempotent for the same lease'
);
select is(
  internal.fail_outbox_delivery(
    'f0000000-0000-4000-8000-000000000001',
    (select id from integration_test_ids where key = 'first_lease'),
    'test_provider',
    'provider_unavailable',
    true,
    null,
    503,
    25,
    '2000-01-01 00:00:19+00'
  ),
  'retry_scheduled'::internal.integration_delivery_status,
  'a duplicate old failure returns its original deterministic result'
);
select is(
  (
    select array_agg(outcome order by attempt_number)
      from internal.integration_delivery_attempts
     where outbox_event_id = 'f0000000-0000-4000-8000-000000000001'
  ),
  array[
    'retryable_failure'::internal.integration_attempt_outcome,
    'delivered'::internal.integration_attempt_outcome
  ],
  'delivery attempts preserve append-only failure and success history'
);

insert into internal.outbox_events (
  id,
  aggregate_type,
  aggregate_id,
  event_type,
  occurred_at,
  available_at
)
values (
  'f0000000-0000-4000-8000-000000000002',
  'integration_test',
  'f1000000-0000-4000-8000-000000000002',
  'integration_lease_test',
  '2000-01-02 00:00:00+00',
  '2000-01-02 00:00:00+00'
);

truncate table current_claim;
insert into current_claim
select *
  from internal.claim_outbox_deliveries(
    'fa000000-0000-4000-8000-000000000003',
    1,
    5,
    '2000-01-02 00:00:00+00'
  );
insert into integration_test_ids (key, id)
select 'expired_lease', lease_token from current_claim;

truncate table current_claim;
insert into current_claim
select *
  from internal.claim_outbox_deliveries(
    'fa000000-0000-4000-8000-000000000004',
    1,
    60,
    '2000-01-02 00:00:06+00'
  );
insert into integration_test_ids (key, id)
select 'recovered_lease', lease_token from current_claim;

select ok(
  (select id from integration_test_ids where key = 'expired_lease')
    <> (select id from integration_test_ids where key = 'recovered_lease'),
  'an expired lease is recovered with a new token'
);
select is(
  (
    select outcome
      from internal.integration_delivery_attempts
     where outbox_event_id = 'f0000000-0000-4000-8000-000000000002'
       and attempt_number = 1
  ),
  'lease_expired'::internal.integration_attempt_outcome,
  'lease recovery records the abandoned attempt'
);
select throws_ok(
  format(
    $sql$select internal.complete_outbox_delivery(
      'f0000000-0000-4000-8000-000000000002',
      %L::uuid,
      'test_provider', null, 202, 1,
      '2000-01-02 00:00:07+00'
    )$sql$,
    (select id from integration_test_ids where key = 'expired_lease')
  ),
  '55000',
  'outbox delivery lease is not active',
  'a stale worker cannot acknowledge a recovered lease'
);
select throws_ok(
  format(
    $sql$select internal.fail_outbox_delivery(
      'f0000000-0000-4000-8000-000000000002',
      %L::uuid,
      'test_provider', 'provider_unavailable', true, null, 503, 1,
      '2000-01-02 00:00:07+00'
    )$sql$,
    (select id from integration_test_ids where key = 'expired_lease')
  ),
  '55000',
  'outbox delivery lease is not active',
  'an expired lease cannot acknowledge a provider failure'
);
select is(
  internal.fail_outbox_delivery(
    'f0000000-0000-4000-8000-000000000002',
    (select id from integration_test_ids where key = 'recovered_lease'),
    'test_provider',
    'invalid_destination',
    false,
    null,
    400,
    20,
    '2000-01-02 00:00:07+00'
  ),
  'dead_lettered'::internal.integration_delivery_status,
  'permanent failures dead-letter immediately'
);
select is(
  internal.requeue_dead_letter_delivery(
    'f0000000-0000-4000-8000-000000000002',
    'destination_corrected',
    'operator:test',
    '2000-01-02 00:00:08+00'
  ),
  2,
  'a trusted operator can requeue a dead letter into a new delivery cycle'
);
select is(
  (
    select count(*)
      from internal.outbox_delivery_requeues
     where outbox_event_id = 'f0000000-0000-4000-8000-000000000002'
  ),
  1::bigint,
  'requeue history is durable and separate from delivery attempts'
);

truncate table current_claim;
insert into current_claim
select *
  from internal.claim_outbox_deliveries(
    'fa000000-0000-4000-8000-000000000005',
    1,
    60,
    '2000-01-02 00:00:08+00'
  );
select is(
  (select delivery_cycle from current_claim),
  2,
  'requeued work is claimed in the new delivery cycle'
);
select is(
  (select attempt_number from current_claim),
  1,
  'requeue resets attempt numbering without deleting prior history'
);
select ok(
  internal.complete_outbox_delivery(
    'f0000000-0000-4000-8000-000000000002',
    (select lease_token from current_claim),
    'test_provider',
    'provider-message-2',
    202,
    15,
    '2000-01-02 00:00:09+00'
  ),
  'the requeued fixture is completed before the next claim scenario'
);

insert into internal.outbox_events (
  id,
  aggregate_type,
  aggregate_id,
  event_type,
  occurred_at,
  available_at
)
values (
  'f0000000-0000-4000-8000-000000000003',
  'integration_test',
  'f1000000-0000-4000-8000-000000000003',
  'integration_attempt_limit_test',
  '2000-01-03 00:00:00+00',
  '2000-01-03 00:00:00+00'
);
update internal.outbox_delivery_state
   set max_attempts = 1
 where outbox_event_id = 'f0000000-0000-4000-8000-000000000003';

truncate table current_claim;
insert into current_claim
select *
  from internal.claim_outbox_deliveries(
    'fa000000-0000-4000-8000-000000000006',
    1,
    60,
    '2000-01-03 00:00:00+00'
  );
select is(
  internal.fail_outbox_delivery(
    'f0000000-0000-4000-8000-000000000003',
    (select lease_token from current_claim),
    'test_provider',
    'provider_unavailable',
    true,
    null,
    503,
    10,
    '2000-01-03 00:00:01+00'
  ),
  'dead_lettered'::internal.integration_delivery_status,
  'retryable failures dead-letter after the bounded attempt limit'
);

select is(internal.delivery_retry_delay_seconds(1), 15, 'retry one waits 15 seconds');
select is(internal.delivery_retry_delay_seconds(2), 30, 'retry two doubles the delay');
select is(internal.delivery_retry_delay_seconds(25), 3600, 'retry delay is capped at one hour');

select throws_ok(
  $$select * from internal.claim_outbox_deliveries(
    'fa000000-0000-4000-8000-000000000007', 0, 60,
    '2000-01-04 00:00:00+00'
  )$$,
  '22023',
  'batch size must be between 1 and 100',
  'invalid worker batch sizes are rejected'
);
select throws_ok(
  format(
    $sql$select internal.fail_outbox_delivery(
      'f0000000-0000-4000-8000-000000000002',
      %L::uuid,
      'test_provider',
      'contains secret data',
      true
    )$sql$,
    (select lease_token from current_claim)
  ),
  '22023',
  'error code is invalid',
  'free-form provider errors cannot enter delivery history'
);

select throws_ok(
  $$update internal.integration_delivery_attempts
       set error_code = 'rewritten'
     where outbox_event_id = 'f0000000-0000-4000-8000-000000000001'$$,
  '55000',
  'internal.integration_delivery_attempts is append-only',
  'delivery attempt history cannot be rewritten'
);
select throws_ok(
  $$delete from internal.outbox_delivery_requeues
     where outbox_event_id = 'f0000000-0000-4000-8000-000000000002'$$,
  '55000',
  'internal.outbox_delivery_requeues is append-only',
  'dead-letter requeue history cannot be deleted'
);

select ok(
  not has_schema_privilege('authenticated', 'internal', 'usage')
  and not has_table_privilege(
    'authenticated',
    'internal.outbox_delivery_state',
    'select'
  )
  and not has_table_privilege(
    'service_role',
    'internal.integration_delivery_attempts',
    'insert'
  ),
  'clients and service role have no direct integration-table access'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'internal.claim_outbox_deliveries(uuid,integer,integer,timestamptz)',
    'execute'
  )
  and not has_function_privilege(
    'service_role',
    'internal.complete_outbox_delivery(uuid,uuid,text,text,integer,integer,timestamptz)',
    'execute'
  ),
  'integration worker commands are not client or service-role endpoints'
);
select is(
  (
    select count(*)
      from pg_class relation
      join pg_namespace namespace on namespace.oid = relation.relnamespace
     where namespace.nspname = 'internal'
       and relation.relname in (
         'outbox_delivery_state',
         'integration_delivery_attempts',
         'outbox_delivery_requeues'
       )
       and relation.relrowsecurity
       and relation.relforcerowsecurity
  ),
  3::bigint,
  'every integration delivery table has RLS enabled and forced'
);
select is(
  (
    select count(*)
      from pg_policy policy
      join pg_class relation on relation.oid = policy.polrelid
      join pg_namespace namespace on namespace.oid = relation.relnamespace
     where namespace.nspname = 'internal'
       and relation.relname in (
         'outbox_delivery_state',
         'integration_delivery_attempts',
         'outbox_delivery_requeues'
       )
       and not policy.polpermissive
       and pg_get_expr(policy.polqual, policy.polrelid) = 'false'
       and pg_get_expr(policy.polwithcheck, policy.polrelid) = 'false'
  ),
  3::bigint,
  'every integration delivery table has a restrictive deny policy'
);
select ok(
  pg_get_functiondef(
    'internal.claim_outbox_deliveries(uuid,integer,integer,timestamptz)'::regprocedure
  ) ilike '%for update of state skip locked%',
  'worker claims use non-blocking row locks'
);

do $$
begin
  if (select status from internal.outbox_delivery_state
       where outbox_event_id = 'f0000000-0000-4000-8000-000000000001')
       <> 'delivered'
     or (select count(*) from internal.integration_delivery_attempts
          where outbox_event_id = 'f0000000-0000-4000-8000-000000000001') <> 2
     or (select delivery_cycle from internal.outbox_delivery_state
          where outbox_event_id = 'f0000000-0000-4000-8000-000000000002') <> 2
     or (select status from internal.outbox_delivery_state
          where outbox_event_id = 'f0000000-0000-4000-8000-000000000003')
       <> 'dead_lettered'
     or has_table_privilege(
       'authenticated', 'internal.outbox_delivery_state', 'select'
     )
     or has_function_privilege(
       'service_role',
       'internal.claim_outbox_deliveries(uuid,integer,integer,timestamptz)',
       'execute'
     ) then
    raise exception using
      errcode = 'P0001',
      message = 'integration delivery aggregate acceptance guard failed';
  end if;
end;
$$;

select * from finish();
rollback;
