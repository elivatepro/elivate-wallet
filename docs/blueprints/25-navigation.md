# Blueprint 25 — Navigation redesign and role homes (slice 25)

Status: **owner approved the Paper drawings 2026-10-10; built in slice 25.**

Contract: `docs/member-build-plan.md` "Owner feedback round (2026-10-10)" (slice 25) and
"Navigation and role homes (2026-10-10)", 00 P-06 (bottom bar, capability-derived sidebar, money
per currency), 01 A-01/A-02 (navigation is a hint; the backend authorizes), W-07 Leadership
(authorized scope only, excluded scope said out loud, one currency at a time, never a
cross-currency total). Builds on Blueprints 08 (leadership overview), 13 (bell tasks), 20/23
(cache, instant taps), 21 (wallet-less navigation, the 64 px header line), 22 (funds not managed)
and 24. Design: Paper `Elivate Wallet`, page "Navigation v5 (approved 2026-10-10)": NV01 (President
Team, mobile), NV02 (member, mobile), NV03 (President Team, desktop). Migration
`20261009250100`; pgTAP `250_`.

### Owner decisions (2026-10-10, binding)
1. **Mobile tab bar:** the Roudio "Fresh Direction" floating pill. Icons only; the current tab
   grows into a filled accent pill with icon and label; the width animates (off with reduced
   motion) and follows the tap at once (`navigating.to`, Blueprint 23). Member: Home · Activity ·
   Withdraw · More. President Team: Home · Approvals · People · Activity · More. A dot on
   Approvals while something waits.
2. **Desktop sidebar in sections:** top (Home / "Network overview", Activity), APPROVALS, MONEY,
   PEOPLE, WORKSPACE and MY WALLET (own-wallet memberships only). Items keep their permissions.
   The 64 px header line stays (slice 21 token and e2e).
3. **President Team home:** the network overview replaces the slice 21 "No wallet in this
   workspace" stopgap: greeting, "Income recorded this month" with a currency switch and the
   change on last month, weekly bars, members / offices / invites out, "Needs your action", and
   "Offices this month" (members and income per office, new read).
4. The workspace switcher card and More follow the new design language.

---

## B1. Navigation model (`#lib/nav.ts`, unit tested)
One pure function, `navModel({ permissions, role, billingOwner, tasks })`, gives the sidebar
sections, the tab set and Home's kind; the layout, the More page and Home all use it. Before the
capabilities load (or offline) the role stands in for own money, as in slice 21.

**Sections** (each item keeps its pre-slice permission):

| Section | Items (permission) |
|---|---|
| top | Home, labelled "Network overview" on a President Team network home · Team overview (leadership reads, only where Home is the wallet) · Activity (`view_own_financials`; the President Team's is the audit log, see B5) |
| Approvals | Withdrawal queue (`approve_withdrawal`, count: withdrawals to approve + payouts to record or fix) · Pocket moves (`approve_pocket_transfer`) · Evidence (`review_financial_evidence`) · Identity reviews (President Team, World Team) · Reversals (`reverse_transaction`) |
| Money | Record income (`record_income`) · Member wallets (leadership reads) · Convert (`perform_currency_conversion`) · Reports (`view_scoped_financial_reports` / `export_scoped_reports`) |
| People | Members, Offices (President Team, `manage_members`, `view_managed_wallets`) · Invitations (`invite_members`) · Access (President Team, `manage_access_rules`) |
| Workspace | Settings (`manage_team_settings`, else the vault with `request_restore`) · Billing (`manage_subscription` or the Billing Owner) · Pockets & split (when the workspace holds no wallet) |
| My wallet | Withdrawals, Payout accounts, Statements (own-wallet permissions) · Pockets & split (with a wallet) |

- Empty sections are not shown. Section headings are groups named for assistive tech.
- Labels follow NV03: "Pocket moves", "Evidence", "Identity reviews", "Convert", "Access",
  "Settings". The pages keep their own headings; quick search also finds the new names.

**Tab sets** (at most five; Home first, More last):

| Workspace | Tabs |
|---|---|
| Member (own wallet, no leadership) | Home · Activity · Withdraw · More |
| President Team | Home · Approvals · People · Activity (audit log) · More |
| Team Leader, Director, World Team (own wallet) | Home · Approvals · People · Activity · More; Withdraw stays on Home's actions and under More → My wallet |
| Director whose funds are not managed | Home · Approvals · People · More (no wallet, no audit log) |
| A leader with a free slot (e.g. People but no approvals) | Withdraw is added before More |

- **Approvals** opens the first approval page the person can use (normally the withdrawal
  queue) and is current on every approval page. **People** opens Members (else Invitations) and
  is current on Members, Offices, Invitations and Access. **More** is current on More and on any
  other page reached from it.
- **Dot:** Approvals shows a dot while the bell's live tasks (Blueprint 13) hold anything for its
  items; the tab says ", something is waiting" to screen readers.

## B2. Shell (Paper NV01–NV03)
- **Sidebar:** on the canvas, 260 px. The switcher block is still exactly `--shell-header`
  (64 px, border-box: 7 + 48 + 8 + 1 px) so its line meets the top bar's; the switcher shows the
  network's tile, its name and "role · office". Quick search, then the sections (36 px top rows,
  34 px section rows, 11 px uppercase headings, counts as 20 px pills: coral for the queue).
