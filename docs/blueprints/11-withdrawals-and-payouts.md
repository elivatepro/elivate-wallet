# Blueprint 11 — Withdrawals, payouts and pocket moves (member build slice 4)

Status: **built under the member build plan** (`docs/member-build-plan.md`, owner decisions 2026-10-08/09). Contract: W-09, W-10, W-11, W-13, W-00, F-01–F-03, E-01–E-03, A-01–A-05. Builds on Blueprints 04 (ledger, holds, evidence), 05 (payout accounts, sealed numbers), 02 (reviewer assignments) and 08 (command-outcome recovery). Migrations `2026100911xxxx`; pgTAP `110_`–`119_`.

Part A is for the owner. Part B is the build spec.

---

## Part A — What this slice does

### What's in it
1. **Withdraw to your bank** (Paper v1 M06–M11, B16). Pick a pocket, type an amount in Naira (no currency choice, owner decision 2026-10-05), pick one of your verified payout accounts, review, and confirm with your PIN. The amount is put on hold straight away ("reserved"); your balance itself only goes down when the payout is completed. No limit beyond what the pocket has available (U-07, owner decision 2026-10-08).
2. **My withdrawals** (Paper v2 W01/W02). Everything you've asked for, with status: Requested, Approved, Completed, Cancelled, Rejected. You can cancel a request until a leader approves it (W03/W04); the hold is released.
3. **Withdrawal queue for leaders** (Paper v1 T03/T06, C01–C04). Leaders with "approve withdrawals" see requests from members in their office and everything below. Approve keeps the hold; Reject needs a reason and releases it. Leaders never see their own requests here (A-04).
4. **Recording the payout** (Paper v1 T03 right panel, C05–C08). The leader who approved pays the member from their own bank app, then:
   - **Reveal** the full account number (PIN; only the approving leader; logged in the audit trail; hidden again on leaving the page).
   - **Record** what was actually sent: amount, optional bank fee (owner decision: the fee field is there), date paid, optional bank reference and **one** receipt (PDF/JPEG/PNG, up to 10 MB).
5. **AI receipt check** (W-10, E-03, owner decision 2026-10-08). OpenAI (`gpt-5-mini`, owner decision 2026-10-09) reads the receipt: amount, currency, account number, recipient name, payment status and date. A plain program, not the AI, compares those with what was recorded and the member's account: everything matches exactly → the withdrawal completes and the money leaves the member's pocket. Anything missing, unclear or different → **one correction** (C07/C08) → checked again → still different → **independent review**. A technical failure (OpenAI down, timeout) is retried and never uses up the correction.
   - **Payment date** (owner decision 2026-10-09): the calendar date as printed on the receipt is compared with the date the leader entered; a printed timezone converts to UTC first.
6. **Evidence review** (Paper v1 C09/C10, W-11). The President Team's assigned Financial Evidence Reviewers see the cases that failed twice: what was recorded, what the receipt shows, the receipt itself and the history. **Clear** (with a reason) completes the withdrawal; **Reject** (with a reason) closes that payout record and the withdrawal stays approved and on hold, so the leader can record a new payout or cancel. A reviewer can't review a payout they recorded or a withdrawal from their own wallet.
7. **Cancel an approved withdrawal** (W-09): only when no payout record is open, by a leader who can approve it, with a reason and PIN. Releases the hold.
8. **Move between pockets** (Paper v1 B05/B06; leaders: Paper v2 W05/W06 "Transfers"). Ask to move money from one pocket to another (same network, same currency). The amount is held at once; a leader with "approve pocket transfers" approves (the move posts at once) or rejects with a reason; you or the person who asked can cancel before that. Debt can receive only up to zero and is never a source (F-01.8).
9. **Activity** shows completed withdrawals (money out) and pocket moves (with both pockets) next to income.

