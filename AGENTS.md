# Elivate Wallet 2.0 — Agent Instructions

These instructions are for any coding agent or model working in this repository. Keep decisions model-agnostic and grounded in the repository; do not assume a particular editor, agent plugin, or MCP connector is available.

## Active access boundary: Paper design authorized; frontend source excluded

The owner has explicitly opened the Paper design phase for the existing `Elivate Wallet` file, using the screenshots supplied in the design request and the existing Elivate logo asset as references. This authorization is limited to that Paper file and design task. Do not open, clone, fetch, search, summarize, or otherwise inspect frontend source or UI implementations. In particular, the legacy frontend at `https://github.com/elivatepro/elivate-wallet-legacy` remains out of scope; the owner provided that link to identify the frontend, not to authorize access to it. Do not access it unless the owner later explicitly changes this boundary.

The owner explicitly authorized this design-system task in Paper. For subsequent work, inspect or edit Paper only when the owner requests a design task. During backend-only work, do not read or modify Paper. For authorized Paper work, use the active Paper guide and only synthetic or safely masked product data. If a task cannot be completed without frontend source access, explain the specific dependency and ask before crossing this boundary. Product-contract files already present in this workspace may be read as requirements context.

## Start here

1. Read `00-product.md` for product scope and settled decisions.
2. Before touching authorization, identity, money, evidence, billing, or other protected workflows, read the relevant sections of `01-domain-rules.md` and the complete applicable workflow(s) in `02-workflows.md`.
3. Inspect the current source, Git status, scripts, and environment setup before changing files or choosing tools. Do not infer implementation details from old previews or this instruction file when the repository says otherwise.

Use the product pack as the approved product contract. The user’s latest explicit decision can supersede it; update the affected contract instead of leaving competing rules. Existing backend schemas, functions, and transport definitions describe the implementation and wire format, but do not silently override approved product behavior. If they conflict, report the exact conflict and pause only the dependent change. Do not invent decisions marked unresolved in P-09.

## Current project decisions

- Product: **Elivate Wallet 2.0**, also called Wallet by Elivate 2.0.
- Frontend direction: Svelte + TypeScript + Effect. Effect is the TypeScript library, not Svelte’s `$effect` rune. Do not switch to React or reopen the selected stack.
- Supabase is the authentication and backend platform. PostgreSQL is authoritative for authorization and financial state; the frontend presents trusted reads and orchestrates approved commands.
- Cloudflare Email Service is the selected outbound email provider. Paystack is selected for yearly subscriptions; automated member payouts remain deferred. See the product pack for the exact boundaries.
- The owner approved the Emberlit visual system in `00-product.md` P-06 and the existing Paper file `Elivate Wallet`: `Design system` and `Authentication` pages, dark default, full light counterpart, Lexend, coral Elivate mark and responsive product patterns. CSS framework, component library, purchased template and unshown route compositions remain open under U-12.
- The runtime/router/SSR adapter, versions, hosting, and PWA plan remain open under U-10. Inspect available code and backend contracts, then ask for the narrow decision needed; do not guess versions or deployment setup.

## Workspace snapshot

At the time these instructions were written, this checkout contains the three product-contract Markdown files, a brand asset, and no backend source, frontend source, package manifest, or `AGENTS.md` predecessor. The existing files are untracked user-provided work: preserve them and do not regenerate, rewrite, or discard them. The owner reports that a backend exists in Supabase, but no backend source or project reference is present here. Inspect only the owner-designated Supabase project or backend-only source location; do not search for source in the legacy frontend repository. Refresh this snapshot when backend source is added.

