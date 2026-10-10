# Elivate Wallet 2.0 — Domain Rules and Safety Contract

Pack version: 1.1 · Compiled: 2026-10-04 · Companion files: `00-product.md`, `02-workflows.md`.

These rules govern every protected read, command, background job, and retry. Frontend choice: **Svelte + TypeScript + Effect**. No rule moves financial truth or authorization into the browser. **The approved responsive visual system is recorded in `00-product.md` P-06; the frontend stack and styling implementation are recorded in P-04 (owner decision 2026-10-08). Cloudflare Email Service is the selected outbound email provider.** No previous visual template or email provider is a fallback authority.

## D-01 — Canonical entities and ownership

| Entity | Contract |
|---|---|
| Account | Maps 1:1 to Supabase Auth identity; owns stable application identity, public UID, profile, and global security state. |
| Public UID | Permanent human-readable account identifier for support/lookup, statements and references. Email/phone is editable contact information, not identity. Format: see below (owner decision 2026-10-07). |
| Verified identity | Proper/legal identity bound to the stable account/UID; not an editable display name or an AI guess. |
| Tenant | One network/organization; subscription, configuration, branding, and top-level isolation boundary. |
| Office | Tenant-owned `world_team`, `director`, or `team_leader` hierarchy node; parent and child must share the tenant, and a parent must be of a strictly higher kind (or none; owner decision 2026-10-08, W-05). No cycles. |
| Membership | Genuine belonging to a tenant/office with one exact fixed role; may coexist with other memberships. One primary membership per tenant. |
| Invitation | Separate pending/redemption object; a token is neither an authenticated identity nor an active membership. |
| Wallet | Account-owned global financial container, at most one per eligible user, never one per tenant/membership. President membership alone creates none. **Owner decision (2026-10-10, Blueprint 22):** a director membership may be marked "funds not managed" by the President Team (reason + PIN, their own director membership included, only while that membership holds no money and has nothing open); the wallet is kept, but that membership holds no money: no own-wallet permissions come from it and the ledger refuses postings and holds on its segments. |
| Pocket definition | Per-tenant logical category; its name is not an authoritative money field. **Owner decision (2026-10-08):** each network starts with Point Value, Business Investment, Personal Investment, Upkeep and Savings (in that display order) plus Debt. The President Team may rename, add and retire pockets (`manage_allocation`, A-03, W-23); Debt is fixed. A pocket can be retired only at zero balance in every currency. |
| Allocation policy | Tenant-level immutable percentage-policy version; one active version/tenant. No office/member overrides in initial 2.0. **Owner decision (2026-10-08):** the default split (Point Value 40%, Business Investment 10%, Personal Investment 15%, Upkeep 25%, Savings 10%; precision 0.01%) is copied into each network at activation; the President Team changes it per network with reason and PIN, every change is a new version, and it applies to future income only. |
| Member-value account | Wallet + originating tenant/membership context + currency + pocket. Same logical pocket may have several provenance segments. |
| Journal | Immutable single-currency balanced accounting event. |
| Financial transaction | Groups the journals/postings for one financial effect and carries domain/provenance links. |
| Reservation | Hold over one exact funding segment; affects availability, not posted money. |
| Evidence | Durable file/provider fact record plus immutable submission/revision history; not the ledger itself. |
| Subscription | One current tenant commercial contract, with preserved historical periods and versioned plans. |
| Billing Owner | One active-account/membership assignment for commercial ownership/contact; not an authorization role. |

**Public identifier formats (owner decision 2026-10-07, adopting the design proposal):** human-readable references are separate from internal database IDs, server-generated, random (not sequential), unique per type and never reused.
- Public UID: `EW-` followed by digits, minimum five (`EW-48213`). Digits only so it can be read aloud. When the five-digit space nears capacity, new UIDs are issued with more digits; existing UIDs never change.
- Operation references: `<TYPE>-XXXX-XXXX`, uppercase Crockford Base32 (digits and letters without I, L, O, U). Types: `WDR` withdrawal, `PTR` pocket transfer, `RTN` returned funds, `INC` income, `CNV` conversion, `ADJ` adjustment, `REV` reversal, `RST` restore request, `PAY` subscription payment, `STM` statement, `RPT` report export, `INV` invitation, `WRQ` workspace request (owner decision 2026-10-08: invitations and workspace requests also carry a reference). A new type needs a new three-letter code here; support/error correlation codes are not operation references.
- `PAY` is Elivate's own reference; the Paystack transaction reference is stored separately and is not shown as the public reference.
- References are shown in a monospace face and copied as-is; search accepts them case-insensitively.

