# Blueprint 21 — Owner feedback fixes (slice 21)

Status: **owner feedback 2026-10-10; built in slice 21.**

Contract: `docs/member-build-plan.md` "Owner feedback round (2026-10-10)". Builds on Blueprints 01
(PIN gate), 06 (profile photo), 10 (account), 13 (emails), 17 (support chat, brand), 19 (founder
ranks) and 20 (caching). No migrations, no new Edge routes, no new screens.

### Owner decisions (2026-10-10)
- Ranks are shown **number first** everywhere ("4 Ruby Director"). Display only: stored values
  keep their form ("Ruby Director 4", founder key `ruby_director_4`).
- The **President Team must not see modules it can't use.** It holds no wallet (D-01; A-03 gives
  it none of the own-wallet permissions).
- The slices after this one: 22 setup by role and "funds not managed", 23 speed II, 24 haptic
  wheel pickers, 25 navigation redesign, then set-based authorization reads.

---

## 1. Password show/hide
- **Cause.** `Field.svelte` set `type` and a one-way `value` in the same template effect. After
  hydration Svelte clears its cached `value`, so the first toggle re-ran `set_value('')` and wiped
  what was typed.
- **Fix.** The input binds to a writable `$derived` of the `value` prop: typing overrides it, a new
  prop value from the parent still replaces it, and re-renders never write it back.
- `PasswordRow.svelte` has no `value` and was not affected.

## 2. Invite → Home (President Team)
- **Cause.** Every Invite entry is a plain link and works. The jump to Home happens when the page
  is fully reloaded with a lapsed PIN (15-minute idle lock), for example after a deploy, when
  SvelteKit reloads on navigation. The shell sent the person to `/pin` without `next`. `/pin` then
  went to `/workspaces`, which auto-opens `/app`. A page's own read that met `pin_required` showed
  an error instead.
- **Fix.**
  - Every gate redirect from the shell carries `?next=<path>`: sign-in, PIN, workspace picker and
    `workspace_invalid`.
  - `/pin`, `/sign-in` and `/workspaces` (auto-open, remembered workspace and the picker's choice)
    honour a `next` only when it is a same-origin `/app` path (`safeAppNext`).
  - `followGate` adds `next` for every gate. Invitations uses it for its own read.

## 3. Wallet-less memberships
- The own-money pages follow the own-wallet permissions from the capabilities (no new backend
  flag):

  | Page | Permission |
  |---|---|
  | Payout accounts | `manage_own_payout_accounts` |
  | Withdrawals | `initiate_own_withdrawal` |
  | Statements | `export_own_statement` |
  | Activity | `view_own_financials` |
  | Move money | `transfer_between_own_pockets` |

  - They are hidden in the sidebar, the tab bar, More, Home actions and quick search. Offline or
    before the capabilities load, the role stands in.
- A direct visit shows "Not available for your role" (X03 pattern) with Back and Switch workspace.
- A President Team Home without money says "No wallet in this workspace" and offers Team overview,
  Invite a member and Pockets & split.

## 4. Support chat
- **Cause.** Chatwoot's `setUser` throws unless the user object has `name`, `email` or
  `avatar_url`. We sent only `identifier_hash`, so every press ended in "Chat isn't available".
  - CSP was fine: no violations with the real SDK.
  - The Worker secrets `CHATWOOT_WEBSITE_TOKEN` and `CHATWOOT_HMAC_TOKEN` are set (names checked).
- **Fix.**
  - The contact is named by the UID (still no real name or email).
  - A refused identity no longer stops the panel opening.

## 5. Images
- **Profile photo.**
  - The browser scales it to at most 512 px and re-encodes it (WebP, else JPEG; this drops camera
    and location metadata).
  - The server still checks the type and the 5 MB limit.
  - It is served `private, max-age=86400` at `/api/profile/photo?v=<photoUpdatedAt>`. The session
    view now carries `photoUpdatedAt`, and the shell reloads after a change.
- **Worker headers.** `hooks.server.ts` sets `no-store` only when the route set no Cache-Control,
  so the brand logo's and the photo's own policies survive.
- **Email images.**
  - Root poses are now 312×420 (2× the 156×210 shown), quantized PNG, about 35 KB each (were
    130–210 KB).
  - `hero.jpg` and `mark.png` are optimized, and the hero is progressive.
  - `/email/*` is cached for 30 days.
- **Auth backgrounds.**
  - The mobile JPEGs (and the desktop one) are progressive.
  - The mobile ones gained AVIF and WebP variants through `image-set()`. They are not precached,
    because the app's heroes use the JPEG.
- `mark.svg` images have width and height.

## 6. Readable text (audit of every screen, 390/1440 px, light/dark)
- Dialogs, the quick-search palette and centred Root images are centred with auto margins, not
  `translate(-50%)`. That transform put text on half pixels.
- **Found in the screenshots and fixed:**
  - Raw permission keys ("manage team settings", "request restore") in Roles & access.
  - Bullets beside list rows (Activity, Member wallets): lists now never show bullets.
  - The Member wallets column header overlapping on phones.
  - "Read-only" breaking in two on the audit hero.
  - The underlined "Invite a member" on Members.
  - The "Email" label breaking mid-word on Profile.
  - The Profile identity line running into the bright felt on desktop, and into Root on phones.
  - Account pages and Support touching the screen edges on phones.
  - A transaction reference split mid-code on Home.
  - The apply form's rank placeholder cut off.
  - Pale theme-switch text over the light auth background.
  - All 10 px text raised to 11 px.

## 7. Rank labels
- `rankLabel()` in `labels.ts` is used on:
  - the apply form (options, lead, hint);
  - Admin founder applications;
  - the onboarding rank wheel;
  - the account page.
- No email shows a rank.

## 8. Sidebar switcher alignment
- One `--shell-header` (64 px, border-box) drives both the top bar and the switcher block. The
  switcher block uses whole-pixel padding (6 + 52 + 5 + 1 px border).
- The e2e checks that both bottom borders sit on the same y at 1024, 1280, 1440 and 1920 px.

## Tests
- Unit tests:
  - `rankLabel`;
  - `safeAppNext` / `withNext`;
  - own-money routes;
  - photo sizing and URL;
  - Chatwoot `startChat` against the SDK's own checks;
  - permission labels.
- e2e `president.e2e.ts`:
  - typing, then show/hide keeps the password;
  - a President Team member reaches Invitations from the sidebar, Team, Members, quick search and
    More, and after a reload;
  - no own-money entries; a direct visit says not available;
  - a lapsed PIN returns to Invitations after a full load and after an in-app tap;
  - the header lines align.