### Decisions I applied (say if you want them changed)
| # | Question | What I did |
|---|---|---|
| Q1 | PIN for which steps? | Request a withdrawal (Paper M07), reveal the account (W-10 "fresh step-up"), record or correct a payout and retry a stuck check (inside the same 5-minute window), cancel an approved withdrawal. **No PIN** to approve or reject a request, to request/approve/reject/cancel a pocket move or to clear/reject in evidence review: Paper draws none for these. |
| Q2 | Fee | Member-borne and inside the request: amount sent + fee ≤ amount requested. The rest of the hold is released on completion. |
| Q3 | Receipts per payout | Exactly one (Paper "One receipt"; E-03: several receipts are ambiguous). |
| Q4 | Who can cancel a request | The member, or the leader who asked on their behalf. Leaders reject instead. |
| Q5 | Withdraw on behalf (`withdraw_on_behalf`) | Built in the backend (same command, target segment owned by someone else, needs that permission). No screen yet: Paper has none. |
| Q6 | Emails | None in this slice; the notifications slice (8) sends M-series emails from these events. Audit rows are written now. |
| Q7 | Approved, then the network is paused | Owner decision 2026-10-09: payouts for withdrawals approved before the pause still go through. Pausing arrives with billing (slice 7), which adds that exception; this slice treats any non-active network as closed for every new action, and a check that finishes while the network is not active still completes (it was approved before). |

### Paper
Built directly from approved designs: "App — Screens v1" M06–M11, B16/B16d, T03/T06, C01–C10, B05/B06; "App — Screens v2" W01–W06. "App — Screens v4" U01–U07 and MV01 (batch 2) are **awaiting approval**; until then:
- Reveal/record payout follows the v1 T03 panel; the PIN for reveal uses the existing PIN dialog.
- Cancel an approved withdrawal reuses the reason + PIN dialog pattern (N01/Z05).
- The pocket-move "Request sent" step reuses the result panel pattern; pending moves are listed under the move form with Cancel.
These are flagged on the PR and get redrawn once batch 2 is approved.

### Not in it
- Currency conversion before a payout (W-12, slice 5), returned funds (W-16, slice 5), reversals (W-15, slice 5).
- Emails and bell items (slice 8). Statements (slice 6).
- Automated bank payouts (W-26, deferred).

---

## Part B — Build spec

### B1. Data (schema `finance`, private)

| Table | Key columns | Rules |
|---|---|---|
| `finance.withdrawals` | `id`, `reference` (`WDR`), `tenant_id`, `office_id`, `membership_id`, `wallet_id`, `owner_user_id`, `account_id` (source segment), `pocket_id`, `currency` (`NGN`), `amount`, `payout_account_id`, destination snapshot (`bank_code`, `bank_name`, `account_last4`, `account_ciphertext`, `key_version`, `account_name`), `requested_by`, `status`, `reservation_id`, `approved_by/at`, `rejected_by/at`, `cancelled_by/at`, `decision_reason`, `completed_at`, `transaction_id`, `idempotency_key`, `created_at` | `requested → approved → completed`; `requested → rejected \| cancelled`; `approved → cancelled`. Snapshot immutable (account edits never rewrite it). Reasons 3–500. Guard trigger. |
| `finance.payouts` | `id`, `withdrawal_id`, `attempt_no`, `status`, `revision` (1\|2), `submitted_by`, `created_at`, `settled_at` | `verifying → completed \| correction_required \| needs_review`; `correction_required → verifying` (revision 2); `needs_review → completed \| rejected`. At most one open (`verifying`, `correction_required`, `needs_review`) per withdrawal. |
| `finance.payout_revisions` | `payout_id`, `revision`, `amount` (sent), `fee_amount`, `paid_on` (date), `bank_reference`, `notes`, `evidence_id`, `idempotency_key`, `created_at` | Immutable. `amount + fee ≤ withdrawal.amount`; `paid_on` ≥ approval date (Lagos), ≤ today + 1. |
| `finance.payout_checks` | `id`, `payout_id`, `revision`, `status` (`queued`, `leased`, `done`, `dead`, `obsolete`), `attempts` (≤ 6), `next_attempt_at`, `lease_token`, `lease_expires_at`, `last_error`, `outcome` (`match`/`mismatch`), `facts` (extracted, jsonb), `reasons` text[], `model`, `policy_version`, `finished_at` | One per revision. Lease 120 s; backoff `30 s × 2^(n−1)`, max 1 h; 6 failed attempts → `dead` (approver may requeue with PIN). A finish for a revision that is no longer current → `obsolete`, nothing posts. |
| `finance.payout_reviews` | `payout_id` (unique), `reviewer_user_id`, `reviewer_membership_id`, `decision` (`clear`/`reject`), `reason`, `decided_at` | Immutable. |
| `finance.pocket_transfers` | `id`, `reference` (`PTR`), `tenant_id`, `office_id`, `membership_id`, `wallet_id`, `owner_user_id`, `currency`, `source_account_id`, `destination_account_id`, `source_pocket_id`, `destination_pocket_id`, `amount`, `reservation_id`, `requested_by`, `status`, `decided_by/at`, `decision_reason`, `transaction_id`, `idempotency_key`, `created_at` | `requested → completed \| rejected \| cancelled`. Same wallet, membership and currency; pockets differ; source ordinary; Debt destination ≤ its deficit. |

