# Blueprint 19 — Founder applications (slice 19)

Status: **owner decisions 2026-10-10; Paper drafts approved 2026-10-10 ("I approve all"); built
in slice 19.**

Contract: P-09 (founder entry), 01 W-19 billing ("an approved founder's first network"), 02 W-01
step 1 (apply first), `docs/member-build-plan.md` "Founder applications (2026-10-10)". Builds on
Blueprints 03 (invitation tokens, outbox, `/join` screens), 10 (Turnstile), 16 (`start_network`,
trial) and 18 (Admin app, reason + PIN dialogs). Migrations `2026100919xxxx`; pgTAP `190_`–`199_`.

### Owner decisions (2026-10-10)
- Founder sign-up is **apply first**; the open "Start your network" sign-up is withdrawn.
- The public form asks for full name, email, phone, team name and a self-declared rank:
  **Ruby Director 4, Ruby Director 5 or Diamond Director**. There is no proof upload.
- Any platform admin approves or rejects in the Admin app, with a reason and the PIN.
  - Approval emails a **founder invitation** (A17). It is the only way to become a founder.
  - Rejection emails a polite no (A18). The same email may apply again **30 days** after the
    rejection.
- Nobody creates a network without approval, paid or not. An approved founder's later networks
  need no new application and pay before activation, as before.
- The trial stays **7 days**, capped at the 400-user band, with no card.
- Prices are shown on the marketing site, not in the application pages.
- Emails: A19 application received (to the applicant), A17 approved (with the invitation link),
  A18 not approved.
- The invitation reuses the Authentication v2 invitation screens (08 verify, 09 set password,
  10 unavailable) with founder wording, then network setup.

### Paper (approved)
| Draft | Screen |
|---|---|
| Authentication v2 13d/13m | Apply to start a network (form; Root with pen and clipboard) |
| Authentication v2 14d/14m | Application received (Root posting an envelope) |
| Admin A22d/A22m | Founder applications: Waiting / Approved / Not approved tabs |
| Admin A22bd/A22bm | Review application: facts, approve or not approved, reason, PIN |
| Emails A17 / A18 / A19 | Approved (key) / not approved (hourglass) / received (folder) |

### Gaps filled while building (the drafts do not show them)
1. **Approved but not yet accepted.** On the Approved tab, a row whose invitation hasn't been
   accepted shows **Resend invitation**. It uses the same dialog, with a reason and the PIN. A
   resend issues a new link, and the old link stops working.
2. **Repeat applications get the same "We have your application" screen.** This covers an
   application that is already waiting, a rejection less than 30 days old, and an email that
   already belongs to a founder. No email is sent and nothing is stored (W-01: no enumeration).
3. **Founders from before this rule stay founders.** Every account that already created a
   network is recorded as approved, with source `existing`.
4. **A signed-in person without approval** who opens "Start a network" goes to the application
   form, prefilled with their email.

---

## B1. Data (`founders` schema, private; migration `20261009190100`)

**`founders.applications`**
- Fields: `id`, `full_name` (2–100), `email` (lower, trimmed), `phone` (`^\+?[0-9]{7,15}$`,
  stored without spaces), `team_name` (2–100), `rank` (`ruby_director_4`, `ruby_director_5`,
  `diamond_director`), `status` (`waiting`, `approved`, `rejected`), `created_at`, and
  `decided_at` / `decided_by` / `decision_reason` (all set only once decided).
- At most one `waiting` row per email (partial unique index).
- Identity columns are immutable, and a decided row never changes status again.
- Delete and truncate are refused.

**`founders.invitations`**
- One per approved application. Fields: `application_id`, `email`, `token_id`,
  `token_digest` (32 bytes, unique), `expires_at` (**14 days**), `issue_count` (1–6),
  `status` (`pending` or `accepted`), `accepted_at`, `accepted_user_id`.
- A resend replaces the token on the same row (as Blueprint 03 reissue), so the old link
  stops working.
- The token is the Blueprint 03 HMAC token (`_shared/invite_token.ts`). Only its digest is
  stored.

**`founders.approved`** is the grant.
- Fields: `user_id` (primary key), `source` (`application` or `existing`), `application_id`,
  `approved_at`.
- Append-only.
- `api.start_network` refuses an account without a row:
  `authorization_denied{reason: founder_not_approved}`.

**`founders.verifications`** rate-limits verification emails (1 per minute, 5 a day per
invitation).

**Outbox templates**
| Template | Params | Paper |
|---|---|---|
| `founder.application_received` | `team` | A19 |
| `founder.application_approved` | `team`, `expiresAt` | A17 |
| `founder.application_rejected` | `team` | A18 |

- Approval links are rebuilt by the worker. `api.outbox_claim` returns the invitation's
  `tokenId`, and `outbox.is_relevant` skips the email once that invitation is accepted,
  replaced or expired.
- The email never contains the decision reason.

