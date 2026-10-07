begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(9);

select ok(not has_function_privilege('anon', 'command_api.create_invitation(uuid,uuid,uuid,uuid,uuid,public.role_key,text,bytea,timestamptz)', 'EXECUTE'), 'anon cannot create invitations');
select ok(not has_function_privilege('authenticated', 'command_api.create_invitation(uuid,uuid,uuid,uuid,uuid,public.role_key,text,bytea,timestamptz)', 'EXECUTE'), 'authenticated callers cannot create invitations directly');
select ok(has_function_privilege('service_role', 'command_api.create_invitation(uuid,uuid,uuid,uuid,uuid,public.role_key,text,bytea,timestamptz)', 'EXECUTE'), 'trusted service can route invitation creation');
select ok(not has_function_privilege('anon', 'command_api.accept_invitation(uuid,uuid,bytea)', 'EXECUTE'), 'anon cannot accept invitations');
select ok(not has_function_privilege('authenticated', 'command_api.accept_invitation(uuid,uuid,bytea)', 'EXECUTE'), 'authenticated callers cannot accept invitations directly');
select ok(has_function_privilege('service_role', 'command_api.accept_invitation(uuid,uuid,bytea)', 'EXECUTE'), 'trusted service can route invitation acceptance');
select ok(not has_function_privilege('anon', 'command_api.revoke_invitation(uuid,uuid,uuid,uuid)', 'EXECUTE'), 'anon cannot revoke invitations');
select ok(not has_function_privilege('authenticated', 'command_api.revoke_invitation(uuid,uuid,uuid,uuid)', 'EXECUTE'), 'authenticated callers cannot revoke invitations directly');
select ok(has_function_privilege('service_role', 'command_api.revoke_invitation(uuid,uuid,uuid,uuid)', 'EXECUTE'), 'trusted service can route invitation revocation');
select * from finish();
rollback;
