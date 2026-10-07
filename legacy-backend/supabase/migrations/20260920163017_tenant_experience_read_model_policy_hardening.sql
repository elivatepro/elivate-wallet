drop policy if exists tenant_member_branding_read_no_client_write
  on public.tenant_member_branding_read;
drop policy if exists tenant_member_branding_read_no_insert
  on public.tenant_member_branding_read;
drop policy if exists tenant_member_branding_read_no_update
  on public.tenant_member_branding_read;
drop policy if exists tenant_member_branding_read_no_delete
  on public.tenant_member_branding_read;

create policy tenant_member_branding_read_no_insert
  on public.tenant_member_branding_read as restrictive for insert to authenticated
  with check (false);

create policy tenant_member_branding_read_no_update
  on public.tenant_member_branding_read as restrictive for update to authenticated
  using (false) with check (false);

create policy tenant_member_branding_read_no_delete
  on public.tenant_member_branding_read as restrictive for delete to authenticated
  using (false);
