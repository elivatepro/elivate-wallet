# Blueprint 13 — Notifications: the bell and transactional email (member build slice 8)

Status: **built under the member build plan** (`docs/member-build-plan.md`, owner decisions 2026-10-08/09 and the slice 8 answers below). Contract: P-05 (bell), U-11, W-21, T-03, F-02, A-04, P-06 (email layout). Builds on Blueprint 03 (outbox, worker, Cloudflare sender, email layout), 06 (NIN review email), 11 and 12 (money audit events). Migrations `2026100913xxxx`; pgTAP `130_`.

Part A is for the owner. Part B is the build spec.

---

## Part A — What this slice does

### What's in it
1. **The bell** (Paper App v1 S01/S04, v4 NB01). Every email sent to a person also appears as a bell item, plus **needs-your-action** items (withdrawal to approve, payout to record, payout record to fix, evidence to review, pocket move to approve, NIN to review). Each item is read/unread; "Mark all as read" / "Read all". An action item is a live task: it stays under "Needs your action" until the work is done (by anyone), then becomes an ordinary item. Items are kept 90 days. Desktop: the popover with Unread / All tabs and "See all notifications"; mobile: the Notifications page. The empty state is the existing v3 H07 drawing.
2. **Money emails** (Paper "Emails — Transactional v2" M01–M14, plus the new M16–M18 approved 2026-10-09), sent from the slice 4/5 events in the same transaction as the money change (F-02, T-03), delivered at least once by the outbox worker and idempotent per event and recipient.
3. **Team and account emails**: T01 Invitation accepted, A10 Account status changed, A11 Role changed, A12 Membership ended (owner, 2026-10-09).
4. The existing three emails (invitation, NIN review decided, payout-account alert) keep working; the last two now also create bell items. Every email footer shows "Questions? support@elivatewallet.com".

### Who gets what
| Event | Email | Bell | Recipient |
|---|---|---|---|
| Income posted | M01 | item | the member |
| Withdrawal requested | M02 | item | the wallet owner (also when a leader requested on their behalf) |
| | M03 | task "Withdrawal to approve" | everyone who can approve that withdrawal (`approve_withdrawal` over the member, never the member) |
| Withdrawal approved | M04 | item | the owner |
| | — | task "Payout to record" | the approver (only they can record the payout, W-10) |
| Withdrawal not approved / cancelled / completed | M06 / M07 / M05 | item | the owner |
| Payout record needs a fix | M08 | task "Payout record to fix" | whoever recorded the payout |
| Payout receipt needs review | M09 | task "Evidence to review" | every current Financial Evidence Reviewer whose scope covers it, except whoever recorded it |
| Payout receipt rejected by the reviewer | M17 (new) | item + task "Payout to record" | whoever recorded it |
| Conversion / adjustment / returned funds submitted | M09 (kind wording) | task "Evidence to review" | reviewers in scope, except the submitter |
| Conversion posted | M16 (new) | item | the member |
| Adjustment posted | M12 (credit or debit) | item | the member (owner decision: the member is notified) |
| Returned funds posted | M14 | item | the member |
| Conversion / adjustment / return not posted | M18 (new) | item | the submitter |
| Pocket move requested | — | task "Move to approve" | everyone who can approve it, never the owner |
| Pocket move done / declined | M10 / M11 | item | the owner |
| Transaction reversed | M13 | item | the member |
| Invitation accepted | T01 | item | whoever sent the invitation |
| Role changed / membership ended | A11 / A12 | item | the person |
| Account status changed | A10 | item | the person |
| NIN review requested | — | task "Identity to review" | President Team and World Team at/above the person's office (Blueprint 06 Q4) |
| NIN review decided, payout-account alert | existing | item | the person |

### Decisions (owner answers 2026-10-09, plus the ones I applied)
| # | Question | Answer |
|---|---|---|
| Q1 | Who gets "awaiting approval" and approval tasks? | Everyone who can approve (owner). |
| Q2 | Who gets "evidence review assigned"? | All assigned reviewers in scope, except the submitter (owner). |
| Q3 | Email for one's own action? | Yes, always: the owner always hears about their own money (owner). |
| Q4 | Opt-out? | None; all are transactional (owner). |
| Q5 | Bell with several workspaces? | The selected network's items plus personal ones (payout accounts, account status). A task shows only when the selected workspace can act on it; authority is re-checked at read time (owner). |
| Q6 | Events with no drawn email | New emails M16–M18, drafted in Paper with new generated Root poses and approved (owner). |
| Q7 | A-series | A10–A12 included (owner). |
| Q8 | Support inbox | `support@elivatewallet.com` is live (owner). |
| Q9 | Retention | Items older than 90 days are deleted daily-ish by the worker's housekeeping; an open task is kept until it's done. |
| Q10 | Unread badge | Count of unread items plus open tasks in the bell's scope, refreshed every minute and on focus (no Realtime: sessions live in the app server). |
| Q11 | What a bell item shows | Like Paper: title, one line (amount, reference, name, bank •• last 4 for approvals, as the app already shows) and time. Emails stay as P-06: amount and reference only, never account digits, balances, reasons or evidence. |
| Q12 | Pocket move cancelled by its owner | No email (none drawn, not asked); the approval task clears. |

### Paper
Built directly: Emails v2 M01–M14, T01, A10–A12; App v1 S01/S04; App v4 NB01 (desktop + mobile). New and approved 2026-10-09: M16 Conversion posted, M17 Payout receipt rejected, M18 Not posted (generated Root poses: two coins, crossed receipt, back in the tray). Dark and 320px versions come from the shared layout.

