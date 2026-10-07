alter table tenant_config.brand_assets
  drop constraint if exists brand_assets_check;

alter table tenant_config.brand_assets
  add constraint brand_assets_storage_path_check
  check (storage_object_path like tenant_id::text || '/%');
