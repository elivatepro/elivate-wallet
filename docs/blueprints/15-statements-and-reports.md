# Blueprint 15 — Statements and reports (slice 6)

Status: **built under the member build plan** (`docs/member-build-plan.md`, "Statements (W-18)" and owner decisions during the build) with the owner's answers of 2026-10-09 below. Contract: W-18 (reports, transaction exports and statements), W-07 (activity), A-03 (`export_own_statement`, `view_scoped_financial_reports`, `export_scoped_reports`), U-11 (M15 "Statement ready"). Builds on Blueprints 04/08 (ledger reads), 11/12 (withdrawals, entries, reversals) and 13 (outbox, `notify.emit`, the bell). Migrations `2026100915xxxx`; pgTAP `150_`–`159_`.

Part A is for the owner. Part B is the build spec.

---

## Part A — What this slice does

### What's in it
1. **Personal statements** (Wallet → Statements). Pick the network (only if you belong to more than one), the currency, a period (this month, last month, a quarter, the year so far, or custom dates) and PDF or CSV. The **PDF statement** (Paper S01/S02/S07) shows opening balance, money in, money out and closing balance from the posted ledger, the same by pocket, every posted movement with a running balance, reversals as their own row with "Reversed" on the original, and what was still waiting at the end of the period (reserved, not posted). The **CSV** is the posted movements only, one per row. Empty periods are a valid statement ("No transactions in this period"), never an error.
2. **Leadership reports** (Team → Reports; President: Money → Reports & exports), over the selected workspace's scope. The Reports page (Paper S05 desktop, S12 mobile) shows income recorded, paid out, reserved now, withdrawal requests and memberships vs distinct people for the chosen currency and period, and a by-member list. **Export report** (S05/S06, S13d) makes, for the whole office or one member:
   - **Office report · PDF** (S03/S04): money held opening → closing with every kind of movement, reserved and available, net income by pocket, withdrawals requested / approved / completed / not approved / cancelled, active memberships vs distinct people, and every member's income, paid out and closing.
   - **Transactions · CSV**: every posted movement in scope, one per row.
   - **Member balances · CSV**: opening, in, out, closing, reserved and available per member.
3. **Files** (S08–S11). Every file is made by the same background job and appears in "Your files" / "Recent reports" as Preparing, Ready, Failed (with Retry), Too large ("pick a shorter period") or Expired (with Recreate). Small files are ready in seconds while you wait. Big ones (more than 1,000 rows) keep going in the background and, when ready, send **M15 "Statement ready"** and a bell item. A personal PDF opens a preview (S09: first page, "Download PDF", "Share" where the device can share files).
4. **Downloads** go through the app: the file is streamed by the app server, never as a storage link. Every download re-checks that you may see it and is recorded in the audit log. **Leadership reports need your PIN** to download (S14d); personal statements don't.

### Decisions (owner answers 2026-10-09)
| # | Question | Answer |
|---|---|---|
| Q1 | Time basis | **WAT (Africa/Lagos) everywhere.** Periods run 00:00–23:59 WAT and every printed time says WAT. CSVs also carry the exact UTC timestamp (`posted_at_utc`), keeping W-18's UTC transaction-date contract. |
| Q2 | PDF rendering | **Cloudflare Browser Rendering** from the app Worker (owner approved adding it; the account is on Workers Paid). Postgres prepares the complete data; the Worker turns it into HTML and then a PDF with headless Chrome. |
| Q3 | Branding until slice 10 | **Network name with its initial tile** and "Powered by Elivate Wallet"; the footer shows `support@elivatewallet.com`. No team contact line until slice 10 adds logo, colour and contact. |
| Q4 | Leadership reports | **Office report PDF plus Transactions CSV and Member balances CSV**, for the whole scope or one member. |
| Q5 | Instant vs job, limits | **Size decides.** Every file is one complete-or-fail job that starts at once; up to 1,000 rows it is normally ready while the screen waits (no email); bigger files send M15 + bell. Hard limits: **PDF 5,000 rows, CSV 50,000 rows**; above that the file is "Too large", never cut short. |
| Q6 | Storage and retention | **Private R2 bucket, 7 days.** The file is removed after 7 days ("Expired · Recreate"); the record (reference, scope, period, who, rows, SHA-256, times, downloads) stays. |
| Q7 | Download protection | **Streamed by the app server, PIN for leadership reports**, authorization re-checked and audited on every download; M15 links to the app page, never to the file. |
| Q8 | Former members | **Own money always**: a person can make statements for any network they hold or held money in, even after leaving it or while it is paused. |

Paper drafts approved 2026-10-09 (Statements & reports v1): **S10d/S10** first visit with the network choice, **S11d** every file state (adds Expired), **S12** Reports mobile, **S13d** Export report with three formats, **S14d** Download report · PIN.