Financial resources carry or resolve immutable origin tenant, office, membership, wallet, owner, acting user, command type and relevant security/audit references. Moving a member changes future belonging, not old financial provenance. Cross-context movement is not an ordinary transfer or conversion.

## D-02 — Lifecycles and state distinctions

- Membership states include `pending`, `active`, `suspended`, `ended`; only `active` contributes authorization. Invitation states separately include pending/accepted/expired/revoked.
- Moving membership ends the old relationship and creates/activates the new one; adding membership preserves simultaneous relationships. Ending/suspending one does not delete identity, wallet, financial records or unrelated memberships.
- Approved administrative account states are `active`, `restricted`, `suspended`, `deactivated`. Legacy `disabled` is compatibility only, not a new administrative command choice. Do not introduce `closed` merely because an older roadmap listed it.
- A globally suspended/disabled account is denied protected actions across all tenants, including own-wallet actions; authentication may only reach a suspended-account presentation. Restricted accounts cannot initiate new money movement. Resolve U-08 before granting suspended users protected history access based on conflicting worksheet wording.
- Tenant inactivity and office/membership inactivity must be enforced where the action requires them. Commercial suspension is separate from account/tenant security status (D-10).
- UI local states—editing, loading, optimistic navigation, retrying—are not durable financial states. Evidence child states do not become Withdrawal Request statuses.

## A-01 — Canonical authorization order

For every protected action:
1. Verify actor identity/session; no valid authentication means deny.
2. Load the real target from the database. Resolve tenant, office, owner, membership, wallet and financial origin; do not trust client authority claims.
3. Apply hard system restrictions: account/tenant state, permission validity, non-delegability, self-target prohibition and applicable commercial/kill-switch checks.
4. Collect relevant active memberships in the target tenant whose scope covers the target.
5. Apply protected wallet-holder baseline permissions only to their owner and intended self-service operation.
6. Load defaults for each exact applicable fixed role; no rank inheritance.
7. Resolve hierarchy coverage: authorized office permissions cover their full managed descendant subtree by default; President tenant-wide authority covers only that tenant.
8. Load matching active explicit rules for actor, permission, target and timestamp.
9. For configurable permissions: **explicit deny > explicit grant > exact-role policy allow**. Hard restrictions still win. Protected permissions cannot be delegated/removed by ordinary policy/rules.
10. Enforce step-up/per-action confirmation as applicable. Absence of any surviving allow means default deny.
11. Return auditable internal reason/source; expose only safe client error/capability data.

A valid JWT, a high role elsewhere, a primary membership, and visible navigation are not authorization. Revalidate on initial calls **and same-key recovery/replay**. A prior success cannot disclose protected results after authority is revoked.

## A-02 — Scope, cross-access and selected workspace

- Fixed roles: `member`, `team_leader`, `director`, `world_team_member`, `president_team_member`. NeoLife/profile rank never creates one.
- Cross-access grants selected **grantable permissions**, not a copied role or its bundle.
- Recipient must already have at least one active membership in the target tenant. Cross-access never creates tenant belonging or cross-tenant authority.
- One permission/effect/scope per access-rule row; group rows under one assignment for UI/audit/bulk revocation.
- Scope is tenant, office subtree, or individual member. Grants can start/expire; explicit denies do not auto-expire and persist until an authorized manager changes/lifts them.
- `manage_access_rules` can manage only a subset of the actor's current effective management scope. Never delegate beyond that scope or bypass protected semantics.
- Selected workspace is presentation context only: verify an actor-owned active membership and active tenant/office server-side. Switching context cannot grant a permission.
- For selected leadership workspace actions/reads, keep the selected tenant and non-self target boundary. A target must be in the selected native subtree **or** have a current canonical allow whose source is a matching explicit grant for that specific action. Preserve approved sibling-office grants; do not reject them just because the target is outside the native subtree.
- Check initiation, approval, reads/reporting, cancellation and choices independently. An approval-only grant does not confer initiation, all target choices, or cancellation. An unrelated office's role-policy allow alone does not widen the selected workspace.
- On context switch, discard prefetched/private state from the old context; cancel pending reads and reload under validated context. Never show another tenant's cached data during transition.
- Membership suspension, grants/denies, role changes, expiry and revocation must invalidate relevant capabilities/caches. Benchmark uncached resolution; cached allows must not survive revocation.

## A-03 — Exact default permission catalog

Defaults seed a new tenant's exact-role policies atomically. They are not role-rank inheritance. Table roles: M=Member; TL=Team Leader; D=Director; W=World Team Member; P=President. `1`=yes; `0`=no. Preserve runtime tenant customization for configurable rows; never overwrite a nonempty policy with defaults as a repair shortcut.

