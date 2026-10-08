# Blueprint 10 — Account and security

Status: **built under the owner's "build everything now" instruction (2026-10-08); Paper batch 1 (`App — Screens v4` Z02–Z07) approved by the owner 2026-10-08 with the decisions in Part A**, scope and decisions from `docs/member-build-plan.md` ("Accounts, auth and security"). Contract: W-01 (recovery, Turnstile), W-17 (replace), W-22 (profile, PIN, devices and sessions), A-05, T-01. Builds on Blueprints 01 (PIN, sessions, gate, step-up), 05 (payout accounts and replacement) and 06 (profile). Migrations `2026100910xxxx`; pgTAP `100_`–`109_`.

Part A is for the owner: what this slice does, in plain language. Part B is the exact build spec.

---

## Part A — What this slice does

### What's in it
1. **Profile & security page.** One place for your name, legal name (from the NIN, locked), phone, rank, email, your PIN and your signed-in devices (Paper "App — Screens v1" B09/B10). Reached from the account menu and the More tab.
2. **Devices & sessions.** See every device signed in to your account, sign one out, or sign out all others (Paper "App — Screens v2" S03/S04). Signing a device out also closes its PIN window.
3. **Change PIN.** Type your current PIN, then the new one twice (S05/S06). A wrong current PIN counts against the same 5 tries as the PIN screen, so this page can't be used to guess PINs; the fifth wrong try locks the PIN and the email reset applies. After a change, every other device has to enter the new PIN.
4. **Edit profile** (Paper Z04, a dialog on Profile & security). Photo, display name, phone (locked when the NIN supplied it) and rank. Legal name, UID and email stay as they are (email changes go through support). No time zone (owner decision).
5. **Forgot password.** "Forgot password?" on the sign-in page → enter your email → Supabase sends the "Reset your Elivate Wallet password" email → the link opens the Continue page (nothing happens until you press Continue, so email scanners can't use the link) → choose a new password → enter your PIN as usual. The answer on screen is the same whether or not the email has an account.
6. **Turnstile.** Cloudflare's "are you human" check on sign-in, sign-up and forgot-password. Invisible (owner decision): nothing shows unless the check fails; then Cloudflare's failed widget, "Run the security check again to …" and a disabled button appear (Paper Z02). The server checks it before Supabase sees the password or sends any email.
7. **Replace a payout account** (Paper Z05). From the account's menu: reason and PIN in the dialog, then look up the new account and save. The old one stays in history as "replaced", primary moves to the new one, and the new one can receive withdrawals 24 hours later (Blueprint 05 rules, already in the backend).

### Decisions I applied (say if you want them changed)
| # | Question | What I did |
|---|---|---|
| Q1 | After a password reset, sign out other devices? | **Yes.** Anyone signed in with the old password is signed out; this device continues to the PIN. |
| Q2 | After a PIN change, close the PIN window on other devices? | **Yes,** like a PIN reset (A-05). This device keeps a fresh 5-minute window. |
| Q3 | Can the new PIN equal the current one? | **No** (`validation_error`, `same_pin`). |
| Q4 | Does signing a device out need the PIN? | **No** (owner decision 2026-10-08): "Sign out all others" asks for confirmation only (Paper Z07). |
| Q5 | Turnstile visibility | **Invisible** (owner decision 2026-10-08): managed mode with "interaction-only"; the failed state is Z02. Z01 (check passed) is superseded. |
| Q6 | Time zone on the profile | **Dropped** (owner decision 2026-10-08) from B09 and Z04; rank stays editable. |

### Paper
Built from: "Authentication v2" 02/03/06/07 (sign-in link, forgot password), "App — Screens v1" B09/B10 (Profile & security), "App — Screens v2" S03–S06 (devices, change PIN), "App — Screens v4" Z02–Z07 (approved 2026-10-08: Turnstile failed state, set a new password, edit profile, replace and remove payout account, sign out all others). The new-account lookup after Z05 reuses the add-account card in "replace" mode (not separately drawn).

### Not in it
- Approximate location and "Unusual sign-ins" on Devices & sessions (Paper S03/S04/B09): the backend keeps no IP (Blueprint 01) and there is no sign-in history yet. Needs an owner decision on what to store.
- Password change while signed in and the "Password · Changed …" row (B09/B10): not in this slice's scope; the recovery flow covers a forgotten password.
- A PIN-changed security email: the notification slice owns the email catalogue.

---

## Part B — Build spec

### B1. Data
No new tables. `identity.record_wrong_pin(user, session, failed_attempts, request)` (private helper, not definer) holds the wrong-PIN bookkeeping: +1 attempt, lock at 5 (closing every PIN window, audit `pin.locked`), else audit `pin.rejected` and return `{ ok: false, code: 'pin_incorrect', attemptsRemaining }`.

### B2. Commands and routes

| Route | Command | Input | Checks | Result |
|---|---|---|---|---|
| `POST /security/pin/change` | `api.change_pin(user, session, current_hmac, new_hmac, request)` | `currentPin`, `pin`, `pinConfirm` | Edge: all `^[0-9]{4}$`, `pinConfirm = pin` (`mismatch`), `pin ≠ currentPin` (`same_pin`), unknown fields rejected. DB: gate `ready` (`require_session`); HMAC hex; credential row locked `FOR UPDATE`; locked → `pin_locked`; wrong current → returned `pin_incorrect`/`pin_locked` (committed, not raised) | New bcrypt hash, attempts reset, other sessions' proofs deleted, fresh proof here, audit `pin.changed`; returns the security state |
| `GET /security/sessions`, `POST /security/sessions/revoke` | existing (Blueprint 01) | — | — | — |
| `PATCH /identity/profile` | existing (Blueprint 06) | — | — | — |
| `POST /payout/lookups` + `POST /payout/accounts` | existing (Blueprint 05), with `replacesPayoutAccountId` and `reason` | — | — | — |

Errors map like `POST /security/pin/verify`: `pin_incorrect` 403 with `details.attemptsRemaining`, `pin_locked` 423. No new error codes.

### B3. App server (BFF)
Account-level JSON endpoints, signed in, `application/json` only, no workspace echo (they do not depend on the workspace), never retried:
- `GET /api/account` → `{ profile, email, sessions }` (email from the verified session; the photo key never leaves the server).
- `POST /api/account/sessions/revoke` `{ sessionId } | { allOthers: true }`.
- `POST /api/account/pin` `{ currentPin, pin, pinConfirm }`.
- `PATCH /api/account/profile` `{ displayName?, phone?, rank?, idempotencyKey }`.
- `POST /api/profile/photo` (multipart, Z04 "Change photo"): Blueprint 06 B4 storage rules.
- Replace (Z05): the dialog's reason and PIN are handed to the add-account page in memory only (never storage or URL) and used once.
- Payout: `POST /api/payout-accounts/lookup` accepts `replacesPayoutAccountId`; `POST /api/payout-accounts` accepts `reason`.

Recovery: `/forgot-password` (Turnstile → `auth.resetPasswordForEmail(email, { redirectTo: <origin>/auth/confirm })`, neutral answer except rate limit/outage) → Recovery email `{{ .SiteURL }}/auth/confirm?token_hash={{ .TokenHash }}&type=recovery` → POST Continue → `verifyOtp({ type: 'recovery' })` sets the short-lived HttpOnly `ew_recovery` cookie → `/reset-password` (only with that cookie and a session) → `auth.updateUser({ password })` → `auth.signOut({ scope: 'others' })` → `/workspaces` (gate → PIN). The Recovery session cannot complete a PIN reset (that needs an `otp`/`magiclink` session, Blueprint 01).

Turnstile: widget `Elivate Wallet app (auth forms)` (site key `0x4AAAAAAFRmbsf5MlhIVVui`), managed mode, domain `app.elivatewallet.com`, rendered explicitly with `appearance: interaction-only`, size normal and an `action` per form; on `error-callback` the form shows Z02 and disables submit. The form action posts `secret`, `response`, `remoteip` (`CF-Connecting-IP`) and an idempotency key to siteverify, validates the answer at runtime, and refuses a failed check or a token minted for another form. Missing keys or an unreachable siteverify fail closed. CSP adds `https://challenges.cloudflare.com` to `script-src` and `frame-src`. Keys: Worker secrets `TURNSTILE_SITE_KEY`, `TURNSTILE_SECRET_KEY`; local development and e2e use Cloudflare's documented test keys.

### B4. Configuration
- Auth templates: Recovery link changed to the token_hash form in `backend/scripts/auth-email-templates.ts`; applied to dev with the script's `--payload` through the Management API (templates and subjects only, never `supabase config push`).

### B5. Tests
pgTAP `100_change_pin.sql`: needs a PIN; raw PINs rejected; same PIN refused; wrong current PIN counted and audited; success resets attempts, closes the other session's window, opens a fresh one here; old PIN fails, new works; audit has no PIN material; 5 wrong current PINs lock and close every window; a locked PIN cannot be changed; only `service_role` may call it.
Deno `security_change_pin_test.ts`: actor from the token, HMACs only, no PIN in logs; validation order and codes; `pin_incorrect`/`pin_locked` mapping; 401 without a token.
Unit: Turnstile verification (fail closed, missing/oversized token, posted fields, rejected/other-form tokens, outage), device labels and activity text.
E2E `account.e2e.ts`: Turnstile on the three forms and a token-less POST refused; forgot password through Mailpit to a new password and the PIN; change PIN (wrong try, then success; the other device must re-enter the PIN); sign out all others; profile edit.
