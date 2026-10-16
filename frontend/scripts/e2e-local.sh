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
  [ -n "${E2E_LOCAL_EXPORTS:-}" ] && rm -rf "$E2E_LOCAL_EXPORTS"
  (cd "$backend" && supabase stop --no-backup >/dev/null 2>&1) || true
}
trap cleanup EXIT

cd "$backend"
# A stack that is already running may hold data from earlier runs: reset it.
# A fresh start already applied every migration to an empty database, so CI
# (always fresh) skips the second replay.
if supabase status >/dev/null 2>&1; then already_running=1; else already_running=""; fi
supabase start --exclude studio,imgproxy,logflare,vector,supavisor
if [ -n "$already_running" ] || [ -z "${CI:-}" ]; then
  supabase db reset --local --yes >/dev/null
fi

# Values printed by the local stack (local defaults, not secrets).
eval "$(supabase status -o env | grep -E '^(API_URL|ANON_KEY|MAILPIT_URL)=')"
export MAILPIT_URL="${MAILPIT_URL:-http://127.0.0.1:54324}"

# Throwaway secrets, generated per run and never stored. The invitation secret
# is also handed to Playwright: the local stack sends no application email, so
# the join tests rebuild the link from the token id exactly as the worker does.
INVITATION_TOKEN_SECRET="$(openssl rand -hex 32)"
export INVITATION_TOKEN_SECRET
# Blueprint 13: the tests call the outbox worker with this secret; it sends
# through the fake Cloudflare in fake-providers.mjs into the local mail
# catcher (Mailpit). No real email is ever sent.
OUTBOX_WORKER_SECRET="$(openssl rand -hex 32)"
export OUTBOX_WORKER_SECRET
# Blueprint 14: only the app server may record sign-ins; it and the security
# function share this per-run secret.
APP_SERVER_SECRET="$(openssl rand -hex 32)"
export APP_SERVER_SECRET
# Blueprint 15: the export runner (app server) and the exports-worker function
# share this per-run secret; files go to a temp directory and are rendered with
# Playwright's Chromium (no R2 or Browser Rendering locally).
EXPORTS_WORKER_SECRET="$(openssl rand -hex 32)"
export EXPORTS_WORKER_SECRET
# Blueprint 16: the fake Paystack signs its webhooks with the same throwaway
# test key the billing function verifies, and posts them to the local function.
export PAYSTACK_SECRET_KEY="sk_test_e2elocal0000000000"
export BILLING_WEBHOOK_URL="$API_URL/functions/v1/billing/paystack/webhook"
BILLING_WORKER_SECRET="$(openssl rand -hex 32)"
export BILLING_WORKER_SECRET
E2E_LOCAL_EXPORTS="$(mktemp -d)"
export E2E_LOCAL_EXPORTS
# Blueprint 42: a throwaway VAPID key pair per run (public half to the app
# server, both to the outbox worker); pushes go to the fake push service.
eval "$(node -e '
const { generateKeyPairSync } = require("node:crypto");
const jwk = generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey.export({ format: "jwk" });
const pub = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, "base64url"), Buffer.from(jwk.y, "base64url")]);
console.log(`PUSH_VAPID_PUBLIC_KEY=${pub.toString("base64url")}; PUSH_VAPID_PRIVATE_KEY=${jwk.d}`);
')"
export PUSH_VAPID_PUBLIC_KEY
{
  echo "PIN_HMAC_SECRET=$(openssl rand -hex 32)"
  echo "INVITATION_TOKEN_SECRET=$INVITATION_TOKEN_SECRET"
  echo "NIN_FINGERPRINT_KEY=$(openssl rand -hex 32)"
  echo "PAYOUT_ACCOUNT_ENC_KEY=$(openssl rand -hex 32)"
  echo "PAYOUT_ACCOUNT_HMAC_KEY=$(openssl rand -hex 32)"
  # Fake providers (tests/e2e/fake-providers.mjs), reached from the functions container.
  echo "NUBAN_KYC_API_KEY=e2e-local"
  echo "NUBAN_KYC_BASE_URL=http://host.docker.internal:54399"
  echo "PAYSTACK_SECRET_KEY=$PAYSTACK_SECRET_KEY"
  echo "PAYSTACK_TEST_ORIGIN=http://host.docker.internal:54399"
  echo "OUTBOX_WORKER_SECRET=$OUTBOX_WORKER_SECRET"
  echo "APP_SERVER_SECRET=$APP_SERVER_SECRET"
  echo "EXPORTS_WORKER_SECRET=$EXPORTS_WORKER_SECRET"
  echo "BILLING_WORKER_SECRET=$BILLING_WORKER_SECRET"
  echo "CLOUDFLARE_ACCOUNT_ID=e2e-local"
  echo "CLOUDFLARE_EMAIL_API_TOKEN=e2e-local-email"
  echo "CLOUDFLARE_API_TEST_ORIGIN=http://host.docker.internal:54399"
  echo "EMAIL_FROM_ADDRESS=noreply@elivatewallet.com"
  echo "APP_ORIGIN=http://127.0.0.1:3000"
  echo "PIN_RESET_REDIRECT_URL=http://127.0.0.1:3000/auth/confirm"
  echo "CORS_ORIGINS="
  echo "PUSH_VAPID_PUBLIC_KEY=$PUSH_VAPID_PUBLIC_KEY"
  echo "PUSH_VAPID_PRIVATE_KEY=$PUSH_VAPID_PRIVATE_KEY"
  echo "PUSH_VAPID_SUBJECT=mailto:support@elivatewallet.com"
  echo "PUSH_TEST_ENDPOINT_BASE=http://host.docker.internal:54399"
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
