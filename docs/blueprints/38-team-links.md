# Blueprint 38 — Team invite links (slice 38)

Status: **owner decisions 2026-10-15; Paper "Team links v11" approved 2026-10-15.**

Contract: W-02 (invitation-bound completion, amended), W-03 (invitations, amended), D-01 (new
reference type `LNK`), D-10 (seats), A-05 (step-up). Builds on Blueprint 03 (invitations, link
tokens, join page, `org.require_invite_authority`, `org.require_join_session`), 16 (seat cap in
`org.create_membership`), 24/30 (wheel picker, desktop list) and 29 (Invite dialog C13/C14).
Migration `20261009380100_team_links.sql`, pgTAP `380_team_links.sql`.

---

## Part A — What this slice does

A leader makes **one open link for an office** and shares it (WhatsApp group, event). Anyone who
opens it signs up with their own email (or signs in) and joins that office as a **Member** straight
away, then goes through the usual onboarding (PIN, NIN, profile, bank, install). Email invitations
stay exactly as they are.

### Owner decisions (2026-10-15, binding)
| # | Question | Decision |
|---|---|---|
| 1 | Kind of link | **Open team link**: one link, anyone with it can sign up with their own email. A new kind of invitation next to email invitations (not bound to an email). |
| 2 | How people join | **Instantly**: verifying their email and pressing Join makes them an active Member. The seat cap still applies; leaders can remove people afterwards. |
| 3 | Limits | The leader picks **how long it works** (1, 7 or 30 days, or no end; default 7 days) and **how many people can join** (10, 50 or no limit; default no limit). |
| 4 | Who | Any `invite_members` holder, for offices in their scope (Team Leaders: their own office). Links only ever add the plain **Member** role. |
| 5 | Per office | **One live link per office.** Making a new link replaces the old one (the old link stops at once). |
| 6 | Existing accounts | Sign in, then join (a new membership in this network). Refused when they already belong to the network. |
| 7 | PIN | Creating, replacing or turning off a link needs the **PIN** (step-up). |
| 8 | Join page | Before sign-in it shows the inviter, office and network ("Tolu Bakare invited you to Unity Network. You'll join as a Member."). |
| 9 | Design | Paper "Team links v11": TL01–TL06 (mobile) and TL01d–TL06d (desktop). Root · Holding the door is adopted as the Team link pose (one screen, never repeated). |
| 10 | Reference | Team links carry an `LNK-XXXX-XXXX` reference (D-01). |
| 11 | Creator leaves | A link stops working when the person who made it no longer holds `invite_members` over its office (their membership ended, moved or the permission was removed). Email invitations keep their Q10 rule. |

### What people see
- **Invite dialog (C13/C14 → TL01/TL01d):** a By email / Team link switch. Team link shows the
  office (picker when there are several), "Link works for" and "People who can join" (wheel on
  phones TL06, list under the field on desktop TL06d), a note that anyone with the link joins right
  away, and **Create link** (asks for the PIN when the five-minute proof has lapsed).
