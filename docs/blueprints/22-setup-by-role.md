# Blueprint 22 — Setup by role, profile gate, funds-not-managed directors (slice 22)

Status: **owner decisions 2026-10-10; built in slice 22.**

Contract: `docs/member-build-plan.md` "Owner feedback round (2026-10-10)" and "Setup by role
(2026-10-10)", 01 D-01 (wallet), A-01–A-05, F-01–F-03, 02 W-01 (founder entry), W-02 (first-use
wizard), W-05 (memberships), W-07 (wallet visibility), W-22 (profile). Builds on Blueprints 01 (PIN
gate, step-up), 02 (memberships, resolver), 04 (wallets, ledger), 05 (payout accounts), 06 (NIN and
profile), 16/19 (founder setup and payment), 20 (`api.app_bootstrap`) and 21 (`next` handling,
wallet-less navigation). Migrations `2026100922xxxx`; pgTAP `220_`–`229_`.

### Owner decisions (2026-10-10)
1. **Setup differs by role.**
   - **Light setup** (President Team, and directors whose funds are not managed): the PIN, then
     name, photo and rank. No NIN, no phone, no bank account.
   - **Wallet setup** (member, team leader, director, World Team): the PIN, the NIN (and the
     details confirmation), the profile (photo, phone, rank) and a bank account.
2. **"Funds not managed" for directors.** A per-membership switch:
   - Only President Team members set or clear it, with a reason and the PIN. It is audited,
     idempotent and stays inside the network.
   - Setting it is **refused while the director's wallet holds money** (any posted or reserved
     amount, any currency or pocket) or has a withdrawal, pocket move or entry still open.
   - An exempted director keeps every director authority (records income, runs the team,
     approves). They hold no money: light setup, no own-wallet pages, and the ledger refuses to
     post to them.
   - Clearing it restores the wallet. Their setup then asks for the NIN, phone and bank again
     through the gate.
3. **The backend enforces the setup on every call.** The session gate gains `profile_required`
   with the next step. The wizard's own reads and sign-out keep working. The app sends the person
   to the right wizard step and keeps `?next=`. Founders complete their light setup too. The check
   fails closed, and the `ew_ws` workspace cookie no longer skips it. People on dev who have not
   finished setup are gated on their next visit (intended).
4. **NIN review authority is unchanged** (Blueprint 06).

### Decisions taken while building (conservative; see "Open for owner")
- **Where the founder's light setup goes:** right after the PIN, **before** naming the network and
  paying. An approved founder needs the light setup even before they own a network. The payment
  hand-off (Paystack and back to `/app/billing/payments/[id]`) is never interrupted, and the
  Blueprint 16/19 rules (one trial, approval first, pay before activation) are untouched.
- **Wallets are kept.** The switch never deletes or "closes" the wallet: wallets are account-wide
  and immutable (Blueprint 04), and may hold money from the person's other memberships. The switch
  marks the **director membership** instead. Every ledger posting and hold on a segment of an
  exempted membership is refused in the database. History, provenance and same-key recovery (F-03)
  are unaffected: nothing is rewritten or removed, and a replay of an earlier command returns its
  stored result without posting.
- **"Holds money" means this network:** every segment of the person's wallet that came from any
  of their memberships **in this network**. Other networks are never read (tenant isolation).

---

## B1. Setup levels and steps

`identity.setup_state(user)` → `{ level, next, walletMembershipId }`:

| Level | When | Steps, in order |
|---|---|---|
| `wallet` | An **active** membership that is not President Team, in an **active** network and an **active** office, whose funds are managed | `identity` (a NIN record exists; a pending leader review keeps the person here, as W-02 says), `profile` (photo, phone, rank), `bank` (an active payout account) |
| `light` | Any other active membership (President Team, exempted director, a membership in a paused network), or an approved founder (`founders.approved`) | `profile` (first and last name, photo, rank) |
| `none` | Nobody to set up for (no active membership, not a founder; platform admins) | — |

- `next` is the first missing step, or `null`. A **restricted** account is not asked for the bank
  step: it cannot add one (no writes) and cannot move money (D-02). The PIN comes first through the existing PIN gate.
- `walletMembershipId` is the membership the bank step uses (primary first). It is null below the
  `wallet` level.
- The photo is always required. Local e2e runs get a disk-backed photo store (like exports) so the
  wizard behaves as in production.
- A NIN record locks the legal name. Without one, the light profile step sets `first_name` and
  `last_name` through `api.update_profile` (new keys `firstName`, `lastName`; refused with
  `conflict{reason: name_locked}` once a NIN record exists). Verifying a NIN later replaces them,
  as before.

## B2. Gate states

| Gate | Meaning |
|---|---|
| `pin_setup_required` · `pin_locked` · `pin_required` | Unchanged (Blueprint 01). |
| `profile_required` | **New.** The PIN is fine, but `setup_state.next` is not null. |
| `ready` | Everything is done. |

