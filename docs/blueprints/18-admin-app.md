# Blueprint 18 — Platform Admin app (slice 18)

Status: **answered 2026-10-10 (owner: "follow your recommendations"); undrawn screens are being
drafted in Paper for approval before the build.** Nothing is built yet.

### Decisions (owner answers 2026-10-10)
| # | Question | Answer |
|---|---|---|
| Q1 | Hosting | **One codebase, two Workers**: `frontend/` with an admin surface, Worker `elivate-wallet-admin` on `admin.elivatewallet.com`, host-only `ew-admin-auth` cookie (`SameSite=Strict`), its own secrets. Same repo and branch flow as every slice. |
| Q2 | Admin sign-in | **Password + PIN** (A-05, as A01b draws it) **plus Cloudflare Access** (named emails, one-time code) in front of the admin host. |
| Q3 | First admin | **One-time guarded SQL** (`production-readiness.md` §7) on dev, after owner approval. The email is still to come from the owner (session only). |
| Q4 | Kill switches | Eight switches (withdrawals, payout recording = Paper "Remittance", transfers, conversion, income, adjustments, reversals, returned funds); **platform-wide and per network**; all running by default, no automatic restart, reason + PIN to stop and start; members see the X-series paused state; no email; a per-network stop shows in that President's Audit log as "Paused by Elivate". |
| Q5 | Feature flags | **Deferred again.** The flags half of A11/A12 is not built. |
| Q6 | Screen changes | Network "Change status" → **Support activation**; Subscriptions folded into the networks list; NIN queue kept as a simple list; allocation versions read-only on network detail; backups panel shows only real data or "Not configured"; undrawn screens drafted in Paper in one batch. |
| Q7 | Restores | **Guided manual restore**: automatic validation (ZIP, manifest, SHA-256, counts) and a read-only per-section diff; the restore itself is an operator procedure marked completed with notes; no automatic write-back. |

### Paper drafts for approval (2026-10-10, "Admin — Screens v1", desktop; mobile follows approval)
New sidebar on every draft: Overview, Search · Networks, Accounts, NIN reviews · Kill switches, Audit, Backups & restores, Failed emails, Admins ("Tenants" → "Networks", "Subscriptions" and "Flags" removed).

| Draft | Screen |
|---|---|
| A17d | Networks list (status filter, plan, period end, seats; replaces Subscriptions) |
| A18d | Accounts list (status filter, network, last sign-in, PIN state) |
| A19d | Failed emails (template, error code, network, tries 8/8, Requeue) |
| A20d | Platform admins (Add admin, Remove; "Initial setup" for the first) |
| A21d | NIN reviews (name on NIN, network · office, NIN last 4, Review) |
| A07v2d | Network detail: "Support activation" replaces "Change status"; per-network kill switches; pockets & split (read only) |
| A07bd | Support activation dialog (complimentary until a date, or development exception; reason + PIN) |
| A15rd | Restore review: team's reason, validation result, per-section differences (money tables "Kept · never overwritten"), Reject / Start restoring |
| A11v2d | Kill switches: 8 switches + "Stopped on one network"; feature flags removed |
| A11cd | Start a switch again (reason + PIN) |
| A01cd / A01dd / A01ed | Gates: not an admin, set your PIN first, PIN locked |

Root poses on the drafts reuse existing poses (A15rd uses the unused "Plus-minus card with glasses"); new poses can be generated on request. Copy fix for the built A11b: "every tenant" → "every network".
Contract: P-03 (platform operator), P-04 (domains: `admin.elivatewallet.com`), P-09 U-05/U-06/U-09,
01 A-05 (PIN step-up), 02 W-23 (platform administration, audit, flags, kill switches), W-24
(restores), T-03 (outbox requeue). Builds on Blueprints 01 (platform admins, account status), 03
(outbox), 04 (allocation versions), 06 (NIN reviews), 16 Q9 (support activation) and 17 (restore
requests that only Elivate moves). Migrations `2026100918xxxx`; pgTAP `180_`–`189_`.

Part A is for the owner. Part B is the build spec; it is written for the recommended answers
and is updated after the answers come in.

