# Blueprint 09 — Income recording (member build slice 3)

Status: **built under the member build plan** (`docs/member-build-plan.md`, owner decisions 2026-10-08). Contract: W-08, W-00, F-01, F-03, E-01, A-05. Backend: Blueprint 04 (already built and deployed). The first PR (#23) was frontend only; the follow-up (09b) adds one additive backend change: network-wide member search (`api.income_targets` `p_query`, Edge `q`).

---

## Part A — What this slice does (for the owner)

1. **A "Record income" page** for anyone whose role lets them record income for others (Team Leaders, Directors, the President Team). It appears in the sidebar and in More only when the person has that permission; the backend still checks every request.
2. **The form follows Paper T02 (desktop) and T05 (mobile):** the member, currency (NGN or USD), the amount received, where it came from, the date received, 1–5 receipts (PDF, JPEG or PNG, up to 10 MB each) and optional notes. The optional provider reference and fee from your 2026-10-08 decisions sit under "More details" (not drawn in Paper yet).
3. **Live split preview.** While the amount is typed, the panel shows exactly what each pocket will receive under the network's current split, to the kobo/cent, using the same rounding the server uses. The server's numbers are the ones that count; the result screen shows them.
4. **One PIN, at the end.** "Post" opens a confirm sheet with the amount, the member and the PIN. The receipts are uploaded and checked (real bytes, type and size) only then, so an abandoned form leaves nothing behind.
5. **Result.** On success the page shows the `INC-XXXX-XXXX` reference, the amount and the exact pocket split that was posted.
6. **Lost connection is safe.** If the app can't tell whether the income posted (timeout, dropped connection, reload), the form locks and offers **Check again** (the same request again; it can never post twice) or **Cancel this attempt** (with a reason; if it had already posted you are shown the posted income instead). This survives a page reload on the same device.
7. **No email.** No income email exists in the backend yet; the M-series "income posted" email belongs to the notifications slice.

### Waiting on Paper approval
Paper has the form (T02/T05) only. These states are built as minimal stubs using existing components, to be redrawn once approved: the member picker sheet, the confirm sheet (reuses the L02 confirm component), the success/result screen, the outcome-unknown panel and its cancel sheet, the "More details" (provider reference and fee) section, the multi-receipt list, and the empty states (no one to record for, no split configured).

### Deviations from Paper (please confirm)
- Source is free text (decision Q9), so it has no dropdown chevron.
- The receipt row says "Ready to upload · 214 KB" until "Post", then "Uploaded" (Paper shows "Uploaded" while filling the form), because the upload needs the PIN step and happens on confirm.
- Mobile shows Notes too (Paper T05 omits it; the backend accepts notes from both).
- The mobile split preview wraps pocket lines in two columns: five pockets don't fit the drawn one-row layout at 390 px.

---

## Part B — Build spec

### Routes
| Route | Kind | Notes |
|---|---|---|
| `/app/income` | page | Client-rendered inside the signed-in shell; mobile is a pushed page (close button, no tab bar). Shown in nav when `capabilities.permissions` contains `record_income`. |
| `GET /api/income/targets?cursor=` | BFF read | → `GET /ledger/income/targets`; relays `{items, nextCursor, allocation, currencies}`. |
| `POST /api/income/receipts` | BFF command (multipart: `file`, `targetMembershipId`, `idempotencyKey`, optional `pin`) | Workspace echo check; size 1–10 MB; MIME taken from the file's magic bytes (`%PDF-`, `FF D8 FF`, PNG signature), never from the browser; SHA-256 computed on the server; then `withPin` → `POST /ledger/evidence/uploads` → `PUT` bytes to the signed upload URL (path re-based onto the configured Supabase origin; only `/storage/v1/object/upload/sign/financial-evidence/…` is accepted) → `POST /ledger/evidence/uploads/:id/finalize`. Returns `{evidenceId, status, expiresAt}`. File names are never logged. |
| `POST /api/income` | BFF command (JSON) | `RecordIncomeCommand` → `withPin` → `POST /ledger/income`. Never retried server-side. |
| `POST /api/income/cancel` | BFF command (JSON) | `{targetMembershipId, reason, idempotencyKey}` → `POST /ledger/income/cancel`. Returns the posted income (`status: 'posted'`) or `{status: 'cancelled'}`. |

### Client flow
1. Load targets (paged, client-side filter over loaded pages; "Load more" pages the backend cursor). `allocation === null` → "no split yet" state (W-08 step 1: real missing setup, not a fake wallet). Currencies are those the backend returns, limited to the ones the UI can format (NGN, USD).
2. Local validation: target chosen; amount `^\d{1,15}(\.\d{1,scale})?$` and > 0; source 1–100; date `YYYY-MM-DD`, not after today; notes ≤ 1000; provider reference ≤ 100; fee optional (amount + currency, same rules); 1–5 receipts, PDF/JPEG/PNG, ≤ 10 MB.
3. One idempotency key per attempt. Receipts are bound to (key, target): changing the member drops uploaded receipt ids so they are uploaded again.
4. Confirm sheet (PIN). Pending receipts upload first, the PIN going with the first upload (it opens the 5-minute step-up proof); if nothing needs uploading the PIN goes with the record command.
5. Before dispatching `POST /api/income`, the attempt (key, target id and label, request body, time) is written to `localStorage` under `ew:attempt:v1:income:<uid>:<workspace>`; no PIN, token or file content. It is cleared on a definitive answer (posted, refused, cancelled) and after 24 h. It is deliberately not erased on sign-out or session expiry, so recovery survives re-authentication; it holds no secret and is unusable by anyone else (the backend binds the key to the actor). It is the isolated hook to swap for the shared F-03 utility (slice 2) when that lands.
6. Outcomes: success → result screen from the server's response. `BackendError` other than `internal_error` → a definitive refusal; message per code (`step_up_required`/`pin_incorrect` stay in the sheet, `pin_locked` → `/pin/locked`). Transport failure, `internal_error` or a contract violation → **outcome unknown**: inputs lock; Check again re-sends the identical body and key; Cancel this attempt calls the cancel route (reason 3–500).
7. `attempt_cancelled` on Check again means a cancel already won: clear the attempt, new key, receipts re-uploaded.

### Allocation preview
`allocate(amount, scale, lines)` in `src/lib/income.ts` mirrors `ledger.allocate`: integer minor units (BigInt), `base = floor(units × bp / 10000)`, leftover units go one each to the lines with the largest remainder, ties by display order (the order `allocation.pockets` is returned in, i.e. `sort_order, pocket_id`). Unit-tested against the blueprint 04 hand-checked cases. Display only; the posted split comes from the server.

### Checks
Unit: amount parsing, allocation, attempt store. E2E (local stack): the President records income for a member through the UI with a real PDF receipt upload, sees the `INC-` reference and split, and the member's Home shows the money; a non-recorder sees no nav entry; axe and 320 px checks.

---

## Follow-up 09b — owner answers and Paper batch 1 (2026-10-08)

### Owner decisions
1. The four deviations from Paper listed in Part A are **accepted**.
2. **Member search covers the whole network**, not only loaded pages. Built as an additive backend change: migration `20261009090100_income_target_search.sql` re-creates `api.income_targets` with an optional `p_query` (1–100 characters; matches UID, display name, first + last name or office name, case-insensitive, `%`/`_`/`\` taken literally). Authorization, eligibility, ordering and cursor are unchanged; without `p_query` the result is identical. `GET /ledger/income/targets` accepts `q` (additive), `GET /api/income/targets?q=` relays it, and the picker searches on the server (debounced) with "Load more" over the search cursor. Tests: pgTAP `090_income_target_search.sql`, Deno `tests/income_targets_search_test.ts`.
3. A stuck attempt may stay on the device for 24 h after sign-out (**accepted**, as built).
4. Paper "App — Screens v4 (member build)" **J01–J05 approved** and built with exact values:
   - **J01** form: provider reference and fee are visible fields (no "More details" fold); "Receipts · 1 to 5 files · PDF, JPG or PNG" with Remove per row, "Uploading · NN%" while a receipt uploads, "+ Add another receipt"; preview "Split by {network}'s policy · version N", "Review and post", Root (Abacus) on the grain stage. Mobile split preview wraps pocket names ("Business Inv.").
   - **J02** confirm + PIN: "Post ₦X?", "It lands in {first}'s pockets straight away", To / Source · date / Receipts rows, PIN, Cancel / Post income; can't be dismissed while posting.
   - **J03** posted (Root thumbs up), **J04** checking what happened (Root pocket watch, "Sent {date, time}", Cancel this attempt / Check again), **J05** couldn't record (Root handing back; reason + "Nothing was posted."; Back to the form / Choose another member when the refusal is about the member).
   - Root poses reused from existing Paper poses (Abacus E01, Thumbs up M08, Pocket watch B16, Handing back C03), exported 1×/2× WebP to `frontend/static/root/income-*.webp`; the grain stage background to `frontend/static/root/stage.webp`.

### Still not drawn (stubs kept)
Member picker sheet, the PIN re-check sheet and the cancel-reason sheet on J04, and the load-error / no-permission / no-split / no-members states.

### Notes
- Receipts still upload on "Post income" (the step-up opens with the PIN there), so "Uploading · NN%" shows during posting rather than right after choosing a file (accepted deviation 2).
- **"View in activity" (J03)** links to the member's wallet activity owned by member build slice 2. It is hidden until that route is on main.
- Refusals that point at a field or a receipt stay on the form (inline); refusals about the member, the network or setup go to J05. While J04 is showing, a refusal never unlocks the attempt.
