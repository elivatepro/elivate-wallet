# Member app: full build plan and owner decisions (2026-10-08)

The owner asked for every pending member-facing backend and frontend piece to be built
before the Admin app. This file records the decisions given on 2026-10-08 that unblock that
build, the scope, and how the work is run. Where a decision changes the product pack, the
build updates the affected contract line (`00-product.md` U-table, `01-domain-rules.md`,
`02-workflows.md`) in the slice that implements it.

## Owner decisions (2026-10-08)

### Money movement
- **Withdrawal limits (U-07):** none at launch. Any amount up to the available balance of a
  withdrawable pocket; the approver's judgment is the control. Keep limits easy to add later
  as a setting, but do not invent values.
- **Payout receipt check (W-11):** AI check plus human review. OpenAI reads the payout receipt
  (amount, beneficiary name, bank, date, reference) and flags mismatches. An independent
  Financial Evidence Reviewer always decides. One correction, then independent review, as in
  W-11. Secret `OPENAI_API_KEY` (value in the repo-root `.env`; copy it into the dev Supabase
  secrets without printing it).
- **Currency conversion (W-12):** build it. A permitted leader records the rate actually used,
  with a receipt as evidence; no automatic rate tolerance or reference-rate check.
- **Adjustments (W-14):** reason, PIN and at least one evidence file, always. The member is
  notified.
- **Authority for conversion and adjustments:** granted to the President Team by default
  through role permissions; Presidents may grant them to other roles in the role-permission
  editor.
- **Kill switches:** deferred until the Admin app. Do not build switches now.

### Billing (W-19, U-03, U-13)
- **Activation:** a new network starts a **7-day free trial**, then must pay.
- **One trial per founder account**, ever. Further networks must pay before activation.
- **Trial cap:** the smallest band (up to 400 users); everything else works, real money
  included.
- **Paid plans:** the 3 launch bands only (up to 400 = ₦700,000/yr, up to 1,000 =
  ₦1,000,000/yr, 1,001+ = ₦1,500,000/yr). Bands 4–6 stay U-13.
- **Seat cap:** when a network reaches its cap, new members are blocked until the Billing
  Owner upgrades and pays the prorated difference (fills `org.check_seat_capacity`).
- **Renewal:** suspend at expiry, no grace period. Reminder emails before expiry are fine.
- **Suspended network (trial or year ended unpaid):** members keep read-only access to their
  own money; no new income, withdrawals, transfers, conversions or adjustments. Leaders and
  the Billing Owner can still pay to reactivate.
- **VAT:** prices include VAT. Send a receipt email with an Elivate reference; no separate tax
  invoice.
- **Paystack:** test mode on dev. Webhook URL (give this to Paystack):
  `https://crljnkdwkxkwgvhxfrbl.supabase.co/functions/v1/billing/paystack/webhook`.
  So the build must create an Edge Function named `billing` with route
  `POST /paystack/webhook`, `verify_jwt = false`, validating the raw-body HMAC SHA-512
  signature with `PAYSTACK_SECRET_KEY` (already set) and deduplicating events.

### Notifications and email (U-11)
- **Bell:** one in-app item for every email event sent to the person, plus "needs your action"
  items (approvals, reviews). Read/unread per item; kept 90 days.
- **Emails:** all Paper "Emails — Transactional v2" M-series for money events (income posted;
  withdrawal submitted, awaiting approval, approved, not approved, cancelled, completed;
  payout correction required; evidence review assigned; pocket move done/declined; adjustment
  posted; transaction reversed; returned funds; statement ready), plus the B-series billing
  and the relevant T-series emails. Build each from its Paper artboard with the shared layout
  (`backend/supabase/functions/_shared/email/layout.ts`).
- **Support email:** `support@elivatewallet.com` (owner-designated; shown as "Contact support"
  and in email footers). Confirm with the owner that the inbox exists before relying on it.
- **Support widget:** Chatwoot Cloud (`app.chatwoot.com`) now. `CHATWOOT_ACCESS_TOKEN` is in
  the repo-root `.env`. Use the API to find (or create) the website inbox and its widget
  token. Share only UID, network name and current screen; never evidence, bank, PIN or token
  data (W-21).

