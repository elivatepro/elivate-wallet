# Blueprint 23 — Speed II: cache every page, instant taps, precache, page swap (slice 23)

Status: **owner decisions 2026-10-11 (trade-offs accepted); built in slice 23.**

Contract: `docs/member-build-plan.md` "Speed II (2026-10-11)", frontend plan decision 36a (device
cache) as amended by Blueprint 20, 02 W-25 (PWA). Builds on Blueprint 20 (B6 `CachedRead`, the
`ew_who` guard, invalidation; B8 service worker) and 21/22 (gates, `next`). No migrations, no Edge
changes, no new screens. Slice 25 redesigns the tab bar and sidebar (Paper "Navigation v5 —
DRAFT (2026-10-10)"), so the nav changes here are behaviour only: press states and the current
item following the tap.

### Why taps still feel slow (audit 2026-10-11)
- **Most pages had no cache.** Blueprint 20 cached Home, Activity, Team, Wallets, Offices,
  Members and Settings. Every other page (about 30) started empty and waited for its read, even
  on a revisit a second later.
- **Code on first tap.** Only the shell's chunks are precached. The first tap on any other page
  waits for its route chunk (one more round trip) before anything changes.
- **The nav waits for the page.** The tab bar and sidebar take `aria-current` from `page.url`,
  which only changes once the new page's code (and any route data) has loaded.
- **Extra reads.** Every move between write pages read `/api/operations` again.
- **Switch workspace** was a full document load of the picker.

### Owner decisions (2026-10-11, binding; trade-offs accepted)
1. **Cache every page (stale-while-revalidate).** Every `/app` list and detail page shows its last
   saved copy at once (memory, else device cache), with the "Updating…" note, then refreshes.
   The Blueprint 20 rules hold: per user and workspace scope, the `ew_who` guard, the
   forbidden-field guard, invalidation after commands, the "Updating…" note, sign-out purge.
   Money actions always ask the server; data may be seconds old until the refresh lands.
2. **Instant tap feedback.** Tab bar, sidebar and More rows show a pressed state, and the current
   item follows `navigating.to` at once. A light page frame shows while a page is on its way.
3. **Download all screens upfront.** Once the shell is ready and the browser is idle, the code of
   every `/app` page is fetched (about 1.8 MB once).
4. **Page swap.** A short (≤ 200 ms) fade and lift of the page area with `onNavigate` and
   `document.startViewTransition`, feature-detected, off under `prefers-reduced-motion`, never
   delaying the navigation.

---

## B0. Measuring

`frontend/tests/e2e/speed.e2e.ts` (skipped unless `E2E_SPEED=1`; local stack, synthetic data):
- A founder's network with one member and ₦1,000.00 of income. Each run: a new browser context
  (no device cache; service worker blocked, so every fetch is throttled), signed in as the
  President.
- Throttled mobile profile: 390 × 844 touch viewport, 150 ms RTT, 1.6 Mbps down, CPU × 4, plus
  300 ms on every `/api` read for the Worker → Supabase (London) trip.
- Home is reloaded under throttling and left idle for 12 s. Then each route is tapped from More
  twice: **cold** (first visit) and **warm** (revisit). Timed in the page with
  `requestAnimationFrame`: `nav` until the URL changed, `paint` until the route's data marker is
  on screen.
- `E2E_SPEED=1 E2E_SPEED_OUT=/tmp/speed.json scripts/e2e-local.sh speed.e2e.ts`. The same spec ran
  against `origin/main` (before) and this branch (after), 3 runs each; medians below. Raw numbers:
  `docs/perf/2026-10-11-speed-ii.md`.

| Route | Visit | Page swap (ms) | Data on screen (ms) |
|---|---|---|---|
| /app/team | cold | 239 → **54** | 712 → **513** |
| /app/members | cold | 378 → **60** | 851 → **520** |
| /app/offices | cold | 268 → **59** | 745 → **515** |
| /app/audit | cold | 202 → **59** | 670 → **510** |
| /app/invitations | cold | 382 → **61** | 851 → **515** |
| /app/team | warm | 19 → **52** | 19 → **52** |
| /app/members | warm | 33 → **44** | 33 → **44** |
| /app/offices | warm | 20 → **55** | 20 → **55** |
| /app/audit | warm | 21 → **60** | 487 → **60** |
| /app/invitations | warm | 22 → **58** | 487 → **58** |

- Cold taps change the page in about 55–60 ms (was 200–380 ms); data shows once its round trip
  lands (about 510–520 ms here, was 670–850 ms).
- Revisits of pages Blueprint 20 didn't cache: 487 ms → about 60 ms.
- Revisits of pages that were already cached are about 25–35 ms slower (one or two frames at
  CPU × 4): the page swap captures the old page before drawing the new one. Loading itself is
  not delayed, but the new page is drawn that much later. **Open for the owner:** keep the swap
  as built, or turn it off (restores 20–33 ms).
- The tapped tab turns current on the tap instead of after the page swap.

## B1. Every page opens from its saved copy
- **`cachedPage(shell, { kind, load, part?, keep?, cacheable?, enabled? })`**
  (`page-cache.svelte.ts`): Blueprint 20's `CachedRead` steps for a whole page. It shows the
  memory or device copy on mount, reads at the same time as `/api/session` (and again when back
  online, or when `part` changes), keeps the fresh reply once the session names the scope, drops
  what belongs to another person or workspace, refetches when a command invalidates the kind,
  and clears the copy on a 403 or 404. When a refresh fails with a copy shown, the copy stays
  ("Last updated HH:MM").
- **`MorePages`**: "Show more" on top of a cached first page. Only the first page is kept; later
  pages are dropped when the first page is replaced.
- **`part`**: a record id (lower case) or a fixed sub-key. With `part`, undefined means "no
  record yet": nothing is shown or kept. At most 20 records of one family are kept per kind and
  scope (oldest dropped first); fixed sub-keys are never pushed out.
- **`keep`**: the projection kept on the device; the page still shows the full fresh reply.
- **New kinds** (all under the `ew_who` guard, 7-day maximum age, purged on sign-out):

  | Kind | Pages (part) | Kept projection |
  |---|---|---|
  | `withdrawals` | Withdrawals (filter), New withdrawal (`sources`) | list: `payout.revisions` → null |
  | `payout-accounts` | Payout accounts, Add (`banks`) | masked number rebuilt from `accountLast4` |
  | `notifications` | Notifications, bell (`unread`, `all`) | first page |
  | `queue` | Withdrawal queue (tab), Returned funds (`returns`, `return-<id>`) | `payout.revisions` → null |
  | `transfers` | Transfers (tab) | — |
  | `evidence` | Evidence review (tab) | revisions → null, entry `evidence` → [] |
  | `statements` | Statements | — |
  | `reports` | Reports, Export (`overview-<currency>-<period>`, `files`) | preset periods only |
  | `invitations` | Invitations (`status-all` only) | — |
  | `split` | Pockets & split, Move (`move-choices`, `move-open`) | — |
  | `audit` | Audit log | first page |
  | `billing` | Billing, payment (`pay-<id>`) | `authorizationUrl` removed |
  | `nin-reviews` | NIN reviews | `ninLast4` only |
  | `access` | Roles & access | — |
  | `account` | Profile & security | phone masked, no device sessions or sign-ins |
  | `entries` | Income, conversion, adjustment pickers (`*-targets`, `seg-<id>`), reversal lookup (`reversal-<ref>`) | default lists only, no searches |
  | `vault` | Backup vault, Request a restore | — |
  | `offices`, `members`, `history` (existing) | Office and member detail (`<id>`), Presidents (`presidents`), transaction detail (`<id>`) | — |

- **Not cached:** Devices & sessions (each row's `sessionId` signs a device out), the queue's and
  evidence review's open-case detail (receipts, read facts, reveal state), searches and filtered
  views (shown, never kept), custom report ranges, a Paystack return (`?reference`).
- **Forbidden-field guard (amended).** Still refuses account numbers, NIN, tokens, secrets,
  passwords, PINs, evidence, receipts, authorization, cookies and session ids, and now also
  `recipientAccount` (receipt facts) and `uploadUrl` / `downloadUrl` / `signedUrl`. Keys ending in
  `Masked` or `Last4` pass only when they show 4 digits or fewer. A forbidden key whose value is
  empty (`null` or `[]`) holds nothing and passes, and so does an ISO timestamp under a name
  ending in `At` (e.g. `passwordChangedAt`).
- **Writes made on a saved copy.** Forms prefilled from a read are read-only until the fresh copy
  lands (settings, team details, roles & access, restore request, member funds switch, profile
  Edit). Money forms whose limits come from a read (new withdrawal, move money, conversion,
  adjustment, income review, reversal, returned funds) wait for fresh data before review. The
  split editor keeps the version its edits were made on, so a save over a newer split is the
  existing conflict. Commands are unchanged and never answered from the cache.
- **Invalidation.** Money commands clear every money kind (balances, history, wallets, offices,
  withdrawals, queue, transfers, evidence, split, entries, reports, statements) and the audit log.
  A page showing an invalidated kind labels what it shows as a saved copy ("Updating…") until
  the replacement lands, so actions that need fresh data wait for it. Org commands
  clear offices, members, access, invitations and audit; NIN decisions also clear `nin-reviews`;
  settings clear settings and vault; backups and restores clear vault; billing, notifications,
  statements/exports and account commands clear their own kinds. Lookups, revealing a payout
  account and support stay reads. `sendAccountCommand` now invalidates by path too.

## B2. Instant tap feedback
- `navPath = navigating.to?.url.pathname ?? page.url.pathname` drives `aria-current` (and the
  icon weight) in the sidebar and tab bar, and the top bar title.
- `:active` press states on sidebar items, tabs and More rows; tap highlight off.
- If the tapped page isn't ready within 80 ms, the page area shows `PageFrame` (the page title
  and two placeholders, `data-testid="page-frame"`). Form posts and same-page changes don't.
- `data-sveltekit-preload-data="hover"` stays: SvelteKit already starts on `touchstart` on touch
  screens, and `/app` pages read their data in the page, not in `load`.

## B3. Every screen's code, once idle
- `warmRoutes(preloadCode)` (`#lib/client/warm-routes.ts`) runs once per page load after the shell
  is ready: one `preloadCode(routeId)` per idle period for every `/app` route and the workspace
  picker. Skipped under Save-Data; failures are ignored. A unit test keeps the list equal to the
  route files.
- The service worker's runtime cache keeps every hashed file fetched this way, so later cold
  starts have them without the network. Install still precaches the shell only (quick). Each
  version has its own cache; activating a new one deletes the old (unchanged). The update banner
  still asks the waiting worker to take over.

## B4. Page swap
- `onNavigate` starts `document.startViewTransition` when the path changes, the browser has it,
  and motion is welcome. `onNavigate` runs right before the swap, so loading is never delayed.
- Only the page area takes part: `<html data-page-swap>` gives `.content` the transition name for
  the swap only, so the page keeps its normal stacking the rest of the time. Root has no
  animation. Old page fades out in 90 ms; the new one fades and lifts 6 px in 180 ms.

## B5. Fewer round trips
- `/api/operations` (kill switches) is read at most once a minute instead of on every move
  between write pages. The database still refuses a stopped operation at once.
- **Switch workspace** opens the picker inside the app (`goto`, code preloaded). Its server load
  is the round trip it always needed (the workspace list and invitations are read and checked on
  the server, and choosing one sets the HttpOnly cookies through the form). A fully client-side
  switch would need a new picker screen and a JSON select route, so it is left for slice 25's
  navigation work.

## Tests
- Unit: `cachedPage` (cached then fresh, failed refresh keeps the copy, `keep` projections, not
  cacheable views, one copy per record, a reply for another workspace dropped, invalidation
  refetch), `MorePages`, the masked and new forbidden fields per kind, record trimming, path
  invalidation for every new kind, `warmRoutes` (list equals the route files, once per load,
  Save-Data).
- e2e `cache.e2e.ts`: the audit log after a reload and Invitations after an in-app tap render
  before their reads answer, with "Updating…"; the shell fetches every screen's code once idle; on
  a phone, a tapped tab is current and the page frame shows before the page's code arrives.

## Checks and rollout
- `pnpm check`, `pnpm lint`, `pnpm test:unit`, `e2e-local.sh` (backend untouched).
- Deploy: the app Worker only. The owner runs the speed test after deploy.