| Permission | M | TL | D | W | P | Protected | Grantable | Scope | Own wallet |
|---|---:|---:|---:|---:|---:|---|---|---|---|
| `view_own_wallet` | 1 | 1 | 1 | 1 | 0 | yes | no | self | yes |
| `view_own_financials` | 1 | 1 | 1 | 1 | 0 | yes | no | self | yes |
| `export_own_statement` | 1 | 1 | 1 | 1 | 0 | yes | no | self | yes |
| `initiate_own_withdrawal` | 1 | 1 | 1 | 1 | 0 | yes | no | self | yes |
| `manage_own_payout_accounts` | 1 | 1 | 1 | 1 | 0 | yes | no | self | yes |
| `transfer_between_own_pockets` | 1 | 1 | 1 | 1 | 0 | no | no | self baseline | yes |
| `view_managed_wallets` | 0 | 1 | 1 | 1 | 1 | no | yes | office | no |
| `record_income` | 0 | 1 | 1 | 1 | 1 | no | yes | office | no |
| `approve_withdrawal` | 0 | 1 | 1 | 1 | 1 | no | yes | office | no |
| `withdraw_on_behalf` | 0 | 0 | 0 | 1 | 1 | no | yes | office | no |
| `transfer_between_pockets_on_behalf` | 0 | 1 | 1 | 1 | 1 | no | yes | office | no |
| `approve_pocket_transfer` | 0 | 1 | 1 | 1 | 1 | no | yes | office | no |
| `perform_currency_conversion` | 0 | 1 | 1 | 1 | 1 | no | yes | office | no |
| `manual_credit_debit_adjustment` | 0 | 0 | 0 | 1 | 1 | no | yes | office | no |
| `record_returned_funds` | 0 | 1 | 1 | 1 | 1 | no | yes | office | no |
| `view_scoped_financial_reports` | 0 | 1 | 1 | 1 | 1 | no | yes | office | no |
| `export_scoped_reports` | 0 | 1 | 1 | 1 | 1 | no | yes | office | no |
| `invite_members` | 0 | 1 | 1 | 1 | 1 | no | yes | office | no |
| `manage_members` | 0 | 1 | 1 | 1 | 1 | no | yes | office | no |
| `move_membership` | 0 | 0 | 0 | 1 | 1 | no | yes | office | no |
| `suspend_membership` | 0 | 0 | 0 | 1 | 1 | no | yes | office | no |
| `end_membership` | 0 | 0 | 0 | 1 | 1 | no | yes | office | no |
| `manage_access_rules` | 0 | 0 | 1 | 1 | 1 | no | yes | office | no |
| `manage_subscription` | 0 | 0 | 0 | 0 | 1 | no | yes | tenant | no |
| `manage_role_permissions` | 0 | 0 | 0 | 0 | 1 | yes | no | tenant | no |
| `manage_security_settings` | 0 | 0 | 0 | 0 | 1 | yes | no | tenant | no |
| `configure_adjustment_evidence_requirement` | 0 | 0 | 0 | 0 | 1 | yes | no | tenant | no |
| `reverse_transaction` | 0 | 0 | 0 | 0 | 1 | yes | no | tenant | no |
| `transfer_presidency` | 0 | 0 | 0 | 0 | 1 | yes | no | tenant | no |
| `deactivate_tenant` | 0 | 0 | 0 | 0 | 1 | yes | no | tenant | no |
| `manage_allocation` | 0 | 0 | 0 | 0 | 1 | yes | no | tenant | no |
| `manage_team_settings` | 0 | 0 | 0 | 0 | 1 | yes | no | tenant | no |
| `request_restore` | 0 | 0 | 0 | 1 | 1 | yes | no | tenant | no |
| `review_financial_evidence` | 0 | 0 | 0 | 0 | 1* | no | yes* | assignment | no |

