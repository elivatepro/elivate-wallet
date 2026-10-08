# Frontend foundation plan — Elivate Wallet 2.0

Status: **Phase 1 draft for owner review (2026-10-08).** Nothing is scaffolded. No package manifest, app code, Supabase or Cloudflare change is part of this document. Contract: P-04, P-06, P-09 (U-10, U-12), W-00, W-01, W-22, W-25, A-01, A-02, A-05, F-03, T-01, T-02. Wire contracts come from `backend/supabase/functions/**` and `backend/supabase/migrations/**` at `main` = `c648abd`.

Sources used: the product pack, `design-backlog.md`, Blueprints 01–02, the backend code and tests in this repo, and official package registries and docs (listed in §10). The legacy frontend and Paper were not opened. Visual decisions below rely only on the written P-06 tokens; anything that needs the Paper file is listed as a question.

---

## 1. Stack (settled, not reopened)

- **Svelte + TypeScript + Effect** (P-01, P-04, T-02). Effect is the TypeScript library (`effect` package), not Svelte's `$effect` rune.
- Svelte owns presentation, form editing and local view state. Effect owns the service layer: dependency injection (Layers), runtime validation (Schema), typed expected failures, timeouts, cancellation, safe read retries, redacted observability.
- Supabase Auth authenticates. PostgreSQL authorizes and owns financial truth. The frontend presents trusted reads and dispatches approved commands through the `security` and `org` Edge Functions. It never calls `api.*` or any private schema directly.

Everything else in this document is a **proposal** for U-10 and U-12. Section 9 lists every choice that needs your decision.

---

## 2. U-10 proposals: runtime, rendering, hosting, tooling

Versions were checked on **2026-10-08** against the npm registry and nodejs.org.

| Item | Current (2026-10-08) | Proposal | Why |
|---|---|---|---|
| App framework | `@sveltejs/kit` **3.0.1** (3.0.0 released 2026-10-01). Last 2.x: 2.70.3 | **SvelteKit 3.0.x** | Greenfield, so starting on 2.x means an immediate major migration. Kit 3 requires Node ≥ 22.17, TypeScript 6, Svelte ≥ 5.57.1, Vite 8 and `vite-plugin-svelte` 7. Kit config moves into `vite.config` (no `svelte.config.js`) and `$lib` becomes `#lib` (`package.json` `imports`). Remote functions are still experimental in Kit 3, so the plan does not use them. |
| Svelte | `svelte` **5.57.2** | 5.57.x (runes) | Required by Kit 3. |
| Effect | `effect` **4.0.2** (4.0.0 released 2026-10-01; last 3.x: 3.22.2) | **Effect 4.0.x** | Effect 4 is announced as stable with long-term support. Schema ships in the core package (`effect/Schema`). The HTTP modules (`effect/http`) are marked `@stability unstable` in 4.0.2, so the transport is our own thin `fetch` wrapper behind an Effect service (§5.2), not the unstable HTTP client. |
| Rendering | — | **SSR with a server-held session (backend-for-frontend, "BFF")**, form actions with progressive enhancement | See §2.1. |
| Adapter | `@sveltejs/adapter-cloudflare` **8.0.0** (peer `@sveltejs/kit ^3`, `wrangler ^4.118`) | **adapter-cloudflare** | Cloudflare already hosts DNS and email for `elivatewallet.com`. It runs SvelteKit's server on Workers. |
| Hosting | `wrangler` **4.148.0** | **Cloudflare Workers with static assets** at `app.elivatewallet.com` | Cloudflare's SvelteKit guide targets Workers with Workers Assets (`wrangler.jsonc`, `nodejs_compat`). No separate Node host to run. |
| PWA | `@vite-pwa/sveltekit` 1.1.0 supports only Kit `^1.3.1 \|\| ^2.0.1` | **SvelteKit's built-in service worker** plus a hand-written web manifest | No plugin dependency that lags Kit 3. Simpler control over what is cached (§2.2). |
| Package manager | `pnpm` **12.10.1** | **pnpm**, pinned with the `packageManager` field | Strict dependency isolation, fast CI cache, lockfile review. |
| Node (dev/CI/build) | Node **24.21.0 LTS "Krypton"** (2026-09-07) | **Node 24 LTS**, pinned in `.nvmrc` / `engines` | Meets Kit 3 (≥ 22.17), Vite 8 and Vitest 5. Production runs on the Workers runtime, not Node. |
| TypeScript | `typescript` 7.0.2 is latest, 6.0.3 is latest 6.x | **TypeScript 6.0.x** | Kit 3 peers `typescript ^6`. `svelte-check` 4.7.6 peers `^5 \|\| ^6`, so TS 7 is not supported yet. |
| Type checking | `svelte-check` **4.7.6** | svelte-check in CI | — |
| Unit/service tests | `vitest` **5.0.3** | **Vitest**: Effect services, schemas and error mapping in Node mode, components in browser mode (`@vitest/browser-playwright`) | — |
| Component tests | `@testing-library/svelte` 5.4.2 | Optional, only where browser-mode Vitest is awkward | — |
| End-to-end | `@playwright/test` **1.64.0**, `@axe-core/playwright` **4.13.0** | **Playwright** against local Supabase, plus axe checks on every auth/gate route at 320, 390 and 1440 px, dark and light | W-00/P-06 acceptance: 320 px, keyboard, both themes. |
| Supabase client | `@supabase/supabase-js` **2.117.3** (same pin as the Edge Functions), `@supabase/ssr` **0.12.7** | supabase-js plus `@supabase/ssr`, **server-side only** | Session cookies are HttpOnly (§7.4). |

### 2.1 SSR vs SPA, given auth tokens and financial data

| | A. SSR + server-held session (BFF) | B. Static SPA (`adapter-static`, `ssr = false`) |
|---|---|---|
| Where Supabase tokens live | HttpOnly, Secure, SameSite=Lax cookies. Browser JavaScript never sees the access or refresh token. | Browser storage (localStorage/sessionStorage) via supabase-js. Readable by any script that runs on the origin. |
| W-01 / W-22 "native POST even before JavaScript hydration" | Met: SvelteKit form actions work without JS; `use:enhance` upgrades them. | Not met: forms need JS. |
| Who calls the Edge Functions | The Worker, server-to-server. **CORS is not involved.** | The browser, cross-origin. Needs `CORS_ORIGINS` for every origin, and the platform `verify_jwt` 401s arrive outside the envelope. |
| Supabase Auth rate limits | **Risk**: Auth limits sign-in/sign-up by IP, so every user would share the Worker egress IPs. Needs the spike in §8.6. | Each user has their own IP bucket. |
| Financial data in HTML | Server-rendered pages contain data, so every authenticated response must be `Cache-Control: no-store` (set centrally in `hooks.server`). | Data only travels as JSON. |
| Native mobile later (W-25) | Unaffected. The Edge Functions still accept a bearer token directly. | Same. |

**Recommendation: A**, the server-held session. It is the only option that meets the native-POST requirement and keeps bearer tokens out of the browser. It is **conditional on the Auth rate-limit spike** (§8.6). If the spike shows hosted Supabase cannot tell users apart behind the Worker and the limits cannot be raised safely, fall back to B. B keeps the same Effect contract layer, uses PKCE and sessionStorage, adds a strict CSP, and records the native-POST gap as an explicit contract exception for owner approval.

Inside A, Svelte pages call **form actions** for every command and **server `load` functions** for every read. The browser never receives an Edge Function URL or a Supabase token. The Worker adds the bearer token and `X-Membership` header, validates the response with Effect Schema, and returns only the validated `data` (or a typed failure) to the page.

### 2.2 PWA plan (W-25)

- Web app manifest: name, short name, icons from the coral Elivate mark (`Assets/elivate-logo-icon.svg` → 192/512/maskable PNGs), `theme_color` and `background_color` = dark canvas `#111314`, `display: standalone`.
- Service worker (`src/service-worker.ts`, bundled as a module in Kit 3) **precaches only hashed build assets, fonts and one static offline page**. It never caches HTML documents of authenticated routes, form-action responses, or anything from Supabase. Navigation requests go network-first, falling back to the offline page ("You're offline. Wallet data needs a connection.") with its own Root pose (P-06).
- No offline command queue (W-00, W-25). Forms are disabled while offline.
- Update detection: Kit's `version.pollInterval` plus `updated.current` from `$app/state` shows a "New version, reload" prompt. Reloading keeps unresolved attempt identifiers (§5.6).
- Safe areas (`env(safe-area-inset-*)`), `viewport-fit=cover`, 44 px hit areas.
- Native packaging (Capacitor, etc.) and biometrics stay **out of scope** (U-10 future).

---

## 3. U-12 proposals: styling, components, icons, fonts