- **Top bar:** 64 px, the page name, Support, the bell and the person's initials (photo when it
  loads).
- **Mobile app bar:** the network's tile, its name and "role · office" ("whole network" for the
  President Team); bell and initials. Quick search on phones moved to the top of More.
- **Pill bar:** 64 px, 24 px from the sides and 28 px from the bottom (plus the safe area),
  blurred surface. Inactive tabs are 56 px icon slots (64 px with four tabs, 44 px minimum);
  the current tab is `flex: none` with the label's `max-width` and the padding animating over
  260 ms (`cubic-bezier(0.2, 0.8, 0.2, 1)`). Reduced motion: no transition. Light and team themes
  come from the tokens (`--color-accent`, `--button-primary-ink`, surface and border).

## B3. "Offices this month": `api.leadership_offices` (migration `20261009250100`)
- `api.leadership_offices(p_user_id, p_session_id, p_membership_id)`: `security definer`,
  `search_path = ''`, executable by `service_role` only, read-only apart from the session touch.
- **Authority and scope:** as `api.leadership_overview`: `view_managed_wallets` or
  `view_scoped_financial_reports` over the workspace office (the network for the President
  Team), else `authorization_denied`. The workspace must be the caller's own
  (`org.change_workspace`), so another network is never reachable.
- **Rows:** every active office of the scope (and a closed one that has income this month),
  World Team → Director → Team Leader, then by name. Each counts **its own office only**: active
  memberships anchored there (not the President Team, not the viewer, only people the viewer may
  see) and income on segments whose origin office is that office. The rows therefore add up to
  the scope.
- **Income:** postings of `income` transactions on the segments `ledger.visible_segments` allows
  (the same definition as `leadership_overview`), per currency (every active currency and any
  the scope holds), exact decimal strings. No total across currencies.
- **Month:** the network's own: `org.tenant_settings.time_zone` (Africa/Lagos by default),
  from the first instant of the month to the first instant of the next.
- **Excluded scope:** `excludedMembers` per row and `excluded { offices, members }` overall
  (segments the viewer may not see; their own money is neither counted nor reported).
- **Edge:** `GET /ledger/overview/offices` (`X-Membership`, no query; an output shape check).
  **BFF:** `GET /api/overview/offices`. **Contract:** `LeadershipOffices` (`contract/ledger.ts`).
- **Cache (Blueprint 23):** kind `wallets`, part `offices`: shown from the saved copy, then
  refreshed; money commands clear it. The overview read moves to the same network month (`tz`
  from the offices reply, Africa/Lagos until then) under part `overview`.

