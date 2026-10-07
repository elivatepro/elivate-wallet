begin;

create extension if not exists pgtap with schema extensions;

set local search_path = public, extensions;

select plan(119);

select ok(not has_function_privilege('anon', 'command_api.create_membership(uuid, uuid, uuid, uuid, uuid, uuid, public.role_key)', 'EXECUTE'), 'anon cannot invoke create_membership');

select ok(not has_function_privilege('authenticated', 'command_api.create_membership(uuid, uuid, uuid, uuid, uuid, uuid, public.role_key)', 'EXECUTE'), 'authenticated cannot invoke create_membership');

select ok(has_function_privilege('service_role', 'command_api.create_membership(uuid, uuid, uuid, uuid, uuid, uuid, public.role_key)', 'EXECUTE'), 'service_role can route create_membership');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.create_membership(uuid, uuid, uuid, uuid, uuid, uuid, public.role_key)'::regprocedure), 'create_membership has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.activate_membership(uuid, uuid, uuid, uuid)', 'EXECUTE'), 'anon cannot invoke activate_membership');

select ok(not has_function_privilege('authenticated', 'command_api.activate_membership(uuid, uuid, uuid, uuid)', 'EXECUTE'), 'authenticated cannot invoke activate_membership');

select ok(has_function_privilege('service_role', 'command_api.activate_membership(uuid, uuid, uuid, uuid)', 'EXECUTE'), 'service_role can route activate_membership');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.activate_membership(uuid, uuid, uuid, uuid)'::regprocedure), 'activate_membership has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.suspend_membership(uuid, uuid, uuid, uuid)', 'EXECUTE'), 'anon cannot invoke suspend_membership');

select ok(not has_function_privilege('authenticated', 'command_api.suspend_membership(uuid, uuid, uuid, uuid)', 'EXECUTE'), 'authenticated cannot invoke suspend_membership');

select ok(has_function_privilege('service_role', 'command_api.suspend_membership(uuid, uuid, uuid, uuid)', 'EXECUTE'), 'service_role can route suspend_membership');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.suspend_membership(uuid, uuid, uuid, uuid)'::regprocedure), 'suspend_membership has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.end_membership(uuid, uuid, uuid, uuid, uuid)', 'EXECUTE'), 'anon cannot invoke end_membership');

select ok(not has_function_privilege('authenticated', 'command_api.end_membership(uuid, uuid, uuid, uuid, uuid)', 'EXECUTE'), 'authenticated cannot invoke end_membership');

select ok(has_function_privilege('service_role', 'command_api.end_membership(uuid, uuid, uuid, uuid, uuid)', 'EXECUTE'), 'service_role can route end_membership');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.end_membership(uuid, uuid, uuid, uuid, uuid)'::regprocedure), 'end_membership has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.move_membership(uuid, uuid, uuid, uuid, uuid, public.role_key)', 'EXECUTE'), 'anon cannot invoke move_membership');

select ok(not has_function_privilege('authenticated', 'command_api.move_membership(uuid, uuid, uuid, uuid, uuid, public.role_key)', 'EXECUTE'), 'authenticated cannot invoke move_membership');

select ok(has_function_privilege('service_role', 'command_api.move_membership(uuid, uuid, uuid, uuid, uuid, public.role_key)', 'EXECUTE'), 'service_role can route move_membership');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.move_membership(uuid, uuid, uuid, uuid, uuid, public.role_key)'::regprocedure), 'move_membership has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.submit_withdrawal(uuid, uuid, uuid, numeric, uuid, uuid)', 'EXECUTE'), 'anon cannot invoke submit_withdrawal');

select ok(not has_function_privilege('authenticated', 'command_api.submit_withdrawal(uuid, uuid, uuid, numeric, uuid, uuid)', 'EXECUTE'), 'authenticated cannot invoke submit_withdrawal');

select ok(has_function_privilege('service_role', 'command_api.submit_withdrawal(uuid, uuid, uuid, numeric, uuid, uuid)', 'EXECUTE'), 'service_role can route submit_withdrawal');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.submit_withdrawal(uuid, uuid, uuid, numeric, uuid, uuid)'::regprocedure), 'submit_withdrawal has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.approve_withdrawal(uuid, uuid, uuid, uuid)', 'EXECUTE'), 'anon cannot invoke approve_withdrawal');

select ok(not has_function_privilege('authenticated', 'command_api.approve_withdrawal(uuid, uuid, uuid, uuid)', 'EXECUTE'), 'authenticated cannot invoke approve_withdrawal');

