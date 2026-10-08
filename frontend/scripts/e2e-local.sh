#!/usr/bin/env bash
# End-to-end tests against the LOCAL Supabase stack (decision 49). Starts the
# stack from backend/, serves the Edge Functions with throwaway secrets, runs
# Playwright, then stops everything. Never touches a hosted project.
#
# On a shared machine, hold the stack lock while this runs (see the Phase 2
# common rules): until mkdir /tmp/elivate-supabase.lock ...; trap rmdir ... EXIT
set -euo pipefail

frontend="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
backend="$frontend/../backend"
env_file="$(mktemp)"
serve_log="$(mktemp)"
serve_pid=""

cleanup() {
  [ -n "$serve_pid" ] && kill "$serve_pid" 2>/dev/null || true
  rm -f "$env_file"
  (cd "$backend" && supabase stop --no-backup >/dev/null 2>&1) || true
}
trap cleanup EXIT

cd "$backend"
supabase start --exclude studio,imgproxy,logflare,vector,supavisor
supabase db reset --local --yes >/dev/null

# Values printed by the local stack (local defaults, not secrets).
eval "$(supabase status -o env | grep -E '^(API_URL|ANON_KEY)=')"

# Throwaway secret, generated per run and never stored.
{
  echo "PIN_HMAC_SECRET=$(openssl rand -hex 32)"
  echo "PIN_RESET_REDIRECT_URL=http://127.0.0.1:3000/auth/confirm"
  echo "CORS_ORIGINS="
} > "$env_file"

supabase functions serve --env-file "$env_file" >"$serve_log" 2>&1 &
serve_pid=$!
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$API_URL/functions/v1/security/state" || true)"
  [ "$code" = "401" ] && break
  sleep 1
done

cd "$frontend"
export SUPABASE_URL="$API_URL"
export SUPABASE_PUBLISHABLE_KEY="$ANON_KEY"
if ! pnpm exec playwright test "$@"; then
  echo "--- functions serve log (tail) ---"
  tail -n 60 "$serve_log"
  exit 1
fi
