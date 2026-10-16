# Blueprint 42 — Push notifications (slice 42)

Status: **Approved 2026-10-16** (owner: "Let's build"; Paper "Push notifications v13 (approved
2026-10-16)" PN01–PN03 and the decisions below). Contract: P-05 (bell), U-11, F-02, T-03, P-06 (what a message
may show), `02-workflows.md` mobile readiness ("device/push architecture"). Builds on Blueprint
13 (bell, `notify.emit`, outbox worker), 14 (devices and sessions), 35 (install step), 41 (Hide
amounts). Migrations `2026100942xxxx`; pgTAP `420_`.

Part A is for the owner. Part B is the build spec.

---

## Part A — What this slice does

### Owner decisions (2026-10-16, binding)
| # | Question | Answer |
|---|---|---|
| Q1 | Which events push? | **Tasks + own money:** every "needs your action" task, plus income posted and a withdrawal approved, completed or not approved, for the wallet owner. |
| Q2 | What shows on a lock screen? | **Title + amount**, e.g. "Income posted · ₦250,000.00". Same limits as email (P-06): never account digits, balances, reasons or evidence. |
| Q3 | When does the app ask? | **After the install step** (last onboarding screen), plus an on/off switch in **Profile & security**. |
| Q4 | How much control? | **One switch per device.** Email keeps no opt-out. |

### What's in it
1. **PN01 "Know the moment money moves"** after the install step: "Turn on notifications" asks
   the browser's permission; "Not now" moves on. Shown only where push can work (below).
2. **PN02 Profile & security → Notifications → "Notifications on this phone"** ("this computer"
   on desktop), a switch for this device only. PN03 shows its other states: off, blocked by the
   phone's settings, and iPhone Safari before the app is installed.
3. **The push itself**, sent the moment the bell item is written (a few seconds, not a minute),
   for the Q1 kinds only. Tapping it opens the same page as the bell item.

### Push wording (title · line)
| Kind | Title | Line |
|---|---|---|
| Income posted | Income posted | ₦250,000.00, split across your pockets |
| Withdrawal approved | Withdrawal approved | ₦85,000.00. Payout is next. |
| Withdrawal completed | Withdrawal completed | Payout of ₦85,000.00 confirmed. |
| Withdrawal not approved | Withdrawal not approved | ₦85,000.00 is back in your pocket. |
| Withdrawal to approve | Withdrawal to approve | ₦85,000.00 is waiting for you |
| Payout to record | Payout to record | ₦85,000.00 to pay out |
| Payout record to fix | Payout record to fix | ₦85,000.00 needs a fix |
| Payout / evidence to review | Payout to review (Conversion / Adjustment / Returned funds to review) | ₦85,000.00 is waiting for you |
| Pocket move to approve | Pocket move to approve | ₦20,000.00 is waiting for you |
| Identity to review | Identity to review | Someone in your network is waiting for you |

Titles match the bell. Lines are the bell's without member names, bank •• last 4 or references
(Q2). With **Hide amounts** on for that device, the amount shows as the bell shows it hidden.

### Decisions I applied (say if you want them changed)
- **Sign-out stops push on that device.** A device's push belongs to its signed-in session:
  signing out, being signed out from Devices, or a password change that signs others out ends
  it. Signing in again as the same person on the same device turns it back on by itself; a
  different person starts with it off. No one gets someone else's money on their lock screen.
- **iPhone/iPad:** Apple only allows push for an installed app (iOS 16.4+). In Safari, PN01 is
  skipped and the switch says to add Wallet to the Home Screen first (PN03). Android, desktop
  Chrome/Edge/Firefox and macOS Safari work in the browser too.
- **Desktop** shows PN01's copy in the IA03 layout (panel left, art right); no new drawing.
- **A task done before its push leaves** (someone else approved first) is not pushed.
- **Not pushed** to a suspended or closed account.
- **Progress:** PN01 is part of the last step; the wizard stays "5 / 5" with the eyebrow "One
  last thing".

