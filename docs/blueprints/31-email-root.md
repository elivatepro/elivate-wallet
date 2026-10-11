# Blueprint 31 — Lighter email images (slice 31)

Status: **owner decision 2026-10-11 ("Root in emails still loads after the email is opened";
keep the images linked, make them lighter, no inline attachments); built in slice 31.**
Assets only; no template change.

## What changed (`frontend/static/email/`)
- **Root poses (46):** 234×315 (1.5× the 156×210 shown; phones show 88×118), 48-colour PNG with
  alpha, oxipng. About 12 KB each, was about 35 KB.
- **Hero grain (`hero.jpg`):** 792×336 (1.5× the 528 px band), progressive JPEG, quality 60.
  15 KB, was 58 KB.
- One email's images: about 27 KB, was about 95 KB (−70%). All email assets: 0.56 MB, was 1.63 MB.
- PNG and JPEG on purpose: WebP and AVIF don't show in every mail client (Outlook desktop).
- Checked on the dark band: no halo on Root's edges; the band keeps `bgcolor="#1A1D1E"`, so it
  is drawn before its images arrive. Cache headers unchanged (30 days, `/email/*`).

## Why it still loads after opening
Mail clients fetch linked images after the message opens (Gmail through its image proxy, which
then keeps them). Smaller files arrive sooner; only inline attachments would remove the wait,
and the owner chose not to use them.
