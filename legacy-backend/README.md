# Elivate Wallet Backend

The backend is a greenfield Supabase/PostgreSQL system. The linked remote Supabase project is the development database. Foundation migrations are authored locally and applied there only after review; no production project is targeted by this workflow.

Domain boundaries are documented in [`docs/architecture/backend-domain-boundaries.md`](../docs/architecture/backend-domain-boundaries.md).

Implementation rules:

- Build by domain, with explicit ownership and dependency direction.
- Treat the frozen Notion canonical domain model and authorization mapping as the source of truth.
- Write permanent schema changes only as forward, reproducible migrations.
- Keep authorization internals private and financial truth inside PostgreSQL transactions.
- Do not import legacy application records or use the legacy repository as the implementation base.

The first implementation wave established the Deno foundation plus Account, Organization, and private Authorization migrations. The Wallet wave added global Wallet ownership, the protected pocket catalogue structure, tenant allocation-policy versions, RLS, and resolver integration. The Ledger wave added the private immutable double-entry source of truth, idempotent posting primitive, and transactionally maintained balance projections. The withdrawal-approval wave added verified payout destinations, withdrawal requests, immutable destination snapshots, funding reservations, and authorization-audited approval/rejection/cancellation. The payout-evidence wave added immutable evidence metadata and verification history, President-controlled reviewer assignments, one-correction escalation, reviewer clear/reject commands, transactional outbox records, and atomic final withdrawal posting. The remaining-financial-operations wave added income allocation, reserved pocket transfers, two-journal currency conversion, policy-snapshotted administrative adjustments, exact transaction reversal/reinstatement, partial returned funds, and reusable append-only financial evidence workflows. The integration-delivery foundation adds private outbox leases, deterministic retries, dead-letter handling, append-only attempt/requeue history, stable downstream idempotency, provider-neutral Deno delivery contracts, and a bounded provider-neutral batch runner. The Commercial Subscription foundation adds immutable launch plan versions, tenant subscription history, distinct-user capacity enforcement, audited Billing Owner assignment, and global restriction of new money movement during effective suspension or cancellation. The Organization lifecycle wave adds private idempotent invitation and membership commands, identity-bound invitation acceptance, primary-membership maintenance, seat-capacity enforcement, Billing Owner protection, wallet initialization, and authorization-version invalidation. Provider adapters and credentials, worker deployment/scheduling, billing collection, invoices, generic non-financial document management, and public Edge Function endpoints remain intentionally deferred.

## Current backend checkpoint — September 20, 2026

The private PostgreSQL backend is implemented through the account, organization, authorization, wallet, ledger, withdrawal, evidence, financial-operations, integration-delivery, commercial-subscription, payout-account, and Auth-account provisioning boundaries. Account provisioning maps each new Supabase Auth user to one application account and profile row without copying mutable Auth metadata into authoritative fields. Profile RLS and immutable-field protections are covered by regression tests.

The linked development project is synchronized through the latest committed migration. The CI `Backend database` workflow is the authoritative fresh-database gate: it replays all migrations, runs every pgTAP file, lints the supported schemas, checks generated-type drift, and runs the strict Deno checks. The latest completed run passed.

The committed Edge Function inventory is also a CI-enforced security boundary. `scripts/verify-functions-list.sh` requires every configured and committed function to have an implementation directory and `verify_jwt = true`; it currently verifies 29 JWT-gated functions.

The Tenant Experience / Configuration wave now has an approved implementation baseline. It adds immutable team-configuration revisions, private branding asset metadata, a member-safe branding read model, step-up and permission-gated idempotent commands, internal security audit events, and optional white-label-domain entitlement state. Product-facing terms use Team rather than Brand. The authenticated `tenant-branding` read, `update-team-configuration` mutation, `request-brand-asset-upload`, and `finalize-brand-asset-upload` transports are deployed and JWT-gated. The detailed boundary is documented in [`docs/architecture/tenant-experience-configuration.md`](../docs/architecture/tenant-experience-configuration.md). DNS verification workers, anonymous public tenant pages, and billing collection remain separate trusted infrastructure work.

The remaining implementation-ready work requires approved contracts or infrastructure for the broader public API inventory, identity verification, DNS verification workers, billing collection, and environment promotion. Account-status administration, membership lifecycle transports, payout-account lifecycle transports, financial-evidence upload authorization, tenant branding-asset upload authorization, and invitation acceptance/revocation transports are implemented; invitation creation/token delivery and no additional client-facing route or permanent SQL should be inferred from frontend templates.

The trusted transport baseline is now implemented for the approved tenant read and mutation boundaries. The `tenant-branding` Edge Function requires a verified Supabase JWT, derives access through the authenticated client and RLS, returns only the explicit member-safe branding read model, and uses a stable request-id/envelope/error contract. The `update-team-configuration` Edge Function validates the approved configuration payload, derives the actor from the verified JWT, and invokes only the private idempotent PostgreSQL command. Both deployment configurations require JWT verification, and the linked development functions have been deployed and verified to reject unauthenticated requests. Additional command functions will be added one action at a time against approved private PostgreSQL commands.

Account-status administration is now implemented as a private platform-admin boundary. The approved `active`, `restricted`, `suspended`, and `deactivated` states are supported; tenant roles cannot grant this authority. The idempotent status command requires a registered platform-admin actor, a valid elevated session, a reason, and trusted service transport. The `set-account-status` Edge Function verifies the caller JWT before invoking the protected PostgreSQL command, which performs the final platform-admin and step-up checks, persists the change, and writes the internal audit event.

