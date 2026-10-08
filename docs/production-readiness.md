# Production readiness runbook — Elivate Wallet 2.0 backend

Status: **decisions answered by the owner 2026-10-08 (§1); not executed.** Written 2026-10-08 against `main` at `c648abd` (slices 01–02: 9 migrations, Edge Functions `security` and `org`). Read-only inspection of the development project `crljnkdwkxkwgvhxfrbl` and the Cloudflare account informed it (see §10).

This is a runbook an agent executes top to bottom, in one session, **after** the owner has (1) answered the decisions below (done 2026-10-08) and (2) created the production Supabase project (owner decision: before the first public deploy). Every step that changes something is one the owner has approved by approving this runbook for that session; anything not listed here needs a separate request. Steps marked **OWNER** are done by the owner in a dashboard or terminal; the agent never sees or handles those values.

Hard rules for the whole run:
- **Never run `supabase config push`.** It overwrites dashboard-managed Auth settings, including the Cloudflare SMTP setup.
- **Never run `supabase link`** for production. The main checkout's `backend/supabase/.temp` is linked to development, and re-linking would make every later "linked" command hit production. Pass `--project-ref "$PROD_REF"` explicitly on every command.
- Never print, log, commit or paste a secret value (API tokens, database password, `PIN_HMAC_SECRET`, service keys, user passwords, PINs, JWTs).
- Read no data rows except the owner's own account in §7, which the owner names.
- Use the CLI version CI pins (`supabase` 2.117.0) unless the owner approves an upgrade.

Not covered here (separate work): the frontend and its hosting (decided 2026-10-08: SvelteKit on Cloudflare Workers, not deployed yet; `00-product.md` P-04), the `api.elivatewallet.com` custom domain, Paystack, application email (slice 03 outbox), Storage buckets, cron jobs, monitoring/alerting, and DR targets (U-06).

---

## 1. Owner decisions (2026-10-08)

The owner approved every recommendation; the answers are recorded here.

| # | Question | Owner decision |
|---|---|---|
| 1 | Region (permanent) | **`eu-west-2` (London)**, after a quick latency check from a Nigerian connection (§2.1); Paris or Frankfurt only if clearly faster. Every option is outside Nigeria, so the owner checks NDPA cross-border transfer obligations with their adviser. |
| 2 | Compute size and backups | **Micro compute + daily backups now; Small compute + 7-day PITR before the first real income is recorded.** Recovery targets stay open (U-06). Storage files are never in database backups. |
| 3 | Project names | **"Elivate Wallet — Production"**, and rename dev to **"Elivate Wallet — Development"**. The dev rename has **not been performed yet**; until it is, the dev project is still the bare "Elivate Wallet". |
| 4 | Production sender and sending domain | **Production sends from `noreply@elivatewallet.com`, name "Elivate Wallet", no reply-to.** Development moves to `noreply@dev.elivatewallet.com` once that subdomain is onboarded in Cloudflare Email Sending (until then dev may use the main domain). One Email Sending token per environment, with separate SMTP (Auth) and REST (application email) tokens. The daily quota belongs to the Cloudflare account and is shared. |
| 5 | Production app URLs | **App `https://app.elivatewallet.com`, admin `https://admin.elivatewallet.com`.** Site URL `https://app.elivatewallet.com`; allow-list `https://app.elivatewallet.com/**` and `https://admin.elivatewallet.com/**`, no localhost; `CORS_ORIGINS=https://app.elivatewallet.com,https://admin.elivatewallet.com`; `PIN_RESET_REDIRECT_URL=https://app.elivatewallet.com/` until the frontend's `token_hash` confirm route exists (W-01), then that route. |
| 6 | First platform admin | **The owner's own named mailbox, created by the one-time guarded SQL in §7** after it has confirmed its email and set its PIN. A second admin is added in the app soon after. |
| 7 | Legacy Supabase API keys | **Launch on legacy keys if the new project still issues them; migrate the functions to the new keys before the end of 2026.** If the new project has no legacy keys, stop at §6. |
| 8 | Back up `PIN_HMAC_SECRET` | **(b):** the agent generates it and copies it once to the owner's clipboard for their password manager, then clears the clipboard. |
| 9 | When to create production | **Before the first public deploy.** Not needed for local Phase 2 work. |

