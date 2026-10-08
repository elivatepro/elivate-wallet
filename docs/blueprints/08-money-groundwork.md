# Blueprint 08 — Money groundwork

Status: **built under the owner's member-build decisions of 2026-10-08** (`docs/member-build-plan.md`, slice 2). Contract: F-03, W-00, W-07 (Personal, Leadership, Activity), W-25 (recovery identifiers), T-02, T-04 ("unknown result after commit"). Builds on Blueprint 04 (ledger reads, managed wallets, idempotency results). Reserved ranges: migrations `2026100908xxxx`, pgTAP `080_`–`089_`. Edge Function: `ledger` (routes added; nothing removed).

Part A is for the owner: what this slice does, in plain language. Part B is the exact build spec.

---

## Part A — What this slice does

### What's in it
1. **"Did it go through?" for every command.** When the app sends something important (a split change today; income, withdrawals and transfers as they land) and the answer never comes back — a timeout, the connection drops, the page reloads — the app no longer guesses. It shows Paper's "Checking your request" screen, keeps the exact attempt on the device (never the PIN), and asks the server what happened to that attempt:
   - **It went through** → the app shows the result (and its reference, e.g. `INC-7F2K-0931`).
   - **It didn't go through** → "Send again" re-sends the very same attempt; the server can only ever act on it once.
   - **Still unsure** (a reload that lost the form) → "Check again" until the original request can no longer be running.
   A new attempt is only started after a clear answer. Signing out erases kept attempts.
2. **Activity.** Every movement of your money in the selected network, newest first, grouped by month with the month's money in / money out per currency (never added across currencies). Search by name (income source), reference (with or without dashes, any case) or amount (`180000`, `₦180,000.00`); Money in / Money out; currency, status, pocket and date filters. Nothing is filtered until you choose. On desktop a transaction opens in a side panel; on mobile it opens full screen.
3. **Transaction detail.** Status, signed amount, type, from, to, date, who recorded it, the copyable reference and the exact split into pockets it was posted with.
4. **Team overview** for leaders (Team Leader, Director, World Team, President Team): income recorded this month (with the change vs last month), money reserved for open requests, available, active members and pending invitations, and income per week — for the selected currency only. Members you can't view are left out of the totals and the app says so.
5. **Member wallets** for leaders: the members whose money you may view (never your own), each wallet's balance per currency and its activity with the same search and filters.

### Not in it
- Withdrawal parts of the team overview (payouts completed, requests waiting, "Needs your action"), the export shortcut and "Recently opened": they arrive with the withdrawals and statements slices.
- "Ask support" on a transaction: arrives with the support slice.
- The President's separate tenant dashboard (P01/P02): the team overview serves every leadership workspace for now.

### Screens
Built from Paper "App — Screens v1": M03 (activity + side panel), M04 (mobile activity), M05 (mobile detail), T01/T04 (team overview, mobile hero card), B16/B16d ("Checking your request").

**Waiting on Paper approval** (built as minimal working stubs, to be redrawn): the resolved states of the checking screen ("It went through", "It didn't go through yet", "This attempt was cancelled"), the mobile Filters panel, the Member wallets list and a single member's wallet header.

### Decisions this slice made inside the approved contract
| # | Question | Choice | Why |
|---|---|---|---|
| D1 | What does the "what happened?" lookup reveal? | Only the fate (committed / cancelled / not found), the command name, when, and the public reference. The full result comes from a same-key replay of the command, which re-checks current permission, session and PIN window. | F-03: protected replay results only under current authority. |
| D2 | Where is an unresolved attempt kept? | On the device (localStorage), per person, workspace and command, for at most 24 h; erased at sign-out; never the PIN, password, tokens or full account numbers. | F-03, W-25. Matches the income slice's own store. |
| D3 | When is "not found" final without the original form? | 60 s after it was sent (beyond every timeout on the way). With the form kept, "Send again" is offered at once (safe: same key). | W-00 "no replacement key until resolved". |
| D4 | Which statuses can activity be filtered by? | The durable ledger statuses that exist: `posted`. Reversal (W-15) and withdrawal slices add theirs. | Don't invent statuses. |
| D5 | Months and date filters in which time zone? | The browser's zone, sent explicitly (`tz`); without it the existing inclusive UTC dates are kept. | 02 W-18: label local calendar filters accurately. |
| D6 | "Active members" | Distinct people with an active, non-President membership in scope that the leader may view; memberships counted separately. | W-07: label people vs memberships. |

---

## Part B — Build spec

### B1. Migrations
| File | Contents |
|---|---|
| `20261009080100_command_outcome.sql` | `api.command_outcome` |
| `20261009080200_activity_search.sql` | `ledger.time_zone`, `ledger.search_amount`, new `ledger.activity` (search, status, tz, month summaries), `api.my_activity` / `api.managed_wallet_activity` re-created with `p_query`, `p_status`, `p_tz`; `ledger.transaction_json` adds `status`, `recordedBy` |
| `20261009080300_leadership_overview.sql` | `api.leadership_overview` |

All functions `set search_path = ''`; only `api.*` are definer; each new `api.*` revoked from `public, anon, authenticated` and granted to `service_role`.

