# Blueprint 44 — Withdrawal follow-through (slice 44)

Status: **Approved 2026-10-17** (owner: "Implement them", after approving Paper "Withdrawal
follow-through v14 (approved 2026-10-17)" WF01–WF05). Contract: W-07 (activity), W-09
(withdrawals, amended), W-20 (team settings), P-05/P-06 (bell and push limits), 01 F-01 (no
single-open-request rule unless the network switches it on). Builds on Blueprint 11
(withdrawals), 17 (team settings), 40 (withdrawal reason), 42 (push). Migration
`20261009440100_withdrawal_follow_through.sql`; pgTAP `440_withdrawal_follow_through.sql`,
`441_one_open_withdrawal_race.sql`.

Part A is for the owner. Part B is the build spec.

---

## Part A — What this slice does

### What the owner saw (2026-10-16, member test account on dev)
1. A requested withdrawal did not show in Home's Recent activity (every row said "Posted").
2. Withdrawal rows looked rough and tapping one did nothing; "Track this withdrawal" only
   opened the list.
3. No push when the member requested a withdrawal.
4. The cancel dialog said "The hold is released. No money moves." (jargon).
5. "Request sent" had long copy, was off design and reused the income pose.
6. Nothing stopped a member placing a second withdrawal while one was open.

### Owner decisions (2026-10-17, binding)
| # | Decision |
|---|---|
| D1 | **Activity.** Open withdrawals (requested or approved) show in Home's Recent activity and on the Activity page, labelled with their stage ("Requested" / "Approved"), the amount shown **on hold** (not as money out, never signed), and the row opens the withdrawal. Once completed, the posted ledger row represents it (no duplicate). Cancelled and rejected requests never moved money: they stay only in Withdrawals. Statements and reports stay posted-only. Same currency, network and permission scope as the existing activity reads. |
| D2 | **Push.** The owner gets a push when their own withdrawal is requested: "Withdrawal requested" · "₦5,000.00 is on hold until it’s approved." (amount hidden with Hide amounts; P-06 limits). |
| D3 | **One at a time.** A team setting the President Team can switch on, **off by default**: "One open withdrawal at a time" ("Members wait for their open withdrawal to finish."). When on, a wallet owner who already has a requested or approved withdrawal in that network can't place another, whether they or a leader places it. New withdrawal says so up front: Root, "Your withdrawal of ₦5,000.00 is still open." and "View withdrawal". |
| D4 | **Detail** (Paper WF01 phone page, WF04 desktop side panel): the card with the stage pill, the amount, "To <Bank> •• last4" and Root with a clipboard; Requested → Approval ("With your team leader") → Paid out ("To your bank"); cancelled shows "Cancelled by you <date>" (or by whom), rejected "Not approved <date>" with the reason the member already sees; From, For (Blueprint 40, only when given), Reference; "Cancel withdrawal" only while requested and the member may cancel. |
| D5 | **List rows** (Paper WF02/WF03): arrow tile, "<Bank> •• last4" (the bank name truncates, "•• last4" never does), "<pocket> · <date>" on phones, amount and status pill on the right; desktop columns Withdrawal / From / Status / Amount / chevron with sub-lines like "Requested 16 Oct, 22:15 · WDR-…", "Approved 1 Oct · waiting for payout", "Paid 22 Sep · WDR-…", "Cancelled by you 15 Sep", "Rejected 9 Sep · <reason>". No inline Cancel, no quoted reason. The whole row is a link that answers the press; the selected row (panel open) has a slightly lighter fill and a quiet 1 px outline, never a coloured edge bar; with the panel open the From column hides. |
| D6 | **Cancel dialog:** "₦5,000.00 goes back to <Pocket>." |
| D7 | **Request sent:** Root with an hourglass, pill "Waiting for approval", "Request sent", one line "₦4,000.00 is on hold until it’s approved.", "View withdrawal" (primary) and "Back to Home", the reference small underneath. |

### Paper
File "Elivate Wallet", page "Withdrawal follow-through v14 (approved 2026-10-17)": WF01 detail
(phone), WF02 list (phone), WF03 list (desktop), WF04 detail side panel (desktop), WF05 the two
new Root poses (clipboard `withdrawal-detail`, hourglass `withdrawal-sent`).

### Decisions I applied (say if you want them changed)
- **Desktop panel routing.** One link for every entry point: `/app/withdrawals/<id>`. On phones it
  is the full page; at 1024 px and wider it opens the list with the panel
  (`/app/withdrawals?w=<id>`). A phone given the `?w=` link opens the full page. Push, email,
  Home, Activity and "View withdrawal" all use the same link.
- **Where the setting lives:** Team details, a "Withdrawals" group above Save, saved with the
  rest (PIN, a new revision, restorable, in Recent changes as "Withdrawal rule changed", and in
  the President Team's T05 email as "the withdrawal rule").
- **Activity layout:** open withdrawals are their own "Open" group above the months (they are
  not posted, so they never sit inside a month or count in its In / Out totals). They follow the
  search and filters that make sense for them: hidden for "Money in", a status filter (posted /
  reversed are ledger statuses), a type other than Withdrawal or a currency other than NGN.
- **Only your own wallet:** leaders looking at a member's wallet see posted movements only, as
  before (their queue already shows open requests).
- **Approved rows** in the detail say "Waiting for payout"; the pill on the list still says
  "Approved".
- **Leader-placed:** the rule refuses a leader placing a withdrawal on behalf while the owner has
  one open, with the same reason; Withdraw on behalf has no screen of its own yet, so the
  refusal shows as a plain message there.
- **Contrast:** closed amounts, column heads and "To your bank" use the app's muted text colour
  (Paper's darker grey is under AA at those sizes).

### Not in this slice
Push and bell links to the withdrawal itself (they still open Withdrawals); a per-member rule;
limits on how many open withdrawals a leader may place.

---

## Part B — Build spec

### B1. Push (D2)
- `notify.push_kinds` gains `money.withdrawal_submitted` (insert-only, as Blueprint 42).
- `_shared/push/text.ts`: `money.withdrawal_submitted` → "Withdrawal requested" ·
  "<amount> is on hold until it’s approved."; hidden amounts as the others. Deno tests cover
  shown and hidden.

### B2. The setting (D3, W-20)
- `org.tenant_settings.one_open_withdrawal` and `org.tenant_setting_revisions.one_open_withdrawal`
  (`boolean not null default false`).
- `org.apply_settings` accepts `oneOpenWithdrawal` (a JSON boolean only, `validation_error`
  otherwise); `snapshot_settings`, `settings_audit`, `settings_json` (`settings.oneOpenWithdrawal`),
  `settings_summary` ("withdrawal rule") and `api.restore_team_settings_revision` carry it.
  Same command, route (`PATCH /org/settings`) and permission (`manage_team_settings` + PIN).
- Edge `org` `settingsPatch`: `oneOpenWithdrawal` must be `true` or `false`.
- `backups.snapshot`: a revision carries `one_open_withdrawal: true` only when on, so earlier
  archives still compare equal (F-03). `org.brand_json` is unchanged.

### B3. Enforcement (D3)
- `finance.lock_open_withdrawal(tenant, owner)` takes a transaction advisory lock per
  (network, owner) and returns the owner's newest open withdrawal there.
- `api.request_withdrawal` (same signature), after the replay check and before any reservation:
  when the network's rule is on, it takes that lock and refuses with `conflict`,
  `details.reason = 'open_withdrawal_exists'`, `details.withdrawalId`. A concurrent second
  request waits for the first to commit, then sees it (pgTAP 441 drives two sessions). A replay of
  an accepted request still answers.
- `api.withdrawal_sources` adds `openWithdrawal` (`{ withdrawalId, reference, status, currency,
  amount }`) while the rule is on and one is open, else null (`finance.blocking_withdrawal`).

### B4. Activity reads (D1)
- `ledger.open_withdrawals(user, wallet, tenant, filters…)`: the caller's own requested/approved
  withdrawals in that wallet and network, newest first: `{ withdrawalId, reference, status,
  currency, amount, title ("<Bank> •• last4"), pocket, tenantId, createdAt, approvedAt }`.
- `api.my_activity` adds `pending` on the first page only (no cursor); `api.home_view` adds
  `pending` (five newest). `ledger.activity` (managed wallets), month totals, `total` and the
  statement/report figures are unchanged.

### B5. Frontend
- Contract: `PendingWithdrawal` (`Activity.pending`, `HomeView.pending`),
  `WithdrawalSources.openWithdrawal`, `TeamSettings.oneOpenWithdrawal`,
  `SettingsPatch.oneOpenWithdrawal`, `SettingsField` `oneOpenWithdrawal`.
- `#lib/withdrawals`: `memberLine` (D5), `phoneLine`, `detailPill`, `detailSteps`,
  `cancelSummary`, `onHoldLine`, `stillOpenLine`, `pendingStage`, `withdrawalHref`,
  `openWithdrawalConflict`; `moveMessage` knows `open_withdrawal_exists`.
- `WithdrawalDetail.svelte` (page / panel), route `/app/withdrawals/[id]` (not prerendered;
  redirects to `?w=` when wide), the list rewritten as links with the panel beside it.
- New withdrawal: the D7 sent screen and the D3 blocked state (from `openWithdrawal`, or from the
  server's conflict).
- Home and Activity show `pending` rows (stage, "on hold", unsigned muted amount).
- Team details: the switch.
- Root poses `withdrawal-detail` and `withdrawal-sent` (390 × 525 and 780 × 1049 WebP).

### B6. Tests
pgTAP 440 (push kind, default off, settings read, several open allowed when off, pending rows in
Activity/Home for the owner only and with filters, shared activity read and month totals
unchanged, statement figures unchanged, switching on with revision/changed/audit, boolean only,
members can't change it, conflict with reason and id, on behalf refused, replay answers, up-front
read, cancelled requests leave Activity, restore turns it off, backup marks only the revision
with it on, single read scope, privileges) and 441 (two sessions); Deno (push wording, settings
boolean); Vitest (rows, steps, pills, copy, conflict, settings patch); e2e
(`withdrawals.e2e.ts`: sent → View withdrawal → panel; Home "Requested" row; Activity "Open";
phone row → page; the President switches the rule on and New withdrawal shows the blocked state).