Tenant-scoped financial evidence transport is now implemented. Upload intents derive tenant ownership and submitter authority from the target financial operation, issue short-lived signed uploads into a private Storage bucket, and expire after 15 minutes. Finalization downloads the object through trusted transport, verifies byte size and SHA-256 against the intent, then atomically attaches immutable evidence to the operation; clients cannot call the private commands or mark an object as evidence directly. Request and finalization functions require verified JWTs and use the service role only as a transport credential after database authorization.

Tenant-scoped branding asset transport is now implemented. Authorized configuration managers request short-lived signed uploads into a private Storage bucket, with idempotent tenant-scoped intents and fixed size/type limits. Finalization downloads the object through trusted transport, verifies byte size and SHA-256 against the intent, then atomically registers immutable branding metadata; clients cannot call the private commands or finalize an unverified object directly. Request and finalization functions require verified JWTs and use the service role only as a transport credential after database authorization.

Member payout-account lifecycle transport is now implemented. Separate JWT-gated functions add, replace, deactivate, and select a primary payout account. The transport validates request shape and exact identifiers, derives the actor from the JWT, and invokes only the existing idempotent step-up-protected PostgreSQL commands; account ownership, verification, masking, historical retention, and authorization remain database-owned.

Membership lifecycle transport is now implemented. Separate JWT-gated functions create, activate, suspend, end, and move memberships. The transport validates exact identifiers and fixed role keys, derives the actor from the JWT, and invokes only the existing idempotent PostgreSQL commands; tenant/office scope, authorization, seat capacity, Billing Owner protection, primary-membership rules, wallet initialization, and audit remain database-owned. Invitation creation/acceptance/revocation is intentionally separate until its token generation and delivery contract is defined.

Invitation acceptance and revocation transport is now implemented. The JWT-gated `accept-invitation` function hashes the raw invitation token inside the trusted transport and sends only a PostgreSQL bytea digest to the private command. The `revoke-invitation` function derives actor identity from the verified JWT and invokes the existing idempotent, step-up-protected command. Invitation creation and token delivery remain separate until their external delivery contract is defined.

Wallet implementation details and deferred boundaries are documented in [`docs/architecture/wallet-domain.md`](../docs/architecture/wallet-domain.md).

Ledger implementation details and trusted posting boundaries are documented in [`docs/architecture/ledger-domain.md`](../docs/architecture/ledger-domain.md).

Member withdrawal reads include the JWT-gated `member-withdrawal-sources` endpoint. It returns one owned, eligible Ledger account per stored organizational context, with exact balance strings, currency scale, safe labels, and UUID pagination. An optional `sourceId` looks up one owned source, retaining access after eligibility changes so an authorized idempotent retry reaches the command. The exact lookup proves ownership; source eligibility and mutation authorization remain command-owned. The existing `member-withdrawals?withdrawalId=…` endpoint returns an exact owned target's ID and status for mutation preflight; missing or foreign targets fail closed. Neither read grants mutation authority. Submission and cancellation still reauthorize through their private PostgreSQL commands, and withdrawal availability subtracts both withdrawal and pocket-transfer reservations. The fresh-database gate also lints `read_api`.

Withdrawal request and approval boundaries are documented in [`docs/architecture/withdrawal-approval.md`](../docs/architecture/withdrawal-approval.md).

Withdrawal payout and evidence-review boundaries are documented in [`docs/architecture/withdrawal-payout-evidence.md`](../docs/architecture/withdrawal-payout-evidence.md).

Remaining financial-operation and evidence boundaries are documented in [`docs/architecture/financial-operations-evidence.md`](../docs/architecture/financial-operations-evidence.md).

Integration delivery behavior, the provider-neutral batch runner, and provider-specific deferred contracts are documented in [`docs/architecture/integration-delivery-foundation.md`](../docs/architecture/integration-delivery-foundation.md).

Commercial subscription behavior and unresolved billing boundaries are documented in [`docs/architecture/commercial-subscription-foundation.md`](../docs/architecture/commercial-subscription-foundation.md).

Trusted transport, command, read-model, error, idempotency, and logging boundaries are documented in [`docs/architecture/trusted-api-command-boundaries.md`](../docs/architecture/trusted-api-command-boundaries.md).

Backend environment separation and promotion rules are documented in [`docs/runbooks/backend-environments.md`](../docs/runbooks/backend-environments.md).

Remote development verification:

```sh
supabase migration list --linked
supabase db push --linked --dry-run
supabase gen types typescript --linked --schema public,authz,ledger,financial_ops,evidence,internal,commercial,tenant_config
supabase db query --linked --file supabase/tests/009_organization_lifecycle.sql
```

Each pgTAP file creates the test extension inside its transaction and rolls it back with all fixtures. Run remote pgTAP through `supabase db query --linked --file`; the current Supabase CLI still starts a local container for `supabase test db`, including when `--linked` is supplied, so that command is reserved for the container-capable CI replay rather than ordinary remote-only development.

Fresh-database CI validation entrypoint:

```sh
./scripts/verify-foundation.sh
```

Run that entrypoint only in a container-capable CI environment. It replays the migrations from an empty local Supabase database, runs pgTAP, and refreshes generated database types. Docker is not required for ordinary development or remote verification; it is required only for this independent fresh-replay gate.
