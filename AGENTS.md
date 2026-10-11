# Elivate Wallet 2.0 — Agent Instructions

Rules for any agent in this repo. History lives in Git and `docs/`; keep this file short.

## Boundaries

- Never open or summarize the legacy frontend (`elivatepro/elivate-wallet-legacy`) or other UI
  code. `legacy-backend/` is read-only reference; never build or deploy it.
- **Production is off-limits.** "Prod" means the dev Supabase project plus the live Worker.
- **Secrets** never go in Git, Paper, chat, logs, URLs or this file. Repo-root `.env` (ignored)
  holds local values; copy them into secret stores without printing them.
- **Data:** dev has real accounts. Never query, export or touch real user or financial rows;
  review uses code and schema; smoke tests create no users and use synthetic data.
- Never run `supabase config push`. Change Auth only through the Management API, field by field.
- Paper only for a requested design task or a drawn screen's exact values; inspect before
  editing; synthetic data only.

## Start here

1. `00-product.md`, then the relevant `01-domain-rules.md` and `02-workflows.md` sections before
   touching auth, identity, money, evidence or billing.
2. `docs/member-build-plan.md` before any member slice; its "Owner decisions during the build"
   are binding, and the latest decision wins (update the affected contract line).
3. Check `git status`, scripts and current source first. Report code/contract conflicts; never
   invent unresolved decisions (P-09): ask, with options.

## Stack (decided; do not reopen)

- Supabase Auth + Postgres + Edge Functions (Deno); Postgres owns authorization and money.
- `frontend/`: SvelteKit 3, Svelte 5, Effect 4, TypeScript 6, pnpm, Node 24; BFF with HttpOnly
  session cookies; plain CSS + Emberlit tokens, Bits UI, Lucide, Lexend. Cloudflare Worker
  `elivate-wallet-app` (app.elivatewallet.com) with private R2 `PHOTOS` (also logos),
  `EXPORTS` (7-day lifecycle) and `BACKUPS` (no lifecycle; 90-day expiry in the database) and
  Browser Rendering `BROWSER` (PDFs). Support chat: Chatwoot Cloud, loaded on demand.
- Email: Auth via Cloudflare SMTP; app email via the outbox and Cloudflare REST on
  `_shared/email/layout.ts` (Paper "Emails — Transactional v2"); a new kind adds a template row,
  a renderer and a `notify.emit` call (Blueprint 13). Paystack (test mode) for yearly billing.
- Design: Paper file `Elivate Wallet`. Build drawn screens directly; draft undrawn ones in Paper
  and get approval first. Extend existing routes in `frontend/src/routes`. Accepted deviations:
  single-screen PIN entry, wizard progress bar in the panel. Member-app dropdowns are the
  `WheelPicker` (Blueprint 24; banks included); the admin console keeps native selects.

## Backend rules

- Only `api.*` functions are `security definer` (plus three accepted ledger trigger checks);
  every function sets `search_path = ''`; private schemas stay private.
- Validate all transport and provider input/output. Reuse envelopes, routes, permissions and
  error codes (new cases: `conflict` + `details.reason`).
- Keep exact money/currency provenance, tenant isolation, idempotency, evidence, audit and F-03
  recovery. No direct client writes to protected tables.

## Environments

- Dev Supabase `crljnkdwkxkwgvhxfrbl` (no production project). pg_cron wakes workers through
  Vault URL/secret pairs (outbox, payout checker, exports, billing sync). Auth redirects:
  `https://app.elivatewallet.com`, `http://127.0.0.1:3000/**`.
- Worker secrets: `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `TURNSTILE_SITE_KEY`,
  `TURNSTILE_SECRET_KEY`, `APP_SERVER_SECRET` and `EXPORTS_WORKER_SECRET` (each of the last two
  matches its Edge secret; the exports one also matches Vault), plus `CHATWOOT_WEBSITE_TOKEN`
  and `CHATWOOT_HMAC_TOKEN` (Blueprint 17). Admin Worker `elivate-wallet-admin`
  (`frontend/wrangler.admin.jsonc`, `APP_SURFACE=admin`, admin.elivatewallet.com behind Cloudflare
  Access): `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `APP_SERVER_SECRET`. Edge `BILLING_WORKER_SECRET`
  matches Vault `billing_worker_secret`; Paystack is test mode (`PAYSTACK_SECRET_KEY`).
- Still open: the signed-in dev call test (Edge `verify_jwt` with ES256 user tokens; see
  `docs/production-readiness.md`), editing the dev Auth email templates.

## How a slice ships

- One slice at a time, in worktree `../elivate-wallet-worktrees/<nn-name>` from fresh
  `origin/main` (copy `backend/supabase/.temp` in). Blueprint `docs/blueprints/NN-*.md`;
  migrations `20261009NNxxxx`, pgTAP `NN0_` (next: `27`/`270_`).
- Checks: `backend/scripts/verify-database.sh`, `deno task check`; frontend `pnpm check`,
  `pnpm lint`, `pnpm test:unit`, e2e via `frontend/scripts/e2e-local.sh` (fake Cloudflare into
  local Mailpit). The local stack is shared: hold the `/tmp/elivate-supabase.lock` directory
  (`mkdir`/`rmdir`) while using it.
- One PR per slice, linked to the thread; wait for CI and Greptile (read comments by latest
  timestamp) and fix real findings before merging.
- Deploy to dev from fresh `origin/main` (owner approval covers the member build):
  - Migrations: `supabase db push --linked --include-all` in `backend/`. Port 5432 may be
    blocked on the owner's network; the Supabase GitHub integration has applied them at merge
    so far. Check the dev history via the Management API first and say which path was used.
  - Deploy changed functions and any new secrets, then `pnpm build && pnpm exec wrangler deploy`
    in `frontend/` (deploy doesn't build; CI's `wrangler deploy --dry-run` checks the bundle).
  - Other sessions may deploy too: confirm a new route is live; redeploy from fresh main if not.
- Report what ran and what didn't. Never reset, force-push or discard others' work.

## Status (2026-10-11)

On dev: backend slices 01–06, frontend M1, member slices 1–10 and the slice 9 follow-up
(blueprints 07–17). Slice 18 (Blueprint 18): the platform Admin app (admin.elivatewallet.com),
kill switches and guided restore review; feature flags deferred. Slice 19 (Blueprint 19):
founder applications (apply first at `/apply`, admin review, `/founder` invitation; only approved
founders start networks). Slice 20 (Blueprint 20): speed and caching (Smart Placement,
bootstrap/home reads, device-cache-first pages, 30 s session touch, indexes). Slice 21
(Blueprint 21): owner feedback fixes. Slice 22 (Blueprint 22, PR #59, not yet on dev): setup by
role (light vs wallet), a backend `profile_required` gate, "funds not managed" directors. Slice 23
(Blueprint 23, frontend only): every page opens from its saved copy, instant tap feedback, idle
code preload of every screen, page swap. Slice 24 (Blueprint 24, frontend only): one haptic
wheel picker, with search for long lists and banks, for every member-app dropdown. Slice 25
(Blueprint 25): pill tab bar per role, sectioned sidebar, network home with "Offices this month"
(`api.leadership_offices`). Slice 26 (owner fix, no blueprint): the setup profile step starts from the
founder application's name and rank (`suggested` on the profile read). Next: set-based authorization reads.
