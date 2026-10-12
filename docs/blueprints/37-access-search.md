# Blueprint 37 — Search in Roles & access (slice 37)

Status: **owner request 2026-10-12; Paper draft approved; built in slice 37 (frontend only).**

Design: Paper `Elivate Wallet`, page "Access search v10 (DRAFT 2026-10-12)": AS01 (desktop),
AS02 (phone). Builds on Paper R01/R02 (role permissions) and Blueprint 36.

### Owner decision (2026-10-12, binding)
The Search tab is for **the permissions themselves**, the rows of the Role permissions table,
not for people. (A first draft that listed Cross-access people under each permission was
rejected.)

### What it does
- A fourth tab, **Search** (`?tab=search`), next to Role permissions, Cross-access and Evidence
  reviewers. Shown wherever Role permissions is (the President Team). On phones it is a
  magnifier only, and the hero reads "Search · Find a permission".
- Typing filters the permission rows by name: every word typed must be in the label (or key),
  in any order and case (`searchPermissions` in `#lib/org`). Matching rows stay in their groups
  ("2 of 9 match"), always open, with the same switches, locks and save bar as Role permissions;
  phones keep the role chips. "Review financial evidence" (assigned) shows when it matches.
- The field is focused when the tab opens; a count shows as you type; "No permission matches
  “…”." when nothing does. Nothing new on the backend.
