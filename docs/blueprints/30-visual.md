# Blueprint 30 — Header, Activity chips, Profile banner, desktop dropdowns (slice 30)

Status: **owner feedback 2026-10-11; built in slice 30.** Frontend only.

### Owner decisions (2026-10-11, binding)
1. **Header:** drop the "role · office" line, replace the heavy coral initial tile with a quiet
   one, fix spacing and alignment. Applies to the phone app bar and the desktop sidebar
   switcher; the role and office stay on Profile and More.
2. **Desktop dropdowns:** a list anchored under the field (the field's width, at least 220 px;
   search for long lists); the wheel stays on phones and touch screens.
3. Activity filters and the Profile & security banner must look as drawn (Paper M04, B10).

## Causes found
- **Activity chips** sat in a bordered rail on phones: the shell's global `.segmented` (a
  segmented-control style) leaked onto the chip row. Paper M04 has separate chips.
- **Profile banner** centred and indented its content, cutting off the photo: the shell's global
  `.identity` (the account menu row: centred, 16 px padding) leaked onto the banner. A photo that
  failed to load showed a broken image.

## B1. Frontend
- **Header** (`routes/app/+layout.svelte`): network name only (16 px) with a switch chevron; the
  initial tile is quiet (raised surface, 1 px border, coral letter); one 56 px row that shares
  a centre line with the bell and avatar. The team logo still replaces the tile.
- **Activity** (`ActivityBrowser`): the chip row resets the leaked rail on phones (both themes).
- **Profile banner** (`AccountHero`, account page): stretch and pad explicitly, photo and name on
  one left edge, never clipped; a failed photo falls back to the initials.
- **WheelPicker** (`#lib/ui/WheelPicker.svelte`): on `(min-width: 1024px) and (pointer: fine)`
  it opens a Popover-API list under the field (flips above when there is no room, follows
  page scroll): one click chooses, arrows / Page / Home / End / type-ahead move, Enter chooses,
  Escape and Tab close (Escape never closes a Bits dialog underneath), a click outside closes.
  Long lists keep the search field. Phones and touch screens keep the wheel sheet.
- e2e: `pick()` handles both modes; `visual.e2e.ts` covers the anchored list, the header, the
  chips and the banner; `pickers.e2e.ts` has a desktop list test.

## Still open
The owner's Activity-filter screenshot never arrived; the leaked rail is the border problem
found on the screen. Next: lighter email Root images (slice 31).