---

## Part A — What this slice does

### What already exists (survey, 2026-10-10)

Backend commands an admin can already call. All of them check `identity.platform_admins`,
need a reason, are idempotent and audited, and the writes need the PIN. None has a screen yet.

| What | Command | Route today |
|---|---|---|
| Change an account's status (active, restricted, suspended, deactivated; never yourself) | `api.set_account_status` | `POST security /admin/accounts/status` |
| Add / remove a platform admin (the last admin can't be removed) | `api.grant_platform_admin`, `api.revoke_platform_admin` | `POST security /admin/admins/grant`, `/revoke` |
| Support activation: complimentary period to a date, or the development exception (B16 Q9) | `api.activate_tenant` | `POST org /admin/tenants/:id/activate` |
| View any network's pocket/split versions (read only; Presidents edit them) | `api.admin_allocation_versions` | `GET ledger /admin/tenants/:id/allocation-versions` |
| NIN leader-review queue and decision | `api.admin_nin_reviews`, `api.decide_nin_review` | `GET/POST identity /admin/nin/reviews…` |
| Move a restore request (validating, in review, restoring, completed, rejected, failed) | `api.platform_advance_restore` | `POST org /platform/restores/:id/advance` |
| Failed emails (dead letters) and requeue | `api.outbox_dead_letters`, `api.outbox_requeue` | `GET security /admin/outbox`, `POST …/:id/requeue` |

Missing:
- **No cross-network reads at all.** There's no overview, no network or account list, no
  network or account detail, and no global search. Quick search (slice 10) only covers one
  workspace.
- **No "am I an admin" check** and no list of current admins.
- **No platform audit view.** Admin and account events are in `audit.security_events`, which
  has no reader. Network events are in `audit.tenant_events`, which only the President's log
  reads.
- **No kill switches or feature flags.**
- **No first admin on dev.** `docs/production-readiness.md` §7 has a one-time guarded SQL
  insert. It is not in Git as a migration, and it needs an existing account that has a
  confirmed email and a PIN.
- **No restore engine.** Restores are only status changes today. Nothing yet validates an
  archive, compares it with live data or applies it (see Q7).

Tests that already cover admin commands: `004`, `009`, `032`, `042`, `060`/`062`, `160`, `171`,
`173`.

### What Paper has ("Admin — Screens v1", A01–A16, desktop + mobile)

| Screens | What | Fit with the contract |
|---|---|---|
| A01/A02b | Admin sign-in (email + password) | OK |
| A01b/A02 | Step 2 of 2: **4-digit PIN** (the artboard is still named "MFA code") | Already matches A-05 (password + PIN) |
| A03/A04 | Overview: network count, kill-switch strip, networks table, open restores, recent audit | OK. Numbers come from live data |
| A05/A06 | Global search with tabs All / Accounts / References / Tenants / Teams, plus a tenant filter | OK. Bank account is an exact-match key and is shown masked |
| A07/A08 | Network detail: subscription, seats, Billing Owner, organisation counts, white-label "Not active"; buttons "Tenant audit" and "Change status" | **"Change status" has no backend** (see Q6). Support activation isn't drawn |
| A09/A10 | Account detail: memberships, status history, security (PIN set, sessions, last sign-in, unusual sign-ins); "Change account status" | OK |
| A09b | Change account status dialog (reason + PIN) | OK |
| A11/A12 | Kill switches (Withdrawals, Transfers, **Remittance**, Conversion, Income, Automated payouts "Deferred") + feature flags table + "New flag" | The switch list differs from your brief (see Q4). Flags depend on Q5 |
| A11b | "Stop withdrawals?" dialog (reason + PIN) | OK. The same dialog is reused to start a switch again |
| A13/A14 | Platform audit: filters (actor, action, tenant, dates), expandable before/after/correlation | OK |
| A15/A16 | Platform backups (shows "Not configured" for policy) + tenant restore requests with Validate → Review diff → Restore | **"Review diff" needs a diff that doesn't exist yet** (see Q7) |

Also in Paper: **X-series "withdrawals paused"** (App — Screens v2) is the member-facing screen
when a switch is on.

Not drawn. Each of these needs a Paper draft and your approval, or a cut (see Q6):
1. Networks list.
2. Accounts list.
3. Subscriptions list. It is in the sidebar but has no screen.
4. Support activation dialog (complimentary until a date, or the development exception).
5. Restore review screen (what "Review diff" opens) and the advance/reject/fail dialog.
6. Feature flag create/edit (only if Q5 = now).
7. Failed emails list with requeue.
8. NIN review queue.
9. Pocket/split versions viewer on network detail.
10. Platform admins list with add and remove.
11. Admin gates: "not an admin", "set your PIN first", PIN locked.
12. A network-level switch on network detail (only if Q4 includes network scope).

### The plan in one paragraph
1. A separate admin site at `admin.elivatewallet.com`, built from the same `frontend/` code,
   with its own Worker, its own cookies and its own secrets (Q1).
2. Sign-in is password + PIN, as drawn (Q2).
3. Every screen reads through new `api.admin_*` read functions. Each one checks that the caller
   is a platform admin and returns only the masked, allowlisted fields the screens show.
4. Kill switches are one table checked in the database's single permission choke point
   (`authz.require`). A stopped switch refuses only new operations. Cancellations, rejections,
   payouts already approved, reviews and unknown-outcome recovery keep working (Q4).
5. All admin writes reuse the existing commands, plus new ones for switches (and flags, if
   kept). Every write needs a reason and the PIN and is audited.
6. The platform audit is a read-only merged view of the security and network event logs.

### Questions (please answer; options, my recommendation first)

**Q1. Hosting and session isolation**
- **(a) Recommended: one codebase, two Workers.** `frontend/` gets a second Wrangler config.
  - The new Worker is `elivate-wallet-admin`, on the custom domain `admin.elivatewallet.com`.
  - Its own secrets: `SUPABASE_*`, `TURNSTILE_*` and `APP_SERVER_SECRET`. No R2 or Browser
    bindings unless a screen needs them.
  - A build-time surface flag makes each Worker serve only its own routes (`/admin/*` returns
    404 on app, member routes return 404 on admin).
  - The admin cookie is `ew-admin-auth`: host-only, `SameSite=Strict`, with no shared domain.
    The two sites never share a session, and signing in on one doesn't sign you in on the other.
  - Shares the Emberlit components, Edge client and contracts with no repo restructure.
- (b) A separate SvelteKit app (`admin/`) and its own Worker. The bundles are cleanest, but it
  needs a pnpm workspace and a shared UI package first, so it's a bigger change.
- (c) One Worker serving both hosts, split by hostname. Simplest, but admin and member code,
  secrets and CSP live in one deployment.
- Outward-facing steps under (a): a new Worker, a DNS custom domain, Worker secrets and one
  Supabase Auth redirect URL (`https://admin.elivatewallet.com`), added through the Management
  API on that field only. I'll ask before each one.

**Q2. Admin sign-in**
- **(a) Recommended: password + PIN, like members (A-05, as A01b already draws it), plus
  Cloudflare Access in front of `admin.elivatewallet.com`.**
  - Access allows only named email addresses, with a one-time code. It's free for small teams.
  - It stops anyone outside that list from even reaching the sign-in page.
- (b) Password + PIN only, exactly as members.
- (c) Supabase TOTP for admins only. This reopens the 2026-10-07 "no authenticator app"
  decision for this one group, and A01b would be redrawn.
- **Either way:**
  - Admin sessions ask for the PIN again after 15 minutes idle.
  - The admin must already be a Wallet account (an `EW-` UID with a PIN set). Admin rights sit
    on that account; there's no separate admin user store.

**Q3. First platform admin on dev**
- **Who?** I need the email (give it in the session; it isn't written down anywhere). That
  person needs a confirmed account with a PIN on dev first. If they have no network, they sign up
  as a founder and stop at plan selection; that's enough.
- **How:**
  - **(a) Recommended:** the one-time guarded SQL from `production-readiness.md` §7, run on dev
    through the Management API after you approve. It refuses if an admin already exists, matches
    exactly one confirmed email, and records `platform_admin.granted` with `bootstrap: true`.
  - (b) A migration that does the same from a Vault value.
- **After that:** later admins are added in the app (Platform admins screen: reason + PIN).

**Q4. Kill switches: which operations, scope, defaults, member experience**

What each switch stops:

| Switch | Stops (new only) | Keeps working |
|---|---|---|
| Withdrawals | new requests and approvals | cancel, reject, payouts already approved, reviews, unknown-outcome recovery |
| Payout recording ("Remittance" in Paper) | recording new payouts and corrections | approved withdrawals stay reserved, unchanged; cancel still works |
| Transfers | new pocket-move requests and approvals | decline / cancel |
| Conversion | new conversions | reviews of submitted ones |
| Income | recording income | recovery of an unknown-outcome attempt |
| Adjustments | new adjustments | reviews of submitted ones |
| Reversals | new reversals | — |
| Returned funds | recording returned funds | reviews of submitted ones |

"Automated payouts" stays drawn as "Deferred" (W-26), with no switch.

- **4a. Remittance.** I read Paper's "Remittance" as payout recording. Is it its own switch, or
  part of Withdrawals?
- **4b. Scope.**
  - **Recommended:** platform-wide **and** per network (a network row on network detail).
    Either one stopped means stopped.
  - Alternative: platform-wide only.
- **4c. Defaults.** All running. A stopped switch has no automatic restart. A
  reason and the PIN are needed both to stop and to start again.
- **4d. What members see.** The X-series "paused" screen: "Withdrawals are paused for now. Your
  money is safe; open requests keep their place." The action buttons are disabled with that
  line. The command refuses with `conflict` + `details.reason = operation_paused`. Every action
  is still audited.
  - Do you want an email or bell item when a switch stops? **Recommended: no.** The screen
    already says it.
  - Should a per-network stop appear in that President's Audit log? **Recommended: yes**, as
    "Paused by Elivate" with the reason.

**Q5. Feature flags**
- **(a) Recommended: defer again.** Nothing in the app is waiting on a flag today. Building
  targeting (tenants, roles, plans, percentages) with no consumer is a cost with no use. I'd hide
  the flags half of A11/A12 and keep switches.
- (b) Build now as drawn. Flags only change UI visibility and never grant permissions or skip
  checks (W-23). Every change is audited.

**Q6. Cuts and changes to A01–A16 and the undrawn list**

My recommendations:
- **Cut "Change status" on network detail (A07).** There's no network suspend or deactivate
  command, and pausing is already done by billing. **Replace it with "Support activation"**
  (complimentary period or development exception, B16 Q9).
  - If you do want admins to suspend or deactivate a network, that's a new rule. I'd need what
    members, money and billing do.
- **Keep:** networks list, accounts list, restore review, failed emails, platform admins and the
  admin gates. I'd draft these in Paper in one batch.
- **Fold "Subscriptions" into the networks list** (columns for plan, period end and seats, plus
  a status filter) instead of a separate page.
- **NIN review queue:** keep it. The backend exists, but the NIN provider is still open (U-02),
  so the queue would normally be empty. Your call; I'd keep a simple list.
- **Pocket/split versions:** a read-only section on network detail. No new screen.
- **"Platform backups" panel on A15:** shows "Not configured" for everything we don't have
  (U-06). No fake numbers. The "Latest database backup" card would show only if Supabase's
  backup list API gives real data; otherwise "Managed by Supabase", with a link to the
  dashboard.

**Q7. Restores: how far this slice goes**
- **(a) Recommended: guided manual restore.**
  - *Validate* is automatic. It re-reads the archive from R2 and checks the ZIP, the manifest,
    every SHA-256 and the row counts.
  - *Review diff* is an automatic, read-only report. Per section, it lists rows added, removed
    and changed between the archive and live data. Money tables are always "kept, never
    overwritten".
  - *Restore* is an operator procedure. Elivate fixes non-financial settings by hand or with
    reviewed SQL, then marks the request completed with notes.
  - No automatic write-back.
- (b) Status buttons only, as today. Validation and the diff are done outside the app.
- (c) An automatic restore of non-financial sections (settings, branding, offices). This is a
  large and risky engine. I'd make it its own slice after (a).

### Not in it
- Automated payouts (W-26).
- White-label domain activation (U-05; shown as "Not active").
- Backup destinations and schedules (U-06).
- Analytics (U-11).
- Editing network data on a network's behalf (P-03: presidency and platform powers stay
  separate).
- Production.

---

## Part B — Build spec (for the recommended answers; revised after Part A is answered)

### B1. Data (`platform` schema, private)
- `platform.kill_switches`:
  - Columns: `key` (`withdrawals`, `payouts`, `transfers`, `conversion`, `income`,
    `adjustments`, `reversals`, `returned_funds`), `tenant_id` (null = platform-wide), `stopped`,
    `reason`, `changed_by`, `changed_at`.
  - Unique on (key, tenant_id).
  - Platform rows are seeded as running.
- `platform.kill_switch_changes`: append-only (`audit.reject_change`), one row per stop or start.
- Optional, if Q5 = (b): `platform.feature_flags`, `platform.flag_targets` and
  `platform.flag_changes`. These are UI-visibility only and have no link to `authz`.
- RLS is on, there are no policies, and no grants to `anon`/`authenticated`.

### B2. Rules
- `platform.switch_for(permission_key)` maps a permission to a switch:
  - `request_withdrawal`, `approve_withdrawal` → withdrawals
  - `record_payout` → payouts
  - `transfer_between_*`, `approve_pocket_transfer` → transfers
  - `perform_currency_conversion` → conversion
  - `record_income` → income
  - `manual_credit_debit_adjustment` → adjustments
  - `reverse_transaction` → reversals
  - `record_returned_funds` → returned_funds
- `authz.require` checks the switch (platform row or the tenant row) after the paused check.
  If stopped, it raises `conflict{reason: operation_paused, switch}`.
- Not checked: cancel and reject commands, `finance.require_reviewer`, reads, command-outcome
  recovery, and payout recording with `p_allow_paused` for withdrawals approved before the stop.
  - Each of these gets a pgTAP case so that a stop never strands a reservation.
- Switch reads are `stable` and indexed. No caching that could serve a stale "running".

### B3. Commands and reads (all `api.*`, `security definer`, `search_path = ''`, platform admin)
- **Reads:**
  - `admin_me`: admin yes/no, PIN state, open step-up window.
  - `admin_overview`: counts, switch strip, open restores, the last 5 audit events.
  - `admin_tenants`: list with search, status filter and keyset cursor. Plan, period end and
    seats come from billing.
  - `admin_tenant`: detail, organisation counts, Billing Owner.
  - `admin_accounts`: list.
  - `admin_account`: detail with memberships, status history and security summary. No IPs;
    city/country only.
  - `admin_search`:
    - Keys: UID, name, email prefix, phone digits, any `XXX-XXXX-XXXX` reference, network name.
    - Bank account: an exact 10-digit number, which the Edge layer turns into the HMAC
      fingerprint. The full number never reaches SQL or logs.
    - Results are masked.
  - `admin_audit`: the union of `security_events` and `tenant_events`, with filters (actor,
    action group, tenant, date range) and a keyset cursor; safe fields only.
  - `admin_admins`.
  - `admin_switches`.
  - `admin_restores`, plus `admin_restore_diff` if Q7 = (a).
- **Writes (PIN + reason + idempotency key):**
  - `admin_set_switch(key, tenant_id?, stopped, reason)`. Audited as `kill_switch.stopped` or
    `kill_switch.started` in `security_events`. A per-network stop is also written to
    `tenant_events` as `operations.paused_by_elivate`.
  - Existing: `set_account_status`, `grant/revoke_platform_admin`, `activate_tenant`,
    `platform_advance_restore`, `outbox_requeue`, `decide_nin_review`.
- **Fixes:**
  - `docs/frontend-plan.md` still lists `authorization_denied{self_target}` for
    `set_account_status`. Update it to `self_target_forbidden`.

### B4. Routes
- New Edge Function `admin` (`verify_jwt = true`) gathers every admin route: `GET /me`,
  `/overview`, `/tenants`, `/tenants/:id`, `/accounts`, `/accounts/:uid`, `/search?q=`,
  `/audit`, `/admins`, `/switches`, `/restores`, `/restores/:id/diff`, `/outbox`, `/nin/reviews`,
  `/tenants/:id/allocation-versions`; `POST /switches`, `/accounts/:uid/status`, `/admins/grant`,
  `/admins/revoke`, `/tenants/:id/activate`, `/restores/:id/advance`, `/outbox/:id/requeue`,
  `/nin/reviews/:id/decide`.
- The existing admin routes on `security`, `org`, `ledger` and `identity` stay for now and are
  removed in a follow-up once nothing calls them.
- Every request and response is validated with the shared envelopes and error codes.
- Every admin call carries `x-app-server-secret` from the admin Worker. This is defence in depth:
  only the admin site can reach these routes, even with a valid user token.

### B5. Admin site (`frontend/`, surface `admin`)
- **Worker and session:**
  - `wrangler.admin.jsonc` → Worker `elivate-wallet-admin`, custom domain
    `admin.elivatewallet.com`.
  - `ADMIN_SURFACE` is set at build time. `hooks.server.ts` 404s routes outside the surface.
  - Cookie `ew-admin-auth` (host-only, `SameSite=Strict`), a stricter CSP, and
    `X-Robots-Tag: noindex`.
- **Routes** (as drawn in A01–A16, plus the approved drafts):
  - Sign-in and PIN: `/admin/sign-in`, `/admin/pin`.
  - `/admin` (overview), `/admin/search`.
  - `/admin/tenants`, `/admin/tenants/[id]`.
  - `/admin/accounts`, `/admin/accounts/[uid]`.
  - `/admin/controls`, `/admin/audit`, `/admin/backups`.
  - `/admin/emails` (failed emails), `/admin/admins`, `/admin/nin`.
- **App server:** a same-origin BFF under `/admin/api/*`. Tokens stay in the HttpOnly cookie.
- **Behaviour:**
  - The "Not elevated" / "Elevated · 4:12" chip shows the live step-up window.
  - Every write opens the reason + PIN dialog (A09b/A11b pattern).
- **Member app:**
  - `operation_paused` maps to the X-series paused state on the affected pages.
  - A new `/api/operations` read lets pages disable buttons ahead of time. It returns stopped
    switches for the selected network only, and no reasons.

### B6. Tests
- pgTAP `180_`–`18x_`:
  - Every `admin_*` read and write refuses non-admins, including a President.
  - Masking and allowlisted fields; no PINs, NINs, full account numbers, IPs or evidence.
  - Search by every key, including the bank fingerprint.
  - Audit merge, filters and cursor; append-only on the new tables.
  - Each switch, platform-wide and per network, refuses its new operations and lets every
    continuation through (cancel, reject, approved payout, review, recovery). Reservations
    are unchanged after a stop.
  - Switch PIN, reason, idempotency and audit.
  - Restore diff and validation (Q7a).
- Deno: route and contract validation for `admin`.
- Frontend unit: surface gating, cookie isolation, error mapping for `operation_paused`.
- e2e (local):
  - Admin signs in (password + PIN), searches, opens an account, suspends it (PIN).
  - Stops withdrawals; a member sees the paused state while an already-approved payout still
    records; then starts it again.
  - Advances a restore to completed; requeues a failed email.
  - A member-surface session can't open `/admin`.
  - axe at 320 px and desktop.

### B7. Deploy (after merge, from fresh `origin/main`)
1. Migrations: check the dev history through the Management API, then push. Say which path
   was used.
2. Deploy the `admin` function.
3. Build and deploy the app Worker (paused-state handling).
4. **With owner approval:**
   - create Worker `elivate-wallet-admin` and its secrets;
   - add the custom domain `admin.elivatewallet.com`;
   - add the Auth redirect URL;
   - add the Cloudflare Access policy (Q2a).
5. Bootstrap the first admin (Q3). Smoke-test with synthetic data.