select ok(has_function_privilege('service_role', 'command_api.approve_withdrawal(uuid, uuid, uuid, uuid)', 'EXECUTE'), 'service_role can route approve_withdrawal');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.approve_withdrawal(uuid, uuid, uuid, uuid)'::regprocedure), 'approve_withdrawal has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.reject_withdrawal(uuid, uuid, uuid, text, uuid)', 'EXECUTE'), 'anon cannot invoke reject_withdrawal');

select ok(not has_function_privilege('authenticated', 'command_api.reject_withdrawal(uuid, uuid, uuid, text, uuid)', 'EXECUTE'), 'authenticated cannot invoke reject_withdrawal');

select ok(has_function_privilege('service_role', 'command_api.reject_withdrawal(uuid, uuid, uuid, text, uuid)', 'EXECUTE'), 'service_role can route reject_withdrawal');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.reject_withdrawal(uuid, uuid, uuid, text, uuid)'::regprocedure), 'reject_withdrawal has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.cancel_withdrawal(uuid, uuid, uuid, text, uuid)', 'EXECUTE'), 'anon cannot invoke cancel_withdrawal');

select ok(not has_function_privilege('authenticated', 'command_api.cancel_withdrawal(uuid, uuid, uuid, text, uuid)', 'EXECUTE'), 'authenticated cannot invoke cancel_withdrawal');

select ok(has_function_privilege('service_role', 'command_api.cancel_withdrawal(uuid, uuid, uuid, text, uuid)', 'EXECUTE'), 'service_role can route cancel_withdrawal');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.cancel_withdrawal(uuid, uuid, uuid, text, uuid)'::regprocedure), 'cancel_withdrawal has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.replace_payout_account(uuid, uuid, uuid, uuid, uuid, text, text, text, text, text, text, text, boolean)', 'EXECUTE'), 'anon cannot invoke replace_payout_account');

select ok(not has_function_privilege('authenticated', 'command_api.replace_payout_account(uuid, uuid, uuid, uuid, uuid, text, text, text, text, text, text, text, boolean)', 'EXECUTE'), 'authenticated cannot invoke replace_payout_account');

select ok(has_function_privilege('service_role', 'command_api.replace_payout_account(uuid, uuid, uuid, uuid, uuid, text, text, text, text, text, text, text, boolean)', 'EXECUTE'), 'service_role can route replace_payout_account');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.replace_payout_account(uuid, uuid, uuid, uuid, uuid, text, text, text, text, text, text, text, boolean)'::regprocedure), 'replace_payout_account has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.deactivate_payout_account(uuid, uuid, uuid, uuid, uuid)', 'EXECUTE'), 'anon cannot invoke deactivate_payout_account');

select ok(not has_function_privilege('authenticated', 'command_api.deactivate_payout_account(uuid, uuid, uuid, uuid, uuid)', 'EXECUTE'), 'authenticated cannot invoke deactivate_payout_account');

select ok(has_function_privilege('service_role', 'command_api.deactivate_payout_account(uuid, uuid, uuid, uuid, uuid)', 'EXECUTE'), 'service_role can route deactivate_payout_account');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.deactivate_payout_account(uuid, uuid, uuid, uuid, uuid)'::regprocedure), 'deactivate_payout_account has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.set_primary_payout_account(uuid, uuid, uuid, uuid, uuid)', 'EXECUTE'), 'anon cannot invoke set_primary_payout_account');

select ok(not has_function_privilege('authenticated', 'command_api.set_primary_payout_account(uuid, uuid, uuid, uuid, uuid)', 'EXECUTE'), 'authenticated cannot invoke set_primary_payout_account');

select ok(has_function_privilege('service_role', 'command_api.set_primary_payout_account(uuid, uuid, uuid, uuid, uuid)', 'EXECUTE'), 'service_role can route set_primary_payout_account');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.set_primary_payout_account(uuid, uuid, uuid, uuid, uuid)'::regprocedure), 'set_primary_payout_account has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.submit_payout_assertion(uuid, uuid, numeric, numeric, text, text, timestamptz, jsonb, uuid, numeric, text, text, uuid)', 'EXECUTE'), 'anon cannot invoke submit_payout_assertion');

select ok(not has_function_privilege('authenticated', 'command_api.submit_payout_assertion(uuid, uuid, numeric, numeric, text, text, timestamptz, jsonb, uuid, numeric, text, text, uuid)', 'EXECUTE'), 'authenticated cannot invoke submit_payout_assertion');

