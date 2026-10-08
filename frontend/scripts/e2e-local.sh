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
fake_pid=""

cleanup() {
  [ -n "$serve_pid" ] && kill "$serve_pid" 2>/dev/null || true
  [ -n "$fake_pid" ] && kill "$fake_pid" 2>/dev/null || true
  rm -f "$env_file"
  (cd "$backend" && supabase stop --no-backup >/dev/null 2>&1) || true
}
trap cleanup EXIT

cd "$backend"
supabase start --exclude studio,imgproxy,logflare,vector,supavisor
supabase db reset --local --yes >/dev/null

# Values printed by the local stack (local defaults, not secrets).
eval "$(supabase status -o env | grep -E '^(API_URL|ANON_KEY)=')"

# Throwaway secrets, generated per run and never stored. The invitation secret
# is also handed to Playwright: the local stack sends no application email, so
# the join tests rebuild the link from the token id exactly as the worker does.
INVITATION_TOKEN_SECRET="$(openssl rand -hex 32)"
export INVITATION_TOKEN_SECRET
{
  echo "PIN_HMAC_SECRET=$(openssl rand -hex 32)"
  echo "INVITATION_TOKEN_SECRET=$INVITATION_TOKEN_SECRET"
  echo "NIN_FINGERPRINT_KEY=$(openssl rand -hex 32)"
  echo "PAYOUT_ACCOUNT_ENC_KEY=$(openssl rand -hex 32)"
  echo "PAYOUT_ACCOUNT_HMAC_KEY=$(openssl rand -hex 32)"
  # Fake providers (tests/e2e/fake-providers.mjs), reached from the functions container.
  echo "NUBAN_KYC_API_KEY=e2e-local"
  echo "NUBAN_KYC_BASE_URL=http://host.docker.internal:54399"
  echo "PAYSTACK_SECRET_KEY=sk_test_e2elocal0000000000"
  echo "PAYSTACK_TEST_ORIGIN=http://host.docker.internal:54399"
  echo "APP_ORIGIN=http://127.0.0.1:3000"
  echo "PIN_RESET_REDIRECT_URL=http://127.0.0.1:3000/auth/confirm"
  echo "CORS_ORIGINS="
} > "$env_file"

node "$frontend/tests/e2e/fake-providers.mjs" 54399 &
fake_pid=$!

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