- **Live link (TL02/TL02d):** the link with **Copy**, joined count ("12 of 50" / "12"), when it
  stops working, "Made by <name> · <date>", **Make a new link** (back to the form; the old link
  stops when the new one is made), **Turn off** (PIN) and **Share link** on phones (the system share
  sheet; Copy where sharing isn't available) or **Done** on desktop.
- **Join page (TL03/TL03d):** `/j/<code>`. Signed out: email + "Create a password" + Create
  account (Turnstile), then "check your inbox"; "Have an account? Sign in to join". The
  confirmation email returns to this page in the same browser.
- **Signed in (TL05/TL05d):** "Signed in as <email>" and **Join <network>**; "Not you? Sign out".
- **Unavailable (TL04/TL04d):** one message for expired, full, turned off, replaced or unknown
  links (no hint which).

### Not in it
- Leader approval of joiners (decision 2 chose instant).
- QR codes for links (W-03 "future convenience").
- A list of who joined through which link (joins are recorded; the panel shows the count).
- Notifications to the leader when someone joins.

---

## Part B — Build spec

### B1. Data (`org`, RLS on, no client access)

| Table | Columns | Rules |
|---|---|---|
| `org.team_links` | `id`, `reference` (`LNK-…`, `refs.issue('LNK')`), `tenant_id`, `office_id`, `created_by`, `creator_membership_id`, `token_id` (uuid), `token_digest` (bytea 32, unique), `expires_at` (null = no end), `max_uses` (null, 10 or 50), `uses` (≥ 0, ≤ `max_uses`), `status` (`active`/`replaced`/`turned_off`), `created_at`, `ended_at`, `ended_by` | Composite FK `(tenant_id, office_id)` → offices. One `active` row per office (partial unique index). `status = 'active'` ⇔ `ended_at` null ⇔ `ended_by` null. Identity columns immutable; an ended link never changes (trigger). No delete/truncate. |
| `org.team_link_joins` | `id`, `tenant_id`, `team_link_id`, `user_id`, `membership_id`, `at` | Append-only. One row per join. |

`refs.issued.type` gains `LNK`; `audit.tenant_events.target_type` gains `team_link`.

**Live link** (`org.team_link_live`): `status = 'active'`, `expires_at` null or in the future,
`max_uses` null or `uses < max_uses`, network `active`, office `active`, the creator's membership
not ended and `authz.decide(created_by, 'invite_members', tenant, office, null,
creator_membership_id)` allowed (decision 11). The read reports why a link is not live:
`expired`, `full`, `creator_left`, `office_closed`.

**Link code.** Same scheme as invitation tokens (Blueprint 03 B2): the Edge Function draws a
`token_id`, derives `code = Crockford-Base32(HMAC-SHA256(INVITATION_TOKEN_SECRET, "team:v1:" ||
token_id))`, first 10 characters (50 bits), and Postgres stores only `token_id` and
`SHA-256(code)`. The link is `{APP_ORIGIN}/j/<code>`. A team link is meant to be shared, so it sits
in the path (short and readable); the Worker posts it to the Edge Function in a body, never logs
it, and the join page moves it into an HttpOnly cookie and redirects to a clean URL. Codes are
read case-insensitively. 50 bits cannot be guessed online.

### B2. Commands (`api.*`, `security definer`, `search_path = ''`, service_role only)

| Route (`invitations` function) | Command | Checks | Effects / result |
|---|---|---|---|
| `GET /team-link?officeId=` (`X-Membership`) | `api.team_link` | session; workspace; `invite_members` over the office | `{ link: null }` or `{ link: { teamLinkId, reference, url, expiresAt, maxUses, uses, createdAt, createdBy, state } }`, `state` = `live` or why not (B1). The Edge Function turns `tokenId` into `url` and never returns `tokenId`. |
| `POST /team-link` (`X-Membership`) `{officeId, days, maxUses, idempotencyKey}` | `api.create_team_link` | writer + **step-up**; `org.require_invite_authority(…, 'member')`; `days` ∈ {1, 7, 30, null}; `maxUses` ∈ {10, 50, null} | Ends the office's active link (`replaced`), inserts the new one, audit `team_link.created` (and `team_link.replaced`). Returns the link as above plus `replaced`. |
| `POST /team-link/:id/turn-off` (`X-Membership`) `{idempotencyKey}` | `api.turn_off_team_link` | writer + **step-up**; same authority over the link's office | `turned_off`, audit `team_link.turned_off`. Already ended → `{ changed: false }`. |
| `POST /team-link/preview` `{code}` (no session) | `api.team_link_preview` | live link | `{ networkName, officeName, invitedBy }` (inviter's display name). Anything else → `invitation_unavailable`. |
| `POST /team-link/join` `{code, idempotencyKey}` (session) | `api.join_team_link` | `org.require_join_session` (gate `ready` or `pin_setup_required`, confirmed email); live link under lock; no open membership in the network (`membership_exists`) | `org.create_membership(tenant, office, user, 'member', user)` (seat cap, wallet hook), `uses + 1`, join row, `org.bump_authz_version`, audit `team_link.joined`. Returns `{ membershipId, tenantId, officeId, role, isPrimary }`; a replay returns the same. |

Lock order (Blueprint 03 B3): person → office row `FOR NO KEY UPDATE` → team link row `FOR UPDATE`
→ seats (inside `org.create_membership`). Create/turn-off lock only the office's active link row.
The use count is checked and raised under the link lock, so concurrent joins never exceed
`max_uses`.

### B3. Frontend
- `/app/invitations` Invite dialog: tabs; `TeamLinkPanel` (TL01/TL02/TL06) through
  `/api/team-link` (GET, POST with `pin`) and `/api/team-link/[id]/turn-off` (POST with `pin`),
  `withPin` like other protected commands; `step_up_required` shows the PIN field.
- `/j/[code]`: checks the code (preview), keeps it in the HttpOnly `ew_team` cookie (7 days) and
  redirects to `/team-join`; an invalid code renders TL04.
- `/team-join`: `signup` (Turnstile `sign-up`, `auth.signUp` with `emailRedirectTo
  /auth/confirm`; the same "check your inbox" answer whether or not the email has an account,
  W-01), `join` (signed in), `unavailable`. `/auth/confirm` and sign-in continue to `/team-join`
  while the cookie is set. Joining clears the cookie, records the onboarding membership and goes
  to `/onboarding`.
- Root pose `team-link` (Holding the door) in `static/root/`.

### B4. Tests
pgTAP `380_team_links.sql`: authority (member/leader/outsider, Team Leader own office only),
step-up, option validation, one active link per office (replace), turn off, preview fields,
join (membership, use count, replay, `membership_exists`, gate `pin_setup_required`), limits
(expiry, full, turned off, replaced, creator left, office closed), privileges. Deno: routes,
validation, code derivation. Frontend unit tests for the option labels and link formatting.
