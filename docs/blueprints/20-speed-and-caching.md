# Blueprint 20 — Speed, caching and infra (slice 20)

Status: **owner decisions 2026-10-10; approved 2026-10-10; built in slice 20.**

Contract: frontend plan decision 36a (device cache) and §5.9 (no-store), 02 W-07 (Home), W-25
(PWA). Builds on Blueprints 01 (sessions, PIN gate), 04/09 (ledger reads), 17 (brand) and 18
(Admin app). Migrations `2026100920xxxx`; pgTAP `200_`–`209_`. No new screens.

### Why it is slow (audit 2026-10-10)
- **Distance.** The Worker runs at the user's nearest Cloudflare location (often Lagos), while
  Supabase is in eu-west-2. Every Edge call is a full round trip to London.
- **Waterfalls.** Opening the app runs `/api/session`, which makes 5 Edge calls in a row
  (state → profile → workspaces → capabilities → brand). Home's 4 calls only start after it, so a
  cold Home is about 9 calls in about 8 sequential steps. Admin pages re-run `requireAdmin` on every
  click (`await parent()`), which is 3 calls in a row.
- **Every read writes.** `identity.require_session` updates `session_pin_proofs.last_activity_at`
  on every call, so calls that run in parallel queue behind each other on that row's lock.
- **Unbounded reads.** `ledger.activity` aggregates the whole wallet history before it applies the
  page cursor, even for Home's `limit 5`.
- **No reuse.** The device cache is read only when offline, and pages keep no data in memory.
- **Bytes.**
  - The first visit precaches about 4.6 MB, admin chunks included.
  - `/root`, `/auth-bg` and `/icons` have no Cache-Control.
  - Lexend isn't preloaded.
  - The auth backgrounds and grain textures are heavy (587 KB and 169 KB).
- **Checked and fine.** Dev signs tokens with ES256, so `getClaims` verifies locally; JWKS is
  cached per isolate. `/_app/immutable/*` is already cached for a year.

### Owner decisions (2026-10-10)
- **Scope.** Every page is slow, so the fix is global. It targets Nigerian mobile data and office
  desktops equally. In scope: free Cloudflare config and Supabase tuning. Out of scope: paid
  upgrades and the production region.
- **Short private caching (amends 36a and §5.9).** Signed-in pages open from cached data, balances
  included, then refresh in the background. Writes clear the affected data and always go to the
  server. Server responses stay `no-store`, so only the app's own device cache holds data.
- **Cache guard.** The server sets a readable, non-secret `ew_who` cookie: a keyed hash of the
  user id and membership id. The client shows cached data only when the cache scope's hash matches
  it. Sign-out and workspace changes rewrite or clear it. Capabilities (the nav) are not cached.
- **New reads.** `api.app_bootstrap` and `api.home_view` are added, behind new BFF routes with the
  existing envelopes and error codes. The old endpoints stay.
- **Idle timer.** `last_activity_at` is written at most once every **30 s**. Step-up still uses
  `verified_at`, which doesn't change.
- **Authorization rewrite deferred.** Set-based `visible_segments` and `my_capabilities` move to
  a later slice (after slice 25 since the 2026-10-10 feedback round), with an equivalence suite
  against `authz.decide`.
- **Measuring.** The owner runs the speed test after deploy (2026-10-10). The synthetic test
  account has no workspace yet, so no signed-in baseline was taken before the change.

---

## B0. Baseline and targets

`frontend/scripts/perf-probe.ts` (new; Node, not shipped):
- Signs in with `PERF_TEST_*` (repo-root `.env`) and runs each scenario 5 times cold (new
  context, no service worker). The account needs a workspace with synthetic data.
- Records TTFB, the per-endpoint server timing and the time until the first usable view.
- Prints a Markdown report. Usage is at the top of the script.
- Scenarios: app open → Home, Home → History → Home, Wallets, Settings, and one admin page (if
  the account is an admin; otherwise local only).

| Measure | Target |
|---|---|
| Cold app open → Home usable (desktop, from Lagos) | ≤ 50% of baseline |
| Warm Home (cached) shown | < 150 ms, fresh data < 1 s |
| Sequential Edge steps, cold Home | ≤ 2 (from about 8) |
| First-visit bytes (precache) | ≤ 1.5 MB (from about 4.6 MB) |
| `ledger.activity` limit 5 on a 5,000-entry synthetic wallet (local) | flat in history size |