### Not in it
B-series (slice 7), M15 statement ready (slice 6), PIN-change email (slice 9 follow-up), T02–T05 (slice 10). The catalogue is open: those slices add a template row, a renderer and a `notify.emit` call.

---

## Part B — Build spec

### B1. Data (`notify` schema, private)
| Object | Rules |
|---|---|
| `notify.items` | `id`, `user_id`, `tenant_id` (null = personal), `kind` (catalogue key), `task` (bool), `subject_type` + `subject_id` (the withdrawal, payout, entry, transfer, review…), `params` (safe display values only), `email_event_id` (the outbox event, if an email went), `dedupe_key` (unique per user), `created_at`, `read_at`, `resolved_at` (tasks). Only `read_at`/`resolved_at` change. |
| `notify.kinds` | Catalogue: `key`, `task`, `permission` (for the read-time authority check of tasks), `email_template` (nullable). Rows are immutable like `outbox.templates`; later slices add rows. |
| `outbox.templates` | New rows (version 1, duplicate-safe): `money.income_posted`, `money.withdrawal_submitted`, `money.withdrawal_awaiting_approval`, `money.withdrawal_approved`, `money.withdrawal_not_approved`, `money.withdrawal_cancelled`, `money.withdrawal_completed`, `money.payout_correction_required`, `money.evidence_review_assigned`, `money.payout_receipt_rejected`, `money.pocket_move_done`, `money.pocket_move_declined`, `money.adjustment_posted`, `money.conversion_posted`, `money.entry_not_posted`, `money.transaction_reversed`, `money.returned_funds`, `team.invitation_accepted`, `account.status_changed`, `account.role_changed`, `account.membership_ended`. |

### B2. Writing events (same transaction as the change)
- `notify.emit(user, tenant, kind, subject, params, dedupe, email_params)` inserts the bell item and, when the kind has an email, `outbox.enqueue_email` with dedupe `notify:<source>:<user>`. Replays never duplicate either.
- Sources: an `after insert` trigger on `audit.tenant_events` (money, invitation, role events), on `org.membership_events` (`ended`), on `audit.security_events` (`account.status_changed`), on `identity.nin_reviews` (requested), and on `outbox.events` for the two older person emails (NIN review decided, payout-account alert) so they get bell items.
- Recipients are computed at event time with `authz.decide` over the candidate memberships (roles whose policy allows the permission, explicit grants, reviewer assignments); the member/actor exclusions above apply.
- Tasks resolve in the same transaction as the work: `after update of status` triggers on withdrawals, payouts, pocket transfers, entries and NIN reviews mark open tasks for that subject `resolved_at` when their open-condition no longer holds. The read also re-checks the condition and the selected workspace's authority.

### B3. API (`identity` Edge Function, verified JWT; `x-membership` = selected workspace)
| Route | RPC | Notes |
|---|---|---|
| `GET /notifications?view=unread\|all&cursor&limit` | `api.my_notifications` | `{ actions[], items[], nextCursor, unread }`; tasks first (open only), then items newest first. |
| `GET /notifications/unread` | `api.my_notification_count` | `{ unread }` for the badge. |
| `POST /notifications/read` | `api.mark_notifications_read` | `{ ids: uuid[] }` or `{ all: true }`; own items only, idempotent. |

Errors reuse the existing envelope (`validation_error`, `workspace_invalid`, `authentication_required`).

### B4. Emails
- Renderers in `_shared/email/templates.ts` on the Paper layout; network-branded (sender = network) except A10 (Elivate). Footer "Questions? support@elivatewallet.com". Buttons link to the app path in the event (`/app/withdrawals`, `/app/queue?withdrawal=…`, `/app/evidence`, `/app/activity`, …), validated against an allow-list.
- Amounts are formatted from the exact decimal string and currency (₦/$), never from floats.
- Root poses exported from Paper into `frontend/static/email/root-*.png` (333×448).
- The Cloudflare transport takes an optional API base for local tests only (`CLOUDFLARE_API_BASE`, accepted only for `http://host.docker.internal:*`), so e2e sends through a fake Cloudflare that relays to the local mail catcher (Mailpit). No real email from tests.

### B5. Frontend
- `GET /api/notifications`, `GET /api/notifications/unread`, `POST /api/notifications/read` (BFF, workspace cookie + echo on the POST).
- Shell: badge dot on the bell; desktop popover (NB01/S01) with Unread/All tabs, Needs your action / New / Earlier sections, Mark all as read, See all; mobile page (S04/NB01) with Read all. Clicking an item marks it read and opens its link.

### B6. Tests
pgTAP `130_notifications` (catalogue, every money event, tasks and their resolution, reads, scope, retention, privileges, the quiet badge poll) and two T01 checks in `030_invitations`; Deno tests for every renderer (Paper copy, poses, escaping, no unknown params, link allow-list), the bell routes and the transport's local test base; Vitest for the bell wording and links; e2e `notifications.e2e.ts`: the member's bell (S01/S04), the President's tasks (NB01) clearing on approval, M01–M04 delivered to the local mail catcher, and one sample of every new email delivered and rendered (light, dark, 320px).

### B7. Deviations from Paper (say if you want them changed)
- Bell time text is `#8A9396` instead of Paper's `#7D8588`: Paper's value fails AA contrast on the tinted task rows.
- Mobile email hero (≤480px): the Root cell is narrower (92px) and the amount 24px so it stays on one line, as Paper's 320px artboards show; chips never break mid-word.
- A done task stays in the list as an ordinary item with its task title (owner decision); the desktop "See all notifications" page reuses the mobile cards with a "Mark all as read" next to the title.
- T01 names the new member by UID when they had not entered their name yet at acceptance (the invitation is accepted before the profile step).