Also: `ledger.transactions.type` gains `withdrawal`, `pocket_transfer`; system accounts `external_outflow` (amount sent) and `payout_fee` (fee); `evidence.files.purpose`/`attached_type` gain `payout`; `audit.tenant_events.target_type` gains `withdrawal`, `payout`, `pocket_transfer`.

### B2. Posting
- **Withdrawal completion:** one NGN journal: source segment −(sent + fee), `external_outflow` +sent, `payout_fee` +fee (when > 0). The hold is consumed for `sent + fee`; any remainder is freed with it. Withdrawal `completed`, payout `completed`, check/review linked, audit `withdrawal.completed`.
- **Pocket move approval:** one journal: source −X, destination +X; hold consumed; Debt re-checked at posting.
- Lock order: withdrawal/transfer row `FOR UPDATE` → payout row → balances (via `ledger.post`, by account id).

### B3. Payout receipt check (E-03, `strict-single-receipt-v1`)
- Edge Function `payout-checker` (`verify_jwt = false`; `Authorization: Bearer PAYOUT_CHECKER_SECRET`), called every minute by pg_cron through pg_net (Vault `payout_checker_url`, `payout_checker_secret`; no-op when missing, as for the outbox). Each call claims up to 3 jobs.
- Worker: `api.claim_payout_check` → downloads the receipt (size, SHA-256, magic bytes re-checked) → OpenAI Responses API (`OPENAI_RECEIPT_MODEL`, `store: false`, strict JSON schema, no expected values in the prompt) → decrypts the destination snapshot (`PAYOUT_ACCOUNT_ENC_KEY`) → deterministic comparison → `api.finish_payout_check` (or `api.fail_payout_check` on technical failure).
- Extracted facts: `amount`, `currency`, `recipientAccount`, `recipientName`, `institutionName`, `transactionDate`, `transactionTime`, `transactionTimezone`, `transactionReference`, `paymentStatus` (`successful`/`failed`/`pending`/`unknown`), `confidence` (`high`/`medium`/`low`), `notes`. Nullable strings.
- The payment date is the printed calendar date; when the receipt prints a time and a time zone, its UTC date (owner decision 2026-10-09). Model `gpt-5-mini` in `OPENAI_RECEIPT_MODEL`.
- Match only when all hold: amount exact (decimal, no rounding) = sent; currency `NGN`; account digits = snapshot (leading zeros kept; masked → mismatch); name equal after trim/collapse spaces/lower-case; status `successful`; confidence `high`; date: the printed calendar date (or its UTC date when a timezone is printed) = `paid_on`.
- Reasons (stored, shown to reviewer): `amount_missing|invalid|mismatch`, same for `currency`, `recipientAccount`, `recipientName`, `paymentDate`; `payment_not_successful`; `reading_confidence`.
- `finish` SQL re-validates the payload shape and, for `match`, re-checks amount/currency/account last 4/date against the revision before completing.

### B4. Commands and reads (`api.*`, definer, `service_role` only)
All take `(p_user_id, p_session_id, p_membership_id, …)`; commands also `p_idempotency_key` and replay through `identity.replay`/`store_result`.

