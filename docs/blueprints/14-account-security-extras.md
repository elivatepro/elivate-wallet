# Blueprint 14 — Account and security extras (slice 9 follow-up)

Status: **built under the member build plan** (`docs/member-build-plan.md`, owner decisions during the build: "Devices", "Password", "PIN change") with the owner's answers of 2026-10-09 below. Contract: W-22 (devices, sessions, password), W-01 (recovery), A-05 (PIN), U-11 (security emails). Builds on Blueprint 10 (account and security) and Blueprint 13 (outbox, `notify.emit`, the bell). Migrations `2026100914xxxx`; pgTAP `140_`–`149_`.

Part A is for the owner. Part B is the build spec.

---

## Part A — What this slice does

### What's in it
1. **Where you signed in.** Every sign-in records the device, the IP address and Cloudflare's approximate city and country. Devices & sessions shows "Lagos, Nigeria (approx.)" under each device (Paper App v4 Z07, App v2 S03/S04). The IP itself is never shown, emailed or logged.
2. **Unusual sign-ins.** A sign-in from a city or country this account has never used, or from a device it has never used, is "unusual" (the account's very first sign-in never is). Devices & sessions lists them ("Windows · Edge · new location", "Signed in 3 Oct, 22:14 · now signed out", "Not you? Change password"), and each one sends the **A07 New sign-in** email and a bell item.
3. **Change your password while signed in** (new Paper Z08/Z09, approved 2026-10-09). Profile & security → Password → enter the new password and your PIN. A wrong PIN counts against the same 5 tries as everywhere else. Afterwards: "Password changed. Your other devices were signed out. This one stays signed in."
4. **After a password reset** (new Paper Z10): "Password changed. Any other devices signed in to your account were signed out." then the PIN as usual.
5. **Security emails** (Paper "Emails — Transactional v2"), each also a personal bell item: **A06 Password changed** (both a signed-in change and a reset), **A07 New sign-in** (unusual sign-ins only), **A08 PIN changed**.
6. Profile & security shows "Password · Changed 9 Oct 2026" with a Change button (Paper App v1 B09).

### Decisions (owner answers 2026-10-09)
| # | Question | Answer |
|---|---|---|
| Q1 | How is the location shown? | **City, country** from Cloudflare's own location for the request, marked "(approx.)". The IP is stored but never shown. |
| Q2 | How long are sign-in records kept? | **Kept; never deleted** ("vital info"). |
| Q3 | What is "unusual"? | **New location or new device**: a city/country or a device (device type · browser) never seen on this account before. The first sign-in is never unusual. |
| Q4 | Which security emails? | **A08 PIN changed, A06 Password changed, A07 on unusual sign-ins** only. |
| Q5 | What does a signed-in password change need? | **The PIN only** (no current password). |
| Q6 | Other devices after a password change? | Owner first chose "let them choose"; testing showed **Supabase Auth always signs out every other session when a password changes** (supported path, not configurable), so the owner decided: **always sign out, and say so** — no choice screen. |

### Decisions I applied (say if you want them changed)
- A07 for a sign-in that is only a new location (same device) keeps Paper's layout with the status "New location" and the headline "Your account signed in from a new place." (Paper draws only the new-device copy.)
- The email time is shown in UTC ("9 Oct 2026, 14:05 UTC"), like every other email so far; Paper's A06/A08 show WAT. No time zone is kept per person (owner decision 2026-10-08).
- A07's mono line is "Windows · Edge · Lagos" (the app's device label and the city), not Paper's "Chrome on Windows · Lagos".
- Z08 keeps the "Forgot your PIN?" link under the buttons, as the Change PIN page does.
- Location comes only from Cloudflare (no third-party lookup). In local development there is no location; the device rows then show no location line, and a sign-in with no known location is never "unusual" for its location.

### Paper
Built directly: App v4 Z07 and App v2 S03/S04 (Devices & sessions with location and Unusual sign-ins), App v1 B09 (Password row), Emails v2 A06/A07/A08 (Root poses `password-changed`, `new-sign-in`, `pin-changed`). Drafted and approved 2026-10-09: App v4 **Z08** Change password, **Z09** Password changed, **Z10** Reset — password saved (desktop and mobile).

### Not in it
- Email change (A04/A05): account email changes go through support (owner decision 2026-10-07).
- A "this wasn't me" lock button: the unusual-sign-in row links to Change password; sign out is on the same page.

---

## Part B — Build spec

