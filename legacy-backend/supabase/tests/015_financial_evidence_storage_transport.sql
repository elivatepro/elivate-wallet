begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(11);

select extensions.is(
  (select public from storage.buckets where id = 'financial-evidence'),
  false,
  'financial evidence bucket is private'
);

select extensions.is(
  (select file_size_limit from storage.buckets where id = 'financial-evidence'),
  52428800::bigint,
  'financial evidence bucket has a 50 MiB limit'
);

select extensions.is(
  (select relforcerowsecurity from pg_class
    where oid = 'evidence.financial_upload_intents'::regclass),
  true,
  'upload intents use forced RLS'
);

select extensions.is(
  has_function_privilege(
    'service_role',
    'evidence.request_financial_evidence_upload(uuid,uuid,text,uuid,text,text,text,bigint,text)',
    'EXECUTE'
  ),
  true,
  'trusted transport can request an upload intent'
);

select extensions.is(
  has_function_privilege(
    'service_role',
    'evidence.finalize_financial_evidence_upload(uuid,uuid,bigint,text,timestamptz,text,text,text)',
    'EXECUTE'
  ),
  true,
  'trusted transport can finalize an upload intent'
);

select extensions.isnt(
  has_function_privilege(
    'authenticated',
    'evidence.request_financial_evidence_upload(uuid,uuid,text,uuid,text,text,text,bigint,text)',
    'EXECUTE'
  ),
  true,
  'authenticated clients cannot call the upload command directly'
);

select extensions.isnt(
  has_function_privilege(
    'authenticated',
    'evidence.finalize_financial_evidence_upload(uuid,uuid,bigint,text,timestamptz,text,text,text)',
    'EXECUTE'
  ),
  true,
  'authenticated clients cannot call finalization directly'
);

select extensions.throws_ok(
  $$select evidence.request_financial_evidence_upload(
    '00000000-0000-0000-0000-000000000201',
    '00000000-0000-0000-0000-000000000202',
    'income_record',
    '00000000-0000-0000-0000-000000000203',
    'income',
    'receipt.exe',
    'application/x-msdownload',
    10,
    '0000000000000000000000000000000000000000000000000000000000000000'
  )$$,
  '22023',
  'financial evidence upload input is invalid',
  'upload intent rejects unsupported MIME types'
);

select extensions.throws_ok(
  $$select evidence.request_financial_evidence_upload(
    '00000000-0000-0000-0000-000000000204',
    '00000000-0000-0000-0000-000000000205',
    'income_record',
    '00000000-0000-0000-0000-000000000206',
    'income',
    'receipt.pdf',
    'application/pdf',
    10,
    '0000000000000000000000000000000000000000000000000000000000000000'
  )$$,
  'P0002',
  'financial evidence target was not found',
  'upload intent derives ownership from an existing financial target'
);

select extensions.throws_ok(
  $$select evidence.finalize_financial_evidence_upload(
    '00000000-0000-0000-0000-000000000207',
    '00000000-0000-0000-0000-000000000208',
    10,
    '0000000000000000000000000000000000000000000000000000000000000000',
    clock_timestamp()
  )$$,
  'P0002',
  'financial evidence upload intent was not found',
  'finalization requires a server-created upload intent'
);

select extensions.is(
  (select prosecdef from pg_proc
    where oid = 'evidence.finalize_financial_evidence_upload(uuid,uuid,bigint,text,timestamptz,text,text,text)'::regprocedure),
  true,
  'finalization is a security-definer trusted boundary'
);

select extensions.finish();
rollback;
