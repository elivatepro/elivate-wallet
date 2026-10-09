# Blueprint 07 — Org management (screens, close office, role change)

Status: **built under the member build plan (owner decisions 2026-10-08, `docs/member-build-plan.md` slice 1); close-office and role-change rules and Paper "App — Screens v4" N01–N04 approved by the owner 2026-10-08.** Contract: W-05, W-06, W-07 (office money), W-23 (President audit log), A-01–A-05, D-02, D-11, T-01. Builds on Blueprints 02 (offices, memberships, authorization, audit), 03 (invitations), 04 (office totals, managed wallets) and 06 (profile names). Migrations `2026100907xxxx`; pgTAP `070_`–`079_`; Edge Function `org`.

Part A is for the owner: what this slice does, in plain language. Part B is the exact build spec.

---

## Part A — What this slice does

### What's in it
1. **Offices screen.** Every office you can see, as a tree (World Team → Directorates → team offices), with its leader, how many people sit in it and everything below it, and the money held for members in it and below it, in NGN or USD (never added together). The President Team starts new offices here; a leader is always named (by UID).
2. **Office page.** The office's money per currency, its members, its leaders and where it sits in the network. Rename it, or change a leader (the old leader's leadership ends, the new one starts; reason and PIN).
3. **Close an office (new; owner decision 2026-10-08).** The President Team closes an office with a reason and PIN (Paper N01), only when it has no active members (its leaders aside), no open offices under it and no money held in it. Whatever is left on it (its leaders, suspended members) is archived: those memberships end with the reason. Pending invitations into it are revoked and evidence-reviewer roles held through those memberships end. A closed office is read-only and shows why and when it closed (Paper N02); its money history stays visible to the President Team and the leaders above (decision 23). Offices can also be placed under another office or at the top (Paper N04, reason + PIN).
4. **Members screen and member page.** Search people by name or UID, filter by status, open one membership: its office, role, history, other memberships in the network and (when you may see it) the member's money in this network per currency. Suspend, reactivate, move to another office or end the membership, each with a reason and PIN (W-05).
5. **Change a role (new; owner decision 2026-10-08).** The role only, never the office (Paper N03): changing it ends the current membership and starts a new one in the same office, a member becoming the office's leader or a leader becoming a member. Reason and PIN; the office must be below your own office (the President Team: any office); the last leader cannot step down. Changing office is only done with Move. Money history is untouched.
6. **Roles & access.** The five roles' permissions, grouped (Own wallet, Money, Reports, People, Governance). Protected rows are locked; the others are switched per role and saved together with a reason and PIN. Currency conversion and credit/debit adjustments are in the Money group, so the President decides which roles hold them (plan: Money movement).
7. **Cross-access.** Give or block specific permissions for one person, for the whole network, an office and everything below it, or one member; start date, optional expiry (grants only), reason, PIN. Revoke a whole assignment with a reason and PIN.
8. **Evidence reviewers.** Find a member, add them as a reviewer (reason, PIN), remove them. Only they clear or reject financial evidence, never their own.
9. **President Team.** Add or remove President Team Members (reason, PIN; one always remains; nobody removes themselves).
10. **Audit log.** The President reads the network's log, newest first: who, what, when, why and the safe before/after values.

### Not in it
- Office money in a single list read: the Offices screen asks the ledger for each office's totals (up to 60 offices); beyond that the column shows "—". A bulk read can come later if networks grow.
- Audit-log filters (who / area / period) drawn on Paper F05 need a backend filter; not built.
- "Last activity" per member (Paper C11) needs a money-activity read across members; the row shows office and role instead.
- Picking a leader or cross-access person from a searchable list: UIDs are typed. Reviewers are picked by search.

### Screens waiting on Paper approval (minimal stubs only)
President Team (add/remove) and the cross-access list tab have no Paper composition yet; they work (backend, app server and a plain page/list) and will be redrawn once approved. Close office, the closed office, role change and placing an office are built from the approved N01–N04.

