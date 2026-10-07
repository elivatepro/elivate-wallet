#!/usr/bin/env bash
set -euo pipefail

# Fresh-database gate: replays every migration into an empty local Supabase
# stack, runs pgTAP and lints. Needs a container runtime (CI has one).

cd "$(dirname -- "${BASH_SOURCE[0]}")/.."
trap 'supabase stop --no-backup >/dev/null 2>&1 || true' EXIT

supabase start --exclude studio,imgproxy,inbucket,logflare,vector,supavisor
supabase db reset --local --yes
if compgen -G "supabase/tests/*.sql" >/dev/null; then
  supabase test db --local
fi
supabase db lint --local --level warning --fail-on error
printf 'Fresh replay, pgTAP and lint passed.\n'
