# Elivate Wallet 2.0 — Agent Instructions

Rules for any agent in this repo. History lives in Git and `docs/`; keep this file short.

## Boundaries

- Never open or summarize the legacy frontend (`elivatepro/elivate-wallet-legacy`) or other UI
  code. `legacy-backend/` is read-only reference; never build or deploy it.
- **Production is off-limits.** "Prod" means the dev Supabase project plus the live Worker.
- **Secrets** never go in Git, Paper, chat, logs, URLs or this file. Repo-root `.env` (ignored)
  holds local values; copy them into secret stores without printing them.
- **Data:** dev has real accounts now. Never query, export or touch real user or financial
  rows; review uses code and schema; smoke tests create no users and use synthetic data.
- Never run `supabase config push`. Change Auth only through the Management API, field by field.
- Paper only for a requested design task or a drawn screen's exact values; inspect before
  editing; synthetic data only.

## Start here

1. `00-product.md`, then the relevant `01-domain-rules.md` and the full workflow in
   `02-workflows.md` before touching auth, identity, money, evidence or billing.
2. `docs/member-build-plan.md` before any member slice; "Owner decisions during the build" is
   binding. The latest owner decision wins: update the affected contract line.
3. Check `git status`, scripts and current source first. Report code/contract conflicts; never
   invent unresolved decisions (P-09) — ask, with options.

## Stack (decided; do not reopen)

- Supabase Auth + Postgres + Edge Functions (Deno); Postgres owns authorization and money.
- `frontend/`: SvelteKit 3, Svelte 5, Effect 4, TypeScript 6, pnpm, Node 24; BFF with HttpOnly
  session cookies; plain CSS + Emberlit tokens, Bits UI, Lucide, Lexend. Cloudflare Worker
  `elivate-wallet-app` (app.elivatewallet.com, private R2 `PHOTOS`).
- Email: Auth via Cloudflare SMTP; app email via the outbox and Cloudflare REST, rendered on
  `_shared/email/layout.ts` (Paper "Emails — Transactional v2"); new kinds add a template row,
  a renderer and a `notify.emit` call (Blueprint 13). Paystack (test mode) for yearly billing.
- Design: Paper file `Elivate Wallet`. Drawn screens are built directly; undrawn ones are drafted
  in Paper and approved first. Extend existing routes in `frontend/src/routes`, don't rebuild.
  Accepted deviations: single-screen PIN entry, wizard progress bar in the panel, native bank select.

## Backend rules

- Only `api.*` functions are `security definer` (plus three accepted ledger trigger checks);
  every function sets `search_path = ''`; private schemas stay private.
- Validate all transport and provider input/output. Reuse envelopes, routes, permissions and
  error codes (`conflict` + `details.reason` for new cases).
- Keep exact money/currency provenance, tenant isolation, idempotency, evidence, audit and F-03
  recovery. No direct client writes to protected tables.

## Environments

- Dev Supabase `crljnkdwkxkwgvhxfrbl` (no production project). pg_cron runs workers via Vault
  URL/secret entries. Auth redirects: `https://app.elivatewallet.com`, `http://127.0.0.1:3000/**`.
- Worker secrets: `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `TURNSTILE_SITE_KEY`, `TURNSTILE_SECRET_KEY`.
- First real sign-up done (2026-10-09). Still open: the signed-in dev call test (risk: Edge
  `verify_jwt` with ES256 user tokens; see `docs/production-readiness.md`), the first platform
  admin, and editing the dev Auth email templates.

## How a slice ships

- One slice at a time. Worktree `../elivate-wallet-worktrees/<nn-name>` from fresh `origin/main`;
  blueprint `docs/blueprints/NN-*.md`; migrations `20261009NNxxxx` and pgTAP `NN0_` (next: `14`/`140_`).
- Checks: `backend/scripts/verify-database.sh` and `deno task check`; frontend `pnpm check`,
  `pnpm lint`, `pnpm test:unit`, e2e via `frontend/scripts/e2e-local.sh` (emails go through a
  fake Cloudflare into the local Mailpit). The local stack is shared: hold the
  `/tmp/elivate-supabase.lock` directory while using it.
- One PR per slice, linked to the thread; wait for CI and Greptile (read comments by their latest
  timestamp) and fix real findings before merging.
- Deploy to dev from fresh `origin/main` (owner approval covers the member build):
  `supabase db push --linked --include-all` in `backend/`, deploy changed functions, then
  `pnpm build && pnpm exec wrangler deploy` in `frontend/` (deploy doesn't build). Other sessions
  may deploy too: afterwards confirm a new route is live, and redeploy from fresh main if not.
- Report what ran and what didn't. Never reset, force-push or discard others' work.

## Status (2026-10-09)

On dev: backend slices 01–06, frontend M1 and member slices 1–5, 8 and 9 (blueprints 07–13).
Next: slice 9 follow-up (blueprint 14), then 6 → 7 → 10.
