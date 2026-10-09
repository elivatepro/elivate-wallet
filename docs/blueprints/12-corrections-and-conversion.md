# Blueprint 12 — Returned funds, adjustments, reversals and conversion (member build slice 5)

Status: **built under the member build plan** (`docs/member-build-plan.md`, owner decisions 2026-10-08/09). Contract: W-12, W-14, W-15, W-16, W-11, W-00, F-01–F-03, E-01, E-02, A-01–A-05. Builds on Blueprints 04 (ledger, holds, evidence), 08 (reversal display, command-outcome recovery) and 11 (withdrawals, review queue, pocket moves). Pocket moves (W-13) shipped in slice 4. Migrations `2026100912xxxx`; pgTAP `120_`–`129_`.

Part A is for the owner. Part B is the build spec.

---

## Part A — What this slice does

### What's in it
1. **Record a conversion** (Paper v1 B07/B08, v4 MV04; W-12, owner decision 2026-10-08/09). A leader with "perform currency conversion" (President Team, World Team, Director and Team Leader by default, A-03) records a conversion that was done outside the app: the member, the pocket, the amount converted, the amount **actually received**, the provider, when it happened, the optional quoted rate and reference, and the receipt. The effective rate is worked out from the two amounts; there is no rate tolerance and no reference-rate check (owner decision). The converted amount is held at once; nothing posts until a reviewer clears it. Clearing posts both sides in one transaction (out of one currency, into the other, same pocket). It starts from its own menu item and from a member's wallet ("Convert" next to Move).
2. **Adjust a member's money** (Paper v1 E05/E06, v4 MV02/MV03; W-14). A leader with "manual credit/debit adjustment" (President Team and World Team by default) chooses credit or debit, currency and amount, a reason, and at least one evidence file, and confirms with the PIN (always, owner decision). The split into pockets follows the network's current allocation policy and is fixed when it's submitted. It posts once a reviewer clears it; a debit then needs every pocket share to be available, or the whole adjustment fails.
3. **Returned funds** (Paper v2 W07–W10; W-16). When money from a completed payout comes back, a leader with "record returned funds" records the amount, when it was seen, who returned it, the bank reference and proof. It goes back to the same pocket it left. Never more than what is still returnable (what left the pocket − what has already come back); several partial returns are fine. It posts once a reviewer clears it.
4. **Reverse a transaction** (Paper v1 E07/E08, v4 MV05; W-15). The President (non-delegable `reverse_transaction`) picks a posted transaction by reference, gives a reason and a note, types the reference to confirm, and enters the PIN. The reversal posts at once: the exact opposite of the original lines, if every pocket still has that much available; otherwise nothing happens. A transaction can be reversed once; a wrong reversal is undone by reversing the reversal. Activity shows the reversal as its own row and "Reversed" on the original (already built in slice 2).
5. **Evidence review** gains conversions, adjustments and returned funds next to payouts. An assigned Financial Evidence Reviewer (not the person who submitted it and not the member) clears or rejects with a reason. Reject: nothing posts (a conversion's hold is released).
6. **Payout screens redrawn** (Paper v4 U01–U07, approved 2026-10-09): Show account number dialog, revealed account with Hide, the fee field, "Fix the date/amount" dialog (one fix, keeps the receipt) or New receipt, completed / check delayed / receipt rejected states, and the cancel dialog. **Move requested** (MV01) replaces the slice 4 stub.

### Decisions I applied (say if you want them changed)
| # | Question | What I did |
|---|---|---|
| Q1 | Who checks conversion, adjustment and returned-funds evidence? | The independent **Financial Evidence Reviewer**, directly (W-14 allows routing non-machine-verifiable evidence straight to review; Paper B07 says "Submit for review"). No AI check: the owner approved the AI receipt check for payouts only, and E-03 forbids reusing the payout policy for these. |
| Q2 | PIN | Adjustments (owner decision), reversals (A-05), and conversions and returned funds like income (manual money facts); asked only when the 5-minute PIN window isn't open. Reviewer decisions: no PIN, as in slice 4. |
| Q3 | Conversion hold | The converted amount is held from submission until review (so it can't be withdrawn or moved meanwhile); released on rejection. |
| Q4 | Linked conversion before a withdrawal (W-12) | Not built: withdrawals are Naira only (owner decision 2026-10-05), so a withdrawal never needs converting. |
| Q5 | Which transactions can be reversed | Income, pocket moves, conversions, adjustments, returned funds, and reversals (that's the reinstatement). Not completed withdrawals: money that really left is corrected with Returned funds (W-15). |
| Q6 | Conversion fee | Not asked: the amount actually received is what posts and the effective rate shows any difference from the quote (Paper B07). |
| Q7 | One payout fix (U03) | The fix dialog changes only what didn't match and keeps the same receipt; "New receipt" replaces it. Still one fix. |
| Q8 | Adjustment reason | A list of common reasons plus "Other" with your own words (Paper shows a list). Reversal: reason list + note. |
| Q9 | Notifications | Not sent now (slice 8). Every step writes an audit event (`conversion.submitted/posted/rejected`, `adjustment.*`, `returned_funds.*`, `transaction.reversed`) carrying the member's membership, so slice 8 can send the M-series emails and bell items. |

### Paper
Built directly from approved designs: "App — Screens v1" B07/B08, E05/E06, E07/E08; "App — Screens v2" W07–W10; "App — Screens v4" MV01–MV05 and U01–U07 (approved 2026-10-09; they replace the slice 4 stubs). New Root poses exported from those files: magnifier, party popper, balance scale, two coins, U-turn sign, boomerang, mailbox.

**Deviations (say if you want them redrawn or changed):**
- Mobile B08/E06/E08: one column of the desktop fields with the summary list above the button; the drawn mobile hero cards (B08 From/To card, E06 amount card with Root, E08 "Reversal will post" card) are not built yet. W08's "Can still come back" card is built.
- Reversals: Paper has the form only, so "Reversals" opens it with a reference lookup in place of the original-transaction card until one is chosen; the transaction detail also links "Reverse this transaction" (President).
- Provider (B07) is a text field with suggestions, not a fixed list; dates and times use the device's own picker.
- The adjustment reason is a list with "Other" for your own words (E05 shows a list).

### Not in it
- Emails and bell items (slice 8). Statements (slice 6).
- A list of a leader's pending conversions/adjustments/returns: Paper has none; they're in the review queue and, once posted, in activity.
- The Reversals list page: Paper has only the reverse form, so "Reversals" opens that form with a reference lookup until a list is drawn.

---

## Part B — Build spec

### B1. Data
| Object | Rules |
|---|---|
| `finance.entries` | One row per conversion / adjustment / returned funds (`kind`). `reference` (`CNV`/`ADJ`/`RTN`, also the ledger reference), tenant/office/membership/wallet/owner, `currency`, `amount` (> 0), `direction` (`credit`/`debit`), `pocket_id`, `account_id` (conversion source / return target), `reservation_id` (conversion), `destination_currency` + `destination_amount` (conversion), `quoted_rate`, `provider`, `observed_at`, `external_reference`, `reason`, `notes`, `withdrawal_id` (return), `policy_id` (adjustment), `status` `needs_review → posted \| rejected`, `submitted_by`, review (`reviewer_user_id`, `reviewer_membership_id`, `review_reason`, `decided_at`), `transaction_id`, `idempotency_key`. Guarded; immutable once settled. |
| `finance.entry_lines` | Adjustment split snapshot (pocket, name, order, basis points, amount, account). |
| `finance.reversals` | `reference` (`REV`), `original_transaction_id` **unique**, `transaction_id`, `category`, `note`, `reversed_by`. Immutable. |
| Shared edits | `ledger.transactions.type` + `conversion`, `adjustment`, `returned_funds`, `reversal`; reservation purpose + `conversion`; evidence purpose/attached type + `conversion`, `adjustment`, `returned_funds`; audit target types + `entry`, `reversal`; `payout_revisions.evidence_id` no longer unique (U03 keeps the receipt). |

System accounts: `fx_clearing` (per currency), `adjustment`, `returned_funds`.

### B2. Posting (at review clearance; reversal at once)
- **Conversion:** journal 1 (source currency): source −X, `fx_clearing` +X; journal 2: `fx_clearing` −Y, same membership/pocket in the destination currency +Y. Hold consumed.
- **Adjustment:** credit: snapshot lines +, `adjustment` −total; debit: lines −, `adjustment` +total. A debit line beyond what's available fails the whole clearance (`insufficient_funds`); the case stays in review.
- **Returned funds:** withdrawal's segment +R, `returned_funds` −R. Under the withdrawal row lock: R ≤ (sent + fee) − Σ effective posted returns (a reversed return no longer counts).
- **Reversal:** every original posting negated, same accounts. Original tx locked; one reversal per transaction (unique). Metadata `reversesTransactionId`.

### B3. Commands and reads (`api.*`, definer, `service_role` only)
| Function | Who | PIN |
|---|---|---|
| `entry_targets(kind, office, cursor, limit, q)` | the kind's permission | – |
| `entry_segments(kind, target_membership_id)` | same; member's segments with available, plus allocation | – |
| `create_entry_evidence_upload(kind, target_membership_id, key, file…)` | same | window |
| `submit_conversion(source_account_id, amount, destination_currency, destination_amount, quoted_rate, provider, converted_at, external_reference, notes, evidence_ids, key)` | `perform_currency_conversion` | yes |
| `submit_adjustment(target_membership_id, direction, currency, amount, reason, notes, evidence_ids, key)` | `manual_credit_debit_adjustment` | yes (always) |
| `returnable_withdrawal(withdrawal_id)`; `submit_returned_funds(withdrawal_id, amount, seen_at, returned_by, bank_reference, notes, evidence_ids, key)` | `record_returned_funds` | yes |
| `review_entry(entry_id, decision, reason, key)`; `review_queue`/`review_case` cover entries; `entry_evidence(entry_id, evidence_id)` | assigned reviewer, not submitter, not owner | – |
| `reversal_preview(reference)`; `reverse_transaction(transaction_id, category, note, confirm_reference, key)` | `reverse_transaction` | yes |

Errors: existing codes only; new cases `conflict` + `details.reason` (`entry_state`, `not_reversible`, `already_reversed`, `confirmation_mismatch`, `exceeds_returnable`, `withdrawal_state`, `same_currency`).

### B4. Edge routes (`ledger`)
`GET /entries/targets`, `GET /entries/segments`, `POST /entry-evidence/uploads`, `POST /conversions`, `POST /adjustments`, `GET /withdrawals/:id/returnable`, `POST /withdrawals/:id/returns`, `POST /reviews/:id/decision` (kind in body), `GET /reviews/:id/evidence/:evidenceId`, `GET /reversals/preview?reference=`, `POST /reversals`; `POST /payouts/:id/correct` accepts no `evidenceId` (keeps the receipt).

### B5. Frontend
Routes `/app/convert` (B07/B08 → MV04), `/app/adjust` (E05/E06 → MV02 → MV03), `/app/queue/returns` (W07/W08 → W09/W10), `/app/reversals` (E07/E08 → MV05). Entry points: wallet "Convert"/"Adjust" next to Move, a member's detail, a completed withdrawal ("Record returned funds"), a transaction detail ("Reverse", President). Evidence page shows the new case kinds. `WithdrawalPanel` follows U01–U07; `/app/split/move` result follows MV01. Commands use `CommandAttempt` and the try-without-PIN pattern.

### B6. Checks
pgTAP `120_` conversions, `121_` adjustments, `122_` returned funds, `123_` reversals, `124_` payout fix, member-wallet memberships and privileges. Deno `entry_routes_test.ts`. Vitest `entries.spec.ts` (exact rates, difference from quote, moments, messages) and the signed upload paths. Playwright `corrections.e2e.ts` (convert and adjust from a member wallet → reviewer clears; payout → returned funds → reviewer clears; reverse an income) and `withdrawals.e2e.ts` (U01 reveal, U02 record with fee, U03 one fix keeping the receipt, U04 completed; MV01).

Also: migration `20261009120500` adds `membershipId` to a member wallet's memberships so "Convert" and "Adjust" open for that membership.
