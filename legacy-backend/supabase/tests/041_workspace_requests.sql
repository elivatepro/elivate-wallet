begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select no_plan();

select ok(to_regclass('public.workspace_requests') is not null,'workspace requests are persisted');
select ok(to_regclass('public.workspace_request_entry_tokens') is null,'entry tokens are not public');
select ok(to_regclass('public.workspace_request_delegations') is null,'delegations are not public');
select ok(has_function_privilege('service_role','command_api.submit_workspace_request(uuid,uuid,text,text,text,text,text,text)','EXECUTE'),'service transport can submit');
select ok(not has_function_privilege('anon','command_api.submit_workspace_request(uuid,uuid,text,text,text,text,text,text)','EXECUTE'),'anonymous clients cannot bypass transport');
select ok(not has_function_privilege('authenticated','command_api.decide_workspace_request(uuid,uuid,uuid,uuid,uuid,text,text)','EXECUTE'),'authenticated clients cannot decide directly');
select ok(has_function_privilege('service_role','command_api.activate_workspace_request(uuid,uuid,uuid,uuid,uuid,uuid)','EXECUTE'),'service transport can activate transactionally');
select col_is_null('public','workspace_requests','office_id','office remains absent until activation');
select col_not_null('public','workspace_requests','entry_token_digest','request retains trusted entry digest');

select * from finish();
rollback;