### Owner decisions (2026-10-08)
| # | Question | Decision |
|---|---|---|
| Q1 | When can an office close? | Only with no active members, no offices below it and no money held. Memberships left on it are archived. |
| Q2 | Does a role change move the office? | No. Role only; moving office is only through Move. |
| Q3 | PIN for move, suspend and end membership? | Yes, with the mandatory reason (R09–R14). |

### Still open
| # | Question | What was built meanwhile |
|---|---|---|
| O1 | Conversion and adjustment authority: the plan says "granted to the President Team by default"; the A-03 table also gives conversion to Team Leaders, Directors and World Team and adjustments to World Team. Should new networks start with those off for the other roles? | A-03 defaults unchanged; the President can switch them in the editor. |
| O2 | Should an evidence-reviewer assignment carry over to the new membership after a role change? | It ends; the President re-adds the reviewer. |

---

## Part B — Build spec

### B1. Migration `20261009070100_org_management.sql`
- `org.check_membership_role()` (replaced): an **insert** into `org.memberships` reads the office row `FOR SHARE` and refuses a closed office with `conflict` / `office_closed`. `FOR SHARE` waits for a concurrent `close_office` (`FOR NO KEY UPDATE`), so no membership can be added to an office while it closes.
- `org.check_invitation_office()` (new trigger on `org.invitations` insert): same `FOR SHARE` check, so a concurrent invitation cannot outlive a closing office (`conflict` / `office_closed`).
- `assign_reviewer` (replaced): reads the target membership `FOR SHARE`, so it cannot assign a membership that a concurrent close or role change is ending.
- Helpers (private, invoker): `org.masked_email(user)` (`a•••••@example.com`), `org.office_leaders(office)`, `org.office_visible(workspace, office)`, `org.end_reviewer_for(membership, reason, actor, request)`.
- Commands (`api.*`, definer, `service_role` only):

| Command | Actor · checks | Effect | Result |
|---|---|---|---|
| `close_office(user, session, membership, office, reason, key, req)` | President Team workspace · R · S · active network | Lock order: people (open memberships of the office) → tree → office row → its open memberships (`FOR UPDATE`, so a concurrent ledger posting that holds a membership `FOR SHARE` finishes before the money check); if someone joined between the person locks and the office lock it answers `conflict/office_changed` (retry) rather than take a person lock out of order. Refuses `conflict/has_child_offices` (an active child office), `conflict/office_not_empty` (an active non-leader membership) and `conflict/money_held` (any `ledger.balances` row of the office with posted or reserved ≠ 0). Sets `closed`; archives (ends, with the reason) every open membership left on it (leaders, suspended members), primary handover; ends reviewer assignments held through them; revokes pending invitations into the office (`invitation_events` row each; `FOR UPDATE SKIP LOCKED`, because acceptance locks office → invitation and creation invitation → office: a row held by a concurrent command is left to it, and an invitation into a closed office can neither be created nor accepted); audit `office.closed`. Closing a closed office returns `changed: false`. | `{ officeId, status, changed, endedMembershipIds, revokedInvitations }` |
| `change_membership_role(user, session, membership, target, role, reason, key, req)` | `manage_members` over the office and person · office strictly below the actor's own (President Team: any) · R · S | `role` ∈ {`member`, office's leader role} and ≠ current (`validation_error/role`); President Team memberships refused (`conflict/president_membership`); target must be `active` (`conflict/membership_not_active`). Creates the new membership (same office, primary carried over), ends the old one as `replaced` with `replaced_by_id`, ends a reviewer assignment held through it, keeps ≥ 1 leader (`last_leader`), audit `membership.role_changed`. | `{ endedMembershipId, membershipId, role }` |

- Reads:
  - `list_offices` (replaced, same signature): adds `childCount` (open child offices) and `leaders` (up to 3 persons).
  - `office_detail(user, session, membership, office)`: visible offices only (`not_found` otherwise). `{ id, name, type, status, parentOfficeId, createdAt, leaders[{membershipId, person, startedAt}], path[{id,name,type}] (top → this), children[], memberCount (subtree, distinct people), ownMemberCount, pendingInvitations, canManage, canLeadAssign }`.
  - `list_members` (signature changed: adds `p_query text default null` last): name/UID search (`ilike`, escaped, 1–100 chars), adds `emailMasked`.
  - `member_detail(user, session, membership, target)`: same visibility as `list_members` (closed offices: President Team only), else `not_found`. `{ membershipId, person, emailMasked, role, status, isPrimary, startedAt, endedAt, office{id,name,type,status}|null, officeLeaders[], isSelf, walletId|null, memberships[] (the person's open memberships in this network the actor may see), history[] (last 20 events: action, from/to status, at, actor; no reasons), actions{suspend, move, end, changeRole} }`. `actions` are hints; every command re-checks.