**Owner actions outstanding:**
- Confirm the Cloudflare **Workers Paid** plan is active and **request a sending-quota increase** (currently 200 a day, shared by dev and production) before a public launch (§2.5).
- Rename the dev project (decision 3).
- Run the region latency check (§2.1) and create the production project (decisions 1–3, 9).

Record the answers here before running:

```
PROD_REF=            # filled in after the owner creates the project
REGION=eu-west-2     # decision 1 (confirm after the latency check)
COMPUTE / PITR=Micro + daily backups; Small + PITR before first real income   # decision 2
PROJECT_NAME=Elivate Wallet — Production                                      # decision 3
SENDER=noreply@elivatewallet.com, "Elivate Wallet", no reply-to                # decision 4
APP_URL=https://app.elivatewallet.com (admin https://admin.elivatewallet.com)  # decision 5
FIRST_ADMIN_EMAIL=   # decision 6 — kept in the session only, never committed
```

---

## 2. Pre-flight (no changes yet)

### 2.1 Region latency check (OWNER, before creating the project)
From a typical Nigerian connection (not a VPN), compare round-trip times to the candidate AWS regions, for example by running the following command five times per region and keeping the median of `time_connect`:
```sh
for r in eu-west-2 eu-west-3 eu-central-1 eu-west-1; do
  curl -s -o /dev/null -w "$r %{time_connect}\n" "https://dynamodb.$r.amazonaws.com/ping"
done
```
Then create the project in the dashboard with decisions 1–3. Use a long random database password stored in your password manager. Don't share it with the agent.

### 2.2 Tooling
```sh
supabase --version          # expect 2.117.0 (CI pin)
supabase projects list      # confirms the CLI login (owner-configured session)
cd backend && git status    # clean, on the commit being released
```
CI on that commit must be green (`.github/workflows/backend.yml`: Deno check, then fresh replay + pgTAP + lint). Optionally re-run `backend/scripts/verify-database.sh` locally (Colima: `colima start`).

### 2.3 Confirm the target ref — twice
```sh
export DEV_REF=crljnkdwkxkwgvhxfrbl
export PROD_REF=<ref the owner gives>
```
1. Guard: run this before every mutating command in §5–§7:
   ```sh
   prod_guard() { [ -n "$PROD_REF" ] && [ "$PROD_REF" != "$DEV_REF" ] || { echo "ABORT: PROD_REF unset or equals dev"; return 1; }; }
   prod_guard
   ```
2. Show the project behind the ref and have the owner confirm the **name and region** match decisions 1 and 3:
   ```sh
   supabase projects list -o json | jq --arg r "$PROD_REF" '.[] | select(.ref==$r or .id==$r) | {ref: (.ref // .id), name, region}'
   ```
   The owner replies with the ref typed back. If anything differs, **abort**.

### 2.4 Confirm the new project is empty
```sh
supabase migration list --project-ref "$PROD_REF"   # expect: no remote versions
supabase functions list --project-ref "$PROD_REF"   # expect: none
supabase secrets list --project-ref "$PROD_REF" -o json | jq -r '.[].name'   # names only
```
If the project already has migrations or functions, **abort** and ask.

Check in the dashboard under **Settings → API Keys** that legacy `anon` and `service_role` keys exist (decision 7). Check under **Settings → JWT Keys** which signing key is active. Dev uses ES256 (asymmetric), and the production project will too. See the risk in §10.

### 2.5 Cloudflare Email Sending (read-only checks)
- **Workers Paid plan (OWNER):** in the Cloudflare dashboard, open **Manage account → Billing → Subscriptions** (or **Workers & Pages → Plans**). It must show **Workers Paid**. Without it, Email Sending only delivers to verified destination addresses, and sign-up mail to real users silently fails. The agent's Cloudflare token can't read billing (`/accounts/{id}/subscriptions` returns an authentication error), so this check is the owner's.
- **Current limits (checked 2026-10-08 against Cloudflare docs; re-check at run time):**
  - Workers Paid includes 3,000 outbound emails a month per account, then $0.35 per 1,000.
  - New accounts start with a conservative **daily quota that grows with reputation**. This account currently shows **200 a day** (`GET /accounts/{id}/email/sending/limits`). Request an increase before a public launch.
  - A message can have at most 50 recipients across To, Cc and Bcc, and at most 5 MiB.
  - SMTP is accepted **only on port 465 with implicit TLS**. STARTTLS on port 587 is not supported.