- `identity.security_state` returns the gate and a new `setup` object (`{ level, next,
  walletMembershipId }`). `api.app_bootstrap` returns only the state at `profile_required`, as at
  any other gate.
- `identity.require_session` (every protected read and command) now fails
  `profile_required` (HTTP 403, `details: { step, level }`) after the PIN checks. The old body
  lives on as `identity.require_pin_session`. The bell's quiet session check applies it too.
- **Calls that stay open during setup.** `identity.setup_exempt()` reads the call stack
  (`get diagnostics … pg_context`) and takes the **outermost `api.*` function**, the entry point
  the Edge called. It is exempt when it is on `identity.setup_exempt_functions()` or is an
  `api.admin_*` read. The entry point decides: a gated command stays gated even if it calls an
  exempt one. (A per-function `set` of a custom setting would be simpler, but it needs superuser
  on Supabase.) The list:
  - the wizard: `my_profile`, `update_profile`, `set_profile_photo`, `prepare_nin_check`,
    `record_nin_check`, `request_nin_review`, `list_banks`, `refresh_banks`,
    `prepare_account_lookup`, `record_account_lookup`, `confirm_payout_account`,
    `list_payout_accounts`, `my_workspaces`, `my_invitations`;
  - joining (`accept_invitation`, `accept_founder_invitation`) through
    `org.require_join_session`, which now uses the PIN-only check;
  - account security: `list_sessions`, `revoke_sessions`, `change_pin`, `security_overview`,
    `authorize_password_change`, `record_password_change`, `record_sign_in`;
  - the platform Admin app's admin-only commands (every `api.admin_*`, plus `activate_tenant`,
    `set_account_status`, `grant_platform_admin`, `revoke_platform_admin`, `outbox_*`,
    `platform_advance_restore`). `decide_nin_review` (leaders and admins) stays gated.
  - Sign-out is Supabase Auth and needs no call. `security_state`, the PIN commands and
    `onboarding_workspace` never used `require_session`.
- pgTAP `220_` pins the exact exempt list, so a new function is gated unless it is added on
  purpose. Suites written before this slice turn the gate off for their own transaction with
  `set local identity.setup_gate = off` (their fixtures predate setup). Only a database session
  of the `postgres` role can do that: API calls arrive through PostgREST (session user
  `authenticator`) and cannot set it. `220_`/`221_` run with the gate on.

## B3. Funds not managed

### Data (`org` schema, private, RLS on; migration `20261009220200`)
`org.funds_exemptions`: `id`, `tenant_id`, `membership_id`, `user_id`, `set_by`, `set_reason`,
`set_at`, `cleared_by`, `cleared_reason`, `cleared_at`.
- At most one open row per membership (partial unique index where `cleared_at` is null).
- Identity and "set" columns are immutable; the "cleared" columns are written once. No delete or
  truncate. The history is the rows themselves.
- `org.funds_not_managed(membership)` → boolean.

### Command `api.set_funds_managed(user, session, membership, target, notManaged, reason, key, req)`
1. `org.require_writer` with **step-up**; the workspace is the actor's **President Team**
   membership in an active network (`authz.require_president`), else `authorization_denied`.
2. The target must be in the workspace's network (else `not_found`, never another network's),
   hold the `director` role and not be ended (`conflict{reason: not_a_director}`), and not belong
   to the actor (`self_target_forbidden`). Reason 3–500 characters.
3. Replay (`identity.replay`, after the checks above) returns the stored result.
4. Exclusive lock `org.funds:<network>:<person>` (postings, holds and pending entries on any of
   the person's memberships in the network take it shared, so the check and any of them are
   serialized).
5. Already in the asked state → returns `{ changed: false }`, no audit.
6. Setting: refused with `conflict{reason: wallet_not_empty}` if any wallet segment from this
   network holds `posted <> 0` or `reserved <> 0`, or a withdrawal (`requested`/`approved`), pocket
   move (`requested`) or entry (`needs_review`) is open for the person in this network.
7. Writes the row (or clears it), bumps `authz_version`, audits `membership.funds_not_managed` /
   `membership.funds_managed` (target `membership`, reason).
8. Returns `{ membershipId, fundsNotManaged, changed }`.

Route: `POST /org/memberships/:id/funds` `{ notManaged, reason, idempotencyKey }` (`X-Membership`).

### Effects
- **Authorization:** in `authz.decide`, the self-service (own-wallet) rows only come from memberships
  whose funds are managed. Capabilities therefore drop `view_own_wallet`, `view_own_financials`,
  `export_own_statement`, `initiate_own_withdrawal`, `manage_own_payout_accounts` and
  `transfer_between_own_pockets` in that workspace, and the Blueprint 21 navigation hides those
  pages. Leadership rows are untouched.