## B1. Worker placement (both Workers)
- Add `"placement": { "mode": "smart" }` to `wrangler.jsonc` and `wrangler.admin.jsonc`.
- If Smart Placement doesn't settle near London within the probe (it needs traffic), use an
  explicit region hint (`"placement": { "region": "aws:eu-west-2" }`) instead. The B0 numbers
  decide.
- Assets stay served before the Worker (`run_worker_first` remains false).

## B2. Session touch at most every 30 s (migration `20261009200100`)
- Replace `identity.require_session` (same signature, same failures):
  - Read `verified_at` with a plain select.
  - Update only `where session_id = p_session_id and last_activity_at < now() - interval '30
    seconds'`.
- Idle-timeout checks read `last_activity_at` as before. They become up to 30 s looser.
- pgTAP `200_session_touch.sql`:
  - Two reads 1 s apart leave `last_activity_at` unchanged.
  - A read after it is 31 s old updates it.
  - Step-up and idle lockout behave as before.

## B3. Activity: page first (migration `20261009200200`)
- Rewrite `ledger.activity` so it first takes `limit + 1` rows from `ledger.transactions` by
  `(wallet_id, posted_at desc, id desc)` after the cursor (the existing `transactions_wallet_idx`).
- Joins, `reversed_by` and amounts are then computed for that page only.
- `months` becomes its own grouped query, and only when the caller asks for it (History). Home
  never does.
- Output shape, ordering, cursor format and amounts stay **identical**.
- As built: `ledger.activity` gains `p_months boolean default true` (every existing caller keeps its
  output). With `false` (Home) it returns `months: []` and no `total`. With `true` (History),
  `months` and `total` still come from the whole filtered set, as before. The page itself is
  `ledger.activity_rows`, a one-shot dynamic statement, so the limit is always planned as a
  constant.
- pgTAP `201_activity_equivalence.sql`: on a synthetic multi-currency wallet (reversals,
  conversions, ties on `posted_at`), the old and new functions return the same rows for every
  page and filter.

## B4. Hot-path indexes (migration `20261009200300`)
- Composite FK indexes `(tenant_id, office_id)` on:
  - `ledger.transactions`, `finance.entries`, `finance.income_records`, `finance.withdrawals`,
    `finance.pocket_transfers` and `org.memberships`;
  - `org.offices (tenant_id, parent_office_id)`;
  - `exports.files` (tenant, wallet, member), `billing.owners (user_id)` and
    `nin_reviews (membership_id)`.
- The exact list is confirmed against the advisor output when built.
- Additive only. Large tables use `create index concurrently`, in their own migration files.
  As built: plain `create index if not exists` (the dev tables are small, and the CLI runs a file
  as one batch, where `concurrently` is refused). `exports.files (tenant_id)` is covered by
  `(tenant_id, scope_office_id)`.
- pgTAP `202_indexes.sql` checks that the indexes exist.

## B5. `api.app_bootstrap` and `api.home_view` (migration `20261009200400`)
- `api.app_bootstrap(p_user_id, p_session_id, p_membership_id uuid null)` runs `require_session`
  once and returns `{ state, profile, workspace, capabilities, brand }`.
  - The shapes match the existing pieces.
  - `profile` and `brand` stay best-effort (null on failure, as today).
  - It returns `workspace_invalid` exactly when `/api/session` does now.
- `api.home_view(p_user_id, p_session_id, p_membership_id)` resolves the tenant from the
  membership server-side and returns `{ network, activity (last 5), split }`, the existing
  `HomeView`. It reuses the B3 activity and `wallet_networks(p_tenant_id)` for one network only.
- Both are read-only `security definer` with `search_path = ''`, and both validate the membership
  belongs to the user.
- Edge: new routes on the existing functions: `GET /security/bootstrap` (X-Membership optional)
  and `GET /ledger/home` (X-Membership required). As built, input checks and a light output check
  sit in each handler, like the other routes. The response schemas are in the app contract
  (`AppBootstrap` in `contract/security.ts`, `HomeView`).