| Item | Options | Proposal | Why |
|---|---|---|---|
| CSS approach | Plain CSS + design tokens · Tailwind CSS v4 (4.3.3) · UnoCSS | **Plain CSS with design tokens as CSS custom properties**, Svelte component-scoped styles, plus a small hand-written layer for layout primitives (stack, cluster, grid) | Emberlit is a small, fixed token set (§3.1). Tokens as variables give dark/light/system switching in one place, add no build-time framework, and keep the "simple, grainy" look hand-tuned rather than utility-generic. Tailwind v4 is the credible alternative (its `@theme` can hold the same tokens) if you prefer utility classes for speed. |
| Component library | None · **Bits UI 2.19.5** (headless, Svelte 5, peer `svelte ^5.33`) · Melt UI 0.86.6 (pre-1.0 builders) | **Bits UI (headless)**, styled entirely with Emberlit tokens | P-06 requires keyboard operation, focus restoration, dismissal and searchable long lists. Bits UI provides accessible Dialog, Popover, Select, Combobox, Command (⌘K), Tabs and Tooltip without imposing styles. Melt UI is still pre-1.0. A home-grown dialog/combobox is where accessibility bugs come from. |
| Icons | `@lucide/svelte` 1.52.0 · custom SVG set from Paper | **`@lucide/svelte`** (per-icon imports, tree-shaken), **unless the Paper file uses a different icon family** | Paper can't be inspected in this phase, so please confirm. Custom icons (the mark, Root poses) stay as local SVG/PNG assets. |
| Font | Self-hosted `@fontsource-variable/lexend` 5.3.0 · Google Fonts CDN | **Self-hosted Lexend variable** (weights 400–700), preloaded, `font-display: swap` | No third-party request on auth pages (privacy), works offline in the PWA shell. |
| Template | Purchased template · none | **None** | P-06 forbids reusing old template decisions as defaults, and the approved system already exists. |
| Grain/texture | — | Use the repo assets `Assets/textures/grain-256.png` and `Assets/shaders/grain-gradient-*.png` as static backgrounds | They are already in the repo. The GrainGradient auth background belongs to the **proposed** `Authentication v2` page, so adoption is a question for you (§9). |

### 3.1 Tokens (from P-06, verbatim values)

```css
/* src/lib/ui/tokens.css — values copied from 00-product.md P-06 */
:root {
  --font-sans: "Lexend Variable", system-ui, sans-serif;
  --space-1: 4px; --space-2: 8px; --space-3: 12px; --space-4: 16px;
  --space-6: 24px; --space-8: 32px; --space-12: 48px;
  --radius-sm: 8px; --radius-md: 12px; --radius-lg: 16px; --radius-xl: 24px;
  --hit-min: 44px;
  --brand-coral: #FF7F4F;          /* Elivate mark: never recolored */
}
:root, [data-theme="dark"] {
  --canvas: #111314; --surface: #1A1D1E; --raised: #232728;
  --border: #343A3C; --text: #F2F4F4; --accent: #FF7F4F;
  color-scheme: dark;
}
[data-theme="light"] {
  --canvas: #F7F6F3; --surface: #FFFFFF; --raised: #EEF0F1;
  --border: #D8DDDE; --text: #212628;
  --accent: #B74725;               /* deeper coral for small text/controls on light */
  color-scheme: light;
}
@media (prefers-color-scheme: light) {
  [data-theme="system"] { /* same values as [data-theme="light"] */ }
}
```

Secondary text, status colors (success, warning, danger, info) and focus-ring values are **not in P-06**. They must come from the Paper `Design system` page in Phase 2 (exported values, not screenshots), or be proposed and approved. They are not invented here. Status always carries text, not only color (P-06).

Design-backlog rules carried into implementation: no colored left-edge accent bars (selection = lighter fill + 1 px outline); minimal copy (headline + one line); every screen gets its own Root pose and Root stays away from destructive buttons and dense tables; light mode is built from tokens, not drawn.

---

## 4. App shell

### 4.1 Route map (in scope now)

SvelteKit route groups. `(public)` needs no session; `(gate)` needs an Auth session but the PIN gate may be closed; `(app)` needs gate `ready`.

| Route | Methods | Purpose | Backend calls |
|---|---|---|---|
| `(public)/sign-in` | GET, POST (`default` action) | Email + password, password visibility toggle, generic error | Supabase Auth `signInWithPassword`, then `GET /security/state` |
| `(public)/sign-up` | GET, POST | Founder entry, "Start your network" (W-01). Email + password (min 8, Blueprint 01 Q2) | Supabase Auth `signUp` (`emailRedirectTo` = `/auth/confirm`) |
| `(public)/sign-up/check-email` | GET | Neutral "Check your email" notice. No promise that an account was created or an email delivered (W-01). "Resend" action. | Supabase Auth `resend` (type `signup`) |
| `(public)/auth/confirm` | GET shows a **Continue** button; POST verifies | Landing for every emailed link (sign-up confirmation and PIN-reset link). GET never consumes the token, so email link scanners can't burn it. POST calls `verifyOtp` with `token_hash`, sets the session cookie and 303-redirects to a clean URL. | Supabase Auth `verifyOtp` |
| `(public)/auth/link-expired` | GET | One truthful "This link has expired or was already used" state, with the right next step | — |
| `sign-out` | POST only | Ends this Auth session (proofs cascade) and clears cookies | Supabase Auth `signOut({ scope: 'local' })` |
| `(gate)/pin/setup` | GET, POST | First PIN, entered twice | `POST /security/pin/set` |
| `(gate)/pin` | GET, POST | Enter PIN after password, or after 15 min idle. Shows attempts remaining after an error | `POST /security/pin/verify` |
| `(gate)/pin/locked` | GET | Locked state. Only action: send reset email | — |
| `(gate)/pin/forgot` | POST | Request the reset email, then show a "sent" state with expiry | `POST /security/pin/reset/request` |
| `(gate)/pin/reset` | GET, POST | New PIN after arriving from the emailed link (magic-link session) | `POST /security/pin/reset/complete` |
| `(gate)/blocked` | GET | Account suspended or deactivated: status message plus sign out (gate `account_blocked`) | — |
| `(app)/workspaces` | GET, POST (`select`) | Workspace picker. Lists non-ended memberships; suspended ones or ones in an inactive office can't be selected. Empty state for a new founder. | `GET /org/workspaces`, then `GET /org/capabilities` with `X-Membership` |
| `(app)/` (home) | GET | Signed-in shell with a truthful empty home until the ledger slice exists. No fake balances (P-06). | `GET /org/capabilities` (via layout) |
| `(app)/settings/security` | GET, POST | Devices and sessions; sign out one or all others (W-22). Milestone 2. | `GET /security/sessions`, `POST /security/sessions/revoke` |
| Step-up | — (not a route) | Inline PIN step on the form that needs it (§7.3) | `POST /security/pin/verify` |
| `+error.svelte`, offline page | — | 404, no access, session expired, unavailable (Paper X01–X08 compositions) | — |

Out of scope now, though the shell leaves room for them: network creation and checkout (`POST /org/networks` exists, but plan choice and payment belong to the billing slice), invitations (Blueprint 03), onboarding wizard (U-02), offices/members/access screens (later milestones on the same client), and the admin app (`admin.elivatewallet.com`, separate deployment).

### 4.2 Layout

- **Mobile (390, checked at 320):** top bar (mark, workspace switcher, notification bell placeholder, account menu) and a bottom navigation bar derived from capabilities (P-06).
- **Desktop (1440):** a capability-derived sidebar (the mark at top, workspace switcher, nav items, account at the bottom). Tablet (768) adapts between the two. The design backlog's reference is a 72 px icon rail, but tablet is not drawn (P-06).
- Navigation items appear only when `GET /org/capabilities` returns the permission that backs them. Nothing is inferred from role names (T-02). Unknown permission keys are ignored, not errors (§6.3).
- The notification bell is required in the shell (P-05). The event contract is open (U-11), so it ships as an honest "No notifications yet" state, not a fake feed.
- ⌘K quick search (P-06) is reserved in the shell and built when its read models exist.

### 4.3 Theme switching

- Three values, **Dark (default), Light, System**, stored in a non-sensitive `ew_theme` cookie. Because the cookie is read server-side, SSR writes `data-theme` on `<html>` with no flash of the wrong theme. When it is absent, the default is `dark`.
- `System` follows `prefers-color-scheme` through CSS only. The `<meta name="theme-color">` updates to match.
- The theme control is on the auth pages (W-01 Light/Dark/System capability) and in the account menu.

### 4.4 Loading, empty, error and unknown states (W-00)

Every data region renders exactly one of: *loading* (skeleton, `aria-busy`), *authoritative empty* (Root pose + one line), *ready*, *restricted/unavailable* (short authoritative reason), *error* (safe message + retry for reads), or *outcome unknown* for commands (§5.6). Messages shown to users come from the backend envelope's `message` or reviewed client copy keyed by `code`. They never show raw exceptions, `requestId` alone, or stack traces. `requestId` is shown small, as a support reference, on error states.

### 4.5 Accessibility