### B2. Edge Function `org` (new routes)
`GET /offices/:id` → `office_detail` · (existing `POST /offices/:id/place` → `place_office` now has a screen, N04) · `POST /offices/:id/close` `{reason, idempotencyKey}` → `close_office` · `GET /memberships/:id` → `member_detail` · `POST /memberships/:id/role` `{role (member|team_leader|director|world_team_member), reason, idempotencyKey}` → `change_membership_role` · `GET /members` accepts `q`. No new error codes.

### B3. App server (`/api/org/*`, SvelteKit)
Reads: `GET offices` (all pages ≤ 500 offices; per-office ledger totals for ≤ 60 active offices when the workspace holds `view_managed_wallets` or `view_scoped_financial_reports`; unavailable totals are omitted, never zero), `GET offices/:id` (+ ledger totals + first 50 members), `GET members` (`q`, `status`, `role`, `officeId`, `cursor`), `GET members/:id` (+ this network's per-currency wallet totals via the ledger managed-wallet read, + move targets), `GET access` (role permissions and reviewers for the President Team; every assignment page (≤ 1,000) and active offices (≤ 500) for `manage_access_rules`), `GET audit`. Commands (workspace echo, body schema, optional dialog PIN → step-up, never retried; the browser keeps the key while the outcome is unknown): `POST offices`, `PATCH offices/:id`, `POST offices/:id/close`, `POST offices/:id/place`, `POST offices/:id/leaders`, `POST offices/:id/leaders/replace`, `POST members/:id/{suspend|reactivate|end|move|role}`, `PUT role-permissions` (one PIN + reason, then each change in order with its own key), `POST access`, `POST access/:id/revoke`, `POST reviewers`, `POST reviewers/:id/end`, `POST presidents`, `POST presidents/:id/remove`.

### B4. Screens
Paper "App — Screens v2" O01/O03, O04/O06, O07/O09, O10–O13, R01–R14; "App — Screens v4" N01 (close office), N02 (closed office, read-only), N03 (change role, no office picker), N04 (place office); "App — Screens v1" C11/C12 (members) and F05/F06 (audit log). New Root poses exported 1×/2× WebP (`offices`, `office`, `office-new`, `office-rename`, `office-leader`, `roles`, `cross-access`, `reviewers`, `member`, `member-suspend`, `member-move`, `member-end`, and from v4 `office-close`, `office-closed`, `member-role`, `office-place`). Stub: `/app/access/presidents`. Deviations: leaders and cross-access subjects are typed as UIDs; dialogs add the PIN field (A-05); Offices list "Held" uses per-office reads; no "Last activity" or audit filters.

### B5. Tests
pgTAP `070_org_management.sql`: list_offices leaders/childCount; office_detail path, rolled-up count, sibling and cross-tenant `not_found`, `canLeadAssign`; member search by name/UID, masked email, blank search refused; member_detail visibility and action hints; role change validation, reason, below-own-office rule, step-up, end + new with `replaced`, primary carried, reviewer ended, replay and key conflict, single audit, leader → member, `last_leader`, President refused; close office President-only, child offices, active members, money held (income left behind by a move), reason, step-up, leader and suspended member archived with the reason, invitations revoked, replay, idempotent re-close, no adds (API and table trigger), no child under a closed office, primary cleared, single audit, President still reads it; privileges. Deno: close/role/detail/search route validation. Vitest: tree order, labels, permission groups, audit sentences, failure mapping. Playwright `org.e2e.ts`: create, rename, place (N04) and close (N01/N02) an office, members list, role-permission save with reason + PIN, audit log; axe on each screen; signed-out API 401.
