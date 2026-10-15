# Blueprint 40 — Withdrawals ask for a reason (slice 40)

Status: **owner decision 2026-10-15; Paper "Withdrawal reason v12 (DRAFT 2026-10-15)" WR01/WR02
approved 2026-10-15.**

Contract: W-09 **Input** (amended), P-06 email rule (one exception), Blueprint 11 (withdrawals and
payouts), 13 (notification emails M02/M03), 29 (no early submits). Migration
`20261009400100_withdrawal_reason.sql`, pgTAP `400_withdrawal_reason.sql`.

### Owner decision (2026-10-15, binding)
Whoever places a withdrawal (the member, or a leader withdrawing on their behalf) gives a reason:
one free-text note, **required, 3–500 characters after trimming** (the `identity.require_reason`
rule), no preset choices. It is shown to approvers in the queue and detail, on the member's own
withdrawal, in Activity's transaction detail and in the withdrawal emails. It is **not** in
statements or reports. Withdrawals placed before it have none (null) and show nothing.

### Backend
- **Column:** `finance.withdrawals.reason text`, null or 3–500 characters after trimming. The
  guard trigger keeps it fixed once placed, like the rest of the request.
- **`api.request_withdrawal`** takes `p_reason` (before the idempotency key; the old signature is
  dropped, same `security definer`, `search_path = ''`, service_role only). It validates with
  `identity.require_reason` (`validation_error`, field `reason`) after the amount and account, stores
  the trimmed text, puts it in the idempotent request (same key, different reason →
  `idempotency_conflict`) and records it as the audit event's reason. The on-behalf path is the same
  command (`withdraw_on_behalf` in `finance.withdrawal_source`), so leaders give one too.
- **Reads:** `finance.withdrawal_json` returns `reason`, so My withdrawals, `my_withdrawal`, the
  queue and `withdrawal_detail` all carry it (also the payout review case, which embeds it).
  `ledger.transaction_json` (latest: `20261009120600`) returns `withdrawal.reason` for Activity's
  transaction detail. Export figures read the tables directly and never select it.
- **Emails:** `money.withdrawal_submitted` (M02, to the owner) and
  `money.withdrawal_awaiting_approval` (M03, to each approver) accept an optional `reason` param
  (template rows updated in place, version 1, so events queued earlier still render).
  `notify.on_tenant_event` adds it to those two emails only; bell items never carry it. Approved,
  not approved, cancelled and paid emails stay amount and reference only.
- **Edge:** `POST /ledger/me/withdrawals` requires `reason` (`v.reason`, 3–500 after trimming) and
  passes `p_reason`.

### Emails
`_shared/email/layout.ts` gains an optional `note` under the line: a quiet box (canvas fill, rule
border, 12 px radius) with a mono uppercase label ("REASON") and the text in quotes, Lexend 15/22,
escaped, line breaks kept; dark-mode colours follow the card. The plain-text part adds
`Reason: “…”`. P-06's "no reasons in emails" keeps holding for review and decision reasons.

### Frontend
- **Withdraw (WR01):** the Review step shows "What’s this withdrawal for?" with "Required", a note
  field (surface, 1.5 px border, accent when focused, 14 px radius, 14/16 padding, 84 px min
  height, 16 px text so iOS does not zoom) and the hint "Your leader sees this when they approve
  it." On phones the "After you submit" card follows and the button reads "Enter PIN to submit";
  desktop puts the same field in its Review card. The button stays tappable: an invalid note shows
  an inline error and takes focus, and the PIN sheet opens only once it is valid. Enter in the note
  is a new line, never a submit. The note stays in page state when going back to the amount, and is
  sent trimmed.
- **Approver panel (WR02):** after "Send to", a Reason section: mono label, the note in quotes
  (16/24), and a muted line ("Requested 2 min ago", with "Written by …" when placed on behalf).
  Approve and Decline are unchanged.
- **My withdrawals:** each row quotes the reason under its status line; the cancel dialog lists it
  as "For".
- **Activity:** the transaction detail of a withdrawal has a "Reason" row.
- **Contract:** `RequestWithdrawalCommand.reason` (3–500); `reason` optional and nullable on
  `Withdrawal` and on `TransactionDetail.withdrawal`.

### Deploy order
Deploy the `outbox-worker` function **before** the migration lands: its new renderers accept both
shapes, while the old ones refuse an email carrying `reason`. The `ledger` function and the
migration go out back to back (the old route calls the dropped signature, the new one the new
signature), then the Worker; new withdrawals fail only in that short gap.

### Not in this slice
- Backups (`backups.contents`) do not yet carry `withdrawals.reason`; a restore would bring the
  withdrawal back without its note.
- Approved / not approved / cancelled / paid emails do not repeat the reason.