## B2. Rules
- **Submit** (`api.submit_founder_application`, public, called only by the Wallet server):
  1. Validates every field. A new application is created only if the email has no waiting
     application, no rejection in the last 30 days and no founder grant.
  2. Only then does it queue A19.
  3. The reply is always `{received: true}`.
  4. A platform-wide cap of 200 new applications an hour returns `rate_limited`.
  5. Turnstile runs in the Wallet server before the call, and the route needs
     `x-app-server-secret`.
- **Decide** (`api.admin_decide_founder_application`, platform admin, PIN step-up, reason,
  idempotent):
  - **Approve** creates the invitation and queues A17.
  - **Reject** queues A18.
  - Deciding an application that isn't waiting gives `conflict{reason: already_decided}`.
  - Audited as `founder_application.approved` / `founder_application.rejected` (platform audit,
    group "accounts").
- **Resend** (`api.admin_resend_founder_invitation`, same guards): works only on an approved
  application whose invitation isn't accepted. It replaces the token, resets the expiry and
  queues a fresh A17. A resend more than 5 times is refused with `conflict{reason: resend_limit}`.
- **Accept** (`api.accept_founder_invitation`) needs:
  - a session at gate `ready` or `pin_setup_required` (`org.require_join_session`)
  - a confirmed email that matches the invitation
  - a live, current token
  
  It marks the invitation accepted and inserts the `founders.approved` row. It is idempotent
  for the same account. Accepting with a different email gives `invitation_email_mismatch`.
  Any other failure gives `invitation_unavailable`.
- **Preview / verify-email** match Blueprint 03 (no session; the person sees only the masked
  email).

## B3. Database functions (`api.*`, `security definer`, `search_path = ''`)
- **Public:** `submit_founder_application`, `founder_invitation_preview`,
  `request_founder_verification`.
- **Session:** `accept_founder_invitation`.
- **Admin:**
  - `admin_founder_applications(status, cursor, limit)` returns `{items, nextCursor, counts}`.
  - `admin_founder_application(id)`.
  - `admin_decide_founder_application`.
  - `admin_resend_founder_invitation`.
  - `admin_overview` gains `founderApplications` (the waiting count).
- **`billing_setup`** gains `founderApproved`.

## B4. Routes
- **`invitations` function:**
  - `POST /founder-applications` (public, needs `x-app-server-secret`).
  - `POST /founder/preview` and `POST /founder/verify-email` (public). The verification email
    redirects to `/founder`.
  - `POST /founder/accept` (signed in).
- **`admin` function:**
  - `GET /founder-applications`, `GET /founder-applications/:id`.
  - `POST /founder-applications/:id/decide` with `{decision, reason, idempotencyKey}`. Approval
    issues the token at the Edge.
  - `POST /founder-applications/:id/resend`.
- **Outbox worker:** `founder.*` links are `${APP_ORIGIN}/founder#t=<token>`.

## B5. Frontend
- **`/apply`** (13d/13m) is the form with Turnstile, followed by "Application received"
  (14d/14m).
  - `/sign-up` redirects to `/apply`.
  - The sign-in link reads "New to Elivate? Start your network" → `/apply`.
  - Signed-in visitors see their email prefilled and "Back to workspaces".
- **`/founder`** is the founder invitation flow, a copy of `/join` with founder wording. The
  cookie is `ew_founder`, and `/auth/confirm` and `/workspaces` route to it while it's set.
  After accepting:
  - at gate `pin_setup_required` → `/pin/setup?next=/setup`
  - otherwise → `/setup`
- **`/setup`** sends a person without approval to `/apply`.
- **Admin `/admin/applications`** (A22/A22b):
  - tabs by status, with a review dialog (approve or not approved, reason, PIN)
  - Resend on approved rows not yet accepted
  - sidebar "Founder applications" with the waiting count
  - a row in the overview's "Needs attention"
  - a More entry on mobile
- **Root poses:** `apply`, `apply-sent`, `admin-applications`, `admin-application-review`.
  The email poses are `founder-approved`, `founder-rejected` and `founder-received`.

## B6. Tests
- **pgTAP `190_founder_applications.sql`:**
  - submit (new, duplicate, rejection window, existing founder, cap, validation)
  - decide (step-up, admin only, idempotency, already decided, emails and params)
  - resend
  - accept (gate, mismatch, idempotent, grant)
  - `start_network` refusal
  - backfill and privileges
- **Existing pgTAP files** that start networks grant their founders first.
- **Deno:** handler tests for the new routes and the secret check, renderer tests for the three
  emails, and the worker's founder link.
- **Frontend:** unit tests for phone and rank parsing. e2e `founders.e2e.ts` covers: apply →
  A19 in Mailpit → admin approves → A17 link → verify → password → PIN → `/setup` → trial;
  reject → A18; axe at 320 px and desktop.

## B7. Deploy (after merge, from fresh `origin/main`)
1. Migrations: check the dev history through the Management API, then push. Say which path was
   used.
2. Deploy the `invitations`, `admin`, `outbox-worker` and `billing` functions. No new secrets
   are needed: `APP_SERVER_SECRET` and `INVITATION_TOKEN_SECRET` are already project secrets.
3. Build and deploy both Workers (app and admin).
4. Smoke test with synthetic data only. Real accounts are not touched.