### Accounts, auth and security
- **Forgot password:** yes. Supabase recovery email → `/auth/confirm` (token_hash, POST
  Continue) → set a new password → PIN as usual. Update the Recovery Auth template's link to
  the token_hash form and re-apply templates.
- **Suspended accounts (U-08):** keep today's behaviour: the blocked "account unavailable"
  screen only. (Ended memberships and suspended networks keep read-only own money, as decided
  earlier.)
- **Turnstile:** build now on sign-in, sign-up and forgot-password. The agent creates the
  Turnstile widget for `app.elivatewallet.com` itself through Cloudflare and stores the keys
  as Worker secrets (`TURNSTILE_SITE_KEY`, `TURNSTILE_SECRET_KEY`); verify server-side.

### Deferred (do not build now)
- Workspace requests (U-04). Founders create networks directly; invitations only.
- White-label custom domains (U-05). Network branding (logo, colour, name) is in scope.
- Kill switches and feature flags (with the Admin app).
- The Admin app itself.

### Backups (U-06)
- Build **restore requests** (W-24 statuses, `RST` reference, requester notified; Elivate
  reviews and runs restores later in the Admin app) and an on-demand **signed full-network
  export download** for Presidents. Scheduled cloud destinations stay deferred.

### Statements (W-18)
- PDF (Paper "Statements & reports v1") and CSV, generated server-side; long ones run as jobs
  and send "statement ready".

## Owner decisions during the build (2026-10-08/09)

Paper `App — Screens v4 (member build)` batch 1 (N, Q, J, Z) is approved; Z01 is superseded.
Batch 2 (U01–U07 payouts, MV01–MV05 money moves, PL billing, NB bell, WK support chat) is
approved (2026-10-09): build these directly, replacing the slice 4 U/MV stubs.

- **Offices:** an office closes only with no active members, no offices below and no money
  held; any remaining memberships are archived. Role change changes the role only; office
  moves go through Move. Move, suspend and end membership require reason + PIN.
- **Activity:** search and status filter get backend support; type filter on mobile too.
  A reversal shows as its own row and as a "Reversed" status on the original.
- **Member wallets (leaders):** own menu item and reachable from Members; per-pocket
  breakdown visible; lists show the available balance per currency.
- **Income:** member search covers the whole network; an unknown-outcome attempt may stay
  on the device for 24 hours after sign-out.
- **Profile and security:** no time zone on the profile; Turnstile is invisible and shows
  only on failure; sign out all other devices needs no PIN.
- **Devices:** store the IP address per session for approximate location and "Unusual
  sign-ins".
- **Password:** build changing the password while signed in. After a password reset, the
  person chooses whether to sign out other devices.
- **PIN change** sends a security email.
- **Slice 9 follow-up (2026-10-09, Blueprint 14):** location shown as city, country from
  Cloudflare (the IP is stored, never shown); sign-in records are never deleted; "unusual" =
  a new city/country or a new device (never the first sign-in); emails A06 Password changed,
  A07 New sign-in (unusual only), A08 PIN changed; the signed-in password change needs the PIN
  only. Supabase Auth always signs out other sessions on a password change, so the "choose
  whether to sign out other devices" decision became: always sign out, and say so (Z09, Z10).
- **Billing:** seat upgrade costs the price difference × days left in the paid year ÷ 365.
  A founder may skip the trial and pay for any launch band directly. Paused networks give
  leaders and the Billing Owner a pay-to-reactivate view; withdrawals approved before the
  pause still get paid out.
- **Needs your action** bell items are both live tasks (they clear when done) and ordinary
  read/unread notifications.
- **Notifications (slice 8, 2026-10-09):** approval and review emails/tasks go to everyone who
  can act (approvers by `approve_withdrawal`/`approve_pocket_transfer` over the member; every
  assigned reviewer in scope, never the submitter); the owner always hears about their own
  money, even their own actions; no opt-out; the bell shows the selected network plus
  personal items; events with no drawn email got new emails M16 Conversion posted, M17 Payout
  receipt rejected and M18 Not posted (with generated Root poses, approved); A10–A12 are sent
  too; `support@elivatewallet.com` is live.
- **Full-network export** download requires the PIN.
- **Payout recording** has the optional fee field (U02).
- **Currency conversion (W-12)** starts from its own leader tab/menu item and from a
  member's wallet (a "Convert" action next to Move).