Special interpretation:
- `transfer_between_own_pockets` is catalogued as a wallet-holder baseline but not protected. Do not silently change its metadata to match protected self rows.
- Self-service (own-wallet) rows never come from a director membership whose funds are not managed (owner decision 2026-10-10, Blueprint 22); every other director permission is unchanged.
- `withdraw_on_behalf` is an optional tenant capability. President decides which roles/users receive it; listed W/P defaults do not substitute for the approved operational policy.
- `review_financial_evidence`: the matrix lists P as default, but actual review authority/routing is the President-controlled specific-person reviewer assignment. No presidency, role choice, generic routing list or financial-operation permission substitutes for current designated assignment. Self-review is forbidden. Do not create independently administered routing and review-authority systems.
- Office-scoped defaults still use tenant-wide President scope where applicable and the target-based resolver. “Own wallet=no” is the leadership self-target guard, not a denial of separately eligible self-service.
- Workspace-request approval requires an explicit trusted capability; this source matrix does not settle its wire key. Use reviewed existing contracts or U-04/U-09 rather than inventing a catalog entry.
- `manage_team_settings` (owner decision 2026-10-10, Blueprint 17): team settings and branding (D-11, W-20), their revisions and restore, and the Team Backup Vault (back up, download). Protected and President-only; the PIN is needed to save, to restore a revision and to download a backup.
- `request_restore` (Blueprint 17, encoding the 2026-10-07 W-24 decision): asking Elivate for a restore, with a reason. Protected; World Team and President. The catalogue now has 34 rows.
- `manage_allocation` (owner decision 2026-10-08): the tenant's pocket catalogue and allocation percentages (rename, add and retire pockets; change the split). Protected and President-only (32 rows at the time). Every change needs reason and step-up, creates a new policy version and applies to future income only. Elivate platform admins may view versions but do not edit them.
- Retired names: `grant_cross_access` → `manage_access_rules`; `view_financial_reports` → `view_scoped_financial_reports`; `export_reports` → `export_scoped_reports`.

## A-04 — Self-service, approval and evidence-review separation

Leadership cannot use managed-wallet permissions to record income, convert, adjust, approve withdrawals/transfers or otherwise operationally manage its own wallet. Eligible leaders still use protected/self-service holder actions.

Ordinary withdrawal/transfer initiation and approval do **not** require universally different people: an authorized non-owner holding both relevant permissions may initiate and approve the same operation.

Evidence review is different: reviewer must be specifically assigned, active in the tenant and within scope, and cannot clear/reject their own financial operation. President assignment is the single source of notification routing, queue visibility, and effective review authority. No hardcoded Director/admin reviewer routing.

## A-05 — Step-up and high-risk confirmation

- **Owner decision (2026-10-07): no authenticator app.** Every user (tenant app and platform admin) sets a 4-digit PIN during onboarding. Sign-in is password, then the PIN, every time. The same PIN confirms high-risk actions (below). 5 wrong attempts lock it; reset is by email link. Implementation notes: Supabase Auth has no built-in PIN factor, so the PIN check is a trusted server-side step that must hash the PIN, rate-limit attempts and bind the verified state to the current Auth session (the five-minute window below). Password plus PIN are both knowledge factors; this is the owner's accepted trade-off, not authenticator-grade MFA. Do not invent enabled-factor removal/recovery bypasses beyond the email reset.
- Successful step-up opens a **five-minute window bound to the current Auth session**, anchored to proof time. Retries do not extend it; AAL/session liveness, revocation, downgrade, expiry and account restrictions remain enforced.
- Tenant role-policy/security/high-level access changes, Billing Owner changes, payout-account add/replace/deactivate/primary changes, branding/configuration changes, adjustments, and sensitive financial operations require their approved step-up contract.
- Adjustments always require step-up. Reversal requires step-up, mandatory reason and explicit high-risk confirmation. Presidency transfer/tenant deactivation require fresh per-action confirmation even inside a current window; confirmations are action/target/session-bound and consumed atomically.
- Financial step-up can depend on operation and configured amount thresholds; tenants may tighten, not weaken system minimums. Thresholds and PIN use are not guessed (U-02/U-07).
- **Owner decision (2026-10-07):** in-app step-up confirmation for high-risk actions (Billing Owner change, role/access changes, account-status changes, kill switches and other actions listed above) uses the person's 4-digit transaction PIN, not an authenticator-app code. **Owner decision (2026-10-07):** 5 wrong PIN attempts lock the PIN; the person resets it through a link sent to their account email (Supabase-issued, single-use), then sets a new 4-digit PIN. Changing the account email is not self-service: the person contacts support. A PIN reset revokes any open step-up window. **Owner decision (2026-10-08):** the PIN is stored only as bcrypt over an HMAC of the PIN keyed with a server-side secret (never in the database or client); verification happens server-side; a 4-digit PIN is protected by attempt limits, not by the hash. After 5 wrong attempts the PIN stays locked until the email reset completes; there is no automatic time-based unlock. **Owner decision (2026-10-08):** a signed-in session asks for the PIN again after 15 minutes of inactivity; the password session lasts up to 7 days.
- **Owner decisions (2026-10-08):** the PIN (step-up, five-minute window) is required to record income (W-08), to invite someone into a leader role and to add or replace an office leader (W-03, W-05), to change pockets or the allocation split (`manage_allocation`), and before a payout-account lookup (W-17).
- Do not add MFA to every upload/read solely because another workflow requires it. Follow the exact approved endpoint contract.