### B2. Unknown-outcome lookup (F-03)
`api.command_outcome(p_user_id, p_session_id, p_idempotency_key, p_command default null) returns jsonb`
1. `identity.require_session`; key `^[A-Za-z0-9_-]{16,100}$`, command `^[a-z][a-z_]{0,59}$` → else `validation_error`.
2. `pg_advisory_xact_lock(hashtextextended(user || ':' || key, 0))` — the lock `identity.replay` and `finance.lock_attempt` take, so an attempt still running in the database finishes first.
3. `identity.command_results` row of this actor+key → `{status:'committed', command, committedAt, reference}` (`reference` = result's string `reference` or null); a different `p_command` → `idempotency_conflict`.
4. Else `finance.income_attempt_cancellations` (when command null or `record_income`) → `{status:'cancelled', command:'record_income', cancelledAt}`.
5. Else `{status:'not_found', command}`. Keys are per actor: another person's key is simply not found.

Route: `GET /ledger/me/command-outcome?idempotencyKey=&command=` (account-level, no `X-Membership`). BFF: `GET /api/commands/outcome?key=&command=`.

### B3. Activity (W-07)
`ledger.activity(wallet, tenant, account_ids, currency, pocket, direction, type, from, to, cursor, limit, query, status, tz)`:
- `tz` validated against `pg_timezone_names` (`validation_error` field `tz`); default `UTC`. `from`/`to` are inclusive dates in that zone.
- `q` (1–100 chars): reference contains the alphanumerics of `q` (≥ 3 chars, dashes ignored, case-insensitive), or income source / provider reference `ilike` (wildcards escaped), or `|amount|` equals `q` read as an amount (`₦ $ , + − -` and spaces stripped).
- `status` ∈ {`posted`} → else `validation_error`.
- Items add `status`, `title` (income source or null), `pocketCount`. Cursor unchanged `(posted_at, id, currency)` desc.
- `months`: for every month the page touches, `{month: 'YYYY-MM', currencies: [{currency, in, out}]}` summed over the **whole filtered set** (not the page); `timeZone` echoed.
Routes `GET /ledger/me/activity` and `/ledger/wallets/:walletId/activity` accept `q`, `status`, `tz`.

Detail (`/me/transactions/:id`, `/wallets/:walletId/transactions/:id`) adds `status` and `recordedBy` (`org.person` of the actor).

### B4. Leadership overview (W-07)
`api.leadership_overview(p_user_id, p_session_id, p_membership_id, p_tz default null)`, route `GET /ledger/overview?tz=` (workspace).
- Scope: the workspace office subtree, or the whole network for the President Team (`office_id` null).
- Gate: `view_managed_wallets` or `view_scoped_financial_reports` over the scope root → else `authorization_denied`.
- Per active currency: `incomeThisMonth`, `incomePreviousMonth` (income postings on visible segments, months in `tz`), `posted`, `reserved`, `available` (visible segments), `weeks` (5 Monday-weeks, current last). Visible segments = `ledger.visible_segments(…, both permissions, scope)`; own segments never count.
- `members`: `active` (distinct people), `activeMemberships`; both only where `ledger.segment_visible` allows; self excluded. `pendingInvitations`: unexpired pending invitations in scope the actor may manage (`invite_members`), `null` without that permission.
- `excluded`: other people's segments in scope that are not visible (offices, members).
Amounts are strings; currencies are never combined.

### B5. Frontend
- `#lib/recovery.ts` — pure rules: `isUnknownOutcome` (no envelope except gateway 401, contract drift, `internal_error`), `keepsAttempt`, `resolveOutcome`, `storableBody` (drops `pin`, `password`, `token`, `accountNumber`), device storage `ew:attempt:v1:<command>:<uid>:<workspace>`.
- `#lib/client/command-attempt.svelte.ts` — `CommandAttempt` runner used by every command form: `send(workspaceId, body, {pin, summary})`, `check()`, `resend()`, `restore()`, `reset()`, `blocked`; states `idle | sending | done | failed | unknown | checking | resolved`. Saved before dispatch; key rotated only after success or a refusal (PIN prompts keep it). On "committed" with the body in memory it replays the same key to get the result.
- `#lib/ui/app/OutcomeUnknown.svelte` (B16/B16d) bound to any `CommandAttempt`.
- First adopter: the split editor. Payout, NIN review and invitation forms keep their key on a relayed 502.
- Routes `/app/activity` (`?tx=` selects), `/app/team`, `/app/wallets` (`?wallet=`); BFF `/api/activity`, `/api/activity/:id`, `/api/overview`, `/api/wallets`, `/api/commands/outcome`.

### B6. Tests
pgTAP `080_command_outcome` (not found, committed + reference, never the result, command mismatch conflict, per-actor keys, any stored command, cancelled income attempt, bad key, wrong session), `081_activity_search` (status/title/pocketCount, search by source, provider reference, reference with/without dashes, formatted and plain amounts, literal wildcards, status filter and refusal, month summaries from the full set per currency, tz echo and refusal, managed search, recorder), `082_leadership_overview` (Team Leader / Director / President scopes, per currency, previous month, weeks, members exclude self, invitations, own money not excluded, deny excluded and reported, member denied, bad tz), `083_money_groundwork_privileges`. Deno: activity params, command-outcome validation and log redaction, overview workspace. Vitest: recovery rules, storage, `CommandAttempt` flows, activity grouping/ranges, exact `sumMoney`. Playwright `money.e2e.ts`: member activity search/filter/detail (desktop and 320 px), President overview and member wallet, unknown outcome committed (replay) and not committed (same key resent).

### B7. Open points for the owner
1. The resolved "checking" states, Filters sheet and Member wallets screens need Paper compositions (listed above).
2. Should the President Team get the separate P01/P02 tenant dashboard, or keep the team overview?
3. "Recently opened" (T01) needs a decision on what is remembered and where (device only?).
