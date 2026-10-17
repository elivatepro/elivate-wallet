# Blueprint 46 — No Root on money and records (slice 46)

Status: **owner decision 2026-10-17; built directly (owner chose no Paper draft).** Frontend
plus the shared email layout; no migration.

### Owner decision (2026-10-17, binding)
This is a financial app. A mascot beside money "feels less trustworthy, distracts from the
numbers and takes space". Supersedes the 2026-10-06 "every screen gets its own Root pose" rule
for the areas below (`00-product.md` mascot paragraph, member build plan).

| Root comes off | Root stays |
| --- | --- |
| Home balance card | Money successes (income posted, withdrawal sent, move requested, paid out, payment confirmed, sent for checking) |
| Money forms: withdraw, income, convert, adjust, reversals, pockets, pocket moves | Empty states (no money yet, no statements, no matches) |
| Money and record confirmations (`RootDialog`, `OrgDialog` on these pages) | Sign-in, onboarding, install |
| Refused and pending money outcomes, "checking" screens, the one-open-withdrawal block | Notifications, support, quick search |
| Review and record pages: queue, returns, evidence, reviews, transfers, wallets, activity, statements, reports, billing, payout accounts, audit, members, offices, access | Account and security pages and dialogs, settings, backups |
| Load errors and denials on those pages | App-wide states (workspace load error, offline, paused, 404) and the admin console |
| Money emails (income, withdrawals, payouts, evidence, moves, adjustments, conversions, reversals, returns, statements, billing payments and renewals, plan paused, payout-account alerts) | Every other email |

Where Root is removed **nothing replaces it**; the layout closes up.

### Build
- Shared components take an optional `pose`; without one they render no Root and shrink:
  `RootHero` and `OrgHero` (the grain band fits its text), `Outcome` (no stage), `StateScreen`,
  `RootDialog` and `OrgDialog` (desktop header becomes plain: no felt band, theme text colours).
  `NoAccess` gains `plain`. `CheckingPanel` and `BalanceCard` lose Root outright (only used on
  money); the balance card is 200 px (phone, min) / 240 px (desktop) and the chips take the width.
- Pages stop passing poses; art-only panels and their CSS are deleted (entry `.en-art*`, the
  statements art panel, the report export stage, the withdraw art column; the withdraw form is
  capped at 720 px on desktop).
- Email: `EmailLayout.root` is `RootPose | null`; `null` drops the Root cell and the band keeps
  its chip, status, amount and reference. Old PNGs stay in `static/email/` (sent emails link
  them). Tests: money emails have no Root image; the others keep their own pose.
