# Blueprint 36 — Who reviews identity (slice 36)

Status: **owner decisions 2026-10-12; built in slice 36.**

Contract: 01 A-03 (new row `review_identity`), Blueprint 06 Q4 (superseded), owner decisions
below. No new screen: one more row in Role permissions (Paper R01/R02) under a new "Identity"
group, and one more permission in the Cross-access picker (R03/R04). Migration
`20261009360100`; pgTAP `360_`. (Slice 35 is the install-app work in another session.)

### Owner decisions (2026-10-12, binding)
1. A President Team member can give another role in their network the ability to **review and
   approve identity** (NIN reviews): a role switch in Role permissions, and Cross-access for one
   person.
2. A lower role that gets it reviews **its office and the offices below** (as the World Team
   always has).
3. **President Team locked on; World Team on by default but switchable.**

### What changed
- **Catalogue (A-03, 34 → 35 rows):** `review_identity`: not protected, grantable,
  `office` scope, defaults on for World Team and President Team. Every existing network gets
  the defaults. `authz.locked_cell(role, key)` marks the President Team cell; `list_role_permissions`
  shows it as not editable and `set_role_permission` refuses it (`permission_not_grantable`,
  `protected`).
- **Authority:** `identity.can_review` asks the resolver (`authz.decide`) for `review_identity`
  against the requester's office and account, so role policy, Cross-access grants and denies,
  expiry and network status all apply. It stays the single check behind the list, the decision,
  the bell task routing and task visibility. Never one's own review. Elivate admins are unchanged.
- **The list** (`api.nin_reviews`) is open to a workspace whose role holds the permission or
  whose person has a current Cross-access grant; anyone else gets `authorization_denied`.
- **Cross-access:** only a President Team workspace can grant `review_identity`
  (`permission_not_grantable`, `president_only`), because Directors and the World Team hold
  `manage_access_rules` for their offices. The Directors' and World Team's picker leaves it out
  (it sits in its own "Identity" group).
- **Navigation:** "Identity reviews" follows the `review_identity` capability (role defaults
  stand in before the capabilities load or offline).
- A network awaiting payment no longer reviews identities (the resolver denies every permission
  but billing there), like every other leadership action.
