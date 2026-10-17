# Blueprint 45 — Notification links (slice 45)

Status: **Approved 2026-10-17** (owner: "lets do it"). Follow-up to Blueprint 44 D4 (the member
withdrawal detail at `/app/withdrawals/<id>`). Contract: P-05/P-06 (bell and push), Blueprint 13
(bell and email links), 42 (push). Migration `20261009450100_notification_links.sql`; pgTAP
`450_notification_links.sql`.

## Part A — What this slice does

The member's own withdrawal news opens that withdrawal, not the Withdrawals list: the bell item,
the Web Push tap and the email button for "Withdrawal requested / approved / not approved /
completed" (and "cancelled", which shares the same link). Quick search does the same for the
member's own withdrawals. Approvers' and payout tasks still open the queue. Items already in the
bell keep the list link they were created with.

A push for a withdrawal in another network (the person belongs to two) opens the detail in the
current workspace, which can't see it: the page says "We couldn't find that withdrawal in this
workspace." with **Switch workspace**, and the chosen workspace opens that withdrawal.

## Part B — Build spec

- **Path.** `notify.on_tenant_event` (last defined in `20261009400100`) is redefined with only
  the owner's `path` changed to `'/app/withdrawals/' || w.id`. That `base` feeds the owner's
  bell item, push job and email (M02, M04–M07); the task items override `path` as before.
- **Allow-lists.** One extra exact alternative `^\/app\/withdrawals\/<lowercase uuid>$`, identical
  in `frontend/src/lib/app-path.ts` (bell and service worker), `_shared/push/text.ts` (push
  payload) and `_shared/email/notifications.ts` (email button). Uppercase, extra segments and
  query strings fall back to `/app` (bell, push) or fail the email permanently, as today.
- **Deploy order.** The outbox worker (email + push allow-lists) goes out with the migration;
  an email whose path the worker doesn't know fails permanently (`template.link_missing`).
- **Quick search.** `recordHref` sends an own withdrawal to `withdrawalHref(r.id)`.
- **Other network.** The bell only lists the current workspace's items, so only push (and
  email) can carry another network's withdrawal. `WithdrawalDetail` shows the not-found line
  with a `Switch workspace` link to `/workspaces?switch&next=/app/withdrawals/<id>`.
- **Tests.** pgTAP 450 (four member kinds and cancelled carry the detail path in bell and email;
  `task.withdrawal_approve`, `task.payout_record` and M03 keep the queue path). Vitest
  `safePath`, push payload and search href; Deno push `safePath`/payload, parity with the bell's
  `safePath`, and the email button.
