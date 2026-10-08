-- Blueprint 06 follow-up — NIN leader-review outcome email (Paper "Emails —
-- Transactional v2" A14b/A14c, owner request 2026-10-08). The person whose
-- review was decided gets one email per decision, enqueued in the deciding
-- transaction. Network and office names only: never the NIN, its last 4, the
-- typed legal name or the reviewer's reason. The office is left out for
-- network-level memberships, which have none.

insert into outbox.templates (key, version, duplicate_safe, params) values
  ('identity.nin_review_decided', 1, true, array['decision', 'network', 'office']);

-- Fires for every decision path (leader or platform admin) when a review
-- leaves pending. Delivery failure never undoes the decision.
create function identity.notify_nin_review_decided()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  network text;
  office text;
begin
  select t.name, o.name into network, office
  from org.tenants t
  join org.memberships m on m.id = new.membership_id and m.tenant_id = t.id
  left join org.offices o on o.id = m.office_id
  where t.id = new.tenant_id;
  if network is null then
    perform identity.fail('invariant_violation', jsonb_build_object('field', 'review'));
  end if;

  perform outbox.enqueue_email(
    'identity.nin_review_decided',
    'nin_review:' || new.id::text || ':' || new.status,
    'nin_review',
    new.id,
    new.tenant_id,
    new.user_id,
    null,
    jsonb_strip_nulls(jsonb_build_object('decision', new.status, 'network', network, 'office', office))
  );
  return null;
end;
$$;

create trigger nin_reviews_decided_email
after update of status on identity.nin_reviews
for each row
when (old.status = 'pending' and new.status in ('approved', 'rejected'))
execute function identity.notify_nin_review_decided();