## F-01 — Ledger, money and provenance

1. All committed changes to member value use an immutable double-entry application ledger.
2. Every ledger account/journal has one currency; postings in each journal sum exactly to zero. A multi-currency transaction groups separately balanced journals atomically, never sums different currencies to claim balance.
3. Member-value accounts are provenance/currency/pocket segmented. System External Inflow/Outflow, FX Clearing and adjustment accounts are bookkeeping counter-accounts, not user balances or claims of custody.
4. PostgreSQL exact `numeric` owns money. No authoritative `real`, `double precision`, JavaScript `Number`, `parseFloat` or binary floating-point calculation. API and Effect/Svelte layers preserve decimal strings or approved exact decimal types; rates/weights also remain exact.
5. Supported scales/rounding are explicit. Allocation weights sum exactly 100%; smallest-unit remainders are deterministic and never lost. **Owner decision (2026-10-08):** NGN and USD both use 2 decimal places; allocation percentages have 0.01% precision; allocation uses the largest-remainder method, ties broken by pocket display order. Other currencies need a new decision (U-07).
6. Policy changes create immutable versions and affect future commands only. Income/adjustment retain exact lines and policy snapshot; reversal negates original lines, not current percentages.
7. Ledger history is financial truth. Projections may be optimized but update consistently with postings; no independent mutable pocket balance is authoritative.
8. Ordinary pockets remain non-negative. Debt alone may be negative; transfer/adjustment credit-to-Debt rules prevent positive Debt as specified in those workflows. Do not use Debt as automatic shortfall balancing. **Owner decision (2026-10-08):** ordinary pockets send and receive and are withdrawable; Debt receives transfers only up to zero, is never a transfer source, is never withdrawn and never receives income.
9. Actor/scope provenance is server-derived and preserved. Aggregate views can sum authorized compatible currencies for presentation; commands never silently pool contexts/pockets.

## F-02 — Atomicity, reservations and concurrency

One money-moving commit includes domain transition, financial transaction, balanced journals/postings, projection updates, idempotency result, required audit and durable outbox capture. Any failure rolls back all financial effects.

`available = posted balance - active reservations` for a funding segment. Reservation is not a posted economic event. Withdrawals/transfers reserve the exact amount immediately; approval/rejection/cancellation/settlement apply their specific consumption/release rules. No double use or temporary release of converted reserved funds.

Lock/serialize affected balance contexts in deterministic order; revalidate current availability and state at the final commit. No request can make an ordinary pocket negative, spend someone else's reserved funds, post twice, or satisfy only part of a multi-journal command. Multiple open requests are allowed when reservations prove sufficiency; no legacy single-open-request rule is inherited.

Debit adjustments and reversals recheck current availability at posting rather than reserve unresolved operations. Returned funds have no reservation phase. Evidence jobs do not themselves change value before verified/cleared canonical completion.

## F-03 — Idempotency and uncertain outcomes

- Every money-moving command has a durable idempotency identity bound to actor/action/immutable payload and target as required by its contract.
- Same identity/same data recovers the prior result without repeating transitions, holds, journals, audit or outbox. Conflicting materially different data with the same identity is rejected.
- Current authorization, reviewer assignment, session/step-up and target validity are checked before protected replay results are returned. Stable payload binding does not freeze privileges.
- Before dispatch, retain a non-secret attempt identifier sufficient for recovery. Retain no passwords, bearer tokens, PINs, full accounts or evidence contents in browser recovery metadata.
- Timeout, disconnect, reload or cancellation after dispatch is **outcome unknown**, not proof of rollback. Preserve the same key/payload and recover authoritatively. Never replace an uncertain financial attempt with a fresh key just to dismiss the UI error.
- User cancellation of a network task is not domain cancellation. Use the trusted cancellation command; it must serialize against posting/transition and return the real result.
- Client button disabling is useful UX, not idempotency or concurrency protection.
- **Built 2026-10-08 (Blueprint 08):** the per-actor outcome lookup takes the same key lock as replay and returns only the attempt's fate (committed / cancelled / not found) and public reference; full results come only from a same-key replay under current authority. Browser recovery metadata is the key, command, workspace, time, a non-secret summary and the body without PIN/password/token/full account number, kept on the device for at most 24 h, scoped per person, and (owner decision 2026-10-09) kept across sign-out within those 24 h.

## E-01 — Financial evidence and trusted Storage

Evidence is mandatory for manually asserted material external financial facts: manual income, conversion, payout completion and returned funds. Adjustment evidence is always required (owner decision 2026-10-08), and so is the reason. Internal transfer needs no evidence. Pure internal reversal relies on original immutable history plus reason/confirmation; external-fact reversal needs evidence.