### Not in it
Per-category switches; push for team/account/security events; push from the admin console;
quiet hours; a native app. People who finished onboarding before this slice turn it on in
Profile & security (no prompt).

---

## Part B — Build spec

### B1. Data (`notify` schema, private)
| Object | Rules |
|---|---|
| `notify.push_kinds` | `key` → `notify.kinds`. The Q1 kinds: `money.income_posted`, `money.withdrawal_approved`, `money.withdrawal_completed`, `money.withdrawal_not_approved`, every `task.*`. Immutable like `notify.kinds`; later slices add rows. |
| `notify.push_subscriptions` | `id`, `user_id` → `identity.accounts`, `session_id` → `auth.sessions` **on delete cascade** (sign-out, revocation and password-change sign-outs end push), `endpoint` (unique, https, allow-listed host, ≤ 1000 chars), `p256dh` (base64url, 65-byte point), `auth` (base64url, 16 bytes), `device_label` (from the session's device label), `hide_amounts` bool, `created_at`, `last_success_at`, `failures` int. A new subscription with the same endpoint replaces the old row (one person per device). |
| `notify.push_jobs` | One per pushed bell item: `item_id` (pk, → `notify.items` on delete cascade, so the 90-day housekeeping clears them), `status` (`pending`, `processing`, `retry_scheduled`, `sent`, `skipped`, `dead_lettered`, same shape checks as `outbox.deliveries`), `attempt_count`, `max_attempts` 6, `next_attempt_at`, lease columns, `skipped_reason`, `updated_at`. |
| `notify.push_attempts` | Append-only (only a removed device's id is cleared): `job_id`, `lease_token`, `subscription_id` (set null on delete), `outcome` (`sent`, `retryable_failure`, `gone`, `permanent_failure`, `lease_expired`), `provider_status`, `error_code`, `latency_ms`, `at`. Never the endpoint or payload. Goes with its job (item retention). |

Endpoint host allow-list (SSRF guard, checked in SQL and again in the worker):
`fcm.googleapis.com`, `updates.push.services.mozilla.com`, `*.notify.windows.com`,
`web.push.apple.com`, `*.push.apple.com`.

### B2. Writing (same transaction as the bell item)
- `notify.emit` inserts a `notify.push_jobs` row when the kind is in `notify.push_kinds` and the
  user has at least one subscription. Replays never duplicate (pk = item id).
- Once per transaction (`set_config('notify.push_kick', '1', true)` guard) it calls
  `outbox.trigger_worker()`; pg_net sends only after commit, so a push leaves within seconds.
  The per-minute cron run is the safety net for retries.

### B3. Sending (`outbox-worker`, new push pass; no new function, cron or Vault pair)
- `api.push_claim(worker, batch, lease)` leases due jobs and returns, per job, the item's kind,
  only `amount`, `currency`, `subject` and `path` from its params, and the user's live
  subscriptions (newest 10). It skips (with a reason) when the task is already resolved
  (`resolved`), the account is suspended or deactivated (`account_inactive`), the item is older
  than the 12 h push TTL (`expired`, e.g. jobs that waited for VAPID keys), or no live
  subscription is left (`no_device`). One `api.push_report(item, lease, results[])` records an
  attempt per device (idempotent per lease); `gone` (404/410) deletes that subscription.
- Retries: backoff 30 s, 2 min, 10 min, 30 min, 2 h; then dead-lettered (sent to some devices
  counts as sent).
- `_shared/push/webpush.ts`: RFC 8291 `aes128gcm` payload encryption and RFC 8292 VAPID (ES256
  JWT, 12 h expiry) on WebCrypto, no dependency. Headers: `TTL` 43200, `Urgency` `high` for tasks
  and `normal` for money, `Topic` = item id without dashes, so a retry replaces rather than
  repeats.
- `_shared/push/text.ts`: the Part A wording from the kind and safe params; amounts from the
  exact decimal string (never floats); hidden per `hide_amounts`. Payload
  `{ v: 1, id, title, body, path }`, ≤ 1 KB; `path` checked against the bell's link allow-list.
- Secrets (Edge): `PUSH_VAPID_PUBLIC_KEY`, `PUSH_VAPID_PRIVATE_KEY`, `PUSH_VAPID_SUBJECT`
  (`mailto:support@elivatewallet.com`). Without them the pass claims nothing (jobs wait). Local
  tests may set `PUSH_TEST_ENDPOINT_BASE` (only `http://host.docker.internal:*`, like
  `CLOUDFLARE_API_BASE`) so e2e sends to a fake push service.

### B4. API (`identity` Edge Function, verified JWT; personal, no `x-membership`)
| Route | RPC | Notes |
|---|---|---|
| `PUT /push/subscription` | `api.push_subscribe` | `{ endpoint, keys: { p256dh, auth }, hideAmounts }`; validates shape and host; binds to the caller's session. |
| `GET /push/subscription?endpoint=` | `api.push_subscription_state` | `{ on }` for this session's endpoint. |
| `DELETE /push/subscription` | `api.push_unsubscribe` | `{ endpoint }`; own rows only; idempotent. |

New errors reuse the envelope: `validation_error` (`details.field`), `conflict` with
`details.reason = 'push_host_not_allowed'`.

### B5. Frontend
- **BFF:** `PUT|GET|DELETE /api/push/subscription` (JSON bodies only, schema-checked, no
  workspace echo: personal). GET also returns the VAPID `publicKey` (null when not set up), from
  `PUSH_VAPID_PUBLIC_KEY`, a Worker var in `wrangler.jsonc` (public).
- **`#lib/client/push.ts`:** `pushSupport()` → `supported | ios-install-first | unsupported`;
  `enablePush()` (permission from the tap, `subscribe({ userVisibleOnly: true,
  applicationServerKey })`, PUT); `disablePush()` (DELETE, then `unsubscribe()`); the Hide
  amounts switch re-PUTs `hideAmounts`. After sign-in, if permission is granted, a browser
  subscription exists and `localStorage['ew_push_owner']` matches the user, it re-PUTs quietly.
- **Service worker:** `push` → `showNotification(title, { body, tag: id, icon, badge, data:
  { path } })`, ignoring payloads that fail the shape check (`#lib/push` `parsePushPayload`;
  links through `#lib/app-path`); `badge` is `/icons/badge-96.png` (white mark, Android);
  `notificationclick` → focus an open app window and navigate to `path`, else
  `openWindow(path)`; `pushsubscriptionchange` → resubscribe with the same key; the app saves
  it on its next start (`resumePush`, which knows Hide amounts).
- **Onboarding:** `/onboarding/notifications` after `install`, only when `pushSupport()` is
  `supported` and `Notification.permission === 'default'`; cookie `ew_onb_push` like
  `ew_onb_install`; moves on by itself when permission is granted or denied.
- **Profile & security:** the Notifications group (PN02) between Security and Devices; PN03
  states; "this phone" / "this computer" from `installDeviceFor`.

### B5a. Deploy
Edge secrets `PUSH_VAPID_PUBLIC_KEY`, `PUSH_VAPID_PRIVATE_KEY`, `PUSH_VAPID_SUBJECT` (values in
the ignored repo-root `.env`); redeploy `outbox-worker` and `identity`; the Worker var ships with
`wrangler.jsonc`. The immediate kick needs the existing Vault `outbox_worker_url` /
`outbox_worker_secret` pair; without it pushes leave on the next minute's run.

### B6. Tests
pgTAP `420_push` (kinds, subscribe/replace/unsubscribe, host allow-list, session cascade, job
per Q1 kind only, kick once per transaction, claim skips resolved/inactive/no device, gone
deletes, retention cascade, privileges); Deno: RFC 8291 test vector, VAPID JWT verifies with
the public key, wording for every Q1 kind with and without hidden amounts, payload size,
endpoint allow-list, worker pass with a fake transport; Vitest: `pushSupport`, step order,
switch states; e2e `push.e2e.ts`: PN01 and the switch with Chromium's granted permission, a job
delivered to the fake push service and decrypted there, click opens the path.
