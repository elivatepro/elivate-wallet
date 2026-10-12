# Blueprint 35 — Install the app, home-screen name, launch animation (slice 35)

Status: **owner approved 2026-10-12 (Paper "Install app v9 (DRAFT 2026-10-12)"); built in
slice 35.** Frontend only: no migration, no Edge change.

### Owner decisions (2026-10-12, binding)

1. Every user's onboarding ends with installing the app (the PWA), before "All set". Drawn as
   IA01 (Android), IA02 (iPhone/iPad Safari) and IA03 (computer, with a dock and a QR code for
   the phone). The desktop title is "Install Elivate Wallet"; the QR code must really work.
2. The label under the home-screen icon is **Wallet**. The full name stays "Elivate Wallet".
3. The installed app opens with an animation (L02–L05): the phone's still launch screen, then
   the glow blooms, "Wallet / BY ELIVATE" rises, and the app appears.

## B1. Install step (`/onboarding/install`)

- **Order:** `nextStepFor` returns `install` once the backend's gate is `ready`, until the
  `ew_onb_install` cookie (path `/onboarding`, 1 day, cleared on finish) says it was handled.
  Wallet setup is now 5 steps and the light setup 3. The bank step goes to `/onboarding/continue`.
  The backend is not involved: the step is browser only and can't hold anyone back.
- **Which screen:** `installDeviceFor(userAgent, touchPoints)` (server first, corrected on mount
  for iPads that say "Mac"): `android` and `desktop` use Chromium's install prompt (captured
  from app start by `listenForInstallPrompt` in the root layout); `ios` shows the three Safari
  taps; `mac-safari` says File › Add to Dock; `in-app` (Instagram, WhatsApp, Facebook…) says to
  open the page in Chrome or Safari. If no prompt arrives within 3 s, or it was dismissed, the
  screen points to the browser's own menu (Install / Add to Home screen) with "Continue".
- **Moves on by itself** when the page is already running as the installed app, or when the
  browser reports `appinstalled` / the prompt is accepted. "Not now" always works.
- **Picture:** Root's stage shows `InstallArt` instead of a pose (`useStageArt`): the tilted
  home screen with the Wallet tile on phones, the dock with the app raised on computers.
- **QR (computers):** `qrPath` (uqr, ECC M, 4-module quiet zone) encodes `<origin>/app`, drawn as
  an SVG path on white. Verified by decoding the Paper export and the unit test's bounds.

## B2. Name and launch

- `manifest.webmanifest` `short_name` and `apple-mobile-web-app-title`: "Wallet".
- **Launch animation** (`app.html`): a CSS overlay shown only in `display-mode: standalone`
  and `prefers-reduced-motion: no-preference`, 1.2 s, no input blocked. A tiny inline script
  marks it played for the session, so later full page loads skip it; the CSP allows it by its
  sha256, computed from app.html in `vite.config.ts` (no extra request on any page).
- **iOS launch images:** 19 `apple-touch-startup-image` PNGs (`static/splash/`, from
  `scripts/make-splash.ts`): #111314 with the mark at 140 CSS px, the animation's first frame.
  Not precached by the service worker. Android builds its own still screen from the manifest.

## Still open

People who finished onboarding before this slice don't see the step; iPhone users in Safari
still get the in-app "Add to Home Screen" hint (H08).