## B4. Role homes (`NetworkOverview.svelte`)
- **Who gets it as Home:** a leadership workspace that holds no wallet: the President Team and a
  director whose funds are not managed (`navModel().networkHome`). Everyone else keeps the
  wallet Home (`WalletHome.svelte`, unchanged apart from a "Team overview" action for leaders).
- **Leaders with a wallet** (Team Leader, Director, World Team) get the same component as their
  **Team overview** page (`/app/team`), titled with their scope instead of the greeting, with
  "Reserved · Available" in the card. It replaces the T01/T04 composition.
- **Contents:** "October · whole network" (or the office), the greeting, Export report and
  Invite a member (desktop, by permission), the card with "Income recorded this month", the
  NGN/USD switch (one currency at a time), "↑ 12% on September · ₦…" (or "Nothing recorded in
  September"), the five weekly bars (desktop, as drawn; the best week in the accent, this week
  lighter), Members / Offices / Invites out, "Needs your action" and "Offices this month" (top
  five by income in the chosen currency, "All offices →"). A note says how many members the
  figures leave out.
- **Needs your action** lists the approval items the person can use, with the bell's live task
  counts: Withdrawals to approve, Identity reviews, Evidence to check, plus Payouts to record and
  Pocket moves to approve when any wait. The counts load with the bell and refresh when the
  unread count changes or an approval command clears its cache (`onInvalidate`).

## B5. More
- The same sections as the sidebar (without what the tab bar holds), then Account (Profile &
  security, Support, Appearance, Hide amounts) and Sign out.
- Quick search at the top; the profile card; the workspace card (the network's tile, name and
  "role · office", 64 px, 18 px corners).

## Decisions taken while building
- **The President Team's "Activity" is the network's audit log.** The owner's tab set and NV03
  give the President Team an Activity entry, but it holds no wallet and no network-wide money
  feed exists. The audit log (read-only, President only) is the record of what happened in the
  network, so Activity opens it; the separate "Audit log" row is not repeated under Workspace.
  A director whose funds are not managed has neither, so no Activity tab.
- **Pockets & split** sits under My wallet where the workspace holds a wallet, else under
  Workspace (the President Team edits the split there).
- **Per-office rows count their own office** (not their subtree) so the table adds up.
- **Team overview** keeps reserved and available figures in the card (W-07 Leadership).
- **Not drawn, so not added:** the Members count beside "Members" in the sidebar (no cheap read
  holds it; the network home shows it).

## Tests
- **pgTAP `250_leadership_offices.sql` (31):** Team Leader / Director / President scopes and
  row order; per-currency amounts as strings and no total; members exclude the viewer; own money
  neither counted nor excluded; another network never shows and another person's workspace is
  refused; month boundaries in the network's time zone (one second before the Lagos month, its
  first instant, and an instant that is still last month in UTC); a deny excludes the member's
  money and counts them as excluded; a member is refused; execute privilege.
- **Deno** `leadership_offices_route_test.ts`: the call and its arguments, input refused before
  the database (workspace, query, anonymous), database codes kept, odd output is internal.
- **Unit** `nav.spec.ts`: tab sets per role (member, Team Leader, Director, World Team,
  President Team, funds-not-managed director, free slot), at most five tabs, the Approvals dot,
  offline fallback, sections per role (no wallet items for the President Team, My wallet for
  members), current-tab rules, task counting.
- **e2e** `navigation.e2e.ts`: the President's network home (both currencies, the offices
  table), sections without My wallet, the header line at 1024–1920 px (exactly 64 px), the leader
  tab set, the pill growing on the tapped tab and Home folding, Activity → audit log; the member's
  tabs, My wallet and More. Screenshots (`E2E_SHOTS`) at 390 and 1440 px, dark and light.
  Existing specs follow the new labels and Home.

## Open for owner
- **President Team Activity:** it opens the audit log (above). A network-wide money activity feed
  would need a new read; say if you want one.
- **Needs your action counts** come from the bell's live tasks, which are created for the people
  who could act when the request was made; a leader added later sees the queue but no task
  count until the next request.
