# Blueprint 29 — Forms that wait for you, and forms that match Paper (slice 29)

Status: **owner feedback 2026-10-11 ("the form tries to submit when I've not even gotten there
yet"; "the design looks off, not what you designed in Paper"); built in slice 29.** Frontend only.

Design: Paper `Elivate Wallet`, "App — Screens v1" M06 (withdraw, desktop), M09/M10 (withdraw,
mobile), C13/C14 (invite member) and "App — Screens v4" J01 (record income). Root pose
"Invitation (Invite member)" shipped as `invite-member`.

## Why forms complained early (found and reproduced)
1. **A picker's button submitted the form.** Bits UI renders `Dialog.Trigger` (and Close, Popover
   and DropdownMenu triggers) as a `<button>` with no `type`; inside a `<form>` that is a submit
   button. Tapping "Choose a member" on Record income opened the picker *and* submitted the form,
   so every empty field showed its error. A browser test reproduces it on the code before this
   slice and passes after.
2. **Enter submitted the form.** A phone keyboard's Go / Done key sends Enter, and Enter in a text
   field submits its form (implicit submission). Typing an amount and tapping Done to close the
   keyboard validated the whole form (Record income, Withdraw, Invite); on returned funds,
   reversals and conversion it could send the command.

## B1. The fix (frontend)
- Every Bits UI Trigger / Close / Cancel / Action says `type="button"`; a unit test
  (`form-buttons.spec.ts`) fails if one is added without it.
- `enterMovesOn` (`#lib/ui/enter-moves-on.ts`, a Svelte attachment) on every form with more than
  one field: Enter moves to the next field (typing fields and picker triggers), the last field
  closes the keyboard, and only a field marked `data-enter-submits` (the PIN, the natural last
  step) submits on Enter. The keyboard key reads "Next", "Done" or "Go" to match. The submit
  button is unchanged and still validates everything. Short confirm dialogs (PIN + reason)
  keep the browser default.

## B2. Matching Paper
- **Withdraw on phones (M09/M10):** a full-screen flow with its own bar (close, "Withdraw",
  "1 / 3"; back, "Review", "2 / 3") and no tab bar; a pocket chip (the wheel), the amount in
  52 px with its caret, "available in", Use max, a "To" card with Change (the wheel), an in-app
  keypad (a hardware keyboard works too) and Continue. Review shows the amount and From / To /
  Name, then Submit request opens the PIN sheet. Desktop (M06/M07) is unchanged except that its
  buttons keep their own width, right-aligned, as drawn.
- **Invite a member (C13/C14):** the grainy band with Root holding the invitation, "Invite a
  member" and "Joins <office> as a <role>". Paper's "Full name" and "Copy invite link" are not
  built: the backend takes no name, and invite links never reach the page (Blueprint 03).
- **Record income (J01):** already matched; the mobile split preview no longer has a list indent.

## Not in this slice
Header, Activity filter borders, Profile & security banner, anchored desktop dropdowns (slice 30);
lighter email Root images (slice 31).