- Landmarks, one `h1` per page (it can be visually hidden where P-06 removes redundant titles), labels on every field, `aria-describedby` for errors, and focus moved to the error summary after a failed POST.
- PIN input: four single-digit fields, or one `inputmode="numeric"` `autocomplete="one-time-code"` field (decided from the Paper composition). Fully keyboard-operable, announced as one control, never echoed back after a failed submit.
- Visible focus ring, `prefers-reduced-motion` respected, 44 px minimum targets, no horizontal overflow at 320 px, AAA contrast where practical (P-06; no certification claim).
- Dialogs (step-up, confirmations) use Bits UI Dialog: focus trap, Escape to dismiss, focus restored to the trigger.

---

## 5. Effect service layer

All code below is design-level. Exact Effect 4 API names are pinned at scaffold time against the installed version, not guessed (T-02).

### 5.1 Layout

```
frontend/src/lib/
  contract/            # shared by server and client; no secrets
    envelope.ts        # Success/Failure envelope schemas
    errors.ts          # ErrorCode literal union (from http.ts) + tagged error classes
    security.ts        # request/response schemas, §6.1
    org.ts             # request/response schemas, §6.2
    common.ts          # Uid, Uuid, IsoDateTime, IdempotencyKey, Pin, Reason, Person, Page<T>
  server/              # server-only (SvelteKit blocks importing it from client code)
    supabase-auth.ts   # SupabaseAuth service (Layer per request)
    edge.ts            # EdgeTransport service: fetch + envelope decode
    security-api.ts    # SecurityApi service: one method per route
    org-api.ts         # OrgApi service: one method per route
    session.ts         # cookies: session (HttpOnly), workspace, theme
    runtime.ts         # ManagedRuntime + per-request layer composition
  client/
    attempts.ts        # pending command attempts (sessionStorage, non-secret)
    context.ts         # workspace switch: cancel in-flight reads, purge state
    runtime.ts
  ui/                  # tokens.css, primitives, Bits UI wrappers
```

### 5.2 Services

**`SupabaseAuth`** (server, one instance per request). Built on `@supabase/ssr` `createServerClient` with a cookie adapter that writes `HttpOnly; Secure; SameSite=Lax; Path=/` cookies. It uses the **publishable (anon) key only**; no service-role key exists anywhere in the frontend.
- Operations: `signUp`, `resendSignup`, `signInWithPassword`, `verifyOtp(token_hash, type)`, `signOut(local)`, `claims()` (verified claims via `getClaims`, not an unverified `getSession`), and `accessToken()` (refreshes when expired, single-flight within the request).
- Failures are mapped from Supabase Auth's documented `AuthError.code` values (`invalid_credentials`, `email_not_confirmed`, `user_already_exists`, `weak_password`, `over_request_rate_limit`, `otp_expired`, …) to `AuthFailure` variants. Unknown codes become `AuthUnavailable`. Sign-in shows one generic error for bad credentials (W-01). `email_not_confirmed` gets its own truthful state with "resend".

