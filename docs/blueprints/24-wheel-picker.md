# Blueprint 24 — One haptic wheel picker for every dropdown (slice 24)

Status: **owner decisions 2026-10-11; built in slice 24.**

Contract: `docs/member-build-plan.md` "Owner feedback round (2026-10-10)" (slice 24) and
"Wheel pickers (2026-10-11)", 02 W-02 (rank: search, keyboard and empty-result support), W-17
(payout accounts). Builds on the onboarding rank sheet (Paper 10 "Your rank"), Blueprint 21 (ranks
number first) and 23 (page cache, page swap). Frontend only: no migrations, no Edge changes, no
new routes. The admin console keeps its native selects.

### Owner decisions (2026-10-11, binding)
1. Every dropdown in the **member app** uses the same smooth scrolling wheel with haptics as the
   onboarding rank picker: bottom sheet, scroll-snap wheel with 52 px rows, a vibration on each
   step, arrows/Enter/Escape, focus kept in the sheet, listbox/option roles, and a native
   `<select>` without JS.
2. Long lists get a **search field** in the sheet: filter as you type, keyboard reachable, a clear
   message when nothing matches. Threshold: more than 8 options, and always for banks.
3. The bank selects (onboarding bank step, Add payout account) move to the wheel with search. This
   **withdraws the "native bank select" accepted deviation** (AGENTS.md, build plan).
4. Ranks show number first everywhere (`rankLabel`, Blueprint 21).

---

