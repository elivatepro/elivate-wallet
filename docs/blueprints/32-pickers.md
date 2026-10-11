# Blueprint 32 — Member picker layout and the app's date picker (slice 32)

Status: **owner feedback 2026-10-11 (the "Choose the member" sheet still looked broken; "make
this date picker and every other date picker better, designed and easily accessible").**
Design: Paper `Elivate Wallet`, page "Date picker v8 (DRAFT 2026-10-11)": DP01 (desktop,
anchored), DP02 (phone, bottom sheet). Frontend only.

## Member picker (Record income)
- Rows were pushed 40 px right of the search box: the browser's default list indent. `base.css`
  now resets `ul, ol` margin and padding (zero specificity) for every list.
- "Close" sat on the dialog's edge: the picker borrowed ConfirmDialog's `.confirm-actions`, which
  is scoped to ConfirmDialog. It has its own `.picker-actions` row now.

## DatePicker (`#lib/ui/DatePicker.svelte`, logic in `#lib/ui/date-picker.ts`)
- The field reads "2 Oct 2026" (never 11/10/2026, which reads two ways) with a calendar icon,
  in the page's own field style.
- Desktop with a mouse: a calendar anchored under the field (Popover API; flips above; follows
  scroll). Phones and touch screens: a bottom sheet with the field's name and the chosen day.
- Monday-first month grid; today ringed in coral, the chosen day filled; days outside min/max
  dimmed and refused; Today / Yesterday where allowed; Clear on optional fields; the month title
  opens a month-and-year view for long jumps. Choosing a day closes it.
- Keyboard (WAI-ARIA date picker dialog): arrows by day and week, Home/End, Page Up/Down by month
  (Shift: year), Enter/Space choose, Escape closes (months view first; never a Bits dialog
  underneath). Day buttons are named "Sunday 11 October 2026", today has `aria-current="date"`.
- Without JS: the native `<input type="date">` with the same id, name, min and max.
- Every member-app date field uses it (13): Record income, payout record and fix, access grants
  (expiry can't be before the start), Activity custom range (both places), report and statement
  periods. The admin console keeps native fields (as with selects).