- BFF:
  - `/api/session` and `/api/home` call these, so the client contract is unchanged.
  - The old multi-call paths are deleted.
  - `/api/activity` and other money reads stop refetching the workspace list. They pass the
    membership id, and the backend resolves the tenant. As built: `api.my_wallet` and
    `api.my_activity` take an optional `p_membership_id` (sent as X-Membership on `/me/wallet` and
    `/me/activity`), resolved through `org.own_membership`. The managed reads already resolve the
    tenant from the membership.
- pgTAP `203_bootstrap.sql` and `204_home_view.sql` check results equal to the separate calls,
  plus the failures (wrong user, revoked membership, gate not ready).

## B6. Show cached data, then refresh (client)
- **`ew_who` cookie.**
  - Set by the BFF on every successful `/api/session` and on workspace select.
  - Value: `HMAC(APP_SERVER_SECRET, uid + ':' + membershipId)`, truncated to 16 bytes and
    base64url-encoded. `SameSite=Lax`, `Secure`, *not* HttpOnly, same lifetime as the session.
  - Cleared on sign-out, workspace clear and `workspace_invalid`.
  - It holds no ids and isn't an authenticator: the server never trusts it.
- **Device cache.**
  - The scope gains a `who` field. `readCache` returns an entry only if the entry's `who` equals
    the current cookie value.
  - Kinds `history`, `offices` and `members` start being used, joined by `wallets` and
    `settings` (read summaries only; the forbidden-field guard is unchanged).
  - Max age stays 7 days.
- **Flow.**
  - The shell and the page call `/api/session` and the page's read **at the same time**.
  - The page renders memory data first, then device-cache data with the existing quiet label
    (`staleLabel`, "Updating…" while online).
  - It swaps in the fresh response when it arrives.
  - If the session reply names a different user or workspace, all shown data is dropped.
- **Invalidation.**
  - Each successful command clears the kinds it affects (income → balances and history;
    withdrawal → balances and history; office/member changes → offices and members; settings →
    settings) and refetches them.
  - `command-attempt` gets one `invalidates` list per command.
- **Unchanged.** Server responses stay `no-store`. Commands are never answered from cache and are
  never queued offline.
- Unit tests:
  - A `who` mismatch returns nothing.
  - Invalidation per command.
  - The forbidden-field guard on the new kinds.
- e2e:
  - The second Home visit renders before the network responds (route delay).
  - Sign out, then sign in as someone else: no flash of the old data.
  - Recording income updates the cached balance.

## B7. Admin waterfall
- Console pages stop calling `await parent()` for the admin check. The layout's `requireAdmin`
  result goes into `event.locals` once per request (memoised), and pages read it from there.
- Kit then runs only the page load on navigation.
- `data-sveltekit-preload-data="tap"` on the admin root, so hovering stops triggering loads.
- e2e: the admin gate still blocks a non-admin on every page.

## B8. Bytes and static caching
- **Service worker.** The member precache excludes admin route chunks (filtered by the build
  manifest's route ids) and lazy-loaded route chunks other than the shell's. The admin surface
  registers no service worker.
- **`static/_headers`.** `/root/*`, `/auth-bg/*` and `/icons/*` get `Cache-Control: public,
  max-age=86400, stale-while-revalidate=604800`. The files aren't hashed, so this stays one day.
- **Fonts.** `<link rel="preload" as="font" type="font/woff2" crossorigin>` for Lexend latin
  (normal weights used by the shell).
- **Images.**
  - Re-encode `auth-bg/desktop-*.jpg` to AVIF with a WebP fallback through `image-set()`.
  - Replace `grain-256.png` with a WebP tile of 128 px or less.
  - **Root stays exactly as it is** (owner 2026-10-10): no re-encoding, format change or resizing
    of `static/root`, and no changes to `RootImage.svelte`. Root files only gain the cache
    header above.

## Not in this slice
- Set-based authorization (after slice 25; see `docs/member-build-plan.md`).
- Paid add-ons.
- The production region.
- Caching any Edge or HTTP response at Cloudflare.
- Early Hints (low value: the shell is served from assets or the service worker).

## Checks and rollout
- `verify-database.sh`, `deno task check`, `pnpm check`, `pnpm lint`, `pnpm test:unit` and
  `e2e-local.sh`.
- Deploy: migrations, then `security` and `ledger` functions, then both Workers.
- The owner runs the speed test after deploy.