### B1. Data (`identity` schema, private)
| Object | Rules |
|---|---|
| `identity.sign_ins` | `id`, `user_id`, `session_id` (unique; the Auth session, no FK so history survives sign-out), `created_at`, `method` (`password` \| `email_link` \| `recovery` \| `sign_up`), `ip` (`inet`, nullable), `city` (≤100), `country` (ISO 3166-1 alpha-2 or Cloudflare's `XX`/`T1`), `device` (≤60, the app's label "Mac · Chrome"), `user_agent` (≤300), `unusual` (bool), `reasons` (`new_location`, `new_device`). Immutable; never deleted (Q2). |
| `identity.password_changes` | `id`, `user_id`, `session_id`, `method` (`signed_in` \| `recovery`), `authorized_at`, `changed_at` (null until Auth saved it). A signed-in change is authorized by the PIN and must be recorded within 10 minutes; a recovery change is recorded once per recovery session. |
| `outbox.templates` + `notify.kinds` | `security.password_changed` (`at`, `path`), `security.new_sign_in` (`device`, `city`, `country`, `reason`, `path`), `security.pin_changed` (`at`, `path`); all personal (no network), Elivate-branded. |

Unusual (Q3): `new_location` when the sign-in has a city or country and no earlier sign-in of the account has the same city and country; `new_device` when no earlier sign-in has the same device label; neither when there is no earlier sign-in.

### B2. Commands and routes (`security` Edge Function, verified JWT)
| Route | Command | Input / checks | Result |
|---|---|---|---|
| `POST /sign-ins` | `api.record_sign_in` | `method`, `ip?`, `city?`, `country?`, `device`, `userAgent?`; live session (before the PIN); IP parsed as IPv4/IPv6; unknown fields rejected | `{ unusual }`; idempotent per session; audit `session.signed_in` (method and reasons, never the IP); unusual → A07 + bell |
| `GET /overview` | `api.security_overview` | gate `ready` | `{ passwordChangedAt, unusualSignIns[] }` (newest 10: device, city, country, reasons, signedInAt, signedIn, current) |
| `GET /sessions` | `api.list_sessions` | unchanged | each session gains `city`, `country` |
| `POST /password/authorize` | `api.authorize_password_change` | `pin`; gate `ready`; same counter/lock as `verify_pin` | `{ ok: true, changeId }` or `pin_incorrect`/`pin_locked` (committed) |
| `POST /password/changed` | `api.record_password_change` | exactly one of `changeId` (unconsumed, this session, ≤10 min) or `recovery: true` (session from an email link, ≤1 h old, once) | `{ changedAt }`; audit `password.changed`; A06 + bell |
| `POST /pin/change` | `api.change_pin` (unchanged) | — | audit `pin.changed` now also sends A08 + bell |

Errors reuse the envelope: `validation_error`, `pin_incorrect` (403, `attemptsRemaining`), `pin_locked` (423), `conflict` with `details.reason` `password_change_not_authorized` / `password_change_already_recorded`.

### B3. App server (BFF)
- **Recording a sign-in.** After `signInWithPassword` (`password`) and after every `/auth/confirm` `verifyOtp` (`sign_up`, `email_link`, `recovery`), the server posts `/security/sign-ins` with the IP from `CF-Connecting-IP`, `city`/`country` from the Worker's `request.cf`, the device label and the user agent. Best effort: a failure never blocks sign-in. Local e2e only (`E2E_GEO_HEADERS=1` with a loopback Supabase URL): location from `x-e2e-city`/`x-e2e-country`.
- **`POST /api/account/password`** `{ password, pin }` (JSON, signed in, not retried): password rules as sign-up → `/password/authorize` → `auth.updateUser({ password })` (supported Auth path; Auth signs out every other session) → `/password/changed` → `{ changedAt }`. `same_password` and weak passwords map to `validation_error` with a reason.
- **Reset:** `/reset-password` saves, records `/password/changed` with `recovery: true`, and shows Z10; "Continue to PIN" goes to the gate.
- `GET /api/account` adds `security: { passwordChangedAt, unusualSignIns }`.
- Pages: `/app/account/password` (Z08/Z09); Devices (location lines, Unusual sign-ins); Profile & security (Password row).

### B4. Emails and bell
Renderers in `_shared/email/notifications.ts` from Paper A06/A07/A08 (chip "Security", status Changed / New device / New location, Elivate sender, buttons to `/app/account` or `/app/account/devices`). Bell: "Password changed", "PIN changed", "New sign-in · Windows · Edge · Lagos". No IP, PIN, password or token in any email, bell item, audit row or log.

### B5. Tests
pgTAP `140_sign_ins.sql` (recording, idempotency, unusual rules, first sign-in, A07 + bell, immutability, privileges, no IP in audit/email/bell), `141_password_changes.sql` (PIN authorize with the shared counter and lock, change window, single use, recovery rules, A06 + bell, overview, and A08 + bell on `change_pin`). Deno: renderers (Paper copy, escaping, no unknown params) and the new routes (validation, IP parsing, error mapping). Vitest: client-context extraction, device/location labels. E2E `account-security.e2e.ts`: sign-ins from two places/devices produce the unusual row, A07 in Mailpit; change password (wrong PIN, then success; the other device is signed out; A06); reset → Z10 → PIN; change PIN → A08; screenshots of Z08/Z09/Z10, Devices and A06/A07/A08 compared with Paper.