A trusted provider event can be machine evidence only under an approved authoritative integration; a user-typed provider reference is not that exception.

Preserve structured amounts/currencies/provider facts separately from files. Evidence records include linked operation, type, immutable object/revision, filename, MIME, size, checksum where practical, submitter/time, provider/reference/observed time and notes as appropriate. Never overwrite posted evidence; append supplements/corrections with history.

Upload flow: authorized short-lived purpose/tenant-scoped grant → private upload → trusted finalization validating actual content/metadata and intended operation. Clients cannot choose arbitrary Storage coordinates or declare their files verified. Validate ownership/intent before privileged object access; downloads are short-lived signed authorized access. Size/MIME/content validation and asynchronous scanning/processing never make the file authoritative money.

Verification revisions/attempts are immutable. Async jobs bind the exact operation, submission revision and destination snapshot; leases/retries and finishing must recheck the current revision. An old job cannot complete a newer corrected submission.

## E-02 — Verification, correction and review

For evidence-gated operations:
`submitted → verifying → verified → posted/completed`
Alternative: first material mismatch → `correction_required` → **one** correction → verify again → match/post or `needs_review` → authorized designated reviewer clear/reject.

- Verification/correction/review states have no final ledger effect.
- Technical provider failure is retryable/dead-letter according to worker policy; it does **not** consume the human correction opportunity or assert a fact was mismatched.
- Preserve original/corrected structured values, evidence revisions, extracted facts, confidence, mismatch reasons, actor/times, notes and reviewer decision.
- Clearance accepts substantiated current facts with recorded reason; it never erases mismatch history or silently edits the submission.
- Rejection produces no posting. For payout assertions, rejection does not cancel the parent withdrawal or release its reservation; see W-10.
- Evidence routing and authority use A-04. The in-app notification bell (P-05) does not replace the assigned review queue or required durable routing; channel integration still follows U-11.

## E-03 — Strict payout receipt policy

Approved policy: `strict-single-receipt-v1`, with OpenAI extraction and trusted deterministic comparison.

Auto-completion requires high-confidence, unambiguous matching of **beneficiary amount, currency, full destination account, recipient name, successful payment status, and payment date**.
- Compare exact amounts; preserve leading account zeros.
- Name normalization is case/whitespace only, not fuzzy identity matching.
- Compare unambiguous ISO payment dates in UTC under the approved contract.
- Missing/masked/ambiguous/mismatched required facts cannot auto-complete.
- Multiple receipts are conservatively ambiguous; aggregation is not approved.
- Extract bounded nullable strict-schema facts without supplying expected values as prompt anchors. Model output cannot declare a payment verified or post money.
- Technical extraction failures never consume a correction or post funds.
- Worker transport is dedicated-secret/private, not callable by ordinary user JWT. Use short leases/bounded retries and immutable-revision checks at completion.
- Only the original approver with current scope, approval authority and fresh step-up may perform the approved same-key exhausted-job requeue.

Do not apply this exact payout comparison policy indiscriminately to income/conversion/adjustment/return receipts. Their relevant facts and approved evidence contracts differ (U-07).

## D-10 — Commercial semantics

Yearly launch plans: **up to 400 users = ₦700,000/year; up to 1,000 = ₦1,000,000/year; 1,001+ = ₦1,500,000/year**. **Owner decision (2026-10-07):** there will be 6 bands in total and none is smaller than up to 400 users; the caps and prices of the additional bands are pending (record them here when supplied). The frozen Notion commercial spec (2026-10-01) still lists only the three launch bands above; the other three are not in Notion. Paystack is selected for plan purchases. Never infer an upper cap for the last band, taxes, trials, overages or an upgrade algorithm.

Count distinct tenant accounts, not memberships. A retained active/suspended membership counts once; suspended retained accounts/seats count; pending unaccepted invitations and ended-only relationships do not. President counts despite no President wallet. Exact treatment of other global account states must follow the reviewed commercial contract, not guesswork.

At capacity, block activation of a new distinct billable user, not existing users/history. Additional memberships for an already-counted user do not consume another seat. Serialize capacity checks against concurrent acceptance/activation.