## B1. `WheelPicker.svelte` (`#lib/ui/WheelPicker.svelte`)
- **Props:** `options {value, label, hint?, disabled?}[]`, `value` (bindable), `id`, `name`,
  `label` (the wheel's name and default title), `title`, `sub`, `confirmText` (default "Done"),
  `placeholder`, `triggerText` (fixed field text: Activity filters, "+ Add"), `ariaLabel` (when
  the page has no `<label for>`), `class` (the page's own field class) or `variant`
  (`field` | `auth`), `fit`, `invalid`, `describedby`, `disabled`, `required`, `searchable`
  (`'auto'` | `true` | `false`), `searchPlaceholder`, `emptyText`, `initial` (the row to start
  on when nothing is chosen), `onchange(value)`.
- **Without JS** (and for the instant before a server-rendered page hydrates): a native `<select>`
  with the same `id`, `name` and options, so server actions work as before. Pickers created after
  the first hydration (every in-app page) start enhanced, with no select flash.
- **With JS:** a `<button role="combobox" aria-haspopup="dialog">` named by the page's
  `<label for={id}>`, showing the chosen label (and hint) or the placeholder. With `name`, a
  hidden input posts the value (disabled with the field, like a disabled select).
- **The sheet** is a native modal `<dialog>` (top layer). It escapes transforms and stacking, and
  works inside Bits UI dialogs (Invite, office and member dialogs, Edit profile, renewal): its
  Escape and Tab are handled first and stop there, so the dialog underneath stays open. The
  page doesn't scroll while it is open. On iOS the sheet lifts above the on-screen keyboard
  (`visualViewport`). Grip, title, optional line, optional search, the wheel (5 rows visible,
  lens on the third) and the confirm button: the rank sheet's look, unchanged.
- **Choosing:** scrolling (touch, mouse wheel, trackpad) snaps row by row; tapping a row turns
  the wheel to it; the confirm button, Enter or Space chooses the row in the lens. Escape, the
  backdrop or Android's back gesture closes without choosing. Focus returns to the field.
  Disabled options (billing's plans that are too small) show dimmed and can't be confirmed.
- **Keyboard:** on the wheel, arrows step one row, Page Up/Down five, Home/End jump to the ends,
  letters type ahead (a repeated letter cycles). In the search field, arrows and Page keys move
  the wheel and Enter chooses. Tab cycles search → wheel → confirm inside the sheet.
- **Search:** shown when `searchable` is true, or for `'auto'` when there are more than 8
  options. Case, accents and punctuation are ignored; every word typed must appear in the label
  or start a word of the hint; labels that start with the query come first, otherwise the list
  keeps its order. The wheel jumps to the top match, so typing then Enter chooses it. With no
  match: "Nothing matches “…”" (or the page's `emptyText`, e.g. "No bank matches that name."),
  "Check the spelling or try fewer letters.", and the confirm button is disabled. A polite live
  region announces the match count.
- **Where focus starts:** with a mouse or keyboard, in the search field (type straight away); on
  a touch screen (`pointer: coarse`), on the wheel, so the on-screen keyboard doesn't cover the
  wheel until the person taps the search field.
- **Accessibility:** combobox field with `aria-expanded` / `aria-controls`; the sheet is a dialog
  named by its title; the wheel is a `listbox` with `aria-activedescendant`; rows are `option`s
  with `aria-selected` on the lens row (`aria-disabled` when not choosable); the search field is
  a combobox controlling the listbox. Axe runs with the sheet open (e2e).
- **Reduced motion:** the wheel jumps instead of gliding, and the sheet's rise, the row
  transitions and the lens tick are off.
- **Pure rules** (`#lib/ui/wheel-picker.ts`, unit tested): `shouldSearch`, `normalise`,
  `filterOptions`, `startIndex`, `keyTarget`, `typeahead`, `rowAt`.

## B2. Haptics
- Each detent calls `navigator.vibrate(8)` where the browser has it (Chrome on Android; it needs
  the tap that opened the sheet, which it always has). **iOS Safari has no web vibration API**
  (and no other web haptics), so on iPhones the step is visual only: the snap, the lens row
  growing and a short tick of the lens (scale 1.06 → 1, 120 ms; off with reduced motion).

## B3. Desktop
- **Decision: the same wheel on every screen.** At 1024 px and wider the sheet is a centred
  dialog (the rank sheet already did this) instead of a bottom sheet; the grip is hidden. The
  owner asked for one picker everywhere; one code path keeps behaviour, keyboard and tests
  identical. The mouse wheel and trackpad snap row by row, rows are clickable, and keyboard
  people get search, arrows and type-ahead. An anchored popover list was considered and left
  out: a second rendering of the same control for little gain.

## B4. Converted sites (member app)
| Page | Field | Search |
|---|---|---|
| `/apply` | Your rank (founder ranks) | — |
| Onboarding profile (RankPicker) | Your rank | yes (14) |
| Onboarding bank | Bank | always |
| Account → Edit profile | Rank | yes (14) |
| Payout accounts → Add | Bank | always |
| Invite dialog | Office | auto |
| Export report (Reports, Export) | Period (with "This month" etc. as hints) | — |
| Pockets & split → Move | Wallet (office · currency) | auto |
| Settings → Details | Language, Time zone | auto |
| Roles & access → grant | "+ Add" permission, Office scope | auto |
| Adjustment | Reason | — |
| Record income | Currency | — |
| Statements | Network | auto |
| Queue → Returned funds | Completed withdrawal (name; amount · reference) | auto |
| Offices → New office | Parent office | auto |
| Office → Replace leader | Leader to replace | auto |
| Member → Move / Change role | New office (type as hint), New role | auto |
| Conversion | Pocket (available as hint), Currency received | — |
| Reversals | Reason | — |
| Billing → renewal | Next year's plan (too-small plans disabled) | — |
| Activity (desktop filters) | Currency, Status, Type, Pocket, Date | auto |

- `RankPicker.svelte` is now a thin wrapper (auth look, "Set rank", starts on Executive Manager).
  The rank sheet gains the search field W-02 asks for; otherwise it looks as before.
- The Activity filter **sheet** on phones keeps its chips (they are not dropdowns). Action menus
  stay menus (the account menu, row "Options" menus). The admin console is unchanged.
- Each page keeps its own field look by passing its global class (`o-input`, `en-box`,
  `en-input`, `s-input`, `ex-select`, `mm-input`, `en-chip`, `filter`) or styling the field
  through a wrapper (`:global(.wp-trigger)`) where its class was scoped.

## B5. Page cache and page swap (Blueprint 23)
- The sheet only exists while open and lives in the top layer, so the page swap's view
  transition (which names `.content` during a swap only) never captures it. Leaving the page
  with the sheet open removes it and gives the page its scroll back. Values come from the page's
  (cached or fresh) data as before; pickers read nothing themselves.

## Tests
- Unit (`wheel-picker.spec.ts`): the search threshold, normalising, matching (inside labels,
  every word, hint word starts, prefix first, empty), the start row, keys (step, page, ends,
  limits), type-ahead (cycling, wrapping) and the scroll → row mapping.
- e2e:
  - `pickers.e2e.ts` (on `/apply`, no account): without JS the rank is a native select the form
    posts; with JS, at 390 px and 1440 px: the combobox opens the sheet, axe passes with it open,
    Escape keeps the old value and returns focus, End + Enter chooses, Tab stays in the sheet, a
    tapped row is chosen, and the hidden input posts the value.
  - `invitations.e2e.ts`: the bank search (no match message with Done disabled, filtering, the
    top match chosen with Enter, focus back on the field), axe with the sheet open.
  - Every flow that used `selectOption` on a converted field drives the wheel through the
    `pick(field, option)` helper. The fake Paystack bank list has ten banks (only 058 resolves).

## Checks and rollout
- `pnpm check`, `pnpm lint`, `pnpm test:unit`, `e2e-local.sh` (backend untouched).
- Deploy: the app Worker only.
