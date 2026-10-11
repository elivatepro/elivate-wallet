# Blueprint 27 — Person picker and leaders invited by email (slice 27)

Status: **owner approved the Paper drawings 2026-10-11; built in slice 27.**

Contract: 02 W-03 (invitations) and W-05 (offices and memberships), owner decisions 2026-10-11
below. Builds on Blueprints 03 (invitations), 07 (org management) and 19 (founders). Design: Paper
`Elivate Wallet`, page "Person picker v6 (DRAFT 2026-10-11)": PP01 (New office, finding a leader),
PP02 (New office, inviting by email), PP03 (office waiting for its leader). Migration
`20261009270100`; pgTAP `270_`.

### Owner decisions (2026-10-11, binding)
1. Every form that names a person takes a **name, an email address or a UID** in one field:
   New office (leader), Change leader, Access (person and member scope) and President Team.
2. **Search scope:** a name matches only the people in the network the workspace can see; a UID
   or a full email address matches any Elivate account exactly (no browsing).
3. **New office, leader with no account:** the office is created now and shows "Waiting for its
   leader". A leader invitation goes to the email (the reason is filled in: "Leader of new office
   <name>"); accepting it makes them the leader. Members can be invited into it meanwhile.
4. **Invite-by-email only on leader forms** (New office, Change leader). Access rules and the
   President Team need a person with an account.
5. **Change leader by email:** the current leader stays until the invitation is accepted; the
   replacement happens then. If it lapses, nothing changes.
6. **A waiting office whose invitation lapses keeps waiting**; the President Team resends or
   invites someone else.
7. "An active office keeps at least one leader" (W-05) now reads **"an office that has had a
   leader keeps one"**: a waiting office has none yet.

---

## B1. Backend (`20261009270100_person_picker.sql`)
- `api.find_people(user, session, workspace, q)` (GET `/org/people?q=`): leadership workspaces
  and members who hold `manage_access_rules` (`authorization_denied` for other members). UID → that account; full email → that account or
  `noAccount: true`; otherwise 2–100 characters of a name among active/suspended memberships the
  workspace can see (`org.office_visible`; President Team memberships only for the President
  Team). At most 8, by name. Items `{ uid, name, inNetwork, role, officeName }`.
- `api.create_office_inviting_leader(...)` (POST `/invitations/office`): President Team, PIN
  (step-up). Creates the office with no leaders and, in the same transaction, the leader
  invitation through `org.issue_invitation` (rate limit, overdue clean-up, event, audit, email).
- `org.invitations.replaces_membership_id`; `api.create_invitation(..., p_replaces_membership_id)`
  (POST `/invitations` `replacesMembershipId`): only a current, non-ended leader of the office
  with the invited role; `manage_members` over them. `api.accept_invitation` ends that membership
  as `replaced` (actor: the inviter, reason: the invitation's) and audits
  `office.leader_replaced`, if they still hold it. As with a direct replacement, the incoming
  person's other memberships in the office end first; both people are locked before the office.
- `org.assert_leader_remains`: fails only when the office has had a leader (decision 7).
- `api.office_detail.pendingLeaders`: open leader invitations `{ invitationId, email, expiresAt,
  replaces }`, only for those who may invite into the office (`null` for others, so the page
  never claims there is none).

## B2. Frontend
- `PersonPicker` (`#lib/ui/org/`): search box (250 ms debounce, aborts the older read), results
  as a listbox (arrow keys, Enter), a chosen chip with "Choose someone else"; `allowInvite` turns
  an unknown full email into "Invite <email>". Pure helpers in `#lib/person-picker.ts`.
- BFF: GET `/api/org/people`, POST `/api/org/offices/invite`, POST
  `/api/org/offices/:id/leaders/invite` (the `invitations` function issues the link).
- Offices: New office uses the picker ("Create and invite" + the PP02 note); an office with no
  leader reads "Waiting for its leader". Office page: the PP03 leader card, Resend invite (fresh
  link, PIN), a pending replacement line; Change leader uses the picker.
- Access and President Team: the picker without invitations.

## Tests
pgTAP `270_person_picker.sql` (search scope and matches, waiting office, accept makes the
leader, the leader rule, replacement on accept). Deno: route validation for `/people`,
`/invitations/office` and `replacesMembershipId`. Vitest: `pickerQuery`, `pickedUid`. Playwright
`org.e2e.ts`: leader picked by UID; a new office whose leader is invited by email, waiting state
and Resend invite.