States: active, payment_due, grace_period, past_due, suspended, cancelled. **Owner decisions (2026-10-08/09, Blueprint 16):** an approved founder's (owner decision 2026-10-10: founders apply and Elivate approves) first network may run one 7-day trial on the smallest band (one per founder account, ever); further networks pay before activation; a paid year starts at the end of the current trial or period, and paying to reactivate a paused network starts it at payment; renewal is a Paystack subscription (card) with reminders at 30/7/1 days (trial 3/1); expiry suspends at once with no grace period; at the cap new invitations and activations are refused until an upgrade, priced at the price difference × days left in the paid year ÷ 365 (WAT days, half-up to the kobo); no refunds, and a smaller band only at renewal when the seats fit. A paused network keeps own-money reads, history, reports and Billing; withdrawals approved before the pause are still paid out. Networks active before billing are the development scope exception. Effective suspended/effective cancelled restrict catalogued new money-moving actions and new billable-user activation; payment_due/grace_period/past_due/future cancellation alone do not activate that restriction under the foundation contract. Historical/reporting access and subscription management remain subject to normal authorization. Commercial status never overrides global security denial or deletes history.

One current Billing Owner; multiple users may separately hold `manage_subscription`. Owner assignment gives no organizational/wallet/configuration authority. Changing it requires current `manage_subscription`, fresh step-up, active target membership/account, serialization and audit/history.

Plans are immutable/versioned/provider-neutral. Base tiers differ primarily by covered network size, not core Wallet feature gates. Extras: Data Migration, Custom Branding, Special Integrations, Enhanced Support; paid white-label is separately entitled. Preferences cannot self-grant an entitlement. Plan payment never credits a member wallet or automatically grants presidency.

## D-11 — Tenant configuration limits

Approved user-facing settings: Team display/name/short name, support name/email/phone, locale/timezone, one primary logo, optional square icon and light/dark variants, controlled team-color options whose actual presets/values will be decided with styling, short Team Slogan and optional HTTPS support URL.

End-user customization remains controlled, not arbitrary CSS/fonts/colors or per-office branding. This is a tenant-governance limit, not a choice of the application's styling framework or component library; those are recorded in `00-product.md` P-04 and the approved visual system in P-06. No currency/formatting/help-link/module/workflow preference editor in this wave. Optional support URL does not authorize public anonymous configuration. One verified active tenant-provided white-label domain is an optional paid entitlement, not automatic activation.

Every change creates an immutable revision; rollback creates another revision. Explicit configuration authority, trusted context, validation, idempotency and step-up are required; member reads return safe presentation fields, authorized leadership reads scoped configuration. Billing Owner does not automatically administer it. Ordinary Members cannot edit shared brand colors; their personal light/dark choice remains.

Secure tenant-owned Storage and internal audit remain requirements. Change-notification configuration was declined. A read-only, tenant-scoped Audit log for the President was approved on 2026-10-06 (see `00-product.md`); do not expose raw backend controls. The personal in-app notification bell is approved separately in `00-product.md` P-05. Tenant branding cannot weaken ledger/security/billing/retention rules.

## T-01 — Trusted backend and private schemas

- Supabase Auth authenticates; PostgreSQL authorizes. Edge verifies the exact bearer/session and derives actor, selected membership and actual target context; target references are not trusted scope claims.
- Explicit stable success/error envelopes include machine-readable codes and redacted request correlation. Do not invent/mislabel errors from an HTTP status alone; preserve existing wire contracts and validate responses.
- Protected mutations call one explicit private command/transaction. Selected safe read models alone are exposed.
- `authz`, `ledger`, `internal` and `commercial` internals remain private. Narrow `command_api` wrappers can be service-only transport, never a reason to expose tables or grant broad private schema usage.
- RLS on exposed tables, least privilege, indexed scope/self predicates and security-invoker views where appropriate. Pin empty/controlled `search_path` for privileged definer functions and narrowly restrict execution. Include explicit deny/private-table protections in migrations.
- Public/anon/authenticated roles cannot directly write ledger, policies, hierarchy closure, access rules, elevated sessions, audit, command caches or delivery state. Trusted service identity is not user-domain authorization.
- Only low-risk self-owned profile/preferences use reviewed RLS CRUD. Realtime messages/optimistic state never substitute for trusted reads or commands.

## T-02 — Svelte + Effect implementation conventions

These conventions implement this pack; they introduce no new financial semantics.

