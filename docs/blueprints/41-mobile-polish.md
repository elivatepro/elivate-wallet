# Blueprint 41 — Mobile polish (slice 41)

Status: **owner feedback 2026-10-15; scope approved; built in slice 41.** Frontend only.

### Owner decisions (2026-10-15, binding)
1. **Appearance on phones** is one **Dark mode** switch on More (the same switch row as Hide
   amounts). On = the dark theme is on screen ("System" is resolved through the device setting);
   a tap chooses Dark or Light. The desktop account menu keeps Light / Dark / System.
2. **Loading feedback is "spin + outlines":** a pressed look on every button and tile, a small
   spinner on the tapped item when its page takes more than 150 ms, content-shaped outlines
   (skeletons) for pages and the transaction detail. Calm, accent colour, **no top progress bar**.
3. **Withdrawals banner** on phones: about 200 px tall with Root about 120 px wide; title and
   chips stay readable. Desktop unchanged; other Root banners unchanged.
4. **Home "Recent activity" rows** open the transaction, like Activity's rows.

## Causes found
- **Tab bar flash** on tapping the current tab: SvelteKit treats a same-URL link as a refresh
  (scroll reset, re-render), and iOS drops the bar's fixed, blurred layer for a frame. During a
  page swap the fading page (`ew-page`) also painted over the bar.
- **Quick search on phones:** the list scrolled to the highlighted row on every keystroke; a
  finger dragging over rows moved the highlight; the full-screen sheet ignored the on-screen
  keyboard (results and the Root hint sat under it); the field was focused after the tap, so iOS
  often kept the keyboard down; every keystroke flipped the list to "loading" (dimmed list,
  "Searching…") before the 200 ms debounce; opening a result returned focus to the trigger (a
  scroll jump, a keyboard flash); the palette unmounted whenever the shell left "ready".

## B1. Frontend
- **Current tab** (`routes/app/+layout.svelte`, `sameDestination`/`plainClick` in `#lib/nav.ts`):
  a plain tap on the tab or sidebar item of the page on screen (same path and query) is kept on
  the page and scrolls it to the top (smooth; instant with reduced motion). During a page swap
  the tab bar is its own view-transition layer (`ew-tabs`) above `ew-page`, shown in its new
  state at once.
- **Quick search** (`QuickSearch.svelte`, `searchNote` in `#lib/client/search.ts`):
  - the list scrolls only for arrow keys; only a mouse moves the highlight;
  - on phones the sheet is the visual viewport (`visualViewport` top and height, as the wheel
    picker does), so the field and results stay above the keyboard; the Root hint shows only
    with the keyboard down and a tall enough screen;
  - More's "Quick search…" focuses an invisible stand-in field inside the tap on touch screens
    (`#lib/client/keyboard-proxy.ts`); the search field takes the focus over when it mounts (the
    keyboard stays up) and the stand-in is removed;
  - the last results stay while typing; "loading" starts when the request goes out, the list
    dims only after 300 ms of waiting, "Searching…" shows only when nothing is on screen, and
    "No matches" stays steady while the next answer comes;
  - opening a result blurs the field and closes without returning focus; Cancel / Escape return
    focus to the trigger without scrolling (never to the stand-in);
  - mounted once the workspace has loaded (last permissions kept) through retries and offline.
- **Home activity** (`WalletHome.svelte`): with `view_own_financials` each row is a link to
  `/app/activity?tx=<id>` (full-page detail on phones, Back returns Home; the split panel on
  desktop), pressed and hover states; without it the row stays plain.
- **Withdrawals banner:** `RootHero` gets `short` (200 px, padding 18 px, Root 120×161, image
  `sizes` 120 px on phones; the text column widens, chips wrap). Used by `/app/withdrawals` only.
- **Dark mode switch** (`routes/app/more/+page.svelte`, `effectiveTheme` in `#lib/theme.ts`,
  `Appearance.shown` follows `prefers-color-scheme`).
- **Pressed look** (`base.css`, zero specificity so a component's own `:active` or placement
  transform wins): buttons and button-styled links press to 98% with a slight darken; list
  rows darken (`.mm-row` in `money.css` too); Home's quick actions; no layout shift.
- **Tapped-item spinner** (`#lib/client/pending-tap.ts`, root layout, so the app, sign-in and
  admin sites alike): the link or button tapped within 1 s before a navigation shows a 16 px
  accent spinner if the navigation still runs after 150 ms, cleared on completion or cancel. It
  replaces the element's `data-pending-slot` icon (tab icons, activity tiles) or its chevron,
  else sits at the trailing edge. Buttons that are already busy or disabled keep their own state.
  Same-page `?tx=` taps (Activity rows) spin the same way.
- **Busy commands:** `ConfirmDialog`, `OrgDialog`, `RootDialog`, `IncomeConfirm`, the auth
  `PrimaryButton` (in its chip) and Move money's "Send request" show a spinner and the working
  label (`busyLabel` in `#lib/ui/busy-label.ts`: "Save changes" → "Saving…"), at full colour.
- **Outlines** (`.ew-skel` in `base.css`, a soft sweep, still with reduced motion):
  `PageFrame` is a heading, a balance-style card and list rows; Activity's transaction detail
  shows an outline (amount, title, facts) while `/api/activity/:id` loads, as a page on phones
  and in the panel on desktop. The admin console shows `PageFrame` after 150 ms of a page
  loading; sign-in pages dim their panel a little after 150 ms (plus the tapped-item spinner).
- Unit tests: `nav.spec.ts` (same destination, plain click), `theme.spec.ts`,
  `search.spec.ts` (`searchNote`), `pending-tap.spec.ts`, `busy-label.spec.ts`.
- e2e (`visual.e2e.ts`, 390 px): the current tab keeps the page and scrolls to the top, a Home
  row opens its detail and Back returns Home, the Dark mode switch, quick search opens focused,
  the Withdrawals banner is about 200 px.

## Not changed
The withdrawal request page, `WithdrawalPanel` and `TransactionDetail` (slice 40 works on them):
their PIN dialogs get the spinner through `RootDialog`; the request page's own buttons are
unchanged. Nothing new on the backend.