select ok(has_function_privilege('service_role', 'command_api.submit_payout_assertion(uuid, uuid, numeric, numeric, text, text, timestamptz, jsonb, uuid, numeric, text, text, uuid)', 'EXECUTE'), 'service_role can route submit_payout_assertion');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.submit_payout_assertion(uuid, uuid, numeric, numeric, text, text, timestamptz, jsonb, uuid, numeric, text, text, uuid)'::regprocedure), 'submit_payout_assertion has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.correct_payout_assertion(uuid, uuid, numeric, numeric, text, text, timestamptz, jsonb, uuid, numeric, text, text, uuid)', 'EXECUTE'), 'anon cannot invoke correct_payout_assertion');

select ok(not has_function_privilege('authenticated', 'command_api.correct_payout_assertion(uuid, uuid, numeric, numeric, text, text, timestamptz, jsonb, uuid, numeric, text, text, uuid)', 'EXECUTE'), 'authenticated cannot invoke correct_payout_assertion');

select ok(has_function_privilege('service_role', 'command_api.correct_payout_assertion(uuid, uuid, numeric, numeric, text, text, timestamptz, jsonb, uuid, numeric, text, text, uuid)', 'EXECUTE'), 'service_role can route correct_payout_assertion');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.correct_payout_assertion(uuid, uuid, numeric, numeric, text, text, timestamptz, jsonb, uuid, numeric, text, text, uuid)'::regprocedure), 'correct_payout_assertion has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.review_payout_assertion(uuid, uuid, text, text, uuid, uuid)', 'EXECUTE'), 'anon cannot invoke review_payout_assertion');

select ok(not has_function_privilege('authenticated', 'command_api.review_payout_assertion(uuid, uuid, text, text, uuid, uuid)', 'EXECUTE'), 'authenticated cannot invoke review_payout_assertion');

select ok(has_function_privilege('service_role', 'command_api.review_payout_assertion(uuid, uuid, text, text, uuid, uuid)', 'EXECUTE'), 'service_role can route review_payout_assertion');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.review_payout_assertion(uuid, uuid, text, text, uuid, uuid)'::regprocedure), 'review_payout_assertion has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.update_team_configuration(uuid, uuid, uuid, uuid, text, text, text, text, text, text, text, uuid, uuid, uuid, uuid, text, text, text, text)', 'EXECUTE'), 'anon cannot invoke update_team_configuration');

select ok(not has_function_privilege('authenticated', 'command_api.update_team_configuration(uuid, uuid, uuid, uuid, text, text, text, text, text, text, text, uuid, uuid, uuid, uuid, text, text, text, text)', 'EXECUTE'), 'authenticated cannot invoke update_team_configuration');

select ok(has_function_privilege('service_role', 'command_api.update_team_configuration(uuid, uuid, uuid, uuid, text, text, text, text, text, text, text, uuid, uuid, uuid, uuid, text, text, text, text)', 'EXECUTE'), 'service_role can route update_team_configuration');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.update_team_configuration(uuid, uuid, uuid, uuid, text, text, text, text, text, text, text, uuid, uuid, uuid, uuid, text, text, text, text)'::regprocedure), 'update_team_configuration has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.request_brand_asset_upload(uuid, uuid, uuid, uuid, text, text, bigint, text, integer, integer)', 'EXECUTE'), 'anon cannot invoke request_brand_asset_upload');

select ok(not has_function_privilege('authenticated', 'command_api.request_brand_asset_upload(uuid, uuid, uuid, uuid, text, text, bigint, text, integer, integer)', 'EXECUTE'), 'authenticated cannot invoke request_brand_asset_upload');

select ok(has_function_privilege('service_role', 'command_api.request_brand_asset_upload(uuid, uuid, uuid, uuid, text, text, bigint, text, integer, integer)', 'EXECUTE'), 'service_role can route request_brand_asset_upload');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.request_brand_asset_upload(uuid, uuid, uuid, uuid, text, text, bigint, text, integer, integer)'::regprocedure), 'request_brand_asset_upload has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.finalize_brand_asset_upload(uuid, uuid, uuid, bigint, text)', 'EXECUTE'), 'anon cannot invoke finalize_brand_asset_upload');

select ok(not has_function_privilege('authenticated', 'command_api.finalize_brand_asset_upload(uuid, uuid, uuid, bigint, text)', 'EXECUTE'), 'authenticated cannot invoke finalize_brand_asset_upload');

