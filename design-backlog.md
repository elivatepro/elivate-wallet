# Design backlog — Elivate Wallet (Paper)

Handoff for the next design thread (written 2026-10-07). Paper file: `Elivate Wallet`. Read `00-product.md` P-06 and the memory/design rules first; contract files win over this list.

## Pages so far
Authentication v2 · Onboarding — Invited member · App — Screens v1 · App — Screens v2 (backlog work, O01–O09 Offices) · Emails — Transactional v2 (v1 = archive) · Statements & reports v1 · Mascot (Root pose boards) · Design system.

## Tablet (dropped 2026-10-07 — reference only)
768px uses the desktop sidebar collapsed to a 72px icon rail (same nav, labels hidden). Content padding 32px; tables drop secondary columns into the row subline.

## Rules that keep coming up
- Dark compositions only; light mode is built by developers from the light tokens.
- Every screen: mobile 390 (check 320) and desktop 1440. Tablet is NOT drawn (owner 2026-10-07); developers adapt.
- Each screen gets its own new Root pose (never reuse); add new poses to Mascot → "Root — App poses". Check generated poses show Root alone.
- Minimal copy: headline + one line. No footnotes, info boxes or policy text.
- No coloured left-edge accent bars; selection = lighter fill + 1px outline.
- Synthetic data only (Cedar Network / Elivate Network, Lagos office, Adaeze Nwosu EW-48213, Ifeoma O. President, Tunde B. Team Leader). Amounts exact with currency; never mix currencies.
- Don't invent features, permissions or numbers the contract doesn't have; flag them instead.

## Backlog (all designed 2026-10-07)
1. ~~Offices: list, create office, office detail (President).~~ Done 2026-10-07 on App — Screens v2 (O01–O09); poses Org tree / Building block / Keys. Open: confirm World Team can't be created (type picker shows Directorate/Team office only); whether a leader is required at creation; meaning of "manage classifications" (W-05); held column = office's own memberships, not subtree rollup (Rename/Change-leader dialogs now O10–O13).
2–10. Done 2026-10-07 on App — Screens v2 (desktop + mobile): R01–R14 Roles & access / reviewers / member detail + suspend/move/end; W01–W10 my withdrawals, cancel, approve pocket move, returned funds (+ sent); B01–B08 billing owner, plan change, Paystack confirmed / still confirming; S01–S06 MFA, devices & sessions, change PIN; V01–V04 restore request (+ sent); X01–X08 404, no access, session expired, withdrawals paused; K01–K02 quick search; O10–O13 rename office, change leader.

## Responsive pass — done 2026-10-07
B13m, B14d, B15m, B16d (App v1); desktop 04–11 (Authentication v2); S08d, S09d (Statements). Onboarding already paired.

## Platform admin app — done 2026-10-07
Page "Admin — Screens v1": A01–A16 (sign-in + MFA, overview, global search, tenant detail, account detail + status change, flags & kill switches + stop dialog, platform audit, backups & restores). Every admin has full access (owner 2026-10-07); policy fields show "Not configured" (U-05/U-06).

## Owner answers (2026-10-07)
- All platform admins can do everything (U-09 matrix dropped; recorded in 00-product P-09).
- Pocket names Main / Savings / Giving stay for now.
- Step-up = 4-digit transaction PIN, not an authenticator code (recorded in 01 A-05). Applied to B01/B02, A09b/A10, A11b.
- Plans: 6 bands, none smaller than "up to 400" (recorded in 01 D-10); caps/prices of the extra bands pending.

## Notion check — done 2026-10-07
Searched the P-10 provenance pages plus keyword searches (read-only). Results recorded in the contract (01 D-01/D-10/A-05; 02 W-05/W-06/W-13/W-18/W-23/W-24; 00 P-09 U-02/U-06/new U-13).