- **Default permissions:** new networks keep the A-03 defaults (conversion also on for Team
  Leader, Director and World Team; adjustments also on for World Team); Presidents can change
  them in the role editor.
- **Evidence reviewers:** a role change ends the reviewer assignment; the President re-adds it.
- **Prod (2026-10-09):** "push to prod" means dev plus the live Worker; production stays
  off-limits.
- **Receipt check (2026-10-09):** model `gpt-5-mini`, in secret `OPENAI_RECEIPT_MODEL`. The
  payment date compares the calendar date printed on the receipt; convert to UTC only when
  the receipt prints a time zone.
- **Statements and reports (slice 6, 2026-10-09, Blueprint 15):** WAT for periods and printed
  times (CSV also carries UTC); PDFs rendered with Cloudflare Browser Rendering from the app
  Worker (approved addition to the stack; Workers Paid); network name + initial tile until
  slice 10; leadership: office report PDF, transactions CSV and member balances CSV, whole
  scope or one member; every file is one complete-or-fail job, M15 + bell above 1,000 rows,
  hard limits PDF 5,000 / CSV 50,000 rows ("Too large"); private R2, files removed after 7
  days; downloads streamed by the app server, audited, PIN for leadership reports only;
  statements for any network the person holds or held money in. Paper S10–S14 drafts approved.
- **Sequencing:** one slice at a time, each new slice in its own thread. Order: 4 → 5 → 8 →
  slice 9 follow-up (IP storage, signed-in password change, PIN-change email, sign-out
  choice after reset) → 6 → 7 → 10.

## Design rule for screens Paper doesn't have

**Design in Paper first.** For any member screen with no Paper composition, an agent drafts
it in the `Elivate Wallet` Paper file (Emberlit tokens, existing Root poses only, synthetic
data), and the owner approves it before it is built. Batch these drafts so approvals happen
in a few rounds rather than one at a time. Screens with Paper designs are built directly.

## Shipping rule

Agents open one PR per slice. When CI is green, merge and deploy to **dev** (migrations with
`supabase db push --linked`, changed Edge Functions, `pnpm exec wrangler deploy` in
`frontend/`), then smoke-test. Never `supabase config push`; Auth settings change only through
the Management API for the specific fields. Production stays off-limits.

## Scope (from the 2026-10-08 gap analysis)

Build order follows P-02. Each slice gets an owner-visible blueprint in `docs/blueprints/`,
then backend (migration, `api.*`, Edge routes, pgTAP, Deno tests), then frontend (routes,
BFF `/api/*`, e2e).

1. **Org management UI** (backend done): offices tree and lifecycle, members and membership
   lifecycle, President Team, role-permission editor, access grants, evidence reviewers,
   office totals, President audit log. Add close-office and role change (end + new
   membership) to the backend.
2. **Money groundwork:** unknown-outcome recovery for commands (F-03), activity list with
   search/status filters and transaction detail, managed wallets and leadership dashboard.
3. **Income recording UI** (backend done).
4. **Withdrawals and payouts:** request/approve/reject/cancel, payout recording with reveal,
   OpenAI receipt check, one correction, evidence review queue (W-09–W-11, W-13).
5. **Pocket transfers, returned funds, adjustments, reversals, conversion** (W-12, W-14–W-16).
6. **Statements and reports** (W-18), PDF + CSV.
7. **Billing:** founder network setup, 7-day trial, plan picker, Paystack checkout and webhook,
   activation, seat cap and upgrade, expiry suspension, receipts (W-19).
8. **Notifications:** bell backend and UI, all M/B/T outbox templates.
9. **Account and security:** sessions/devices, change PIN, profile edit, forgot password,
   Turnstile, payout-account replace.
10. **Workspace settings:** network branding (W-20), Chatwoot support, support email, restore
    requests and full-network export (W-24), 404/no-access/paused screens, ⌘K search.

Slices 1–3 and 9 can run in parallel now. Withdrawals (4) and transfers/corrections (5) share
the ledger reservations and must be sequenced or carefully split. Billing (7) and
notifications (8) are independent of the money slices. Statements (6) come after 4–5.