select ok(has_function_privilege('service_role', 'command_api.finalize_brand_asset_upload(uuid, uuid, uuid, bigint, text)', 'EXECUTE'), 'service_role can route finalize_brand_asset_upload');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.finalize_brand_asset_upload(uuid, uuid, uuid, bigint, text)'::regprocedure), 'finalize_brand_asset_upload has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.request_financial_evidence_upload(uuid, uuid, text, uuid, text, text, text, bigint, text)', 'EXECUTE'), 'anon cannot invoke request_financial_evidence_upload');

select ok(not has_function_privilege('authenticated', 'command_api.request_financial_evidence_upload(uuid, uuid, text, uuid, text, text, text, bigint, text)', 'EXECUTE'), 'authenticated cannot invoke request_financial_evidence_upload');

select ok(has_function_privilege('service_role', 'command_api.request_financial_evidence_upload(uuid, uuid, text, uuid, text, text, text, bigint, text)', 'EXECUTE'), 'service_role can route request_financial_evidence_upload');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.request_financial_evidence_upload(uuid, uuid, text, uuid, text, text, text, bigint, text)'::regprocedure), 'request_financial_evidence_upload has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.finalize_financial_evidence_upload(uuid, uuid, bigint, text, timestamptz, text, text, text)', 'EXECUTE'), 'anon cannot invoke finalize_financial_evidence_upload');

select ok(not has_function_privilege('authenticated', 'command_api.finalize_financial_evidence_upload(uuid, uuid, bigint, text, timestamptz, text, text, text)', 'EXECUTE'), 'authenticated cannot invoke finalize_financial_evidence_upload');

select ok(has_function_privilege('service_role', 'command_api.finalize_financial_evidence_upload(uuid, uuid, bigint, text, timestamptz, text, text, text)', 'EXECUTE'), 'service_role can route finalize_financial_evidence_upload');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.finalize_financial_evidence_upload(uuid, uuid, bigint, text, timestamptz, text, text, text)'::regprocedure), 'finalize_financial_evidence_upload has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.set_account_status(uuid, uuid, uuid, uuid, public.account_status, text)', 'EXECUTE'), 'anon cannot invoke set_account_status');

select ok(not has_function_privilege('authenticated', 'command_api.set_account_status(uuid, uuid, uuid, uuid, public.account_status, text)', 'EXECUTE'), 'authenticated cannot invoke set_account_status');

select ok(has_function_privilege('service_role', 'command_api.set_account_status(uuid, uuid, uuid, uuid, public.account_status, text)', 'EXECUTE'), 'service_role can route set_account_status');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.set_account_status(uuid, uuid, uuid, uuid, public.account_status, text)'::regprocedure), 'set_account_status has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.read_brand_asset_upload_intent(uuid,uuid,uuid)', 'EXECUTE'), 'anon cannot invoke read_brand_asset_upload_intent');

select ok(not has_function_privilege('authenticated', 'command_api.read_brand_asset_upload_intent(uuid,uuid,uuid)', 'EXECUTE'), 'authenticated cannot invoke read_brand_asset_upload_intent');

select ok(has_function_privilege('service_role', 'command_api.read_brand_asset_upload_intent(uuid,uuid,uuid)', 'EXECUTE'), 'service_role can route read_brand_asset_upload_intent');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.read_brand_asset_upload_intent(uuid,uuid,uuid)'::regprocedure), 'read_brand_asset_upload_intent has pinned definer scope');

select ok(not has_function_privilege('anon', 'command_api.read_financial_upload_intent(uuid,uuid)', 'EXECUTE'), 'anon cannot invoke read_financial_upload_intent');

select ok(not has_function_privilege('authenticated', 'command_api.read_financial_upload_intent(uuid,uuid)', 'EXECUTE'), 'authenticated cannot invoke read_financial_upload_intent');

select ok(has_function_privilege('service_role', 'command_api.read_financial_upload_intent(uuid,uuid)', 'EXECUTE'), 'service_role can route read_financial_upload_intent');

select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'command_api.read_financial_upload_intent(uuid,uuid)'::regprocedure), 'read_financial_upload_intent has pinned definer scope');

select ok(not has_table_privilege('service_role', 'tenant_config.brand_asset_upload_intents', 'SELECT'), 'brand intent table stays private');

select ok(not has_table_privilege('service_role', 'evidence.financial_upload_intents', 'SELECT'), 'financial intent table stays private');

