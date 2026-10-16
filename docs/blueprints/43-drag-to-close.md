# Blueprint 43 — Drag a sheet down to close (slice 43)

Status: **Approved 2026-10-16 (owner: "YES, BOTH"); built in slice 43.** Frontend only; no
backend, no Paper.

## What
Every phone bottom sheet shows a grabber, but none could be dragged. One shared behaviour,
`sheetDrag` (`#lib/ui/sheet-drag.ts`, a Svelte attachment), now closes all eight:
`RootDialog` (Profile, payout accounts, withdrawals, transfers, sessions…), `WheelPicker`,
`DatePicker`, `ActivityBrowser` (Filters), `InstallHint`, `OrgDialog`, `IncomeConfirm` and the
Invitations row sheet.

## Behaviour
- **Phones only:** the sheet layout (under 1024 px; Activity uses its own `wide` flag; the iOS
  install hint and the date picker's sheet, shown on any touch screen, always). Desktop dialogs
  are unchanged.
- **Where a drag starts:** the grabber and header (`data-sheet-grab`, `touch-action: none` on
  phones), or the content when everything under the finger is scrolled to the top and the
  finger moves down. Sideways or upward moves, scrolled content, the wheel (`role="listbox"`),
  fields, buttons, links and labels are left to the browser.
- **Following:** the sheet moves with the finger (`translate`, so a sheet's own `transform`,
  such as the wheel's keyboard lift, still applies); upwards only a 12 px rubber band.
- **Letting go:** past a third of the sheet's height, or a flick down (≥ 0.5 px/ms over the last
  100 ms, at least 16 px), slides it out and calls the sheet's own close (the Cancel / Escape
  path, so state, focus return and `onclose` stay right; a light vibration where supported).
  Otherwise it springs back in 200 ms; with reduced motion it snaps.
- **Can't close, can't drag:** each sheet passes its Escape / backdrop rule. `RootDialog`,
  `OrgDialog` and `IncomeConfirm` refuse while busy (posting); the sheet doesn't move at all.
- A sheet opened inside another (a date picker in Filters, the rank wheel in Edit profile)
  drags alone; the outer sheet ignores its gestures and its backdrop.
- The click after a drag is swallowed (a native `<dialog>` would read it as a backdrop tap).
- Grabbers stay `aria-hidden`; keyboard and screen-reader closing is unchanged.

## Tests
- Unit (`sheet-drag.spec.ts`): slop, header vs content start, scrolled content, sideways and
  upward moves, refusal while busy, rubber band, velocity window, close past a third, flick
  vs jitter.
- e2e (`visual.e2e.ts`, 390 px): Edit profile follows a short drag and springs back, closes
  past a third (focus back on the row) and on a flick; a drag from a field leaves it open; the
  same with real touches (CDP), so touch-action and the browser's pan are covered.