### Decisions I applied (say if you want them changed)
- **Presidents** have no personal wallet in their own network (A-03), so they get reports there, not personal statements; their statements for other networks work as usual.
- A leader's **own wallet is not in their reports** (A-04 self guard, as on Team overview); the report says how many people were left out because they are outside the leader's permission.
- **The preview** (S09) shows the first page as an image with "Page 1 of N" instead of a page flipper; the full file is the download.
- **Desktop Reports** shows "Recent reports" under the by-member table, as mobile S06 does (desktop S05 draws no list).
- **Leadership "ready" emails** reuse M15 with chip "Report", headline "Your report is ready." and button "Get report". A big job that fails leaves a bell item ("Couldn't finish your statement"), no email.
- A statement covers **all of the person's memberships in that network** (several offices are listed together).
- The **office report's money-held table** lists every movement type that occurred (income, reversals, paid out, returned funds, conversions in/out, adjustments) so the closing balance always reconciles; Paper S03 draws only income, reversals and paid out.
- A period that ends in the future is cut at the moment the job starts ("as of 9 Oct 2026, 14:05 WAT").

### Not in it
- Team logo, colour and contact details on files (slice 10).
- Full-network export (slice 10, W-24).
- Scheduled or emailed attachments: files are only downloaded in the app.

---

## Part B — Build spec

### B1. Data (`exports` schema, private)
| Object | Rules |
|---|---|
| `exports.files` | `id`, `reference` (`STM-…` for statements, `RPT-…` for reports; `refs.issued`), `kind` (`statement_pdf`, `statement_csv`, `office_pdf`, `transactions_csv`, `member_balances_csv`), `requested_by`, `session_id`, `tenant_id`, `currency`, `period_kind` (`month`, `quarter`, `year`, `year_to_date`, `custom`), `period_from`/`period_to` (WAT dates, inclusive), `as_of` (the cut-off instant, ≤ end of `period_to`), statements: `wallet_id`; reports: `workspace_membership_id`, `scope_office_id` (null = whole network), `member_user_id` (one member, optional); `status` (`queued`, `preparing`, `rendering`, `ready`, `failed`, `too_large`), `row_count`, `page_count`, `byte_size`, `sha256`, `object_key` (server-built `exports/<tenant>/<file id>.<ext>`, never returned to clients), `fail_reason`, `attempts`, `lease_owner`, `lease_expires_at`, `notify` (big job), `idempotency_key` (unique per requester), timestamps, `expires_at` (ready + 7 days), `download_count`, `last_downloaded_at`. Status changes only through `api.*`. |
| `exports.rows` | `file_id`, `seq` (1…n), `section` (`txn`, `pocket`, `member`, `pending`, …), `data` jsonb of exact decimal strings. Written in **one transaction** by the prepare step, read by the Worker in `seq` order, deleted when the file is ready or failed. |
| `exports.files.summary` | jsonb header for the PDF: opening/in/out/closing, pockets, reserved/available, withdrawals, counts, excluded scope, network name, member details. |
| Templates + kinds | `money.statement_ready` (M15: `network`, `title`, `currency`, `format`, `chip`, `path`); kinds `export.statement_ready`, `export.report_ready` (email M15) and `export.failed` (bell only). |

### B2. Figures (Postgres owns them)
- **Statement** for wallet *w*, network *t*, currency *c*: the member-value accounts of *w* in *t* and *c* (all memberships). Opening = postings before the period start; each posted transaction in the period gives its net amount (pocket moves net 0) and per-pocket lines; closing = opening + Σ nets, **checked against the direct posting sum, or the job fails** (`invariant_violation`). Money in/out = Σ positive / negative transaction nets. "Not yet posted on <end>" = reservations active at `as_of` (created ≤ cut-off, not settled before it) with their withdrawal/pocket-move reference and status at that moment; available = closing − reserved.
- **Office report**: the segments the actor may see with `export_scoped_reports` in the workspace subtree (or one member); excluded people are counted. Money held by movement type; reserved at the cut-off; net income by pocket (income and its reversals); withdrawals by lifecycle timestamp in the period (amounts are the requested amount); active memberships, distinct people and memberships joined in the period; by member sorted by income desc, then name, then id.
- Order everywhere: `posted_at`, then transaction id, then currency: **deterministic, equal timestamps never skipped**.
- Money is `numeric` in SQL and exact decimal strings everywhere after; no floats.