- **Sending domain status:**
  ```text
  GET /zones/{zone}/email/sending/subdomains                 → elivatewallet.com, enabled
  GET /zones/{zone}/email/sending/subdomains/{id}/dns/status → status "ready", errors []
  ```
  On 2026-10-08 the status was **ready**. It used return path `cf-bounce.elivatewallet.com` (MX ×3 plus SPF `v=spf1 include:_spf.mx.cloudflare.net ~all`), DKIM selector `cf-bounce._domainkey`, and DMARC `v=DMARC1; p=reject;`. If decision 4 introduces a new subdomain, onboard it under **Email Service → Email Sending** and wait for "ready" before §4.
- Recommended, not blocking: add a `rua=` reporting address to the DMARC record, so failures under `p=reject` are visible.

---

## 3. Auth configuration (dashboard only, OWNER or agent with dashboard access)

**Do not run `supabase config push`.** Set every value below in the dashboard. `backend/supabase/config.toml` is the local-development mirror. Values that intentionally differ in production are marked ≠.

Write down each setting's value before changing it. That record is the rollback for this section.

| Area (dashboard path) | Setting | Production value | Source |
|---|---|---|---|
| Auth → URL Configuration | Site URL | `https://app.elivatewallet.com` ≠ (local `http://127.0.0.1:3000`) | B6, decision 5 |
| | Redirect URLs | `https://app.elivatewallet.com/**`, `https://admin.elivatewallet.com/**`, **no localhost** ≠ | B6 |
| Auth → Sign In / Providers | Allow new users to sign up | On (founders self-serve, Blueprint 02 Q1) | config `enable_signup` |
| | Email provider | On | |
| | Confirm email | **On**: invitation acceptance binds to a proven email (W-02) | config `enable_confirmations` |
| | Secure email change | On | `double_confirm_changes` |
| | Secure password change | Off (matches config) | `secure_password_change` |
| | Email OTP expiration | 3600 s (the PIN reset itself is limited to 15 min in the database) | `otp_expiry` |
| | Email OTP length | 6 | `otp_length` |
| | Anonymous sign-ins · Manual linking · Phone · all OAuth / Web3 / third-party | Off | config |
| Auth → Passwords | Minimum length | **8** | Blueprint 01 Q2 |
| | Required characters | None | `password_requirements = ""` |
| | Leaked password protection | **On** | B6 |
| Auth → Multi-Factor | TOTP · Phone · WebAuthn enroll/verify | **All off**. The 4-digit PIN replaces an authenticator app (A-05, U-09). | `[auth.mfa.*]` |
| Auth → Sessions | Time-box user sessions | **168 h (7 days)** | Blueprint 01 Q1 |
| | Inactivity timeout | Unset. The 15-minute PIN idle rule is enforced by `identity.session_gate`, not by Auth. | config comment |
| | Single session per user | Off (devices are listed and revoked in the app) | |
| Auth → JWT / Tokens | Access token expiry | 3600 s | `jwt_expiry` |
| | Refresh token rotation · reuse interval | On · 10 s | config |
| Auth → Rate Limits | Emails sent per hour | 30 (the custom-SMTP default) until the Cloudflare daily quota is raised. Set it to at most quota ÷ 24 so Supabase throttles before Cloudflare rejects. | Supabase SMTP guide |
| | Token refresh / Sign-up + sign-in / Token verification | 150 per 5 min / 30 per 5 min / 30 per 5 min per IP | config |
| Auth → Emails → SMTP | (see §4) | | |
| Auth → Emails → Templates | Confirm signup, Magic Link | Owner decision (2026-10-08, W-01): both links use `token_hash` and open the frontend's Continue (POST) page. Switch the production templates once that route exists; until then the defaults are acceptable for a smoke test. Editing the **development** project's templates is not approved yet (it comes with the first real sign-up). The **Magic Link** template is used only for the PIN reset (`security` → `signInWithOtp`, `shouldCreateUser: false`), so its subject should say so, e.g. "Reset your Elivate Wallet PIN". | Blueprint 01 B4 |
| | Security notifications (password/email changed etc.) | Leave off for now. Each one is an extra Auth email, which counts against the quota and complicates the one-email-per-event check in §8. | |
| Auth → Hooks | All hooks | **None enabled.** The gate reads `auth.sessions` / `auth.mfa_amr_claims` directly; no custom access-token hook exists. | migrations 0300 |
| Auth → Attack Protection | CAPTCHA | Off. Owner decision (2026-10-08): Worker rate limiting + Turnstile on sign-up/sign-in in the SvelteKit app; revisit this setting with the frontend's rate-limit spike. | config |
| Settings → API (Data API) | Exposed schemas | **`public`, `graphql_public`, `api`**. Functions call `service.schema("api").rpc(...)`, which fails if `api` isn't exposed. Only `service_role` can execute it. | config `[api].schemas` |
| | Extra search path · Max rows | `public, extensions` · 1000 | config |
| Settings → Database | Enforce SSL | On | hardening |