Answered (fully or in part):
- Pocket-move approvals → own **Transfers** module, not inside the withdrawal queue (main spec 2026-10-03). W05/W06 updated: sidebar "Transfers", tabs "Waiting on you / History".
- Sign-in/step-up MFA → authenticator app (Supabase TOTP); no email-code factor in any source. Mandatory enrollment for President, World Team and security/access-permission holders. S01/S02, A01b/A02 unchanged. Whether MFA is asked at every sign-in: not specified.
- Admin global search → UID, name, email, phone, **bank account**, transaction reference, team. A05/A06 copy updated.
- "Manage classifications" → changing a membership's organizational role (no separate catalogue). How a role change is executed: open.
- Statement branding → team logo, team name, Elivate Wallet branding, optional team contact (PDFs already match).
- Restore → team requests; validate → dry-run/diff → differences presented → authorized recovery (V/A15 steps match).
- Directorate rollup → authority covers the whole descendant subtree; display (own vs rollup) still open.
- Cross-access → record fields known (subject, permission, effect, scope, start/expiry, created by, reason, revoked); managed beside members & invitations.

Owner answers (2026-10-07, after the Notion check) — recorded in the contract:
1. Reference formats: adopt the proposal (01 D-01). `<TYPE>-XXXX-XXXX` Crockford Base32; UID `EW-` + ≥5 digits. Paper references unified (WDR/PTR/RTN/INC/ADJ/REV/RST/PAY/STM/RPT; `TRF` → `PTR`, `RR` → `RST`, `PSK`/`ELV-INV` → `PAY`).
2. Extra plan bands: skipped for now (U-13). B03/B04 unchanged.
3. Change leader replaces the leader (W-05). O12/O13: "Replaced" tag, required reason, "Replace leader".
4. Restore: President/World Team request + approve; operators run it; statuses suggested in W-24. V01–V04 copy, A15/A16 steps (Validate → Team approval → Restore), restore email → "diff ready to approve"; new V05/V06 Approve restore.
5. Quick search covers everything visible in the workspace (P-06). K01/K02 already match.
6. President Team creates every office type incl. World Team; leader required. O04/O06: World Team option + Team Leader field.
7. Office money = office + everything below. O01/O03 (+ tablet/K01 backgrounds) totals and member counts rolled up.
8. PIN: 5 tries, email reset, email change via support (A-05). New S07/S08 PIN locked, S09/S10 Set a new PIN.
9. Reason mandatory for move/suspend/end/change leader. R09–R14 already had reason fields.
10. Cross-access list field set accepted.
11. Statements: one per network + currency with that network's branding (W-18). S09d preview fixed to Cedar Network.
12. MFA: authenticator at every sign-in + step-up (A-05). New Authentication v2 screen 12 (desktop + mobile).
New Root poses on Mascot → App poses: Envelope with key, Big keypad button, Plus-minus card with glasses.

Owner answers (2026-10-07, round 3):
- Restores are done only by Elivate: team requests; Elivate operators validate, review the diff and restore. Statuses `requested → validating → in_review → restoring → completed` (+ rejected/cancelled/failed). V05/V06 removed; V01–V04, A15/A16 and the restore email updated. (Plus-minus pose on the Mascot board is now unused.)
- Plan bands: ignore for now.
- Cross-access reason mandatory (R03/R04 already showed it required; only Expires is optional).
- Mobile: leadership bottom tab "Queue" renamed "Approvals" everywhere; W06 segments Transfers · 2 / Withdrawals · 4. Desktop keeps a separate Transfers item.
- Statement network picker drawn on the Statements builder (desktop + mobile), shown only for 2+ networks.

Still open:
- Sign-in second step = the 4-digit PIN for everyone (owner: no authenticator app). Done: Auth v2 12 and admin A01b/A02 ask for a 4-digit PIN; S01/S02 authenticator setup deleted; "Two-step sign-in" row removed from Profile & security; admin account detail shows "Sign-in PIN".
- Admin onboarding (where platform admins set their PIN) is not drawn.
- "Yes by PT" read as World Team creatable by President Team AND leader required.

Tidy-ups done: S09d background Root hidden; S04 mobile duplicate title replaced with "3 signed-in devices".