### B3. Commands and routes
`ledger` Edge Function (verified JWT; user routes):
| Route | Command | Notes |
|---|---|---|
| `GET /statements/options` | `api.statement_options` | networks the person holds/held money in or is an active non-President member of, with their currencies |
| `POST /statements` | `api.create_statement` | `tenantId?`, `currency`, `period` (`kind` + `from`/`to` for custom), `format`, `idempotencyKey`; gate `ready` |
| `GET /statements` | `api.my_exports` | own files, newest first (cursor) |
| `GET /reports/overview` | `api.report_overview` | workspace, `currency`, period; `view_scoped_financial_reports` or `export_scoped_reports` |
| `POST /reports` | `api.create_report` | workspace, `kind`, `memberUserId?`, `currency`, period, `idempotencyKey`; `export_scoped_reports` |
| `GET /reports` | `api.workspace_exports` | the actor's report files for this workspace |
| `GET /exports/:id` | `api.export_file` | status for polling (own files only) |
| `POST /exports/:id/retry` | `api.retry_export` | failed → new queued attempt (same file) |
| `POST /exports/:id/download` | `api.authorize_export_download` | re-checks the person and permission, expiry and status; reports need a fresh PIN proof (`step_up_required`); audits `export.downloaded`; returns `objectKey`, `fileName`, `contentType`, `byteSize`, `sha256` **to the app server only** |

`exports-worker` Edge Function (`verify_jwt = false`, `EXPORTS_WORKER_SECRET`): `POST /claim` → `api.export_claim` (leases one queued job, 5-minute lease, max 3 attempts), `POST /:id/prepare` → `api.export_prepare` (re-authorizes; counts rows; over the limit → `too_large`; empty → valid empty file; writes `exports.rows` and `summary` in one transaction), `GET /:id/rows?after=&limit=` → `api.export_rows` (seq-ordered pages, 1,000 max), `POST /:id/finalize` → `api.export_finalize` (rows, pages, bytes, SHA-256; **row count must equal the prepared count** or the file fails), `POST /:id/fail` → `api.export_fail`.

Errors reuse the envelope: `validation_error`, `authorization_denied`, `step_up_required`, `not_found`, `conflict` with `details.reason` `export_expired`, `export_not_ready`, `export_too_large`, `period_in_future`, `nothing_to_retry`.

### B4. Worker (app server) and storage
- pg_cron every minute and an immediate pg_net call on create (Vault `exports_worker_url`, `exports_worker_secret`) POST `https://app.elivatewallet.com/internal/exports/run` with the secret.
- The run endpoint claims jobs and, per job: prepare → page all rows (fail on any page error, a gap in `seq` or a count mismatch) → build CSV (RFC 4180, UTF-8 BOM, text cells guarded against formula injection) or HTML (Paper S01–S04/S07, Lexend and IBM Plex Mono embedded, A4, footer "Page x of y") → PDF through the `BROWSER` binding (`@cloudflare/puppeteer`) plus a first-page PNG preview → write to R2 `EXPORTS` (`elivate-wallet-dev-exports`, private, lifecycle delete after 7 days) → finalize. Any failure → `fail`; a file is never marked ready unless every row made it.
- BFF: `/api/statements` (options, list, create), `/api/reports` (overview, list, create), `/api/exports/[id]` (poll, retry), `/api/exports/[id]/file` (authorize, then stream from R2 with `Content-Disposition: attachment` and the exact type), `/api/exports/[id]/preview` (own PDF statements only).
- Local development renders with Playwright's Chromium and a local R2 (same HTML).

### B5. Emails and bell
M15 from Paper Emails v2 (Root pose `statement-ready`, chip "Statement"/"Report", status "Ready", hero = period title, mono line "NGN · PDF statement", headline, "Download it securely from Wallet.", button to `/app/statements` or `/app/reports`). Bell: "Statement ready · September 2026 · NGN", "Report ready · …", "Couldn't finish your statement". No amounts, balances, account numbers or file links in emails, bell items or logs.

### B6. Tests
pgTAP `150_statements.sql` (figures reconcile; reversals and corrections; equal timestamps; reservations at the cut-off; empty period; WAT boundaries; own money after leaving; President exclusion; cross-tenant isolation), `151_reports.sql` (scope and excluded people; one member; withdrawals by lifecycle; counts; self-exclusion; sibling office invisible), `152_export_jobs.sql` (claim/lease/attempts; limits → too_large; finalize count mismatch → failed, never ready; revoked permission between create and prepare → failed; download re-check, expiry, PIN for reports, audit; M15 + bell for big jobs only), `153_export_privileges.sql`. Deno: worker routes and secret, the M15 renderer. Vitest: periods in WAT, CSV builder and escaping, HTML templates (money formatting, reversal labels), the page loop (complete-or-fail). E2E `statements.e2e.ts`: create a statement → ready → preview → download; reports page → export → PIN → download; screenshots of every new screen, a sample PDF statement and report rendered to images, a CSV sample and M15 (light, dark, 320 px).
