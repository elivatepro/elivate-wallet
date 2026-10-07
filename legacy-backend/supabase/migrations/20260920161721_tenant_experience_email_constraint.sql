alter table tenant_config.configuration_revisions
  drop constraint if exists configuration_revisions_support_contact_email_check;

alter table tenant_config.configuration_revisions
  add constraint configuration_revisions_support_contact_email_check
  check (
    support_contact_email is null
    or support_contact_email ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
  );
