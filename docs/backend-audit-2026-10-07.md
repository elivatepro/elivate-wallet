# Backend audit — 2026-10-07 (read-only)

Step 1 of the backend thread (see `AGENTS.md`). Nothing in Supabase was changed; no data rows were read (only aggregate counts of `auth.users` / `auth.mfa_factors`).

## Sources

| Source | What | State |
|---|---|---|
| Supabase project `crljnkdwkxkwgvhxfrbl` ("Elivate Wallet", eu-west-2, Postgres 17.6) | Live schema, migrations history, Edge Functions, advisors | Development database per legacy README; 7 Auth users, 0 MFA factors |
| `elivatepro/elivate-wallet-legacy` `backend/` only, commit `523a2a4` (2026-10-04) | Migrations, functions, pgTAP + Deno tests, scripts | Imported into `backend/` (sparse checkout; no other folder fetched) |

Import notes: legacy `backend/AGENTS.md` and `CLAUDE.md` were **not** imported (they name Notion as source of truth, which conflicts with the product pack). `scripts/provision-development-accounts.py` was **not** kept: it reveals the service-role key, writes raw SQL to the remote bypassing commands, and writes credentials into the frontend folder. The legacy README links to `../docs/architecture/*` outside `backend/`; those were not fetched.

## Repo ↔ remote drift

- Remote has 79 migrations; repo has 82. **Not applied remotely:** `20261004013000_access_management_transport`, `20261004020000_workspace_requests`, `20261004120000_leadership_report_read`. No remote-only migrations.
- Remote has 53 functions; repo has 64. **Not deployed:** `access-management`, `create-access-assignment`, `revoke-access-assignment`, `leadership-report`, `workspace-requests`, `submit-workspace-request`, `decide-workspace-request`, `activate-workspace-request`, `create-workspace-request-delegation`, `revoke-workspace-request-delegation`, `create-workspace-request-entry-token`.
- Deployed code differs from repo for at least `_shared/http.ts` (repo maps `step_up_required` to 403) and `add-payout-account` (deployed v11 calls `financial_ops.add_payout_account`; repo calls `public.add_own_payout_account`). Downloaded function bundles referencing `src/shared/*` could not be fully compared.
- Remote live: RLS enabled on every table in app schemas; storage buckets `financial-evidence`, `tenant-brand-assets` both private; pg_cron job `payout-verification-worker` runs every minute.
- Security advisor: `public.current_step_up()` and `public.establish_step_up()` are SECURITY DEFINER and executable by `authenticated`; leaked-password protection is off; `internal.development_networks` has RLS without policy (intended deny-all). Performance advisor: 38 unindexed FKs, 155 unused indexes (info only).

## What is solid and reusable

Ledger (immutable double-entry, `numeric(38,18)`, per-currency scale, zero-sum journals, trigger-maintained projections); reservations under row lock; allocation with deterministic remainder; idempotency keys + fingerprints; withdrawal lifecycle with destination snapshot; strict payout receipt comparison (exact integer math, OpenAI strict schema, leased verification jobs); NUBAN lookup; pocket transfers; returned funds; authorization resolver order (A-01), A-03 catalog (all 31 keys and role defaults match); office hierarchy + subtree table; seat capacity under advisory lock; launch plan bands match D-10 exactly; private schemas exposed only through service-role `read_api`/`command_api`; JWT-exempt functions limited to three with their own checks; amounts in transport as strings.

## Gaps against the contract

### Blocking for pilot step 1 (auth + PIN)
1. **No PIN at all** — no table, hash, attempts, lockout, email reset (A-05, W-22, U-09).
2. **Step-up is TOTP/`aal2`-based** — `migrations/20260924102651_session_bound_step_up.sql`, `functions/_shared/session.ts`. Conflicts with "no authenticator app". The 5-minute session-bound window logic is reusable; only the proof source must change.
3. **No sign-in gate** ("password, then PIN, every time") for protected reads/commands.
4. **No window revocation** on PIN reset, sign-out or account-status change.
5. **Public UID** is `EW-` + 12 hex; D-01 requires `EW-` + ≥5 digits, random, never reused.
6. Config: email confirmations off and invitation acceptance doesn't check confirmed email; min password length 6; TOTP config conflicts.

