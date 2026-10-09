# Elivate Wallet 2.0 — Agent Instructions

Model-agnostic rules for any agent in this repo. History lives in Git and `docs/`; keep this
file short and current.

## Boundaries

- **Frontend source is out of scope.** Never open, fetch or summarize the legacy frontend
  (`elivatepro/elivate-wallet-legacy`) or other UI implementations. `legacy-backend/` is a
  read-only reference for porting proven logic; never build or deploy it.
- **Paper:** only when the owner requests a design task (or a build step needs a drawn
  screen's exact values). Inspect before editing; synthetic or masked data only.
- **Production is off-limits.** "Prod" means the dev Supabase project plus the live Worker.
- **Secrets:** never in Git, Paper, chat, logs, URLs or this file. Repo-root `.env` (ignored)
  holds local values; copy them into secret stores without printing them.
- **Data:** never query or export real user or financial rows; review uses code and schema.
- **Never run `supabase config push`** (it overwrites dashboard Auth/SMTP settings). Change
  Auth only via the Management API for specific fields.

## Start here

1. `00-product.md` (scope, settled decisions), then the relevant parts of
   `01-domain-rules.md` and the full applicable workflow in `02-workflows.md` before touching
   auth, identity, money, evidence or billing.
2. `docs/member-build-plan.md` before any member slice; its "Owner decisions during the
   build" section is binding.
3. Check `git status`, scripts and current source before changing anything. The owner's
   latest decision overrides the pack; update the affected contract line. Report conflicts
   between code and contract; never invent unresolved decisions (P-09).

## Stack (decided)

- Supabase (Auth + Postgres + Edge Functions, Deno). Postgres owns authorization and money.
- Frontend `frontend/`: SvelteKit 3, Svelte 5, Effect 4 (the library), TypeScript 6, pnpm,
  Node 24; SvelteKit BFF with HttpOnly session cookies; plain CSS + Emberlit tokens, Bits UI,
  Lucide, self-hosted Lexend. Hosted on Cloudflare Worker `elivate-wallet-app`
  (app.elivatewallet.com, private R2 `PHOTOS`). Do not reopen the stack.
- Email: Cloudflare (Auth via SMTP; app email via REST through the outbox with the Paper
  "Emails — Transactional v2" layout in `_shared/email/layout.ts`). Paystack for yearly
  billing (test mode on dev). Automated member payouts stay deferred.
- Design: Paper file `Elivate Wallet` (Emberlit, dark default + light, coral mark, Root
  poses only). A screen with a Paper composition is built directly; one without is drafted
  in Paper and approved first. Before building a screen, check `frontend/src/routes` so an
  existing screen is extended, not rebuilt. Accepted deviations from Paper: single-screen
  PIN entry, wizard progress bar inside the panel, native bank select.

## Backend rules

- Only `api.*` functions are `security definer` (owner-accepted exception: three ledger
  trigger checks); every function sets `search_path = ''`. Private schemas stay private.
- Validate all transport and provider input/output at runtime. Reuse existing envelopes,
  routes, permissions and error codes (`conflict` + `details.reason` for new cases).
- Preserve exact money and currency provenance, tenant isolation, idempotency, evidence,
  audit and F-03 recovery rules. No direct client writes to protected tables.

## Environments

- **Dev Supabase project:** ref `crljnkdwkxkwgvhxfrbl` (no users yet; no production project).
  pg_cron runs workers through Vault URL/secret entries. Dev Auth site URL and redirects
  point at `https://app.elivatewallet.com` (plus `http://127.0.0.1:3000/**`).
- **Worker secrets:** `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `TURNSTILE_SITE_KEY`,
  `TURNSTILE_SECRET_KEY`.
- **Deferred by the owner:** first real sign-up, first platform admin, signed-in call test
  (open risk: Edge `verify_jwt` with ES256 user tokens).

## How a slice ships

- One slice at a time, no parallel agents. Worktree `../elivate-wallet-worktrees/<nn-name>`,
  blueprint `docs/blueprints/NN-*.md`, one migration range `20261009NNxxxx` and pgTAP range
  per slice (slice 4: `11`/`110_`; then `12`/`120_`, …). Next order: 4 → 5 → 8 → 9
  follow-up → 6 → 7 → 10.
- Checks: `backend/scripts/verify-database.sh` (fresh replay + pgTAP + lint, as CI) and
  `deno task check` in `backend/`; frontend `pnpm check`, `pnpm lint`, `pnpm test:unit`,
  `pnpm test:e2e`. Local stack runs on Colima and is shared: hold the
  `/tmp/elivate-supabase.lock` directory while using it.
- PR per slice, linked to the thread. When CI is green: merge, then deploy to dev from a
  fresh `origin/main`: `supabase db push --linked --include-all` (from `backend/`), deploy
  changed functions, `pnpm build && pnpm exec wrangler deploy` in `frontend/` (deploy uploads the last build;
  it does not build). Smoke-test without creating
  users or sending email. Owner approval for dev deploys covers the member build.
- Report what ran and what didn't. Don't reset, force-push or discard others' work.

## Status (2026-10-09)

Merged and on dev: backend slices 01–06, frontend M1, member-build slices 1, 2, 3 (+#27
follow-up), 4 (withdrawals, payouts, OpenAI receipt check `payout-checker`, evidence review,
pocket moves; blueprint 11), 5 (conversions, adjustments, returned funds, reversals, one
evidence-review queue; Paper v4 U01–U07 and MV01–MV05; blueprint 12), 8 (bell with
needs-your-action tasks, M01–M14 + new M16–M18, T01, A10–A12 emails; blueprint 13) and 9.
Paper `App — Screens v4` batches 1 and 2 approved. Next: slice 9 follow-up (IP storage,
signed-in password change, PIN-change email, sign-out choice after reset), then 6 → 7 → 10.
