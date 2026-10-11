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
- **Activation:** a new network starts a **7-day free trial**, then must pay. Only an
  approved founder may create a network (see "Founder applications" below).
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
- ~~Kill switches and feature flags (with the Admin app).~~ Kill switches built in slice 18 (Blueprint 18); feature flags deferred again (2026-10-10).
- ~~The Admin app itself.~~ Built in slice 18 (Blueprint 18).

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
  An approved founder may skip the trial and pay for any launch band directly. Paused networks give
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
- **Billing (slice 7, 2026-10-09, Blueprint 16):** networks active on dev before this slice
  are grandfathered as the W-19 development scope exception (no end date, no seat cap,
  audited, no trial used). Renewal is a **Paystack subscription** (automatic yearly charge on
  the saved card; a payment by any other channel renews manually). A paid year starts at the
  end of the current trial or period (paying early loses no days); paying to reactivate a
  paused network starts the year at payment. B02 at 30, 7 and 1 days before a renewal (trial:
  3 and 1 days before it ends); B04 once per period at 90% of seats. No refunds; auto-renew
  can be turned off and a smaller band chosen for the next renewal only if the seats fit;
  upgrades apply at once for the prorated difference, from the cap or voluntarily ("Upgrade"
  replaces "Request"). manage_subscription holders and the current Billing Owner can pay;
  only manage_subscription changes the Billing Owner (PIN); the founder is the default Billing
  Owner; B01–B05 go to the Billing Owner and the President Team. At the cap new invitations
  and acceptances are refused; an unpaid trial pauses like an expiry. The platform-admin
  activation stays for support (complimentary period or the development exception, never a
  payment). On a paused network leaders keep read-only history, reports, queues and audit,
  plus Billing; B05 says "Pay to turn it back on" with "Review billing".
- **Workspace settings (slice 10, 2026-10-10, Blueprint 17):** restores are reviewed and run by **Elivate only** (W-24; the 2026-10-07 "team approves the diff" note and V05/V06 are withdrawn); Team Vault backups are **kept 90 days**; the team colour is **one of six fixed themes** that colour the network's accent (Paper TS01d/TS02d/TS03d drafts approved); branding and team details use a new protected President-only key **`manage_team_settings`** (PIN to save), restore requests the protected **`request_restore`** (World Team and President), so A-03 has 34 rows. Backups go to their own private R2 bucket (`BACKUPS`, no lifecycle rule); logos live privately in `PHOTOS` under `brand/`.
- **Founder applications (2026-10-10):** founder sign-up is **apply first**; open "Start your
  network" sign-up is withdrawn. The public form asks for name, email, phone, team name and a
  self-declared rank, which must be **Ruby Director 4, Ruby Director 5 or Diamond Director**;
  no proof upload. Any platform admin approves or rejects in the Admin app with a reason;
  approval emails a founder invitation, the only way to create a founder account and network,
  and rejection emails a polite no (the same email may apply again after 30 days). Nobody
  creates a network without approval, paid or not; an approved founder's further networks need
  no new application and pay before activation as before. The trial stays **7 days**, capped
  at the 400-user band, with **no card**. Prices are shown on the marketing site
  (elivatewallet.com), not in the app. Emails: A19 application received (to the applicant),
  A17 approved (with the founder invitation) and A18 not approved. The invitation reuses the
  Authentication v2 invitation screens (08, 09) with founder wording, then network setup.
  Paper drafts: Authentication v2 13/14, Admin A22/A22b, Emails A17–A19, each with a new Root
  pose (awaiting approval).
- **Speed and caching (2026-10-10, Blueprint 20, amends 36a and frontend plan §5.9):** every
  page is slow, so the fix is global, for Nigerian mobile data and office desktops alike, using
  free Cloudflare config and Supabase tuning only. Signed-in pages open from the device cache
  (balances included) and refresh in the background. Writes clear the affected data and always
  go to the server. Server responses stay `no-store`. Cached data is shown only when it matches
  the readable `ew_who` cookie: an HMAC of the user and membership, holding no ids and never
  trusted by the server. Capabilities are not cached. The new reads `api.app_bootstrap` and
  `api.home_view` replace the call chains behind `/api/session` and `/api/home`. Session
  last-activity is written at most every 30 s. The Worker uses Smart Placement. Root images
  stay exactly as they are. Set-based authorization moves to a later slice (after 25; see the
  feedback round below).
- **Owner feedback round (2026-10-10, Blueprint 21):** ranks are shown **number first**
  everywhere ("4 Ruby Director", "1 Ruby Director"); display only, stored values keep their
  form ("Ruby Director 4", founder key `ruby_director_4`). The **President Team must not see
  modules it can't use** (it holds no wallet: Payout accounts, Withdrawals, Activity,
  Statements, Move money). Slice plan from here (the set-based authorization reads move last):
  - **21** quick fixes (Blueprint 21).
  - **22** setup by role, a backend profile gate, and a per-director **"funds not managed"**
    switch: only the President Team flips it; it is blocked while that director's wallet holds
    money; an exempted director still records income and runs their team.
  - **23** speed II: the SWR device cache on every page, instant tap feedback, precache every
    `/app` chunk, view transitions (the owner accepted all the trade-offs).
  - **24** a haptic wheel for every member-app dropdown, with a search field for long lists
    (banks included; this replaces the native bank select deviation).
  - **25** navigation redesign: the mobile Roudio "Fresh Direction" pill bar, a sectioned
    desktop sidebar and role dashboards (Paper drawings approved first).
  - Then **set-based authorization reads** (`visible_segments`, `my_capabilities`).
