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
- **4d. What members see.** The X-series "paused" copy: "Withdrawals are paused for now. Your
  money is safe; open requests keep their place." The action buttons are disabled with that
  line. *As built:* the copy shows as a banner above the write page rather than replacing it, so
  an attempt with an unknown outcome can still be checked or cancelled (F-03; Greptile on PR #55). The command refuses with `conflict` + `details.reason = operation_paused`. Every action
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

## Part B — Build spec (as built)

### B1. Data (`platform` schema, private; migration `20261009180100`)
- `platform.kill_switches`: `key` (`withdrawals`, `payouts`, `transfers`, `conversion`, `income`,
  `adjustments`, `reversals`, `returned_funds`), `tenant_id` (null = platform-wide), `stopped`,
  `reason`, `changed_by`, `changed_at`. One platform row per key (seeded running) and at most one
  row per key and network.
- `platform.kill_switch_changes`: append-only history (update, delete and truncate refused).
- `backups.restore_rows` (archive rows staged for one comparison, removed when the request
  finishes), `backups.restore_runs` (the one current validation run per request) and
  `backups.restore_checks` (validation result; migration `20261009180300`).
- RLS on, no policies, no client grants. Feature flags are not built (Q5).

### B2. Rules
- **Where a stop is enforced:** row triggers on the tables a new operation writes, so every
  command path is covered (not `authz.require`: payout recording and withdrawal approval share
  the `approve_withdrawal` permission, so a permission key can't tell them apart):
  - `finance.withdrawals`: insert, and `requested → approved` → withdrawals.
  - `finance.payouts` / `finance.payout_revisions`: insert → payouts.
  - `finance.pocket_transfers`: insert, and `requested → completed` → transfers.
  - `finance.entries`: insert by kind → conversion, adjustments, returned_funds.
  - `finance.income_records`: insert → income. `finance.reversals`: insert → reversals.
- A stopped switch (platform row, or the network's row) raises
  `conflict{reason: operation_paused, operation}`.
- **Not affected:** cancel, reject and decline; payouts of withdrawals approved before a
  withdrawals stop; reviews of entries already submitted; reads; replays of committed commands
  (unknown-outcome recovery returns the stored result before any insert). Reservations are never
  touched. pgTAP `180` covers each case.
- **Restores:** `in_review` only through a passing validation (`admin_restore_validated`, which
  also checks that the staged row counts equal the manifest); an operator can still fail a stuck
  validation; restoring and completed stay manual with a reason.
- **One validation run at a time:** `admin_restore_source` starts a run and returns its `runId`;
  staging and completion need the current run id, so an older run gets
  `conflict{reason: run_superseded}` instead of erasing a newer run's rows. A storage failure
  ends the run without a verdict (the request stays in validating and can be run again).

### B3. Database functions (all `api.*`, `security definer`, `search_path = ''`, platform admin)
- **Reads:** `admin_me` (no admin check: says whether you are one), `admin_overview`,
  `admin_tenants` (search incl. President name, state filter, keyset cursor, counts),
  `admin_tenant`, `admin_accounts`, `admin_account` (memberships, status history, PIN state,
  sessions, last sign-in, unusual sign-ins in 7 days; no IPs), `admin_search` (UID, name, email
  prefix, phone — last 10 digits so 0801… finds +234801…, any public reference, network, office;
  bank account by fingerprint list; a 10-digit search also matches phones by
  SHA-256 of `phone:` + digits, so the digits themselves never reach SQL), `admin_bank_codes`, `admin_audit` (merged security and
  network events, filters: text, action group, actor UID, network, WAT dates; cursor),
  `admin_admins`, `admin_switches`, `admin_restores`, `admin_restore` (validation, per-section
  differences computed live: archive vs now, added / removed / changed, manual vs kept).
- **Writes:** `admin_set_switch` (PIN, reason, idempotent; audited `kill_switch.stopped|started`;
  a per-network change also writes `operations.paused_by_elivate|resumed_by_elivate` to that
  network's audit log), `admin_restore_source` / `admin_restore_rows` / `admin_restore_validated`
  (the validation run), and the existing commands. `api.stopped_operations` serves the member app.

### B4. Routes
- New Edge Function `admin` (`verify_jwt = true`): every route needs a verified token **and**
  `x-app-server-secret` (only the admin Worker holds it). `GET /me`, `/overview`, `/search?q=`,
  `/tenants`, `/tenants/:id`, `/tenants/:id/allocation-versions`, `/accounts`, `/accounts/:uid`,
  `/switches`, `/audit`, `/admins`, `/restores`, `/restores/:id`, `/outbox`, `/nin/reviews`;
  `POST /tenants/:id/activate`, `/accounts/:uid/status`, `/switches`, `/admins/grant`,
  `/admins/revoke`, `/restores/:id/advance`, `/restores/:id/source`, `/restores/:id/rows`,
  `/restores/:id/validated`, `/outbox/:id/requeue`, `/nin/reviews/:id/decide`.
- A searched 10-digit account number is fingerprinted at the Edge for every bank with a saved
  account (`PAYOUT_ACCOUNT_HMAC_KEY`); the number never reaches SQL or logs.
- `org` gains `GET /operations` (member: stopped operations for the workspace's network).
- The older admin routes on `security`, `org`, `ledger` and `identity` stay until a follow-up.

### B5. Admin site (`frontend/`)
- **One build, two Workers:** `APP_SURFACE` (`member` default, `admin`, or `both` for local e2e
  against a loopback Supabase only). `hooks.server.ts` 404s `/admin/*` on the Wallet app and
  everything but `/admin/*` on the admin site; admin responses add `X-Robots-Tag: noindex` and
  `X-Frame-Options: DENY`. `wrangler.admin.jsonc` deploys Worker `elivate-wallet-admin` on
  `admin.elivatewallet.com` with `APP_SURFACE=admin` and the `BACKUPS` bucket (read, for restore
  validation). CI dry-runs both bundles.
- **Session:** `ew-admin-auth`, host-only, `SameSite=Strict`, separate from `ew-auth`; each site
  reads only its own cookies. Password + PIN (Q2); no Turnstile on the admin form (Cloudflare
  Access gates the host). Gate pages: set your PIN first (links to the Wallet app), PIN locked
  (email reset), not an admin.
- **Server-rendered pages with form actions** (no admin JSON API and no offline cache):
  `/admin` overview, `/admin/search`, `/admin/networks[/id]`, `/admin/accounts[/uid]`,
  `/admin/nin`, `/admin/switches`, `/admin/audit`, `/admin/backups[/id]`, `/admin/emails`,
  `/admin/admins`, `/admin/more` (mobile). Every write is a URL-driven dialog (works without
  JavaScript): reason + PIN; the action verifies the PIN (opening the five-minute window) and
  then runs the command once with the form's idempotency key.
- **Restore validation:** the admin server streams the archive from R2, checks the archive and
  per-file SHA-256 and row counts against the manifest, and sends the rows to the database in
  batches of 1,000.
- **Member app:** `operation_paused` reads "<Operation> is paused for now…"; `/api/operations`
  lets write pages show the paused state ahead of time.

### B6. Tests
- pgTAP `180` (kill switches, 40), `181` (admin reads, 34), `182` (restore review, 22).
- Deno `admin_handler_test.ts` (secret, validation, fingerprinting, logs).
- Frontend unit tests for the restore reader and helpers; e2e `admin.e2e.ts` (sign-in + PIN,
  search, account status, kill switch stop/start with a member seeing it, restore validation,
  axe at 320 px and desktop) with `APP_SURFACE=both`.

### B7. Deploy (after merge, from fresh `origin/main`)
1. Migrations: check the dev history through the Management API, then push; say which path.
2. Deploy the `admin` and `org` functions (`admin` needs `APP_SERVER_SECRET`,
   `PAYOUT_ACCOUNT_ENC_KEY`, `PAYOUT_ACCOUNT_HMAC_KEY`, already set for other functions).
3. Build and deploy the app Worker.
4. **With owner approval:** create Worker `elivate-wallet-admin` and its secrets
   (`SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `APP_SERVER_SECRET`); custom domain
   `admin.elivatewallet.com`; Auth redirect URL `https://admin.elivatewallet.com`; Cloudflare
   Access application for the host.
5. Bootstrap the first admin (Q3, guarded one-time SQL). Smoke-test with synthetic data.
