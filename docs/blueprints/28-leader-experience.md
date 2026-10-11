# Blueprint 28 — What leaders see, and unlock in place (slice 28)

Status: **owner decisions 2026-10-11; PIN unlock drawn and reviewed in Paper; built in slice 28.**

Contract: 02 W-07 (Leadership) and B3 (PIN gate), owner decisions 2026-10-11 below. Builds on
Blueprints 20/23 (device cache), 25 (navigation) and 27. Design: Paper `Elivate Wallet`, page
"PIN unlock v7 (DRAFT 2026-10-11)": PU01 (mobile sheet), PU02 (wrong PIN), PU03 (desktop card);
Root pose "Quiet nod (PIN unlock)" on Mascot → App poses. Migration `20261009280100`; pgTAP `280_`.

### Owner decisions (2026-10-11, binding)
1. **Every leader's Home is the overview of what they lead** (team or network), not their own
   wallet. A leader who holds a wallet finds it under **My wallet** (`/app/wallet`, sidebar
   "My wallet" section and More). `/app/team` sends old links to Home.
2. **Offices (the page) is for the President Team and World Team only.** Directors keep the
   read-only "Offices this month" table on their overview. Where the scope has one office (a
   Team Leader's own) the overview drops the Offices count and table.
3. **Nobody sees themselves** in Members, and a leader no longer sees the invitation they
   accepted in Invitations (everything else stays, accepted invitations included).
4. **"Invite a member" opens the invite form straight away** from every button that offers it
   (`/app/invitations?invite`).
5. The overview's "Nothing recorded in <last month>" line is gone (it read like a mistake); the
   comparison shows only when last month had income.
6. **PIN owed → unlock in place**: when the session owes its PIN again (15 minutes without a
   server call), the app never says "no access" or leaves the page. It shows the PU sheet over
   a blurred outline of the page, unlocks on the 4th digit, and opens the page again. A new,
   subtle Root pose.
7. **The lock cannot be bypassed in the browser**: the backend already refuses every protected
   read and command until the PIN is verified (`identity.require_session`). While locked, no
   real data stays in the page (it is unmounted; the outline has no names or amounts) and **every
   saved device copy is deleted** (the first page after unlocking reads from the server). Other
   open tabs lock too.

---

## B1. Backend (`20261009280100_hide_own_invitation.sql`)
- `api.list_invitations`: same signature, scope and authorization; leaves out invitations
  accepted by the caller (`accepted_user_id is distinct from p_user_id`). pgTAP `280_`.
- Members: `api.list_members` keeps returning the caller (the President Team roster on Access
  needs them); the Members page leaves them out (decision 3).
- Unlock: no backend change. `security/pin/verify` already counts tries and locks after five.

## B2. Frontend
- **Lock** (`#lib/client/pin-lock.svelte.ts`): the transport reports every browser reply
  (`observeReplies` in `#lib/contract/transport.ts`, browser only). A `pin_required` refusal
  anywhere, or the session read's gate, locks: device copies of every kind are deleted (the
  remembered scope stays, so other tabs don't read it as a sign-out) and `ew:lock:v1` tells
  other tabs. After 15 minutes and 5 seconds without a reply the shell asks the server for the
  gate (never sooner, so the check can't keep a session alive). The shell and `followGate` lock
  instead of redirecting to `/pin` while the lock is mounted; other gates still redirect.
- **Sheet** (`PinUnlock.svelte`, PU01–PU03): POST `/api/account/unlock` `{ pin }` → `{ gate }`
  (relays `security/pin/verify`; never retried). `ready` → unlock and reload the session;
  `profile_required` → setup; `pin_incorrect` → "Wrong PIN. N tries left."; `pin_locked` →
  `/pin/locked`; 401 → sign-in. "Forgot PIN?" → `/pin/forgot`; "Sign out" erases the device.
  The app layout renders only the outline and the sheet while locked.
- **Navigation** (`#lib/nav.ts`): `networkHome` for every leader; the top item reads "Team
  overview" (President Team: "Network overview"); "My wallet" heads the My wallet section for
  leaders with a wallet; Offices only for the President Team and World Team. `/app/wallet` is an
  own-money route (`view_own_wallet`).
- **Overview**: Home passes the held figures (reserved · available) for leaders with a wallet;
  Offices count and table only where Offices is theirs or the scope has more than one active
  office.
- **Members / Invitations**: self filtered by UID; `?invite` opens the form once offices load,
  then leaves the URL.

## Out of this slice (owner list 2026-10-11, later slices)
Forms submitting early and their Paper alignment (slice 29); app header, Activity filter
borders, Profile & security banner, anchored desktop dropdowns (slice 30); lighter email Root
images (slice 31).