| Function | Who | PIN | Notes |
|---|---|---|---|
| `withdrawal_sources` | holder | – | Own NGN ordinary segments in the workspace's network (active membership) with available; usable payout accounts. |
| `request_withdrawal(account_id, amount, payout_account_id)` | holder (`initiate_own_withdrawal`) or `withdraw_on_behalf` | yes | Eligible destination (Blueprint 05 rules); reserve. |
| `my_withdrawals(status, cursor)`, `my_withdrawal(id)` | holder | – | Status filter `open`/`completed`/`closed`. |
| `cancel_withdrawal(id, reason)` | holder/requester (requested); approver authority (approved, no open payout) | approved only | Releases hold. |
| `withdrawal_queue(tab, cursor)`, `withdrawal_detail(id)` | `approve_withdrawal` in scope | – | Tabs `action` (requested, approved without open payout, correction_required), `verifying`, `completed`, `closed`. |
| `approve_withdrawal(id)`, `reject_withdrawal(id, reason)` | `approve_withdrawal` | – | Rechecks destination eligibility on approve. |
| `reveal_withdrawal_destination(id)` | the approver, still holding `approve_withdrawal` | yes | Audit before returning ciphertext; Edge decrypts, `no-store`. |
| `create_payout_evidence_upload(withdrawal_id, …)` | the approver | window | Purpose `payout`; then existing `/evidence/uploads/:id/finalize`. |
| `record_payout(withdrawal_id, amount, fee, paid_on, bank_reference, notes, evidence_id)` | the approver | window | Creates payout + revision 1 + check. |
| `correct_payout(payout_id, …same)` | the approver | window | `correction_required` → revision 2. |
| `retry_payout_check(payout_id)` | the approver | window | `dead` → `queued`. |
| `payout_receipt(payout_id, revision)` | approver, owner, assigned reviewer | – | Object path for a 60-second signed URL. |
| `review_queue(tab, cursor)`, `review_case(payout_id)`, `review_payout(payout_id, decision, reason)` | assigned reviewer (`review_financial_evidence`), not submitter, not owner | – | |
| `transfer_choices` | holder | – | Own segments by membership/currency, destinations with Debt limit. |
| `request_pocket_transfer(source_account_id, destination_pocket_id, amount)` | `transfer_between_own_pockets` or `…_on_behalf` | – | |
| `my_pocket_transfers(status, cursor)`, `cancel_pocket_transfer(id, reason)` | holder/requester | – | |
| `transfer_queue(tab, cursor)`, `approve_pocket_transfer(id)`, `reject_pocket_transfer(id, reason)` | `approve_pocket_transfer` | – | |
| Worker: `claim_payout_check(worker)`, `finish_payout_check(…)`, `fail_payout_check(…)` | `payout-checker` only | – | |

Error codes: existing only (`insufficient_funds`, `payout_account_unusable`, `conflict` with `details.reason` such as `withdrawal_state`, `payout_open`, `not_approver`, `transfer_state`, `debt_limit`; `self_target_forbidden`; `evidence_invalid`; `attempt_cancelled` not used). No new codes.

### B5. Edge routes (`ledger` function)
`GET /me/withdrawal-sources`, `GET|POST /me/withdrawals`, `GET /me/withdrawals/:id`, `POST /me/withdrawals/:id/cancel`, `GET /withdrawals`, `GET /withdrawals/:id`, `POST /withdrawals/:id/{approve,reject,cancel,reveal}`, `POST /withdrawals/:id/payouts`, `POST /payouts/:id/{correct,retry}`, `POST /payout-evidence/uploads`, `GET /payouts/:id/receipt?revision=`, `GET /reviews`, `GET /reviews/:id`, `POST /reviews/:id/decision`, `GET /me/transfer-choices`, `GET|POST /me/pocket-transfers`, `POST /me/pocket-transfers/:id/cancel`, `GET /pocket-transfers`, `POST /pocket-transfers/:id/{approve,reject}`. Workspace in `X-Membership` everywhere.

### B6. Frontend
Routes `/app/withdrawals`, `/app/withdrawals/new`, `/app/queue` (leaders), `/app/transfers` (leaders), `/app/evidence` (reviewers), `/app/split/move` (pockets live on Home and Pockets & split, so the move hangs off them; no new Pockets page); BFF `/api/withdrawals/*`, `/api/queue/*`, `/api/transfers/*`, `/api/evidence-reviews/*`, `/api/pocket-moves/*`. Requests use the F-03 `CommandAttempt` runner (B16 "Checking your request"). Nav items appear only with the permission (`initiate_own_withdrawal`, `approve_withdrawal`, `approve_pocket_transfer`, `review_financial_evidence`); the backend re-checks each read, including the reviewer assignment. Payout receipts are read through the app server (it follows the 60-second signed link), so the browser never sees a storage URL. Protected steps try without a PIN first and ask for it on `step_up_required` (the sign-in PIN's 5-minute proof often covers them). Shared parts: `lib/ui/money/` (tabs, pills, the approver panel, `money.css`).

### B7. Checks
pgTAP `110_` withdrawals and payouts, `111_` pocket moves, `112_` privileges: request/reserve/insufficient/eligibility; approve/reject/cancel and hold release; reveal authority + audit; record/correct/check lifecycle incl. obsolete and technical failure; review authority and outcomes; posting balances and projection drift; pocket moves incl. Debt and races; replays. Deno: comparison policy, OpenAI response parsing, worker, routes. E2E: request → approve → reveal → record (stubbed checker) → completed; pocket move request → approve.