select ok(not exists (
  select 1 from pg_proc p
  join pg_namespace pn on pn.oid = p.pronamespace
  cross join lateral unnest(p.proargtypes::oid[]) arg(type_oid)
  join pg_type t on t.oid = arg.type_oid
  join pg_namespace tn on tn.oid = t.typnamespace
  where pn.nspname = 'command_api'
    and tn.nspname not in ('pg_catalog', 'public', 'command_api')
), 'API command inputs never require private schema type casts');

set local role service_role;

select throws_ok($$select command_api.review_payout_assertion(null, null, 'invalid', null, null, null)$$, '22023', null, 'unsupported review decisions are rejected before enum conversion');

select throws_ok($$select command_api.create_membership(null, null, null, null, null, null, null)$$, '22023', null, 'create_membership reaches domain validation as service_role');

select throws_ok($$select command_api.activate_membership(null, null, null, null)$$, '22023', null, 'activate_membership reaches domain validation as service_role');

select throws_ok($$select command_api.suspend_membership(null, null, null, null)$$, '22023', null, 'suspend_membership reaches domain validation as service_role');

select throws_ok($$select command_api.end_membership(null, null, null, null, null)$$, '22023', null, 'end_membership reaches domain validation as service_role');

select throws_ok($$select command_api.move_membership(null, null, null, null, null, null)$$, '22023', null, 'move_membership reaches domain validation as service_role');

select throws_ok($$select command_api.submit_withdrawal(null, null, null, null, null, null)$$, '22023', null, 'submit_withdrawal reaches domain validation as service_role');

select throws_ok($$select command_api.approve_withdrawal(null, null, null, null)$$, '22023', null, 'approve_withdrawal reaches domain validation as service_role');

select throws_ok($$select command_api.reject_withdrawal(null, null, null, null, null)$$, '22023', null, 'reject_withdrawal reaches domain validation as service_role');

select throws_ok($$select command_api.cancel_withdrawal(null, null, null, null, null)$$, '22023', null, 'cancel_withdrawal reaches domain validation as service_role');

select throws_ok($$select command_api.replace_payout_account(null, null, null, null, null, null, null, null, null, null, null, null, null)$$, '22023', null, 'replace_payout_account reaches domain validation as service_role');

select throws_ok($$select command_api.deactivate_payout_account(null, null, null, null, null)$$, 'P0002', null, 'deactivate_payout_account reaches domain validation as service_role');

select throws_ok($$select command_api.set_primary_payout_account(null, null, null, null, null)$$, '23514', null, 'set_primary_payout_account reaches domain validation as service_role');

select throws_ok($$select command_api.submit_payout_assertion(null, null, null, null, null, null, null, null, null, null, null, null, null)$$, '22023', null, 'submit_payout_assertion reaches domain validation as service_role');

select throws_ok($$select command_api.correct_payout_assertion(null, null, null, null, null, null, null, null, null, null, null, null, null)$$, '22023', null, 'correct_payout_assertion reaches domain validation as service_role');

select throws_ok($$select command_api.review_payout_assertion(null, null, null, null, null, null)$$, '22023', null, 'review_payout_assertion reaches domain validation as service_role');

select throws_ok($$select command_api.update_team_configuration(null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null)$$, '22023', null, 'update_team_configuration reaches domain validation as service_role');

select throws_ok($$select command_api.request_brand_asset_upload(null, null, null, null, null, null, null, null, null, null)$$, '22023', null, 'request_brand_asset_upload reaches domain validation as service_role');

select throws_ok($$select command_api.finalize_brand_asset_upload(null, null, null, null, null)$$, '22023', null, 'finalize_brand_asset_upload reaches domain validation as service_role');

select throws_ok($$select command_api.request_financial_evidence_upload(null, null, null, null, null, null, null, null, null)$$, '22023', null, 'request_financial_evidence_upload reaches domain validation as service_role');

select throws_ok($$select command_api.finalize_financial_evidence_upload(null, null, null, null, null, null, null, null)$$, '22023', null, 'finalize_financial_evidence_upload reaches domain validation as service_role');

select throws_ok($$select command_api.set_account_status(null, null, null, null, null, null)$$, '22023', null, 'set_account_status reaches domain validation as service_role');

select throws_ok($$select command_api.read_brand_asset_upload_intent(null, null, null)$$, '22023', null, 'read_brand_asset_upload_intent reaches domain validation as service_role');

select throws_ok($$select command_api.read_financial_upload_intent(null, null)$$, '22023', null, 'read_financial_upload_intent reaches domain validation as service_role');

reset role;

select * from finish();

rollback;