- **Income and money targets:** `finance.target_eligible` is false for an exempted membership, so
  income, adjustments, withdrawals and pocket moves refuse it (`target_not_eligible`) and the
  income member search leaves it out.
- **Ledger backstop:** a trigger on `ledger.postings` and `ledger.reservations` (member-value
  accounts) takes the shared lock and refuses the row with `conflict{reason: funds_not_managed}`.
  This also covers returned funds and anything added later. Entries waiting for review
  (`finance.entries`) get the same trigger, since they post only later.
- **Reads:** `member_detail` gains `fundsNotManaged`, `actions.funds` (President Team viewing a
  non-ended director that isn't themselves) and `fundsBlocked` (`wallet_not_empty` when setting
  would be refused). `workspaces_json` gains `fundsNotManaged`.
- **Setup:** an exempted director counts as `light`. Clearing the switch makes them `wallet` again,
  so the gate asks for the NIN, the phone and the bank account.

## B4. App changes
- **Gate mapping** (`lib/gate.ts`): `profile_required` → `/onboarding/continue`, keeping `next`. A
  `next` may now also be `/setup` (the founder flow). `pathForGateCode('profile_required')` maps
  error replies the same way, so any page read that meets the gate goes to the wizard.
- **Shell** (`/app`): `/api/session` reports the gate; anything but `ready` leaves for its page with
  `next`. A typed `/app/...` URL therefore lands in the wizard, then back.
- **Wizard** follows `state.setup`:
  - Light: PIN → "Your profile" (first name, last name, photo, rank) → done. Step *n* of 2.
  - Wallet: PIN → NIN → details → profile (photo, phone, rank) → bank → done. Step *n* of 4.
  - The bank step uses `setup.walletMembershipId`.
  - Done → `/onboarding/finish` → `next`, else the wizard's workspace, else the picker.
  - `onboardingIncomplete()` (which said "no" on errors) is removed; the picker relies on the
    backend gate.
- **Founders:** `/founder` → PIN → `/setup` → gate → light wizard (`next=/setup`) → `/setup`.
- **Members page** (`members/[id]`, President Team, director target): a "Funds" row with the
  state ("Managed" / "Not managed"), a "Funds not managed" or "Manage funds again" action and the
  reason + PIN dialog. With money in the wallet the row says why it can't be switched and offers no
  action.
- **Admin app:** treats `profile_required` like `ready` (platform admin calls aren't gated).

## B5. Tests
- **pgTAP `220_setup_gate.sql`:** levels and steps per role (member, team leader, director, World
  Team, President Team, approved founder without a network, admin with nothing); `security_state`
  gate and `setup`; `require_session` refuses with step/level; exempt calls work and the exempt list
  is exact; `app_bootstrap` at `profile_required`; join still works; paused network → light; the
  name rules in `update_profile`.
- **pgTAP `221_funds_not_managed.sql`:** only President Team (director, World Team, other network
  refused); step-up and reason; not a director, self; blocked with posted money, with a hold, with
  an open withdrawal; audit row; idempotent replay and different-payload conflict; no-op; tenant
  isolation; capabilities lose own-wallet rows; income refused (`target_not_eligible`) and the
  ledger trigger refuses a direct posting (`funds_not_managed`); clearing restores the wallet
  level.
- **Unit:** the gate mapping (`profile_required`, `next` with `/setup`), wizard step numbers per
  level, the member page funds state.
- **e2e `setup.e2e.ts`:** a President founder must finish the light setup before `/app` works
  (typed URL); a wallet member who skipped the NIN can't reach `/app` or an `/api` read; an exempted
  director gets the light wizard and no own-money pages; the switch is refused while the wallet
  holds money.

## B6. Deploy (after merge, from fresh `origin/main`)
1. Migrations: check the dev history through the Management API, then push (say which path ran).
2. Deploy the `org`, `identity` and `security` functions (new error code and routes). No new
   secrets.
3. Build and deploy the app Worker and the admin Worker.
4. Expect existing dev users without a finished setup to land in the wizard on their next visit.

## Open for owner
1. **Founder light setup before network naming** (B0). The alternative (after payment) would
   interrupt the Paystack return; say if you want it moved.
2. **What blocks the switch:** money or open operations from any of the person's memberships in
   this network, not just the director membership. Narrower is possible.
3. **Returned funds** for an exempted director are refused until the switch is cleared.
4. **Statements:** an exempted director's earlier history is still in their Personal view, but
   statement export is off in that workspace with the other own-wallet pages.
5. **Waiting for a NIN review** keeps a wallet member in the wizard (W-02 as written). Leaders
   who are waiting can't work until a reviewer decides.
6. **Self-switch:** a President Team member can't switch their own director membership; another
   President Team member must.