- Svelte owns presentation, form editing and local view state. It displays backend capability/read models rather than inferring authority from role strings.
- TypeScript remains the language. Effect structures the API/service layer: dependency injection, validated inputs/outputs, typed expected failures, bounded timeouts, explicit cancellation, safe read retries and redacted observability.
- Define stable internal error categories from the actual API contract: validation, authentication, step-up, authorization, conflict/idempotency, unavailable prerequisite, technical transport/provider failure, unknown outcome. These are categories, not invented backend code strings.
- Treat unknown/malformed payloads as boundary errors; TypeScript annotations alone do not validate runtime data. Use an agreed runtime schema/parser and preserve exact decimals.
- Keep expected business errors distinct from defects/unexpected exceptions. UI boundaries show recoverable fallbacks; explicitly handle event-handler/network effects. Never rely on a rendering boundary to catch every asynchronous failure.
- Do not dispatch money movement from reactive reruns, component mounts, automatic `$effect`, or state persistence. Require explicit user intent and approved confirmation.
- Do not blindly retry non-idempotent writes. A financial command retry preserves immutable key/payload and current authorization; a timeout becomes unknown-outcome recovery, not a fresh attempt.
- Cancel stale reads on unmount/context change and prevent late responses overwriting new context. Cancelling execution after write dispatch does not cancel the domain event (F-03).
- Keep service-role/provider/worker credentials server-only. Strip tokens, PINs, full accounts, identity details, evidence and sensitive values from Effect spans/logs and analytics. Logging is not permission to disclose domain internals.
- Do not create an independent in-browser ledger, client authority cache, or parallel frontend financial algorithm. Tests exercise typed failure mapping and recovery as well as UI state.
- Effect/SvelteKit versions and the runtime adapter are pinned by the owner decision of 2026-10-08 (`00-product.md` P-04); optional modules still need a reviewed implementation decision. Do not generate code against a guessed library API/version.

## T-03 — Outbox, integration jobs and operations

Financial/noncritical follow-up events are captured with the business commit and delivered after it. Cloudflare Email Service/analytics/support outage cannot roll back committed money.

Cloudflare Email Sending is the selected outbound provider, not merely inbound Email Routing. Use a server-only Workers binding, REST API or SMTP adapter compatible with the actual job runtime. Configure the sending domain in Cloudflare DNS with provider-required authentication records, scoped credentials and recipient-sending capability; ordinary customer delivery requires the appropriate paid plan. Do not choose a second email provider or declare delivery configured before these prerequisites are verified.

Application email uses durable outbox/delivery state. **Owner decision (2026-10-08):** invitations are application email (the application's own invitation token and `INV` reference, sent through the Cloudflare REST API from the outbox), not Supabase Auth invites; see W-21. Supabase Auth still issues and validates its own verification/recovery tokens: wire its email delivery to Cloudflare using supported SMTP or a reviewed Auth-email hook/adapter, and validate templates/callbacks and real delivery. Do not replace Supabase authentication semantics, enqueue a second duplicate Auth email path, or claim an application outbox alone configures Auth email. Provider acceptance and actual delivery are distinct; report only known results.

Outbox events are immutable. Mutable delivery state, append-only attempts and operator requeues are separate. Delivery is at least once with short leases, expired-lease recovery, deterministic bounded retry, dead-letter status and a new delivery cycle for explicit requeue. Use stable downstream `outbox:<event-id>` idempotency where supported; do not promise exactly-once external delivery.

Private dedicated worker commands, `SKIP LOCKED`/equivalent reviewed claiming, least privilege and credential isolation are required. Store timing and safe provider/error references, not raw exceptions/responses/secrets/evidence. Cloudflare sender/recipient/template, Auth email connection, delivery-status/retry and consent contracts are explicit dependencies, not inferred from an outbox foundation. See U-11; Cloudflare provider selection itself is settled.

Platform-owned DR and tenant-owned exports/backups are separate. Encryption, integrity manifests, financial immutability, auditability and tenant isolation persist through backups, retention, restore and commercial suspension. Never include authentication secrets or another tenant's data.

## T-04 — Mandatory cross-cutting tests

Test each affected rule, not only role names:
- same person with memberships in two offices/tenants; primary/highest role must not broaden target authority;
- native descendants, sibling explicit grant, deny-over-grant, expiry/revocation and replay after loss of authority;
- leadership self-target denied while eligible self-service works; President-only no wallet; mixed-role eligibility without duplicate wallet;
- session-bound five-minute proof, older/lower-assurance token, session revocation and confirmation replay;
- exact decimals/leading account zeros; deterministic allocation sums; balanced per-currency journals and immutable original records;
- duplicate/same-key-conflicting commands, unknown result after commit, cancellation versus concurrent posting, and two requests racing for the same funds;
- evidence mismatch/correction/escalation, technical failure, wrong/stale revision and reviewer self-review;
- private RPC/schema/table denial, tenant-safe pagination and no cross-context cache flash;
- commercial capacity race and suspended tenant restrictions without financial-history deletion;
- no secrets/PII in URLs, native auth GET fallback, logs, spans, session replay or export archives.

See `02-workflows.md` for lifecycle-specific acceptance criteria; see P-09 for unresolved decisions.