---

## 4. Custom SMTP → Cloudflare (OWNER enters the token)

1. **OWNER, in Cloudflare:** create an API token with only the **Email Sending: Edit** permission, scoped to the Elivate Wallet account, and named for production, e.g. `supabase-auth-smtp-prod`. Don't reuse the dev token (decision 4).
2. **OWNER, in Supabase (production) → Auth → Emails → SMTP Settings:**
   | Field | Value |
   |---|---|
   | Enable custom SMTP | On |
   | Sender email | decision 4, e.g. `noreply@elivatewallet.com` |
   | Sender name | `Elivate Wallet` |
   | Host | `smtp.mx.cloudflare.net` |
   | Port | `465` (implicit TLS; 587 doesn't work) |
   | Username | `api_token` (literal) |
   | Password | the token from step 1, typed or pasted by the owner |
   | Minimum interval per user | 60 s (≠ local `max_frequency = "1s"`) |
3. The agent never sees or stores the token. If the dashboard test send fails, check Cloudflare's SMTP troubleshooting: `535` means a wrong username or token permission, and `550 Sender denied` means the sender domain isn't onboarded on this account.

---

## 5. Edge Function secrets

Supabase injects `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` (plus `SUPABASE_PUBLISHABLE_KEYS`, `SUPABASE_SECRET_KEYS`, `SUPABASE_JWKS`, `SUPABASE_DB_URL`). Don't set those. Code today reads exactly:

| Secret | Read by | Production value |
|---|---|---|
| `PIN_HMAC_SECRET` | `security` | **Fresh** 32 random bytes as 64 hex characters. Never reuse dev's. |
| `PIN_RESET_REDIRECT_URL` | `security` | decision 5. It must match the redirect allow-list in §3. |
| `CORS_ORIGINS` | `security`, `org` | decision 5 (comma-separated, exact origins, no trailing slash) |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | both | platform-provided (decision 7) |

Placeholders for later slices. **Don't set them now.** Their exact names are fixed by each slice's approved blueprint, not here:
- Cloudflare Email Sending REST API token (and account id) for application email, plus the worker secret (kept in Vault for pg_cron → pg_net): **added when slice 03 (invitations / email outbox) ships.** Email-Sending-only, separate from the SMTP token, one per environment (decision 4).
- Paystack secret for Resolve Account Number and the bank list: **added when slice 05 (payout accounts) ships** (owner decision 2026-10-08, W-17).
- OpenAI receipt extraction: **added with the withdrawals/payout/verification slice.** Automated payouts stay deferred (W-26).

Set the secrets without echoing them:
```sh
prod_guard || exit 1
umask 077
f=$(mktemp)
{
  printf 'PIN_HMAC_SECRET=%s\n' "$(openssl rand -hex 32)"
  printf 'PIN_RESET_REDIRECT_URL=%s\n' 'https://app.elivatewallet.com/'          # decision 5
  printf 'CORS_ORIGINS=%s\n' 'https://app.elivatewallet.com,https://admin.elivatewallet.com'
} > "$f"
# Decision 8 (b): copy the value once for the owner's password manager, then clear the clipboard.
#   grep '^PIN_HMAC_SECRET=' "$f" | cut -d= -f2- | tr -d '\n' | pbcopy   # owner pastes it, then:
#   printf '' | pbcopy
supabase secrets set --env-file "$f" --project-ref "$PROD_REF"
rm -P "$f" 2>/dev/null || rm -f "$f"
supabase secrets list --project-ref "$PROD_REF" -o json | jq -r '.[].name' | sort   # names only
```
Expect the three custom names plus the platform-provided ones. Never use `supabase secrets list` output other than names.

---

## 6. Migrations, functions and smoke checks

### 6.1 Migrations
```sh
prod_guard || exit 1
cd backend
supabase db push --project-ref "$PROD_REF" --dry-run
```
Expect exactly the files in `backend/supabase/migrations` at the release commit, in order, and nothing else. On 2026-10-08 that is the 9 slice 01–02 files (`20261008000100_foundation`, `…0200_accounts`, `…0300_pin_and_sessions`, `…0400_platform_admin_and_status`, `…0500_review_fixes`, `…0600_admin_lock_order`, `…0700_org`, `…0800_authz`, `…0900_org_commands`), plus `20261009000100_tidy_up` once PR #5 merges, plus whatever slices 03–05 add. **Abort point:** if anything else is listed, stop.

```sh
supabase db push --project-ref "$PROD_REF"          # if prompted for the DB password, the OWNER types it; never pass -p
supabase migration list --project-ref "$PROD_REF"   # local and remote columns identical
```
Don't use `--include-seed` (there is no seed and production gets none) or `--include-all`.

### 6.2 Functions
Both functions verify the JWT at the gateway (`[functions.*] verify_jwt = true` in `config.toml`). **Don't pass `--no-verify-jwt`.**
```sh
prod_guard || exit 1
supabase functions deploy security --project-ref "$PROD_REF" --use-api
supabase functions deploy org      --project-ref "$PROD_REF" --use-api
supabase functions list --project-ref "$PROD_REF"   # both ACTIVE
```
`--use-api` bundles on Supabase's side, so no container runtime is needed. Without it, Colima must be running. Don't use `--prune`.

### 6.3 Smoke checks (no user data)
`P=https://$PROD_REF.supabase.co`, and `K=` the production **publishable** key from Settings → API Keys (public, but keep it out of Git and docs).

| # | Check | Command | Expected |
|---|---|---|---|
| S1 | Private schemas not exposed | `curl -s "$P/rest/v1/accounts?limit=0" -H "apikey: $K" -H "Accept-Profile: identity"` | `PGRST106`, "Only the following schemas are exposed: public, graphql_public, api" |
| S2 | `api` exposed but not executable by anon | `curl -s -X POST "$P/rest/v1/rpc/security_state" -H "apikey: $K" -H "Content-Profile: api" -H "Content-Type: application/json" -d '{"p_user_id":null,"p_session_id":null}'` | `42501 permission denied for schema api` |
| S3 | Gateway JWT check | `curl -s -o /dev/null -w "%{http_code}" "$P/functions/v1/security/state"` and the same for `org/workspaces` | `401` |
| S4 | CORS allows the app | `curl -s -D - -o /dev/null -X OPTIONS "$P/functions/v1/security/state" -H "Origin: https://app.elivatewallet.com" -H "Access-Control-Request-Method: GET"` | `204` with `access-control-allow-origin: https://app.elivatewallet.com` |
| S5 | CORS refuses others | the same with `Origin: https://example.com` | no `access-control-allow-origin` header |
| S6 | Public auth settings | `curl -s "$P/auth/v1/settings" -H "apikey: $K" \| jq '{disable_signup, mailer_autoconfirm, external}'` | `disable_signup:false`, `mailer_autoconfirm:false`, only `email:true` |
| S7 | Advisors | `supabase db advisors --project-ref "$PROD_REF" --type security --level info` | Only `rls_enabled_no_policy` (INFO) on the 24 private tables, which is intended deny-all. No leaked-password warning. |
| S8 | Function boot | Dashboard → Edge Functions → logs for both | No `Missing environment variable` errors |

**Abort point:** any mismatch → stop and report. Nothing user-facing depends on production yet.

---

## 7. First platform admin

Blueprint 01 Q3: the first admin is the owner-named email, created by a **one-time operation that is never stored in Git**. There is no bootstrap function or migration. `api.grant_platform_admin` requires an existing admin, so the first row is inserted directly, with the same lock and audit event the command uses (`identity.platform_admins.granted_by` is nullable for exactly this reason).

Preconditions: §8 steps 1–4 are done for `FIRST_ADMIN_EMAIL` (account exists, email confirmed, PIN set).

Agent runs this once, substituting the email and date in the session only:
```sh
prod_guard || exit 1
supabase db query --project-ref "$PROD_REF" "$(cat <<'SQL'
do $$
declare
  v_user uuid;
  v_uid text;
  v_reason constant text := 'Initial platform admin named by the owner on <YYYY-MM-DD>';
begin
  perform pg_advisory_xact_lock(hashtextextended('identity.platform_admins', 0));
  if exists (select 1 from identity.platform_admins where revoked_at is null) then
    raise exception 'first_admin_already_exists';
  end if;
  select a.user_id, a.uid into strict v_user, v_uid
  from auth.users u
  join identity.accounts a on a.user_id = u.id
  where lower(u.email) = lower('<FIRST_ADMIN_EMAIL>')
    and u.email_confirmed_at is not null;
  insert into identity.platform_admins (user_id, granted_by, grant_reason)
  values (v_user, null, v_reason);
  perform audit.record('platform_admin.granted', null, null, v_user, v_reason,
    null, jsonb_build_object('bootstrap', true));
  raise notice 'platform admin granted to %', v_uid;
end $$;
SQL
)"
```
- `into strict` fails unless exactly one confirmed account matches, and the guard refuses to run if an admin already exists. Both make it safe to re-run.
- The notice prints only the public UID (`EW-…`). Don't echo the email back into logs or docs.
- Then add a second admin in the app (`POST /security/admin/admins/grant`, reason and PIN step-up) when the admin UI exists (decision 6).

---

## 8. Real sign-up and email delivery test (OWNER's own address)

No frontend exists yet, so the owner drives the Auth and function APIs from their terminal. Passwords and PINs are read with `read -s` and never echoed. `P` and `K` are as in §6.3.

1. **Sign up (OWNER):**
   ```sh
   read -r EMAIL; read -rs PW
   curl -s -X POST "$P/auth/v1/signup" -H "apikey: $K" -H "Content-Type: application/json" \
     -d "$(jq -n --arg e "$EMAIL" --arg p "$PW" '{email:$e,password:$p}')" | jq '{id: .id, confirmation_sent_at}'
   ```
   Expect **exactly one** "Confirm your signup" email.
2. **Inspect the email (OWNER):** in Gmail use "Show original", or open the raw headers in another client. Required:
   - `Authentication-Results: … spf=pass smtp.mailfrom=…@cf-bounce.elivatewallet.com` (or the decision-4 domain)
   - `dkim=pass header.d=elivatewallet.com` (selector `cf-bounce`)
   - `dmarc=pass`
   - `From: Elivate Wallet <noreply@elivatewallet.com>`. The confirmation link points to `https://$PROD_REF.supabase.co/auth/v1/verify?…&redirect_to=https://app.elivatewallet.com…`.
   - The message arrived in the inbox, not spam.
3. **Confirm:** click the link. While the app isn't deployed, the redirect target may show an error page. That's fine, because the email is confirmed at `/verify` before the redirect.
4. **Sign in and set the PIN (OWNER):**
   ```sh
   TOKEN=$(curl -s -X POST "$P/auth/v1/token?grant_type=password" -H "apikey: $K" -H "Content-Type: application/json" \
     -d "$(jq -n --arg e "$EMAIL" --arg p "$PW" '{email:$e,password:$p}')" | jq -r .access_token); unset PW
   curl -s "$P/functions/v1/security/state" -H "Authorization: Bearer $TOKEN" -H "apikey: $K" | jq '.ok, .data.gate'
   # expect true, "pin_setup_required"
   read -rs PIN
   curl -s -X POST "$P/functions/v1/security/pin/set" -H "Authorization: Bearer $TOKEN" -H "apikey: $K" \
     -H "Content-Type: application/json" -d "$(jq -n --arg p "$PIN" '{pin:$p,pinConfirm:$p}')" | jq .ok; unset PIN
   ```
   **Abort point:** if `security/state` returns `401` with a valid token (gateway "Invalid JWT"), the gateway JWT check doesn't accept the project's asymmetric (ES256) tokens (see §10). Stop. Fixing it is a reviewed backend change, not something to adjust on the fly.
5. Run **§7** now.
6. **PIN-reset email (OWNER):** `curl -s -X POST "$P/functions/v1/security/pin/reset/request" -H "Authorization: Bearer $TOKEN" -H "apikey: $K" | jq .ok`. Expect **exactly one** magic-link email. Repeat the header checks from step 2. Its link must redirect to `PIN_RESET_REDIRECT_URL`. A second request within 60 s must return `rate_limited` **and send no email**. Don't complete the reset unless you want to test it.
7. **Exactly one email per Auth event:** count the messages in the inbox (expected: 1 confirmation and 1 reset). Cross-check **Cloudflare → Email Service → Email Sending → Logs/metrics** (the same count, delivered) and **Supabase → Logs → Auth** (one mail send per event). More than one send for an event means a duplicate path. Stop and investigate (`01-domain-rules.md` forbids a second Auth email path).
8. `unset TOKEN EMAIL`.

---

## 9. Rollback, abort points and record-keeping

| Where | Abort if | Roll back by |
|---|---|---|
| §2.3–2.4 | Ref, name or region mismatch, or the project isn't empty | Nothing changed. Stop. |
| §2.5 | Workers Paid not active, or the domain isn't "ready" | Nothing changed. Owner fixes it, then resume. |
| §3–4 | A setting can't be set, or the SMTP test fails | Restore the recorded "before" values in the dashboard. |
| §5 | Wrong secret value | `supabase secrets set` again (or `secrets unset NAME`). No redeploy needed. A regenerated `PIN_HMAC_SECRET` is harmless only **before** any PIN exists. |
| §6.1 | Dry-run lists anything other than the release commit's migrations | Stop. A failed real push stops at the failing file; earlier files stay applied. There are no down-migrations, and the project has no user data yet. With owner approval, the cleanest reset is deleting and recreating the project (back to §2). |
| §6.2–6.3 | Smoke mismatch | Redeploy the function from the last good commit. Fix config and re-run the checks. |
| §7 | `first_admin_already_exists` or no or several matches | Nothing was written (one transaction). Investigate. Never insert by hand. |
| §8 | Missing or duplicate email, SPF/DKIM/DMARC not `pass`, or `401` on a valid JWT | Stop. Production stays unused until fixed. Don't announce sign-ups. |

**Record-keeping (agent, last step):**
1. Update the `AGENTS.md` workspace snapshot with an "Update <date> (production)" line. Include: the production ref, name and region; compute/backup choice; the migrations applied (first and last version); `security` and `org` deployed with JWT verification; secret **names** set; SMTP on Cloudflare with sender X (token entered by the owner); first platform admin created (UID only, no email); and §8 results (SPF/DKIM/DMARC pass, one email per event). Also state that `supabase config push` and `supabase link` remain forbidden for production.
2. Update U-11 in `00-product.md` if real delivery and the paid plan are now confirmed.
3. Commit on a branch and open a PR as usual. Never commit refs to secrets, emails, tokens or keys.

---

## 10. Drift and risks found in dev (read-only, 2026-10-08)

Checked: project metadata, migration history, Edge Functions, secret **names**, security advisors, extensions, public Auth settings, the public JWKS, anonymous REST/function probes, and the Cloudflare Email Sending limits and domain status. **Not checked:** the full Auth config (SMTP fields, rate limits, session time-box, redirect list, templates). The Management API token is in the macOS keychain, and reading it needed an interactive prompt. The owner should compare those settings with §3 in the dashboard.

Matches the repo:
- Migrations: all 9 (`20261008000100`–`0900`) applied, with no extras.
- Functions: `security` (v2) and `org` (v1) are ACTIVE with `verify_jwt: true`.
- Exposed schemas are exactly `public, graphql_public, api`. Private schemas return `PGRST106`. Anonymous calls to `api.*` return `permission denied for schema api`.
- Unauthenticated function calls return 401. CORS refuses an unknown origin.
- Signup is on, autoconfirm is off, and email is the only provider.
- Security advisors report only the intended `rls_enabled_no_policy` INFO on 24 private tables. No leaked-password warning, so that protection appears to be on.
- Organization is on Pro. Project is in `eu-west-2`, Postgres 17.6.

Drift:
1. **Resolved 2026-10-08 (owner-approved): leftover legacy function secrets in dev.** `ELIVATE_APP_ORIGIN`, `NUBAN_API_KEY`, `OPENAI_API_KEY`, `OPENAI_RECEIPT_MODEL` and `PAYOUT_VERIFIER_SECRET` were unset. Don't recreate them in production; later slices name their own secrets.
2. **Resolved 2026-10-08 (owner-approved): dev `CORS_ORIGINS` included the production origin.** It is now `http://localhost:5173,http://127.0.0.1:5173,http://localhost:3000,http://127.0.0.1:3000`, so a production frontend can't reach the dev backend.
3. **Dev project name is the bare "Elivate Wallet",** and the main checkout's `backend/supabase/.temp` is linked to it. The owner approved renaming it "Elivate Wallet — Development" (decision 3); the rename hasn't been done yet.
4. `config.toml` `additional_redirect_urls` contained `https://127.0.0.1:3000` (https) while `site_url` is `http://127.0.0.1:3000`. Fixed to `http://` in the backend tidy-up (PR #5, local only). Production must not copy any localhost entry.

Risks:
- **Gateway JWT check vs asymmetric signing keys (unverified, potentially blocking).** Dev signs user JWTs with **ES256** (public JWKS), and both functions keep the gateway's `verify_jwt = true`. Supabase's signing-key docs warn that functions using the Verify JWT setting can break under the new keys and recommend turning it off and verifying in code. The code already verifies the token with `auth.getClaims` and takes `sub`/`session_id` only from it. No authenticated call has run against dev yet (no real users), and CI runs on a local HS256 stack, so this is untested end to end. **The owner deferred the first real sign-up and the signed-in call test on dev (2026-10-08), so this risk stays open.** §8 step 4 is the first real test. If it fails, the fix (`verify_jwt = false`, relying on `getClaims`) is a reviewed change to `config.toml` and the blueprint, not a production tweak. Ideally, test it in dev first with the owner's dev account.
- **Legacy API keys sunset** (decision 7): the functions depend on `SUPABASE_ANON_KEY`/`SUPABASE_SERVICE_ROLE_KEY`, which Supabase says work until the end of 2026.
- **Email capacity:** the Cloudflare account quota is currently **200 a day**, shared by dev and production. Owner action: request an increase (§1). Supabase's custom-SMTP default is 30 Auth emails an hour, and sign-ups and PIN resets share that budget. Request a Cloudflare increase and size the Supabase limit before onboarding a network.
- **Paid plan unconfirmed:** the Workers Paid subscription couldn't be read with the available token; the owner will confirm it (§1). Email Sending usage shows **0 sent**, consistent with real delivery never having been tested (U-11).
- **DMARC `p=reject` without reporting:** misconfigured mail is silently rejected. Add `rua=`.
- **Key escrow:** `PIN_HMAC_SECRET` can't be read back from Supabase (decision 8).
- **Region is permanent:** there's no Supabase region in Africa (decision 1).
