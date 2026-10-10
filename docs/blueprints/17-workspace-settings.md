# Blueprint 17 — Workspace settings (slice 10)

Status: **built** under the member build plan (`docs/member-build-plan.md`, slice 10, "Backups (U-06)", "Support widget" and the owner decisions during the build, including the slice 10 answers of 2026-10-10 below). Contract: W-20 (team settings, branding), D-11 (configuration limits), W-21 (support), W-24 (Team Backup Vault, restore requests), P-06 (quick search, error states), A-03/A-05 (permissions, PIN). Builds on Blueprints 02 (tenants, permissions), 10 (PIN step-up), 13 (outbox, `notify.emit`, the bell), 15 (exports pipeline, R2, Browser Rendering) and 16 (paused networks). Migrations `2026100917xxxx`; pgTAP `170_`–`179_`.

Part A is for the owner. Part B is the build spec.

---

## Part A — What this slice does

### What's in it
1. **Branding** (Paper F01/F03, new draft TS02d). A President uploads the network's **logo**, an optional **square icon** and an optional **light version**, picks one of **six themes**, and writes a short **slogan** (up to 60 characters). The theme colours the network's buttons, links, highlights and network tile for everyone inside that network. The Elivate mark itself stays coral. "What members see" previews the choice before saving.
2. **Themes** (new draft TS01d). A fixed list: **Ember** (today's coral, the default), **Cobalt**, **Fern**, **Iris**, **Saffron** and **Rose**. Each one is a complete set we designed for dark and light mode, contrast-checked: the button ink is at least 7.5:1 on every theme, and in light mode, links reach at least 5.6:1 on white (today's coral reaches 5.3:1). Nobody can type in a colour.
3. **Team details** (F02/F04). Team name, short name, support contact (name, email, phone), an optional help website (HTTPS only), language and time zone.
4. **History and undo** (F02 "Recent changes"). Every save is a new numbered **revision**. A President can **Restore** an older revision, which creates another revision; nothing is overwritten. Saving and restoring both ask for the **PIN**. Every revision appears in the President's Audit log, and T05 "Your team's branding changed" goes to the President Team.
5. **Backup vault** (E09/E10, new draft TS03d). **Back up now** makes a full-network backup: one archive with every person, office, role setting, wallet, transaction, withdrawal, transfer, evidence record, subscription record and audit entry of that network, plus a manifest with counts and a SHA-256 checksum per file. T02 "Backup ready" or T03 "Backup failed" goes to whoever started it. **Download** asks for the PIN, is audited, and is streamed by the app server. Backups are kept **90 days**, then removed automatically.
6. **Restore requests** (V01–V04, TS03d). A President Team or World Team member picks a backup and gives a reason; the request gets an **`RST-XXXX-XXXX`** reference. The requester can **Cancel** while it hasn't started restoring. **Only Elivate** validates, reviews the differences and restores, later in the Admin app. Statuses: requested → validating → in review → restoring → completed, or rejected, cancelled or failed. Each change is audited and sends T04 with a bell item to the requester.
7. **Support** (E11/E12, WK01). The Support page shows **your network's support** (from team details) separately from **Elivate's app help** (`support@elivatewallet.com` and your UID). **Start a chat** opens Elivate's Chatwoot chat. It shares only your UID, the network name and the screen you were on; never names, emails, money, bank details, evidence, PINs or tokens.
8. **Quick search** (K01/K02). **⌘K** (or the search box; on mobile, the search icon) finds people (name, UID, email, phone), offices, transactions and withdrawals, transfers and returned funds by reference, plus pages, all within what you can already see in the selected workspace. Sensitive values stay masked.
9. **Error screens** (X01–X04, PL06). Page not found, No access (instead of each page's own denial message) and, on a paused network, the PL06 view-only screen when a write page is opened.
10. **Branding on statements and reports.** PDFs show the network logo (or the initial tile in the theme colour) and the network's support contact, as deferred in Blueprint 15 Q3.

### Decisions (owner answers 2026-10-10)
| # | Question | Answer |
|---|---|---|
| Q1 | Who approves a restore | **Elivate only (W-24).** The team requests and can cancel; Elivate validates, reviews and restores in the Admin app. The 2026-10-07 "team approves the diff" note in `design-backlog.md` (V05/V06) is withdrawn. |
| Q2 | Backup retention | **90 days**, then removed automatically (audited). |
| Q3 | Team colour | **Pick from a fixed list of themes**, so the design always looks right. The theme colours the network's accent (buttons, links, highlights, tile); see TS01d. |
| Q4 | Who edits branding and team details | **A new protected key, `manage_team_settings`**, President only, which can't be granted to other roles. The PIN is needed to save and to restore an older revision. |

Paper drafts approved 2026-10-10 (App v4, bottom rows): **TS01d** Team themes (6 presets, dark and light, with contrast figures); **TS02d** Branding with the theme picker (replaces F01's free swatches; the preview follows the theme); **TS03d** Backup vault with the Restore requests list (Cancel, statuses, RST references, "kept 90 days"). Mobile follows the drawn mobile layouts (F03, E10, V02) with the same content.

### Decisions I applied (approved with the blueprint, 2026-10-10)
- **Backups use the same key.** Back up now, Download and the vault belong to `manage_team_settings` (Presidents), matching "full-network export for Presidents". World Team members see the backup list (date, size, checksum) only so they can pick one for a restore request; they can't download.
- **Restore requests need a second protected key, `request_restore`**, held by World Team and President by default and not grantable. It encodes the W-24 decision (President Team and World Team request) rather than adding a role check. The catalogue grows from 32 to 34 rows. Asking for a restore needs a reason, not the PIN (V01 has none). One open request per network at a time.
- **Paused networks:** back up, download and restore requests still work (like reports); branding and team details can't be changed until the network is reactivated.
- **What a backup leaves out:** passwords, PIN hashes, sessions, Auth secrets, integration keys, Paystack tokens, other networks, NINs and full bank account numbers (shown as the last 4 digits). Evidence files are listed with their name, size and checksum, but the files themselves stay in private storage (they would make an archive too large to download).
- **Encryption:** archives are stored encrypted in private R2 and downloaded over HTTPS after the PIN; the file itself has no password (a password would have to be shared and could be lost).
- **Size limit:** an archive is refused as "Too large" above 500,000 records. Your network's backup at 41,880 records is about 38 MB; the limit keeps a download inside the app server's memory.
- **Language and time zone** show **English (Nigeria)** and **Africa/Lagos (WAT)** as the only choices for now: the app isn't translated, and statements already use WAT (Blueprint 15). They are stored so more options can be added later.
- **Logos:** PNG, JPEG or WebP up to 1 MB (no SVG, which can carry scripts). They are checked by their bytes and kept private; members see them through the app, never through a public link. Emails keep the drawn initial tile.
- **Help topics** on the Support page are left out until the help site exists (W-21: never show content that isn't there).
- **Chatwoot loads only when someone presses Start a chat**, so no third-party script runs on other pages. Chatwoot's identity check (an HMAC of the UID) stops someone from posing as another person in chat.
- **T05** goes to every President Team member of the network, with a bell item.

### Not in it
- White-label domains (U-05), per-office branding, custom fonts or CSS, scheduled backups and cloud destinations (U-06).
- The Admin app screens: Elivate's restore steps are `api.*` routes only for now.
- The help site and its topics.

---

## Part B — Build spec

### B1. Data
| Object | Rules |
|---|---|
| `authz.permission_catalog` | Add `manage_team_settings` (P only, protected, tenant scope) and `request_restore` (W, P; protected; tenant scope), following `20261009020300_allocation.sql`. Every existing network gets the defaults for its role policies. Update 01 A-03 (34 rows). |
| `org.tenant_settings` | One row per tenant: `tenant_id` PK, `revision` (current), `theme` (`ember`, `cobalt`, `fern`, `iris`, `saffron`, `rose`), `slogan` (≤ 60), `support_name` (≤ 80), `support_email` (valid address, ≤ 254), `support_phone` (E.164, ≤ 20), `help_url` (HTTPS, no credentials, ≤ 300), `locale` (`en-NG`), `time_zone` (`Africa/Lagos`), `logo_key`, `icon_key`, `logo_light_key` (each `brand/<tenant>/<uuid>.<ext>`), `updated_at`. Team name and short name stay on `org.tenants`. Seeded for every tenant at revision 1 (Ember, no logo). |
| `org.tenant_setting_revisions` | Append-only: `tenant_id`, `revision`, a snapshot of every field (including name and short name), `changed` (field list), `restored_from` (revision or null), `actor_user_id`, `created_at`. Unique (`tenant_id`, `revision`). Immutable via trigger. |
| `backups.archives` (new private schema `backups`; `vault` is Supabase Vault's) | `id`, `tenant_id`, `status` (`queued`, `preparing`, `building`, `ready`, `failed`, `too_large`, `expired`), `started_by`, `idempotency_key`, `record_count`, `byte_size`, `sha256`, `manifest` (jsonb: counts per section, files with SHA-256, format version), `fail_reason`, `attempts` and lease, `expires_at` (ready + 90 days), `deleted_at` (file removed), download count, timestamps. The storage key is built per attempt, never stored. One running backup per tenant. |
| `backups.rows` | Prepared snapshot: `backup_id`, `seq`, `section`, `row` (jsonb), all written in one transaction; deleted when the backup finishes. |
| `backups.restore_requests` | `id`, `tenant_id`, `reference` (`RST-…`, `refs.issue('RST')`), `backup_id`, `reason` (10–500), `status` (W-24 values), `status_reason` (safe text for rejected or failed), `requested_by`, `cancelled_by`, `operator_user_id`, `idempotency_key`, timestamps. Partial unique index: one open (`requested`, `validating`, `in_review`, `restoring`) per tenant. `backups.restore_events`: one row per transition (append-only). |
| Templates + kinds | Templates `team.backup_ready` (T02), `team.backup_failed` (T03), `team.restore_update` (T04: `network`, `reference`, `status`, `path`), `team.branding_changed` (T05: `network`, `actor`, `summary`, `revision`, `path`); kinds `backup.ready`, `backup.failed`, `backup.restore_update`, `org.branding_changed`. None is a task. |

### B2. Rules (Postgres owns them)
- **Settings save** (`api.update_team_settings(p_session, p_tenant, p_expected_revision, p_fields jsonb, p_idempotency_key)`): needs `manage_team_settings` in the selected tenant, PIN step-up (5-minute window) and an active, non-paused network. Validates every field (allowlist; unknown keys are refused). Asset keys must be under the same tenant's `brand/` prefix and confirmed uploaded. `p_expected_revision` must match (otherwise `conflict`, `details.reason = 'stale_revision'`). Writes the new revision plus a tenant audit row (safe before/after), emits T05 to the President Team. Name and short name keep their `org.tenants` checks.
- **Restore a revision** (`api.restore_team_settings_revision`): same checks; copies an older snapshot into a new revision (`restored_from`). Asset keys that no longer exist fall back to none.
- **Reads:** `api.team_settings` returns the full editable record and the last 20 revisions to `manage_team_settings` holders. `api.workspace_brand` returns only safe presentation fields (name, short name, theme, slogan, whether each logo exists, support contact) to any active member of the tenant, including on a paused network.
- **Backups:** `api.start_backup` (`manage_team_settings`, idempotent, one running per tenant) queues the job and kicks the worker. `api.backup_prepare` (worker) snapshots, in one transaction (REPEATABLE READ), the network's offices, memberships, accounts (UID, names, email, phone; never the NIN), role policies and grants, reviewer assignments, allocation versions, wallets and pockets, ledger entries and transactions, withdrawals, transfers, conversions, adjustments, reversals, returned funds, payout records (account masked to the last 4), evidence metadata, subscription, periods and payments (without provider tokens), settings revisions and the tenant audit. Above 500,000 rows it is `too_large`. `api.backup_finalize` checks the row count against the prepared rows, stores the size and checksum, sets `expires_at`, emits T02; a failure emits T03.
- **Download:** `api.authorize_backup_download` needs `manage_team_settings` plus the PIN step-up; it returns the R2 key to the app server only (`x-app-server-secret`) and writes an audit row.
- **Expiry:** pg_cron daily marks ready backups past `expires_at` as `expired`; the app runner deletes their R2 objects (audited).
- **Restore requests:** `api.request_restore` (`request_restore`, ready backup of the same tenant, reason, idempotent, one open per tenant) → `requested`, RST reference, audit, T04. `api.cancel_restore_request`: the requester or a President Team member, only in `requested`, `validating` or `in_review`. `api.platform_advance_restore` (registered platform admin, PIN, reason) moves along `requested → validating → in_review → restoring → completed`, or to `rejected` (from `in_review`) or `failed` (from `validating` or `restoring`). Every transition writes `restore_events`, a tenant audit row and T04 to the requester.
- **Quick search** (`api.quick_search(p_session, p_tenant, p_query, p_limit)`): 2–80 characters; up to 5 results per group; only rows the caller's current authority can already read (reuses the scope checks behind `list_members`, `list_offices`, `managed_wallet_activity` and the withdrawal and transfer queues, or `my_activity` for self-service); references match exactly or by prefix; email and phone match exactly or by prefix but return masked (`a•••@example.com`, `+234 •• •••• 2210`). Pages and actions are matched in the app from the capabilities it already has.

### B3. Routes
- **`org` Edge Function:** `GET /settings`, `PATCH /settings` (expected revision, fields), `POST /settings/restore` (expected revision, revision), `GET /brand`, `GET /search?q=`.
- **Also on `org`** (no new function to deploy): `GET /backups` (vault and restore requests), `POST /backups`, `POST /backups/:id/download` (app-server secret), `POST /restores`, `POST /restores/:id/cancel`, `POST /platform/restores/:id/advance` (platform admin), and `POST /brand/asset-key`, `POST /brand/upload-key` (app-server secret).
- **`exports-worker`:** `/backups/claim`, `/backups/:id/{prepare,rows,finalize,fail,deleted}`, `GET /backups/expired`, and `GET /:id/brand` (the logo key of a leased PDF's network).
- **App (BFF):** `/api/settings*`, `/api/brand`, `/api/brand/asset/[kind]` (streams the logo from R2 for members of that tenant), `/api/backups*` (download streamed with PIN), `/api/restores*`, `/api/search`, `/api/support/chat` (returns the Chatwoot identity hash). Upload: `POST /api/settings/assets` checks the bytes (PNG/JPEG/WebP, ≤ 1 MB), asks the database for a `brand/<tenant>/<uuid>.<ext>` key (manage_team_settings), writes it to the `PHOTOS` bucket and returns the key for the next save.
- **Runner:** `/internal/exports/run` also runs backups: pages rows per section, streams one NDJSON file per section plus `manifest.json` into a ZIP (deflate via `CompressionStream`, data descriptors) uploaded in 8 MiB parts to the private **`BACKUPS`** bucket (`backups/<tenant>/<id>/<attempt>.zip`; no lifecycle rule, unlike `EXPORTS`), finalizes with the archive SHA-256 and per-file checksums, and removes expired archives' files.
- **Configuration:** Worker vars/secrets `CHATWOOT_WEBSITE_TOKEN` (public), `CHATWOOT_HMAC_TOKEN` (secret), optional `CHATWOOT_BASE_URL`; the CSP allows `https://app.chatwoot.com` (script, frame, img, connect + wss).

### B4. Screens
- **Settings** (`/app/settings`, tabs Branding · Team details · Backup vault) for `manage_team_settings`; the vault tab also for `request_restore`. Sidebar "Branding & settings" under Workspace. Save opens the PIN dialog; a stale revision shows "Someone saved changes. Reload to see them."
- **Theme:** the app shell sets `data-team-theme` on the root from `/api/brand`; `tokens.css` adds one block per theme that overrides `--color-accent*`, `--button-primary-*`, `--focus-ring`, `--auth-link-underline` and the button shadow for dark, light and system. `--color-brand` (the Elivate mark) never changes. The sidebar tile shows the square icon, else the network initial on the theme colour.
- **Backup vault and restore** as drawn (E09/E10, V01–V04, TS03d), with Download → PIN → file; empty state "No backups yet" with Root.
- **Support** (E11/E12) with the network and Elivate cards and WK01's chat (Chatwoot widget, loaded on demand, styled to Emberlit where Chatwoot allows).
- **Quick search** (K01/K02, Bits UI Command): ⌘K/Ctrl+K, arrows, Enter, ⌘Enter for a new tab, Esc; debounced 200 ms; honest empty, error and offline states.
- **`+error.svelte`** (X01/X02; an `/app/[...missing]` catch-all keeps unknown app pages inside the shell), **No access** (X03/X04) as a shared component for whole-page `authorization_denied` states, **paused** (PL06) for write routes on a paused network (`/app/income`, `/app/withdrawals/new`, `/app/split/move`, `/app/convert`, `/app/adjust`, `/app/reversals`, `/app/queue/returns`, `/app/invitations`).
- **PDFs:** the header uses the logo (as a data URI) or the initial tile in the theme colour; the footer adds "Questions? <network support email or phone>" when set.

### B5. Emails and bell
T02, T03, T04 and T05 from Paper Emails v2 with the shared layout; bell items for each; recipients as in Part A. Footers keep `support@elivatewallet.com` (U-11).

### B6. Tests
- pgTAP `170_`–`179_`: catalogue rows and protection; settings validation, PIN, stale revision, paused refusal, restore of a revision, audit and T05; brand read for members and its denial for other tenants; backup lifecycle (one running, too large, expiry), snapshot contents exclude secrets, NINs and full account numbers; download needs PIN and audits; restore requests (one open, cancel window, platform transitions, illegal transitions, T04); quick search scope (no cross-tenant or out-of-scope rows, masking, references).
- Deno: route validation for the new `org` routes and the `exports-worker` backup steps; T02–T05 renderers.
- Frontend unit: theme tokens (contrast for every theme in dark and light), asset sniffing, ZIP and manifest builder, search grouping.
- e2e (local): President edits branding (PIN), members see the theme; restore of a revision; back up now → ready → download with PIN; request and cancel a restore; ⌘K finds a member, an office and a reference; 404 and no-access screens; axe at 320 px and desktop.