**`EdgeTransport`** (server). One function:
`request({ fn: "security" | "org", method, path, query?, body?, membershipId? }) → Effect<unknown, BackendError | TransportError | ContractViolation>`
- URL `${SUPABASE_URL}/functions/v1/${fn}${path}`. Headers: `authorization: Bearer <access token>`, `apikey: <publishable key>`, `content-type: application/json`, and `x-membership` when `membershipId` is given.
- Timeout 10 s (reads) / 20 s (commands), carrying the incoming request's `AbortSignal` so a cancelled navigation aborts the fetch.
- Decodes the body with `Envelope` (§6.0). `ok: true` returns `data` for the route schema to decode. `ok: false` with a known `code` becomes a `BackendError` (status, code, message, retryable, details, requestId). Any **non-envelope** body (for example the platform gateway's own 401 when `verify_jwt` rejects a token, or an HTML 502) becomes a `TransportError` carrying the HTTP status. A 401 non-envelope response is treated as `authentication_required`. An envelope with an unknown `code` becomes a `ContractViolation` (logged, shown as a generic error). Codes are never invented client-side.

**`SecurityApi`, `OrgApi`** (server). One method per route in §6. Each method encodes the request with its schema (client-side shape validation mirrors the server's, including the 3–500-char trimmed reason rule), calls `EdgeTransport`, and decodes `data` with the route's response schema. A schema failure is a `ContractViolation`, never silently accepted data.

### 5.3 Runtime validation

- **Every** response is decoded: the envelope first, then `data` against the route schema. Requests are encoded through the same schemas before dispatch, so a malformed form is a local `validation_error`-style field error before the network.
- Unknown fields are not allowed in requests (the Edge Functions reject them with `validation_error` / `unknown_field`). Responses may carry extra fields: decode ignores them, because the backend may add fields; it must not remove them.
- Money: there are no money fields in slices 01–02. When the ledger slice lands, amounts decode to exact decimal strings (or `BigDecimal`) with currency attached, never `number` (P-06, F-01).
- `audit.id` is a Postgres `bigint` serialized as a JSON number. The schema checks `Number.isSafeInteger` and treats a larger value as a `ContractViolation`.

### 5.4 Typed errors

`BackendError` is a tagged union keyed by the **exact backend code** (the 24 codes in `backend/supabase/functions/_shared/http.ts:3-28`). Code-specific `details` schemas are used where the backend defines them (§6.3). For the UI, codes fold into the T-02 categories:

| Category | Codes | UI/Effect behavior |
|---|---|---|
| Validation | `validation_error` | Field error on `details.field` (`unknown_field` / `mismatch` reasons); keep the user's input |
| Authentication | `authentication_required`, gateway 401 | Clear private page state, go to `/sign-in` (W-00) |
| Session gate | `pin_setup_required`, `pin_required`, `pin_locked`, `account_blocked` | Route to the matching `(gate)` page; keep a safe `next` path |
| Step-up | `step_up_required` | Inline PIN step, then retry the **same** command and key (§7.3) |
| Authorization | `authorization_denied`, `workspace_invalid`, `scope_exceeds_authority`, `self_target_forbidden`, `permission_not_grantable` | Short denial; reload capabilities; `workspace_invalid` sends the user to the picker |
| Conflict / state | `conflict`, `idempotency_conflict`, `membership_exists`, `last_president`, `last_leader`, `network_not_active`, `hierarchy_invalid`, `role_office_mismatch` | Explain the state; never retry automatically; `idempotency_conflict` means recover the original attempt (W-00) |
| Not found | `not_found` | "Not found or not visible" |
| Throttled | `rate_limited` | Wait `details.retryAfterSeconds` when present |
| Server | `internal_error` | Safe message + `requestId`; reads may retry |
| Transport / unknown | `TransportError` (timeout, network, non-envelope 5xx) | Reads: retry. Commands: **outcome unknown** (§5.6) |
| Defect | `ContractViolation` | Generic error; logged with route pattern + `requestId` only |

### 5.5 Retry and idempotency policy

- **Reads (GET):** up to 2 automatic retries with exponential backoff and jitter, only on `TransportError` or envelope `retryable: true` (`internal_error`, `rate_limited`). They honor `retryAfterSeconds` and are cancelled on navigation or workspace switch.
- **PIN commands** (`/pin/set`, `/pin/verify`, `/pin/reset/*`): **never retried automatically**, because each attempt counts and they are not idempotent (Blueprint 01 B4).
- **Commands with `idempotencyKey`** (all `org` writes, `POST /org/networks`, admin routes): the key is created **once per user intent**, when the form is rendered, as a hidden field holding a `crypto.randomUUID()` value (36 characters, which matches `^[A-Za-z0-9_-]{16,100}$`). A double submit, a retry after a transport failure or a retry after step-up all reuse the same key and payload. A fresh key is issued only after an authoritative result (success or a definite, non-retryable failure). Keys are scoped per actor across **all** commands (`identity.command_results` PK is `(actor_user_id, idempotency_key)`), so a key is never reused for another command.
- At most **one** automatic same-key retry on `TransportError`; after that, the attempt is shown as *outcome unknown*.
- Success payloads carry `replayed: boolean`. `replayed: true` is shown exactly like the original success.

### 5.6 Unknown outcome recovery (F-03, W-00)

Before dispatch, the client records a pending attempt in `sessionStorage`: `{ key, command, routePattern, targetId, createdAt }` plus the non-secret payload fields needed to replay. It never stores a PIN, password, token or email. If the response is lost, or the page reloads mid-flight, the form shows "We couldn't confirm this. Check again." and **replays the same key and payload**. The backend returns the stored result (`replayed: true`) after re-checking current authority. Conflicting submissions are disabled while an attempt is unresolved. The record is deleted on a definite result.

### 5.7 Session gate handling

- `hooks.server` verifies the session cookie (`claims()`). With no valid session, `(gate)` and `(app)` routes redirect to `/sign-in`.
- The `(gate)` and `(app)` layout loads call `GET /security/state` once per navigation. That call does **not** count as activity in the database (`identity.security_state` is `stable`; only `identity.require_session` touches `last_activity_at`). `gate` decides the route:
  - `pin_setup_required` → `/pin/setup`
  - `pin_required` → `/pin` (also after 15 min idle, which is server-enforced)
  - `pin_locked` → `/pin/locked`
  - `ready` → `(app)`; `stepUpExpiresAt` (ISO or `null`) shows the live window (W-22: "display the actual verified-window state")
  - Error `account_blocked` (the backend raises it as an error, not as a gate value) → `/blocked`
- A gate error from **any** later call, for example `pin_required` after idle, is handled the same way. For a form POST, the action returns the PIN step inline instead of navigating away, so unsaved input is kept (§7.3).

### 5.8 `X-Membership` handling

- The selected membership ID lives in a server-read cookie `ew_ws` (HttpOnly, SameSite=Lax, not a permission, A-02). It is **never in the URL**.
- Every `org` call except `GET /workspaces`, `POST /networks` and `POST /admin/tenants/:id/activate` sends `x-membership: <uuid>`. The server is the authority: `workspace_invalid` clears the cookie and opens the picker.
- **Multi-tab safety:** every rendered form carries the workspace ID it was rendered for as a hidden `_ws` field. A form action rejects a mismatch with the cookie ("Workspace changed in another tab", then reload) before calling the backend. A late response for an old workspace is discarded on the client (A-02: "never render old tenant data").
- On switch, the client cancels in-flight reads, drops cached page data (`refreshAll`) and reloads capabilities.

### 5.9 No sensitive data in URLs, logs or analytics

- URLs carry no email, UID, PIN, token, membership ID or pagination cursor. Cursors are base64 JSON that can contain office names (`org.encode_cursor`), so they stay in form or component state, not query strings.
- The one unavoidable URL secret is the single-use `token_hash` in emailed links (§7.1). The confirm page sets `Referrer-Policy: no-referrer`, loads no third-party scripts, consumes the token only on POST, and immediately 303-redirects to a clean URL.
- Server logs mirror the backend rule: `{ requestId, routePattern, status, code, ms }` only. Effect `Redacted` wraps tokens, PINs and passwords so they can't be printed accidentally. No user, session or membership IDs and no email or IP in logs.
- Analytics (PostHog) is **not** installed in Phase 2. The consent/event taxonomy is open (U-11).
- Response headers on all authenticated pages: `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `frame-ancestors 'none'` via SvelteKit CSP (nonce mode), HSTS at the Cloudflare zone.

---

## 6. Typed client spec (derived from code at `c648abd`)

### 6.0 Transport facts common to both functions

- Base: `https://<project>.supabase.co/functions/v1/security` and `/functions/v1/org`. The handler strips everything up to `/security` or `/org` (`security/handler.ts:165`, `org/handler.ts:516`), so **`/admin/...` routes live under the function that defines them**: `/functions/v1/security/admin/accounts/status`, `/functions/v1/org/admin/tenants/:id/activate`.
- Auth: `Authorization: Bearer <user access token>`. Actor `userId` comes from the `sub` claim and `sessionId` from the `session_id` claim (`security/index.ts:20-28`). Body values never set the actor. The platform gateway also enforces `verify_jwt = true` (`config.toml:421-425`).
- Success envelope: `{ ok: true, data, requestId }` with HTTP 200 (`_shared/http.ts:82-91`).
- Failure envelope: `{ ok: false, error: { code, message, retryable, details }, requestId }`. `retryable` is true only for `internal_error` and `rate_limited` (`_shared/http.ts:93-113`).
- Response headers: `content-type: application/json; charset=utf-8`, `cache-control: no-store`, `referrer-policy: no-referrer`, `x-content-type-options: nosniff`.
- CORS (browser-direct mode only): exact-match origins from `CORS_ORIGINS`; allowed request headers `authorization, content-type, apikey, x-client-info, x-membership`; methods `GET, POST, PUT, PATCH, DELETE, OPTIONS` (`_shared/http.ts:115-128`).
- Unknown route: 404 `not_found`, checked **before** authentication (`security/handler.ts:183-184`, `org/handler.ts:542`).
- Body parsing: an empty body counts as `{}`. Non-object JSON → `validation_error {field:"body"}`. Any unlisted key → `validation_error {field:<key>, reason:"unknown_field"}` (`_shared/validate.ts:7-27`). Query strings on `org` reads reject unknown keys the same way.
- Field rules (`_shared/validate.ts`): `pin` = `^[0-9]{4}$`; `pinConfirm` must equal `pin` (`reason:"mismatch"`); UID = `^EW-[1-9][0-9]{4,}$` case-insensitive, trimmed and upper-cased by the Edge; UUIDs are case-insensitive and lower-cased; `idempotencyKey` = `^[A-Za-z0-9_-]{16,100}$`. Text is non-blank and ≤ max at the Edge, then the **database** enforces trimmed minimums: `reason` 3–500 (`identity.require_reason`), office `name` 2–100, network `name` 2–100, `shortName` 1–30.
- Path IDs on `org` must be UUIDs. Otherwise the route doesn't match and the response is **404 `not_found`** (`org/handler.ts:72-89`).
- Gate codes can come from any route that requires a session: `authentication_required` (401), `account_blocked`, `pin_setup_required`, `pin_required`, `pin_locked` (423); `step_up_required` on S routes. Writes from a `restricted` account → `authorization_denied {reason:"account_not_active"}`.

Shared schemas:

```ts
Uid           = /^EW-[1-9][0-9]{4,}$/                // as returned (upper-case)
Uuid          = lower-case UUID string
IsoDateTime   = string parsable by Date.parse (Postgres timestamptz JSON)
Person        = { uid: Uid, name: string | null }    // org.person(); may itself be null
Page<T>       = { items: T[], nextCursor: string | null }
CommandMeta   = { replayed: boolean }                // added to every idempotent result
Role          = "member" | "team_leader" | "director" | "world_team_member" | "president_team_member"
OfficeType    = "world_team" | "director" | "team_leader"
TenantStatus  = "pending_payment" | "active" | "suspended" | "deactivated"
MembershipStatus = "active" | "suspended" | "ended"
AccountStatus = "active" | "restricted" | "suspended" | "deactivated"
```

### 6.1 `security` function

| Method + path | Request | `data` on success | Route-specific errors |
|---|---|---|---|
| `GET /state` | — | `SecurityState` | `authentication_required`, `account_blocked` |
| `POST /pin/set` | `{ pin, pinConfirm }` | `SecurityState` | `validation_error` (`pin`/`pinConfirm`, `mismatch`), `conflict {reason:"pin_already_set"}` |
| `POST /pin/verify` | `{ pin }` | `SecurityState` (gate `ready`, new 5-min window) | `pin_incorrect {attemptsRemaining:1..4}` (403), `pin_locked {attemptsRemaining:0}` on the 5th wrong PIN, or `pin_locked {}` if already locked (423), `pin_setup_required` |
| `POST /pin/reset/request` | `{}` or empty | `{ expiresAt: IsoDateTime }` (+15 min) | `pin_setup_required`, `rate_limited {retryAfterSeconds:60}`, `internal_error` if the email could not be sent (see inconsistency 8) |
| `POST /pin/reset/complete` | `{ pin, pinConfirm }` | `SecurityState` | `conflict {reason:"no_pending_reset"}`, `authorization_denied {reason:"email_link_session_required"}` |
| `GET /sessions` | — | `Array<{ sessionId: Uuid, createdAt, lastActiveAt, userAgent: string\|null, current: boolean }>` | gate codes |
| `POST /sessions/revoke` | exactly one of `{ sessionId: Uuid }` or `{ allOthers: true }` | `{ revoked: number }` | `validation_error {field:"sessionId"}`, `not_found` |
| `POST /admin/accounts/status` | `{ targetUid, status: AccountStatus, reason, idempotencyKey }` | `{ targetUid, previousStatus, status, changed: boolean } & CommandMeta` | platform admin + S: `authorization_denied` (not admin; or `{reason:"self_target"}`), `step_up_required`, `not_found`, `idempotency_conflict` |
| `POST /admin/admins/grant` | `{ targetUid, reason, idempotencyKey }` | `{ targetUid, changed } & CommandMeta` | as above |
| `POST /admin/admins/revoke` | `{ targetUid, reason, idempotencyKey }` | `{ targetUid, changed } & CommandMeta` | as above + `conflict {reason:"last_platform_admin"}` |

```ts
SecurityState = {
  gate: "pin_setup_required" | "pin_locked" | "pin_required" | "ready",
  uid: Uid,
  accountStatus: AccountStatus,          // in practice active | restricted (blocked raises)
  attemptsRemaining: number,             // 0..5
  stepUpExpiresAt: IsoDateTime | null,
}
```

The `/admin/*` routes belong to the admin app (`admin.elivatewallet.com`), not `app.elivatewallet.com`. They are typed in the shared contract package but have no tenant-app UI.

### 6.2 `org` function

**H** = requires `X-Membership`. **S** = step-up. **R** = reason 3–500. All writes take `idempotencyKey` and return `& CommandMeta`.

| Method + path | H | Request | `data` | Notable errors |
|---|---|---|---|---|
| `POST /networks` | – | `{ name, shortName, idempotencyKey }` | `{ tenantId, status:"pending_payment", membershipId }` | `conflict {reason:"pending_network_exists"}`, `authorization_denied {reason:"account_not_active"}` |
| `POST /admin/tenants/:id/activate` | – | `{ reason, idempotencyKey }` (R, S, platform admin) | `{ tenantId, status:"active" }` | `not_found`, `conflict {reason:"not_pending"}` |
| `GET /workspaces` | – | no query | `Workspace[]` | gate codes |
| `GET /capabilities` | H | no query | `{ membershipId, tenantStatus, permissions: string[] }` | `workspace_invalid` |
| `GET /offices` | H | query `type?`(OfficeType) `q?`(≤100) `status?`(`active\|closed`) `cursor?` `limit?`(1–100, default 50) | `Page<Office>` | `network_not_active`, `validation_error` |
| `POST /offices` | H | `{ type: OfficeType, name, parentOfficeId?: Uuid\|null, leaderUids: Uid[1..20], idempotencyKey }` | `{ officeId, leaderMembershipIds: Uuid[] }` | `hierarchy_invalid`, `role_office_mismatch`, `membership_exists`, `not_found` |
| `PATCH /offices/:id` | H | `{ name, idempotencyKey }` | `{ officeId, name }` | `authorization_denied`, `not_found` |
| `POST /offices/:id/place` | H | `{ parentOfficeId: Uuid\|null, reason, idempotencyKey }` R S; the `parentOfficeId` key is required even when null | `{ officeId, parentOfficeId, changed }` | `hierarchy_invalid` |
| `POST /offices/:id/leaders` | H | `{ leaderUid, reason, idempotencyKey }` R S | `{ membershipId }` | `membership_exists`, `role_office_mismatch` |
| `POST /offices/:id/leaders/replace` | H | `{ outgoingMembershipId, incomingUid, reason, idempotencyKey }` R S | `{ endedMembershipId, membershipId }` | `conflict {reason:"not_a_current_leader"}`, `validation_error {field:"incomingUid"}` |
| `GET /members` | H | query `officeId?`(Uuid) `role?`(Role) `status?`(MembershipStatus) `cursor?` `limit?` | `Page<Member>` | `authorization_denied` |
| `POST /memberships` | H | `{ officeId, memberUid, idempotencyKey }` | `{ membershipId, isPrimary }` | `membership_exists`, `not_found` |
| `POST /memberships/:id/move` | H | `{ toOfficeId, reason, idempotencyKey }` R S | `{ endedMembershipId, membershipId }` | `conflict {reason:"president_membership"\|"membership_not_active"}`, `last_leader` |
| `POST /memberships/:id/suspend` | H | `{ reason, idempotencyKey }` R S | `{ membershipId, status:"suspended", changed }` | `last_president`, `last_leader`, `self_target_forbidden` (own President membership), `conflict {reason:"membership_ended"}` |
| `POST /memberships/:id/reactivate` | H | `{ reason, idempotencyKey }` R S | `{ membershipId, status:"active", changed }` | as above |
| `POST /memberships/:id/end` | H | `{ reason, idempotencyKey }` R S | `{ membershipId, status:"ended" }` | `last_president`, `last_leader`, `self_target_forbidden` |
| `POST /presidents` | H | `{ memberUid, reason, idempotencyKey }` R S | `{ membershipId }` | `membership_exists` |
| `DELETE /presidents/:id` | H | JSON body `{ reason, idempotencyKey }` R S | `{ membershipId, status:"ended" }` | `last_president`, `self_target_forbidden`, `not_found` |
| `GET /role-permissions` | H | — | `Array<{ permission, role: Role, allowed, editable }>` | President only |
| `PUT /role-permissions` | H | `{ role: Role, permission, allowed: boolean, reason, idempotencyKey }` R S | `{ role, permission, allowed, changed }` | `permission_not_grantable {reason:"protected"\|"assignment_only"}`, `not_found` |
| `GET /access` | H | query `cursor?` `limit?` | `Page<AccessAssignment>` | |
| `POST /access` | H | `{ subjectUid, rules: AccessRuleInput[1..50], reason, idempotencyKey }` R S | `{ assignmentId }` | `scope_exceeds_authority {permission}`, `permission_not_grantable {permission}`, `self_target_forbidden`, `conflict {reason:"subject_not_member"}` |
| `POST /access/:id/revoke` | H | `{ reason, idempotencyKey }` R S | `{ assignmentId, changed }` | `scope_exceeds_authority`, `self_target_forbidden` |
| `GET /reviewers` | H | — | `Reviewer[]` | President only |
| `POST /reviewers` | H | `{ membershipId, reason, idempotencyKey }` R S | `{ assignmentId }` | `conflict {reason:"membership_not_active"\|"already_reviewer"}` |
| `DELETE /reviewers/:id` | H | JSON body `{ reason, idempotencyKey }` R S | `{ assignmentId, changed }` | `not_found` |
| `GET /audit` | H | query `cursor?` `limit?` | `Page<AuditEvent>` | President only |

```ts
Workspace = { membershipId: Uuid, tenantId: Uuid, tenantName: string, tenantShortName: string,
  tenantStatus: TenantStatus, officeId: Uuid|null, officeName: string|null, officeType: OfficeType|null,
  role: Role, status: "active"|"suspended", isPrimary: boolean }          // non-ended only
Office    = { id, name, type: OfficeType, status: "active"|"closed", parentOfficeId: Uuid|null,
  leaderCount: number, memberCount: number }                            // own memberships only
Member    = { membershipId, person: Person, role: Role, status: MembershipStatus, officeId: Uuid|null,
  officeName: string|null, isPrimary: boolean, startedAt: IsoDateTime, endedAt: IsoDateTime|null }
AccessRuleInput = { permission: string(≤60), effect: "allow"|"deny",
  scopeType: "tenant"|"office_subtree"|"member", scopeOfficeId?: Uuid /* office_subtree */,
  scopeUid?: Uid /* member */, startsAt?: IsoDateTime, expiresAt?: IsoDateTime /* not on deny */ }
AccessAssignment = { id, subject: Person, createdBy: Person, reason, createdAt, revokedAt|null,
  revokeReason|null, rules: Array<{ permission, effect, scopeType, scopeOfficeId|null,
  scopeOfficeName|null, scopePerson: Person|null, startsAt, expiresAt|null }> }
Reviewer  = { assignmentId, membershipId, person: Person, role: Role, officeName: string|null,
  reason, assignedAt, assignedBy: Person }
AuditEvent = { id: number /* bigint */, at, actor: Person|null, action: string, targetType: string,
  targetId: string, reason: string|null, before: object|null, after: object|null }
```

### 6.3 Code-specific `details` the client relies on

| Code | `details` |
|---|---|
| `validation_error` | `{ field: string, reason?: "unknown_field" \| "mismatch" }` (field can be dotted, for example `rules.expiresAt`) |
| `pin_incorrect` | `{ attemptsRemaining: number }` |
| `pin_locked` | `{ attemptsRemaining?: 0 }` (absent when already locked) |
| `rate_limited` | `{ retryAfterSeconds?: number }` |
| `conflict` | `{ reason?: string }`, known values listed in §6.1/§6.2; unknown reasons fall back to the envelope `message` |
| `authorization_denied` | `{ reason?: string }` |
| `permission_not_grantable` | `{ reason?: string, permission?: string }` |
| `scope_exceeds_authority` | `{ permission?: string }` |
| others | `{}` |

`permissions` from `/capabilities` are decoded as `string[]`. The UI maps the known A-03 keys (seeded in `20261008000800_authz.sql`) to navigation and ignores unknown keys, so a new backend permission doesn't break old clients (W-25).

### 6.4 Backend contract inconsistencies found

| # | Finding | Where | Frontend impact / suggested fix |
|---|---|---|---|
| 1 | Blueprint says sessions revoke takes `sessionId \| others` and calls `api.revoke_session`. Code takes `allOthers: true` and calls `api.revoke_sessions`. | `docs/blueprints/01-sign-in-and-pin.md:108` vs `backend/supabase/functions/security/handler.ts:117-127` | Client follows code (`allOthers`). Fix blueprint text. |
| 2 | Blueprint says add-membership takes `userUid`. Code takes `memberUid`. | `docs/blueprints/02-networks-offices-and-access.md:124` vs `backend/supabase/functions/org/handler.ts:355-362` | Client follows code. Fix blueprint text. |
| 3 | Blueprint lists `step_up` and `account_blocked` as session-gate values. `gate` only ever returns four values; blocked accounts get an **error** `account_blocked`, and step-up is exposed as `stepUpExpiresAt`. | `docs/blueprints/01-sign-in-and-pin.md:86-94` vs `backend/supabase/migrations/20261008000300_pin_and_sessions.sql:85-87,92-110,156-177` | Client handles both forms (§5.7). Fix blueprint text. |
| 4 | Blueprint says the selected workspace must be in an **active** network. `authz.require_workspace` accepts memberships in `pending_payment` networks (deliberate, per its comment); reads that need an active network then return `network_not_active`. | `docs/blueprints/02-networks-offices-and-access.md:48` vs `backend/supabase/migrations/20261008000800_authz.sql:433-449` | Picker allows pending networks and shows "Awaiting payment". Align blueprint with code. |
| 5 | Self-target refusal uses two different codes: account status returns `authorization_denied {reason:"self_target"}`, while `org` uses the dedicated `self_target_forbidden`. | `backend/supabase/migrations/20261008000600_admin_lock_order.sql:45` vs `20261008000900_org_commands.sql:845,1382,1509` and `_shared/http.ts:27` | Pick one (suggest `self_target_forbidden`). Client maps both meanwhile. |
| 6 | Edge text validation (non-blank, ≤ max, untrimmed length) is looser than the database minimums (reason 3–500 trimmed, names 2–100). A 1–2 character reason passes the Edge and fails in Postgres with the same code. | `backend/supabase/functions/_shared/validate.ts:45-51` vs `20261008000400_platform_admin_and_status.sql:116-125`, `20261008000900_org_commands.sql:8-19,443` | Same outcome, two rule sets. Client validates the stricter DB rule. Optionally tighten `v.text` to accept a minimum. |
| 7 | A non-UUID path ID returns `404 not_found` (the route doesn't match) rather than `validation_error`. | `backend/supabase/functions/org/handler.ts:72-89`, test `backend/tests/org_handler_test.ts:76-82` | Acceptable. Documented so the client doesn't treat it as "missing record" logic. |
| 8 | PIN reset request is not atomic with the email. The reset row and audit commit first, then `sendResetLink` runs. If the email fails the client gets `internal_error` with `retryable: true`, but a retry within 60 s returns `rate_limited`, and the user can't tell whether an email went out. | `backend/supabase/functions/security/handler.ts:99-104`, `_shared/http.ts:104`, `20261008000300_pin_and_sessions.sql:299-305` | Client never auto-retries this route and shows "If you don't receive it, try again in a minute". Suggest a distinct error (or `details.emailSent:false`) and not consuming the cooldown on send failure. |
| 9 | The security handler's `call()` lacks the "result must be an object/array" guard that the org handler has. | `backend/supabase/functions/security/handler.ts:60-69` vs `backend/supabase/functions/org/handler.ts:209-212` | Client schemas catch it anyway. Align for consistency. |
| 10 | The PIN-reset email is sent by a server-side supabase-js client with default options (`signInWithOtp` + `emailRedirectTo`). With the default email template, the session lands at `PIN_RESET_REDIRECT_URL` as **tokens in the URL fragment** (implicit flow), because a server-side call can't keep a PKCE verifier. That conflicts with W-01 ("bearer values never enter GET URLs") and a server-side app can't read a fragment. | `backend/supabase/functions/security/index.ts:37-46` | Decision §9 #5: switch the Magic Link and Confirm signup templates to `token_hash` links handled by `/auth/confirm` (POST). Dashboard Auth change, owner approval required. |
| 11 | `list_offices` `memberCount`/`leaderCount` count only the office's **own** memberships, while owner answer 7 says office member counts are rolled up over the subtree. | `backend/supabase/migrations/20261008000900_org_commands.sql:382-385` vs `design-backlog.md:56` | Decide which the O01/O03 screens show. Until then, label the value "in this office". |
| 12 | Local Auth redirect allowlist lists `https://127.0.0.1:3000` (https) while `site_url` is `http://127.0.0.1:3000`. Probably a typo. | `backend/supabase/config.toml:159,163` | Local dev runs on `http://127.0.0.1:3000`; fix the allowlist entry. Local only (never `config push`). |
| 13 | Blueprint 01 says no schema is exposed through the Data API, but `config.toml` exposes `api` (needed for `service.schema("api").rpc`). Execution is still `service_role`-only. | `docs/blueprints/01-sign-in-and-pin.md:40` vs `backend/supabase/config.toml:14` | Doc wording only. The frontend never calls the Data API. |
| 14 | Blueprints write admin routes without their function prefix (`POST /admin/tenants/{id}/activate` beside `/org/...` routes), which reads as a separate function. They live at `/functions/v1/org/admin/...` and `/functions/v1/security/admin/...`. | `docs/blueprints/02-networks-offices-and-access.md:114`, `docs/blueprints/01-sign-in-and-pin.md:109-110` | Clarify in blueprints; §6.0 records the real paths. |
| 15 | Two `DELETE` routes require a JSON body (reason + key). That is valid but unusual; some proxies and clients drop DELETE bodies. | `backend/supabase/functions/org/handler.ts:399-407,480-488` | Fine with server-side `fetch`. Note it for future native clients. |
| 16 | No route returns the signed-in person's own profile (name). `GET /state` returns only the UID, so the shell can show the UID and email (from Auth claims) but not a display name. | `20261008000300_pin_and_sessions.sql:156-177` | Gap, not a conflict. The W-22 profile route is a later backend slice. |

---

## 7. Auth and PIN flows against the live functions

### 7.1 Sign-up → confirm → set PIN → workspace picker

1. `GET /sign-up` → native POST `{ email, password }` → server `SupabaseAuth.signUp(email, password, { emailRedirectTo: <origin>/auth/confirm })`. Email confirmations are on (`config.toml` `[auth.email] enable_confirmations = true`), so there is **no session yet**.
   - A new user and an already-registered email (Supabase returns a user with empty `identities`, W-01) both go to `/sign-up/check-email` with neutral copy ("If this email can be used, we've sent a link."). A weak password or rate limit is a field or form error.
   - The DB trigger `identity.on_auth_user_created` creates the account, profile and UID. No metadata is needed.
2. The email link (after the template change, §9 #5) is `…/auth/confirm?token_hash=…&type=signup`. `GET` renders only a **Continue** button. `POST` runs `verifyOtp({ token_hash, type })`, which sets the HttpOnly session cookies, then 303 to `/pin/setup`. Expired or used tokens → `/auth/link-expired` with "Resend". The link works on any device because `token_hash` needs no PKCE verifier.
3. `/pin/setup` → `GET /security/state` = `pin_setup_required` → POST `{ pin, pinConfirm }` → `POST /security/pin/set` → `SecurityState{gate:"ready"}` → 303 `/workspaces`.
4. `/workspaces` → `GET /org/workspaces`. A brand-new founder gets `[]` → empty state "Start your network" (network creation and checkout come with the billing slice).
5. With exactly one selectable workspace, it is auto-selected (§9 #18). Otherwise the user picks → `GET /org/capabilities` with `X-Membership` to validate → set `ew_ws` → shell.

### 7.2 Returning sign-in → PIN → workspace picker → shell

1. `/sign-in` POST → `signInWithPassword` → cookies → `GET /security/state`. A new Auth session never has a PIN proof, so `gate` is `pin_required` (or `pin_locked`, or `pin_setup_required` for someone who never finished).
2. `/pin` POST `{ pin }` → `POST /security/pin/verify`:
   - success → `SecurityState{gate:"ready", stepUpExpiresAt: now+5min}` → `next` (validated local path) or `/workspaces`
   - `pin_incorrect` → "That PIN is incorrect. N tries left." (`details.attemptsRemaining`); input cleared
   - `pin_locked` → `/pin/locked`
3. Picker, then shell, as in §7.1 step 5. If the `ew_ws` cookie still names an active workspace, the picker is skipped and capabilities are re-validated on load.
4. After 15 min without a gated call, the next call returns `pin_required`. For a GET this redirects to `/pin?next=<path>`. For a form POST the form re-renders with an inline PIN step and keeps the user's input (§7.3).

### 7.3 Step-up for protected actions (A-05)

- S commands return `step_up_required` when the proof is older than 5 minutes (anchored to `verified_at`; retries don't extend it).
- **With JavaScript:** the action result `{ stepUp: true }` opens the PIN dialog. `POST /security/pin/verify` opens a new window, then the **same form is resubmitted with the same `idempotencyKey`**. The backend re-checks everything; replay re-runs authorization.
- **Without JavaScript:** the action re-renders the form with a PIN field. On resubmit the action calls `/pin/verify` first, then the command with the same key. The PIN is never echoed back.
- `pin_incorrect` inside step-up shows attempts left. `pin_locked` ends all proofs for the user, so the session drops to `/pin/locked`.
- The UI can show the remaining window from `stepUpExpiresAt` as a hint, but the server's answer is authoritative (clock skew).

### 7.4 PIN reset

1. From `/pin` or `/pin/locked` (password session, gate `pin_required` or `pin_locked`): "Forgot PIN" → POST `/pin/forgot` → `POST /security/pin/reset/request` → `{ expiresAt }` → "Check your email. The link works for 15 minutes." `rate_limited` → "Try again in a minute".
2. The email (Supabase Magic Link template, sent through Cloudflare SMTP) links to `PIN_RESET_REDIRECT_URL`. Proposal: `https://app.elivatewallet.com/auth/confirm`, with the template adding `token_hash` and `type=magiclink` (§9 #5, inconsistency 10). Continue (POST) → `verifyOtp` → a **new** Auth session whose `amr` is `otp`/`magiclink`, as `api.complete_pin_reset` requires → 303 `/pin/reset`.
3. `/pin/reset` POST `{ pin, pinConfirm }` → `POST /security/pin/reset/complete` → `SecurityState{gate:"ready"}`. This deletes **all** PIN proofs for the user (every device must re-enter the PIN) and opens one for this session.
   - `conflict {reason:"no_pending_reset"}` → "This reset expired. Request a new one." (The request TTL is 15 min, but the Auth OTP lives 1 h, `otp_expiry = 3600`, so an "old but valid" link is possible.)
   - `authorization_denied {reason:"email_link_session_required"}` → the user reached `/pin/reset` without the email session → back to `/pin/forgot`.
4. The old password session in that browser is replaced by the link session's cookie. The superseded Auth session stays listed under Devices until it expires or is revoked. Optional improvement: the confirm action calls `signOut({scope:'local'})` on the previous session before switching.

### 7.5 Sign-out and session revocation

- `POST /sign-out` → `signOut({ scope: 'local' })` deletes this Auth session (proofs cascade via FK) → clear `ew_ws` (keep `ew_theme`) → `/sign-in`.
- Devices page: `POST /security/sessions/revoke` with `{ sessionId }` or `{ allOthers: true }`. Revoking the current session behaves like sign-out.

### 7.6 Token storage choice and why

- **HttpOnly, Secure, SameSite=Lax cookies set by the SvelteKit server** (`@supabase/ssr` cookie adapter with no browser client), `Path=/`, chunked by `@supabase/ssr` when large.
- Why: browser JavaScript, including any injected script, cannot read the access or refresh token (P-04 "keep credentials out of browser bundles", W-01 no bearer values in URLs). Native POST works. Revocation is server-side (Auth session delete).
- `Lax` sends the cookie on top-level navigations from email links. Mutating requests are protected by SvelteKit's built-in CSRF origin check (`csrf.trustedOrigins` in Kit 3).
- Refresh: `jwt_expiry = 3600`, rotation on, `refresh_token_reuse_interval = 10` (`config.toml:165-174`). The server refreshes on demand, single-flight per request; the 10 s reuse window absorbs parallel requests from one browser.
- Session ceiling: 7 days (`[auth.sessions] timebox = "168h"`). The 15-minute PIN idle rule is the database's, not the cookie's.
- Not chosen: localStorage/sessionStorage tokens (readable by XSS; that is option B in §2.1 and only the fallback).

---

## 8. Phase 2 build plan

### 8.1 Scaffold (Phase 2, after your decisions)

- `frontend/` beside `backend/` (§9 #23), created with the official `sv` CLI for **Kit 3**, then trimmed: TypeScript 6, pnpm, Node 24, adapter-cloudflare, Vitest, Playwright. ESLint + Prettier as the `sv` defaults; Kit config inside `vite.config.ts`; `#lib` imports.
- Add: `effect@4.0.x`, `@supabase/supabase-js@2.117.3` (same pin as the Edge Functions), `@supabase/ssr@0.12.x`, `bits-ui@2.x` (+ its `@internationalized/date` peer), `@lucide/svelte`, `@fontsource-variable/lexend`.
- `wrangler.jsonc` with `nodejs_compat` and observability enabled, plus **public** vars only: `PUBLIC_SUPABASE_URL` and `PUBLIC_SUPABASE_PUBLISHABLE_KEY`. Both are safe for clients, but in mode A only the server uses them. `frontend/.env.example` lists the names with empty values. Real `.env*` files stay ignored (root `.gitignore` already has `.env` and `.env.*`).
- Assets: copy `Assets/elivate-logo-icon.svg` and the grain textures into `frontend/static/` at build time (or reference them by path). The originals stay untouched.

### 8.2 Directories

```
frontend/
  package.json  pnpm-lock.yaml  vite.config.ts  wrangler.jsonc  tsconfig.json  .env.example
  src/
    app.html  app.d.ts  hooks.server.ts  service-worker.ts (+ its tsconfig)
    lib/contract/  lib/server/  lib/client/  lib/ui/        (see §5.1)
    routes/(public)/sign-in, sign-up, sign-up/check-email, auth/confirm, auth/link-expired
    routes/(gate)/pin, pin/setup, pin/locked, pin/forgot, pin/reset, blocked
    routes/(app)/+layout.server.ts (state + capabilities), +page.svelte (home), workspaces, settings/security
    routes/sign-out/+page.server.ts
  static/  manifest.webmanifest, icons, fonts (via fontsource), offline.html
  tests/unit/  tests/e2e/
```

### 8.3 Milestones

- **M1 — sign-in → PIN → workspace picker (first milestone).** Contract package (§6, all schemas + tests against recorded fixtures shaped exactly like §6), `EdgeTransport` and `SecurityApi`/`OrgApi` (`/state`, `/pin/*`, `/workspaces`, `/capabilities`), the routes in §4.1 except settings, theme switching, tokens, the empty shell, error pages, and e2e for: sign-up → Mailpit link → confirm → set PIN → picker (empty); sign-in → wrong PIN ×2 → correct; lock after 5 → reset via email → new PIN; idle → `pin_required` (the e2e test ages `last_activity_at` through local SQL; nothing in the app shortens the timeout); 320 px + axe in both themes.
- **M2:** Devices & sessions, step-up dialog wired on a real S route (for example `POST /org/memberships/:id/suspend` in a seeded local tenant), unknown-outcome recovery, PWA manifest + service worker + update prompt.
- **M3+:** offices/members/access screens per Paper `App — Screens v2`, as backend slices allow.

### 8.4 CI job

`.github/workflows/frontend.yml`, mirroring `backend.yml`:
- Triggers: `push` to `main`; `pull_request` on `frontend/**` and the workflow file.
- `check` job: Node 24 + pnpm (cached), `pnpm install --frozen-lockfile`, `svelte-check`, lint, `vitest run`, `vite build` (adapter-cloudflare output).
- `e2e` job: `supabase/setup-cli@v1` at the same `2.117.0` as backend CI, `supabase start` in `backend/` (fresh replay of migrations), `supabase functions serve` with a **CI-generated** `PIN_HMAC_SECRET` (`openssl rand -hex 32`, never stored), `PIN_RESET_REDIRECT_URL=http://127.0.0.1:3000/auth/confirm`, empty `CORS_ORIGINS` (BFF needs none). Then the app starts in preview mode on `127.0.0.1:3000` and Playwright runs, reading confirmation emails from the local Mailpit API (`:54324`).
- No deploy from CI in Phase 2. Cloudflare deploy credentials and environments are a later, owner-approved step.

### 8.5 Local dev: local Supabase vs the development project

| | Local Supabase (default) | Dev project `crljnkdwkxkwgvhxfrbl` (smoke only) |
|---|---|---|
| How | `colima start` → `supabase start` in `backend/` → `supabase functions serve` with an ignored env file → `pnpm dev --host 127.0.0.1 --port 3000` (matches local `site_url`) | Same app with `PUBLIC_SUPABASE_URL` = project URL and the **publishable key** in an ignored `frontend/.env.local` |
| Email | Mailpit, nothing leaves the machine; templates from `config.toml` (local only) | Real Cloudflare SMTP; deliveries are real. Use only owner-designated test inboxes, synthetic data. |
| Data | Disposable; e2e seeds via local SQL | No seeding with SQL; no reading of real rows (AGENTS.md) |
| Keys | Local defaults printed by `supabase status` | **Publishable key only.** Never the service-role key, never in Git, never pasted into chat. |
| Changes needed | Fix the `config.toml:163` typo; add local `token_hash` email templates under `[auth.email.template.*]` | Owner-approved dashboard edits only: add `http://127.0.0.1:3000/**` to the Auth redirect allowlist; switch the Confirm signup and Magic Link templates to `token_hash`; set `PIN_RESET_REDIRECT_URL` to the app's `/auth/confirm`. **Never `supabase config push`** (it would overwrite the Cloudflare SMTP setup). |

### 8.6 Spike gates before committing to mode A (first days of Phase 2)

1. **Auth rate limits behind the Worker.** Supabase Auth limits sign-in and sign-up per IP (token bucket, default 30). Behind the Worker every user shares Cloudflare egress IPs. An open `Sb-Forwarded-For` mechanism exists upstream, but support on hosted projects is unconfirmed. Verify with Supabase docs or support; plan Worker-side limits (Cloudflare Rate Limiting binding keyed on client IP + email) and Turnstile on sign-up/sign-in; decide whether the dashboard limits can be raised. If no safe answer is found, fall back to mode B.
2. **Live `verify_jwt` with real user JWTs on the dev project.** There has been no real sign-up yet, so the gateway path with a real access token is unproven. Verify with one owner-approved test account.
3. **`verifyOtp` + `amr`.** Confirm that a `token_hash` magic-link verification produces an `auth.mfa_amr_claims` row with method `otp` or `magiclink` (what `api.complete_pin_reset` checks), first locally, then on dev.

### 8.7 `CORS_ORIGINS` implications

- **Mode A (recommended):** the browser never calls the Edge Functions; the Worker calls them server-to-server without an `Origin` header, so CORS doesn't apply. `CORS_ORIGINS` can stay as narrow as it is today (or empty for the web app). A future native app doesn't use CORS either.
- **Mode B (fallback):** `CORS_ORIGINS` must list **every exact origin**: `http://127.0.0.1:3000` for local, `https://app.elivatewallet.com`, and each preview hostname. `corsHeaders` has no wildcard support (`_shared/http.ts:115-128`), so per-branch preview URLs would each need adding, or one fixed preview hostname. Changing the dev project's secret is a Supabase mutation that needs owner approval. Gateway 401s from `verify_jwt` may lack CORS headers and show up in the browser as opaque network errors.

---

## 9. Decisions I need from you

| # | Question | Options | Recommendation + why |
|---|---|---|---|
| 1 | SvelteKit major version (U-10) | 3.0.x (released 2026-10-01) · 2.70.x | **3.0.x**: greenfield, so no immediate major migration; its required peers (Svelte 5.57, Vite 8, TS 6) are all current. |
| 2 | Effect major version (U-10) | 4.0.x (released 2026-10-01, announced stable/LTS) · 3.22.x | **4.0.x**: Schema in core and long-term support. We avoid its still-unstable HTTP module by wrapping `fetch` ourselves. |
| 3 | Rendering and session model (U-10) | A. SSR + server-held HttpOnly session (BFF) · B. Static SPA with browser-held tokens · C. Hybrid | **A**: the only option meeting W-01/W-22 native POST before hydration with tokens kept out of browser JavaScript. Conditional on the §8.6 rate-limit spike; B is the fallback. |
| 4 | Hosting (U-10) | Cloudflare Workers + static assets · Cloudflare Pages · Node host | **Workers** (`adapter-cloudflare` 8): Cloudflare already runs DNS and email, and it's the target of Cloudflare's SvelteKit guide. |
| 5 | Email link format for sign-up confirmation and PIN reset | Keep default templates (PKCE `code` / implicit `#access_token` fragment) · `token_hash` links to `/auth/confirm` with a Continue (POST) button | **`token_hash` + Continue**: no bearer tokens in URLs, works server-side and cross-device, and email scanners can't consume the link. Needs your approval to edit the dev project's Confirm signup and Magic Link templates and to set `PIN_RESET_REDIRECT_URL`. |
| 6 | Auth abuse/rate-limit handling under mode A | Worker-side rate limiting + Turnstile · raise Supabase per-IP limits · forward client IP (if hosted Supabase supports it) | **Spike first (§8.6), then Worker rate limiting + Turnstile on sign-up/sign-in**: it doesn't depend on unconfirmed forwarding support. |
| 7 | PWA implementation (U-10) | SvelteKit built-in service worker · `@vite-pwa/sveltekit` | **Built-in**: the plugin doesn't support Kit 3 yet (2026-10-08), and the built-in worker makes "assets only, no sensitive caching" explicit. |
| 8 | Package manager (U-10) | pnpm · npm · bun | **pnpm** (pinned via `packageManager`): strict dependency graph and a reviewable lockfile. |
| 9 | Node version for dev/CI (U-10) | Node 24 LTS · Node 22.17+ | **Node 24 LTS** (24.21.0): current LTS, and it meets Kit 3, Vite 8 and Vitest 5 minimums. |
| 10 | TypeScript version (U-10) | 6.0.x · 7.0.x | **6.0.x**: Kit 3 and svelte-check don't support TS 7 yet. |
| 11 | Test tooling (U-10) | Vitest 5 + Playwright 1.64 + axe · alternatives | **Vitest + Playwright + axe**: covers Effect services, components, e2e against local Supabase, and accessibility checks at 320 px. |
| 12 | CSS approach (U-12) | Plain CSS + P-06 tokens · Tailwind v4.3 · UnoCSS | **Plain CSS + tokens**: Emberlit is a small fixed token set, theme switching is one variable layer, no extra framework. Tailwind v4 is fine if you prefer utilities. |
| 13 | Component library (U-12) | Bits UI 2.x (headless) · Melt UI (pre-1.0) · none | **Bits UI**: accessible dialogs, comboboxes and the ⌘K command palette without imposing styles; Emberlit stays the only look. |
| 14 | Icons (U-12) | `@lucide/svelte` · custom set from Paper | **Lucide, unless the Paper file uses another family.** Please confirm, since I can't open Paper in this phase. |
| 15 | Font delivery (U-12) | Self-hosted Lexend variable · Google Fonts | **Self-hosted**: no third-party request on auth pages, and works offline in the PWA shell. |
| 16 | Which auth compositions to build | Approved `Authentication` page · proposed `Authentication v2` (GrainGradient background) | **Your call.** P-06 says v2 is pending adoption. Until you adopt it, I'd build from the approved `Authentication` page. |
| 17 | How the selected workspace travels | HttpOnly cookie + per-form `_ws` echo · workspace ID in the URL path | **Cookie + echo**: keeps IDs out of URLs and logs; the echo stops a stale tab from acting in the wrong workspace. |
| 18 | Auto-select when only one workspace can be selected | Auto-select · always show picker | **Auto-select**: one fewer step for most members; switching stays available in the shell. |
| 19 | Default local dev target | Local Supabase · dev project | **Local Supabase** for daily work and CI; the dev project only for owner-approved smoke tests with the publishable key. |
| 20 | Dev project Auth settings for frontend testing | Approve now · approve at M1 smoke | **Approve at M1 smoke**: add `http://127.0.0.1:3000/**` to redirects, the template change (#5) and `PIN_RESET_REDIRECT_URL`. No `config push`. |
| 21 | Preview/staging origin | One fixed preview hostname · per-branch Workers preview URLs | **One fixed hostname you choose**: Auth redirect allowlists (and CORS in mode B) need exact origins. |
| 22 | Production Supabase project (only dev exists) | Create before the first public deploy · later | **Create before the first public deploy**: not needed for Phase 2 local work, but it blocks any `app.elivatewallet.com` release. |
| 23 | Frontend location in this repo | `frontend/` · `apps/web/` | **`frontend/`**: mirrors `backend/`, so CI path filters stay simple. |
| 24 | Analytics in Phase 2 | Defer PostHog · install now | **Defer**: consent and event taxonomy are open (U-11), and auth pages must not leak data. |
| 25 | Backend doc/code inconsistencies (§6.4) | Fix in a small backend PR · document only | **Small backend PR**: blueprint wording (#1–4, 13, 14), one self-target code (#5), the reset-email failure signal (#8), and a decision on rolled-up member counts (#11). |
| 26 | Office member counts on O01/O03 | Own memberships (current code) · subtree rollup (owner answer 7) | **Subtree rollup, per your 2026-10-07 answer**, which means a backend change to `list_offices`. Until then the UI labels it "in this office". |
| 27 | Native packaging and launch dates (U-10) | Decide now · defer | **Defer**: the bearer-token Edge contract already keeps native clients possible. |

---

## 10. Sources (checked 2026-10-08)

- npm registry `registry.npmjs.org` latest dist-tags and peer dependencies: `@sveltejs/kit` 3.0.1 (2.70.3 last 2.x), `svelte` 5.57.2, `@sveltejs/adapter-cloudflare` 8.0.0, `vite` 8.3.3, `@sveltejs/vite-plugin-svelte` 7.3.1, `effect` 4.0.2 (3.22.2 last 3.x), `@supabase/supabase-js` 2.117.3, `@supabase/ssr` 0.12.7, `vitest` 5.0.3, `@playwright/test` 1.64.0, `@axe-core/playwright` 4.13.0, `tailwindcss` 4.3.3, `bits-ui` 2.19.5, `@melt-ui/svelte` 0.86.6, `typescript` 7.0.2 / 6.0.3, `svelte-check` 4.7.6, `@vite-pwa/sveltekit` 1.1.0, `wrangler` 4.148.0, `@fontsource-variable/lexend` 5.3.0, `@lucide/svelte` 1.52.0, `pnpm` 12.10.1.
- `effect@4.0.2` package contents: `effect/Schema` in core; `effect/http` marked `@stability unstable`.
- Node.js release index `nodejs.org/dist/index.json`: v24.21.0 LTS "Krypton", 2026-09-07.
- SvelteKit 3 migration guide, `svelte.dev/docs/kit/migrating-to-sveltekit-3` (requirements, config in Vite, `#lib`, `csrf.trustedOrigins`, service-worker changes, remote functions still experimental).
- Cloudflare SvelteKit guide, `developers.cloudflare.com/workers/framework-guides/web-apps/sveltekit/` (Workers + Workers Assets, `nodejs_compat`).
- Supabase Edge Functions auth guide, `supabase.com/docs/guides/functions/auth` (`verify_jwt` default and guidance).
- Supabase Auth rate limits, `supabase.com/docs/guides/auth/rate-limits` (IP-based token bucket), and upstream Auth discussion of `Sb-Forwarded-For` (hosted support unconfirmed).
- Effect blog, `effect.website/blog/` (Effect 4.0 announcement, stable/LTS).
