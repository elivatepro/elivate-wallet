-- Shared fixtures are defined per file (each file runs in its own rolled-back
-- transaction); this file only checks that pgTAP itself loads.
begin;
create extension if not exists pgtap with schema extensions;
select plan(1);
select has_schema('identity');
select * from finish();
rollback;