- **Setup by role, profile gate, funds not managed (2026-10-10, Blueprint 22):**
  - Setup differs by role. The **light setup** (President Team, and directors whose funds are
    not managed) is the PIN, then name, photo and rank: no NIN, phone or bank account. The
    **wallet setup** (member, team leader, director, World Team) is the PIN, the NIN with the
    details confirmation, the profile (photo, phone, rank) and a bank account.
  - A per-membership **"funds not managed"** switch for directors: only the President Team sets
    or clears it, with a reason and the PIN (audited, idempotent, inside the network). Setting it
    is refused while the director membership itself holds money (any posted or reserved amount
    on its segments, any currency or pocket) or has an open withdrawal, pocket move or entry
    (`conflict{reason: wallet_not_empty}`); money on the person's other memberships doesn't
    block it. A President Team member may switch their own director membership (reason + PIN). An exempted director keeps every director authority
    but holds no money: the light setup, no own-wallet permissions or pages, and the ledger
    refuses postings and holds for them. Clearing it restores the wallet, and the gate then asks
    for the NIN, phone and bank account.
  - The **backend enforces the setup on every call** (session gate `profile_required` with the
    next step); the wizard's own calls, joining, account security and sign-out keep working. The
    app sends the person to the right step and keeps `?next=`. Founders do their light setup
    right after the PIN, before naming the network and paying. It fails closed, and the `ew_ws`
    cookie no longer skips it. People on dev without a finished setup are gated on their next
    visit (intended). NIN review authority is unchanged.
  - Owner answers on PR #59 (2026-10-10): founders' light setup right after the PIN, returned
    funds refused and statement export off for a marked director, and a wallet member waiting
    for a NIN review staying in setup are all kept as built.
- **Speed II (2026-10-11, Blueprint 23, amends 36a again):** after a tap there was still a lag
  before anything changed. The owner accepted all of these trade-offs:
  - **Every page opens from its saved copy** (stale-while-revalidate): every `/app` list and
    detail page shows its last copy from memory or the device cache at once, then refreshes.
    The Blueprint 20 rules hold (per user and workspace, `ew_who`, the forbidden-field guard,
    invalidation after commands, "Updating…", sign-out purge). Money actions always check the
    server; data may be seconds old until the refresh lands.
  - **Instant tap feedback:** press states, and the tab bar and sidebar follow the tap at once
    (`navigating.to`); a light page frame shows while a page is on its way. Nav styling is left
    to slice 25.
  - **All screens' code downloaded upfront** once the shell is idle (about 1.8 MB once).
  - **A short page swap** (≤ 200 ms view transition; off with reduced motion; never delays).
- **Wheel pickers (2026-10-11, Blueprint 24):** every member-app dropdown is the onboarding rank
  wheel (bottom sheet, 52 px scroll-snap rows, a vibration per step where the browser allows
  it, keyboard, native `<select>` without JS). Lists of more than 8 options, and banks always,
  get a search field with an empty-result message. The bank selects move to the wheel: the
  **"native bank select" accepted deviation is withdrawn**. Desktop shows the same wheel as a
  centred dialog (to become an anchored list on desktop, owner 2026-10-11, slice 30). iOS has no web vibration, so iPhones get the visual snap and tick only. The
  admin console keeps native selects.
- **Navigation and role homes (2026-10-10, Blueprint 25; Paper "Navigation v5" NV01–NV03
  approved):** the mobile tab bar is the Roudio "Fresh Direction" floating pill (icons only; the
  current tab grows into a filled accent pill with its label). Tab sets: member Home · Activity ·
  Withdraw · More; President Team Home · Approvals · People · Activity · More (leaders with a
  wallet the same, Withdraw on Home and More); a dot on Approvals while something waits. The
  desktop sidebar has sections (top, Approvals, Money, People, Workspace, My wallet for own-wallet
  memberships), each item gated as before, the 64 px header line kept. A wallet-less leadership
  Home (President Team, funds-not-managed director) is the network overview with "Offices this
  month" (new read `api.leadership_offices`); leaders with a wallet get it as Team overview.
  Open for owner: the President Team's Activity opens the audit log (no network money feed).
  **Superseded in part 2026-10-11 (Blueprint 28):** see the next entry.
- **What leaders see, and unlock in place (2026-10-11, Blueprint 28; Paper "PIN unlock v7"
  PU01–PU03):** every leader's Home is the overview of what they lead; a leader's own wallet is
  under **My wallet** (`/app/wallet`). The Offices page is for the President Team and World Team
  only; directors keep the read-only "Offices this month" table, and a single-office scope
  drops the Offices count and table. Nobody sees themselves in Members; a leader doesn't see the
  invitation they accepted. "Invite a member" opens the form directly. A PIN owed inside the app
  locks in place (no "no access", no leaving the page): the page is unmounted, **every saved
  device copy is deleted** (amends 36a/Blueprint 23), other tabs lock, and it unlocks on the 4th
  digit. The backend's PIN gate (`identity.require_session`) stays the enforcement.
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
