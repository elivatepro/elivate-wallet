-- Blueprint 03 — owner decision 5: pg_cron calls the `outbox-worker` Edge
-- Function every minute through pg_net. The URL and worker secret live in
-- Supabase Vault (entries `outbox_worker_url`, `outbox_worker_secret`) and are
-- read at run time; when either is missing (local stack, CI, not yet
-- configured) the job does nothing.

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

create function outbox.trigger_worker()
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  worker_url text;
  worker_secret text;
begin
  select decrypted_secret into worker_url from vault.decrypted_secrets where name = 'outbox_worker_url';
  select decrypted_secret into worker_secret from vault.decrypted_secrets where name = 'outbox_worker_secret';
  if coalesce(worker_url, '') = '' or coalesce(worker_secret, '') = '' then
    return null;
  end if;
  return net.http_post(
    url := worker_url,
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || worker_secret),
    timeout_milliseconds := 55000
  );
end;
$$;

revoke all on function outbox.trigger_worker() from public, anon, authenticated;

-- cron.schedule upserts by name, so replays never duplicate the job.
select cron.schedule('outbox-worker', '* * * * *', 'select outbox.trigger_worker()');