### Offices / memberships / authorization (pilot step 2)
- No **reason** on move/suspend/end membership; no **change-leader** command (2026-10-07).
- No create/rename office command; workspace activation creates an office **without a leader**.
- Membership state `pending` missing (D-02).
- Access revoke takes no reason; grant `starts_at` not client-settable; access/workspace replays return before re-authorizing (A-01/F-03). (Undeployed code.)
- No role-policy editing API; reviewer assignment command is revoked from every role (uncallable).
- Invitation creation: idempotency key generated per call (retries not stable); expiry hardcoded 1 h; only member/team_leader roles.
- No President read-only **audit log**; audit events lack reason text and safe before/after.
- `authenticated` lacks USAGE on `authz` while RLS policies call `authz.*` — possible runtime permission errors (unverified).

### Money (pilot steps 3–4)
- **Operation references** are `PREFIX-` + 16 hex; withdrawals `WR-` (need `WDR-`), conversions `FX` (need `CNV-`); need `<TYPE>-XXXX-XXXX` Crockford Base32; `STM`/`RPT` absent.
- **Payout recording and destination reveal require no step-up** (W-10) — `approve_withdrawal` catalog entry is `none`.
- **Withdrawals not restricted to NGN** (owner decision 2026-10-05).
- Conversion, adjustment, reversal, returned funds: **SQL only**, no transport; their evidence verification has no worker/queue.
- Linked conversion doesn't swap the withdrawal hold; reserved funds can't be converted (W-12).
- Reversal/adjustment/conversion/returned-funds replays return before re-authorizing (F-03).
- No reason **category** on adjustment/reversal; no `verifying`/`verified` evidence states; no evidence path for external-fact reversal.
- **Office totals** in leadership report cover the office only, not the subtree; report not scoped to selected workspace; `net_flow` mixes requested and posted amounts; approved/completed merged. (Undeployed code.)

### Statements, platform, operations (pilot step 5 and later)
- **Statements/exports missing entirely** (one network + one currency, opening/closing balances, `STM`).
- **Restore requests / Backup Vault missing** (W-24 statuses and Elivate-only review).
- **Cloudflare email missing**; invitations go via Supabase `inviteUserByEmail`; no outbox worker deployed.
- Paystack adapter exists (tested) but has no purchase table, webhook function, provider-event dedupe or subscription link; Billing Owner/subscription have no client read or transport; `billing_cadence_code` null though contract says yearly.
- Development tenant subscription is created **suspended**; W-19 says active with no service end (blocks all money movement in that tenant).
- No feature flags / kill switches; no config rollback; logger unused (no server-side failure logs) and doesn't redact pin/email/phone/name.
- ~13 early authz definer functions use `search_path` including `public` (one malformed as a single quoted string).
- `bootstrap-development-network` is deployed and can create a real tenant with a one-time token.

### Tooling
- `scripts/verify-foundation.sh` needs Docker (fresh replay + pgTAP + lint + type drift). No CI workflow file in the imported folder. Deno 2, `supabase-js` 2.45.4 via esm.sh, std 0.224.0; no Deno version pin in `deno.json`. `.env.example` lacks `ELIVATE_DEV_NETWORK_SETUP_TOKEN`, `ELIVATE_APP_ORIGIN`, `CORS_ORIGINS`, Paystack and email variables.

## Owner decisions (2026-10-08)
1. The Supabase project is development only; existing UIDs/references may be rewritten into the D-01 formats.
2. PIN storage: bcrypt over HMAC(server secret, PIN); locked after 5 wrong attempts until the email reset (recorded in 01 A-05).
3. The 3 unapplied migrations and 11 undeployed functions are fixed against the contract before any deploy.
4. Invitations and workspace requests carry references too: `INV` and `WRQ` (recorded in 01 D-01).
5. `bootstrap-development-network` removed: deleted from the development project (2026-10-08) and from `backend/` (function, config entry, CI list, test).