Update 2026-10-07: the checkout also holds `design-backlog.md` (design handoff; Paper design phase is complete for now). Still no backend source, Supabase project ref, Git commits or package manifest. **Next thread: backend.** Step 1 is a read-only audit: get the Supabase project ref and the existing backend source location from the owner, pull schema/migrations/Edge Functions into this repo without touching data, and report gaps against the contract (notably the 2026-10-07 decisions: sign-in PIN instead of an authenticator app, public reference formats, Elivate-only restore statuses, subtree office totals, mandatory reasons). Update 2026-10-07 (later): step 1 audit done. Supabase project ref is `crljnkdwkxkwgvhxfrbl` (development database). The legacy `backend/` folder (commit `523a2a4`) is imported into `backend/`; the owner designated only that folder as backend source, so the rest of the legacy repo stays out of scope. Findings and repo↔remote drift are in `docs/backend-audit-2026-10-07.md`. Update 2026-10-08: the owner chose a clean rebuild. `backend/` is the new Supabase project (fresh migrations, built slice by slice from an owner-approved blueprint in `docs/blueprints/`); `legacy-backend/` is the imported legacy code kept as read-only reference for porting proven logic (ledger, reservations, receipt verification) and is not built or deployed. CI is `.github/workflows/backend.yml` (fresh replay + pgTAP + lint needs Docker, so it runs in CI; this machine has no Docker). Then set up the repo foundation (commit contract files, local Supabase, CI) and build in pilot-journey order (P-02): auth + PIN → offices/memberships/authorization → ledger/income → withdrawals/payout/verification → statements. Frontend runtime choice (U-10) can follow in parallel.

## Backend and product rules

- Supabase Auth authenticates; PostgreSQL authorizes and owns financial truth. Preserve the product pack's tenant isolation, exact-money, evidence, idempotency, and recovery rules.
- Use only approved, scoped backend reads and command APIs. Keep private schemas private; never expose service-role credentials, worker credentials, or provider secrets to public clients. Do not introduce direct public-client writes to protected tables.
- Validate all untrusted transport input and output at runtime. TypeScript annotations do not validate network or provider responses. Match existing API envelopes and error codes; do not invent endpoint, RPC, permission, or error-code names.
- Keep sensitive data out of URLs, logs, analytics, traces, screenshots, and design examples. Backend review normally needs code and schema metadata only; do not query or export real user or financial records.
- Preserve exact monetary values and currency provenance. Never combine currencies into a misleading total or present demo values as live data.
- Preserve approved scope, authorization boundaries, auditability, and deferred-feature limits described in P-05, `01-domain-rules.md`, and the applicable workflows. Do not infer product semantics from a deployed implementation when the contract explicitly leaves them unresolved.

## Supabase access and changes

- Use only the owner-designated Supabase project. A project name/ref is an identifier, not a credential. If the target is unclear, ask for the project ref before inspecting project data.
- Prefer the connected Supabase integration or an owner-configured local CLI/session. Do not ask the owner to paste secrets into chat or commit them. Never place credentials, access tokens, database passwords, or service-role keys in `AGENTS.md`, source, Paper, or Git. Keep local secrets in an ignored environment file or secret manager; document required variable names with empty placeholders only.
- Read-only inspection of schema, migrations, Edge Functions, policies, and safe project configuration is appropriate for backend review. Do not inspect production data rows.
- Do not apply migrations, execute mutating SQL, deploy functions, alter auth/email settings, reset/restore/delete projects or branches, or change production data unless the owner explicitly requested that specific operation. Report intended scope and environment before an approved backend mutation.
- Match existing validated request/response and error contracts. Do not invent endpoint, RPC, permission, or error-code names. Keep private implementation details behind approved trusted interfaces.

## Paper design boundary

Paper work requires explicit design-phase authorization. The owner approved the `Elivate Wallet` system documented in `00-product.md` P-06 and commissioned the initial auth compositions on its `Authentication` page. During backend-only work, do not inspect or edit Paper files. For a new Paper task, follow the active Paper tool's guide, inspect the selected file before editing, and use only synthetic or safely masked product data.

## Working safely across models and sessions

- Check `git status` before edits and preserve user changes. Do not reset, clean, overwrite, force-push, or discard work that is not yours. Use the repository’s established branch/worktree conventions when available; if the expected base branch is absent, explain the constraint and keep the user’s current files intact.
- Prefer small, focused changes. Read relevant code and nearby conventions before adding abstractions, dependencies, or generated files. Do not fabricate a build command, runtime version, or package manager when source configuration is absent.
- Use existing project checks that match the change and report what ran and what did not. Do not claim a check passed without running it. Avoid unrelated refactors and dependency upgrades.
- When blocked by a real contract gap or conflict, state the specific affected behavior and ask only the decision needed to proceed; continue independent work.
- At handoff, summarize changed files, decisions made, checks performed, and unresolved questions. Update this file when an owner-approved decision changes the workflow or the workspace snapshot becomes stale.
