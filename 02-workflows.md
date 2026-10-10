# Elivate Wallet 2.0 — Workflow and Acceptance Contracts

Pack version: 1.1 · Compiled: 2026-10-04

Target frontend: **Svelte + TypeScript + Effect**. Read `00-product.md` and applicable rules in `01-domain-rules.md` first. A workflow's UI does not confer backend authority. All protected initial requests/retries use A-01–A-05; all money uses F-01–F-03; all uploads use E-01. Use existing reviewed wire contracts, not invented endpoint/error names. The approved Emberlit visual system and the adopted `Authentication v2` compositions are documented in Paper; the frontend stack is decided in `00-product.md` P-04 (2026-10-08) and only unshown route layouts remain open under U-12. **Cloudflare Email Service** handles outbound email; preserve Supabase Auth and durable delivery boundaries.

## W-00 — Shared interaction, failure and recovery contract

Every workflow distinguishes: not loaded, loading, authoritative empty, ready, submitting, success, expected failure, unavailable/restricted, and outcome unknown. Display only relevant states; none is a fake durable financial status.

| Condition | UI/Effect behavior | Safe next action |
|---|---|---|
| Invalid input | Local field validation plus trusted server validation; retain safe edited data | Correct the field; no money posted on validation failure |
| No session/expired authentication | Clear private stale data; use supported sign-in continuation | Reauthenticate, then reauthorize; preserve only safe local continuation |
| Step-up required/expired | Open supported session-bound verification, not a client boolean | Retry with the same operation identity after proof; every other check still applies |
| Permission denied or revoked | Short authoritative denial; remove stale actions | Change eligible context/contact authorized admin; never retry as another role |
| Missing funding/account/policy/integration | Distinguish genuine prerequisite from unavailable read | Provide the relevant setup/recovery route; do not report zero or success |
| Insufficient available amount | Show current authoritative source availability | Change amount/source before a new confirmed attempt; no silent pocket fallback |
| Same key with different payload | Report command conflict | Recover original attempt; do not mutate its payload/key |
| Read timeout/provider outage | Safe error and explicit read retry; no fictional data | Bounded retry or come back; never infer money changed |
| Write timeout/disconnect/reload after dispatch | Mark outcome unknown and retain original immutable attempt | Recover status/result or same-key replay; no replacement key until resolved. **Built 2026-10-08 (Blueprint 08):** `GET /ledger/me/command-outcome` (fate + reference only) and the shared `CommandAttempt` runner / "Checking your request" screen (Paper B16) |
| User abandons a financial UI | Distinguish close/back from domain cancellation | Use approved cancellation under lock where available; network abort alone is not cancellation |
| Evidence technical failure | Preserve reservation/unposted workflow as applicable | Technical retry/dead-letter recovery; do not consume human correction |
| Stale response after context switch | Discard/cancel it and clear old-context sensitive details | Load newly validated context; never render old tenant data |
| Offline | Cached shell may work; financial reads are visibly stale/unavailable | Reconnect for authoritative data and commands; no offline money queue |

Common acceptance: no duplicate dispatch from reactivity, accessible busy/field/status feedback, no credentials in URLs, exact-decimal formatting, disabled conflicting submission while an outcome is unknown, context-safe reload, 320px/desktop and light/dark/keyboard verification. Recovery identifiers are non-secret and must not store bearer tokens, PINs or bank/evidence contents.

## W-01 — Authentication, founder entry, recovery and identity onboarding

**Actors:** New network founder, invited recipient, returning user. These are distinct entry paths, not a public role selector.

**Required behavior:**
1. Public founder signup says Start your network. Supabase creates/verifies account identity; it does not create President authority merely because a role was selected. **Owner decision (2026-10-10):** founder entry is apply-first: a public application (name, email, phone, team name, rank Ruby Director 4/5 or Diamond Director) is reviewed by a platform admin, and only an approved application's founder invitation creates a founder account and network (see `docs/member-build-plan.md`, Founder applications).
2. After verified account ownership, guide founder through approved tenant setup/configurable operational questions. Protected self-service/President controls are not editable role choices. Specific reviewers are assigned after active tenant membership exists.
3. **Owner decision (2026-10-08):** the founding President Team Member creates their network themselves and chooses a plan and pays during setup; the network stays pending until payment activates it. Production tenant activation must satisfy U-03/approved enrollment contract. Development one-time setup-code bootstrap is not unrestricted production onboarding or evidence of paid purchase.
4. Returning users use sign-in; recovery/password reset validates the supported Auth continuation and local redirect target. Preserve invitation continuation when applicable.
5. Identity verification binds proper verified identity to permanent account UID; profile/rank changes do not replace it. Provider/NIN method and exact UID format require U-02. Do not claim a preview's NIN state is verified identity.
6. Resume incomplete onboarding without repeating durable identity, membership or payment operations. Collect information progressively; do not force unnecessary fields upfront.
7. PIN enrollment, bank account and appropriate first-use onboarding remain required capabilities but use approved policies, not guessed PIN length/hash/thresholds.

**Auth UI:** Initial desktop/mobile sign-in, founder sign-up, verification/recovery notices, invitation verification, verified-session password setup, unavailable-invitation response, and generic sign-in error compositions are documented on the Paper `Authentication v2` page (adopted over the earlier `Authentication` page, owner decision 2026-10-08). Preserve concise headings/labels/actions, password visibility, Light/Dark/System capability, keyboard accessibility, responsive behavior and native POST even before JavaScript hydration. The screens do not select the identity provider or settle U-02's NIN/UID policy. Verification/recovery emails (Supabase Auth through Cloudflare SMTP) and invitation emails (application email through the Cloudflare REST API, W-21) use the configured Cloudflare sending integration; Supabase retains Auth token authority. Founder confirmation guidance must not falsely promise a new account or delivered email. The approved public signup duplicate notice may use Supabase's explicit `user_already_exists`/empty-identities result; do not add a privileged existence lookup. Missing/malformed/error responses remain errors. **Owner decision (2026-10-08):** Auth email links carry a `token_hash` and open a Continue page that submits by POST, so no bearer token sits in a URL and email scanners cannot consume the link. Editing the development project's Auth email templates is not approved yet; it comes with the first real sign-up. **Owner decisions (2026-10-08, built in Blueprint 10):** forgot password is supported: the Recovery email carries a token_hash link to the same POST Continue page, then the person sets a new password (other sessions are signed out) and enters the PIN as usual; the on-screen answer is the same whether or not the address has an account. Cloudflare Turnstile protects sign-in, sign-up and forgot-password and is verified server-side before Supabase Auth is called; a failed or missing check refuses the form. The check is invisible: nothing shows unless it fails, then the failed widget and a retry message appear (owner decision 2026-10-08, Paper App v4 Z02).

**Acceptance:**
- Signup/account selection alone cannot assign a role, office, entitlement or verified identity.
- Tokens are validated and redirects are local/allowlisted; password/MFA/bearer values never enter GET URLs/logs.
- New, existing, unconfirmed, missing-email, expired-link, provider-unavailable and resumed states are distinct and truthful.
- No production billing/enrollment completion claim until its actual contract and live dependencies are verified.

## W-02 — Invitation-bound account completion

**Entry:** A pending invitation link with server-stored intended email, role and office. A token is not authentication.

**Journey:**
1. A narrow token-digest preview validates pending/unexpired invitation plus active network/office and returns only the bound email.
2. Display the bound email disabled. Do not use generic signup to complete an Auth identity already provisioned by an invitation; remove the generic Create account / Sign in choice screen for this completion flow.
3. Offer email verification directly. The server derives recipient from the token, ignoring posted email authority. It may provision that exact unconfirmed Auth identity if approved invitation delivery previously failed, but still requires ownership verification.
4. Only a verified matching session can render password setup/update a password and invoke membership acceptance. A copied domain token alone never authenticates or changes credentials.
5. Existing-account sign-in remains available and preserves token continuation. A verified matching recipient using an older signup link can finish Set password and join through the same trusted acceptance.
6. Complete only the approved role/office assignment, under current capacity, invitation, account and tenant checks.

**Onboarding order (owner decision 2026-10-08, superseding the 2026-10-05 order):** verify email → accept the invitation → set the PIN → add the bank account. Acceptance is allowed while the session gate is still `pin_setup_required` (the person has no PIN yet); every later step needs the PIN, and the bank-account lookup needs a PIN step-up (W-17).

**First-use onboarding (owner decision 2026-10-05, reordered 2026-10-08):** After acceptance, an invited member completes a step-by-step wizard: (1) welcome showing the network, office and role bound by the invitation, with no role/office choice; (2) 4-digit PIN with confirmation; (3) NIN verification, with retries and then a request for their leader to review, during which onboarding waits on a review screen; (4) confirmation of the details locked from the verified NIN record: legal name and, only when returned, phone number; (5) profile: required uploaded photo, phone entered manually when NIN did not return one, and a self-declared rank chosen on a scroll wheel with haptic feedback (Member, Distributor, Manager, Senior Manager, Executive Manager, Director, Emerald Director, Sapphire Director, Ruby Director 1–5, Diamond Director); (6) NGN payout bank account with account-name lookup, checked against the verified NIN name under the W-17 name-match rule; (7) completion into member home. There is no authenticator app (A-05). Rank is self-declared presentation data and grants no role, permission or authority. NIN provider, retry limits and review mechanics remain U-02.

**NIN name match (owner decisions 2026-10-08):** the bank's resolved account name matches the verified NIN name when it has the same words in any order; a missing middle name or a middle initial is accepted; leading titles are ignored; there is no spelling tolerance. On a mismatch saving is blocked and the person fixes the bank record or their NIN. If the NIN is not verified yet (for example while a leader review is pending), the account is saved as "identity check pending" and is usable; it is re-checked automatically when the NIN lands.

**Privacy/recovery:** Invalid/expired/revoked tokens have one unavailable response; no account-existence/password-presence flags. Token pages/responses prevent caching/referrer leakage. Same-browser/cross-browser email continuation must use supported configured templates and verified sessions.

**Acceptance:** Wrong email, expired/revoked/replayed token, inactive office or anonymous acceptance cannot assign membership. Password setup cannot occur before matching ownership verification. Retries cannot duplicate identity/membership or drop the invitation through sign-in/reset redirects.

## W-03 — Create, revoke and accept invitations

**Actor:** Scoped `invite_members` holder; recipient accepts only their intended invitation.

**Input:** Intended recipient/resource, permitted role, intended office, approved expiration/usage policy. Server derives actor/tenant/office authority; invitation role and office types must match.

**Behavior:** Validate target placement and delegation limits; create durable invitation with inviter/redemption tracking and safe token/code/link delivery. Link/code expiry, usage limits and revocation are authoritative. Deliver outbound email through the supported Cloudflare Email Sending adapter/durable mechanism (W-21); invitations are application email, never Supabase Auth invites. Delivery failure is not acceptance. Acceptance rechecks identity, invitation state, capacity and intended role/context and creates/activates membership atomically. QR invitations are future convenience, not a separate authority model.

Invitation lifecycle is distinct from membership. An expired token cannot leave an active or perpetually invited membership. Keep revoked/accepted historical records rather than erase audit history.

**Owner decisions (2026-10-08):**
- **Who may invite whom:** `member` invitations by any `invite_members` holder within their scope. Leader roles (`team_leader`, `director`, `world_team_member`) only into offices strictly **below** the inviter's own office, with reason and PIN; the President Team may invite leaders into any office. A President Team Member is never invited; they are added through W-05.
- **Lifetime:** an invitation link lasts 7 days.
- **Resend:** issues a fresh link; the old link stops working immediately and the 7 days restart. At most 5 reissues per invitation and 1 per minute. Expired or revoked invitations cannot be reissued.
- **Revoke:** a reason (3–500 characters) is required.
- **Inviter loses their role:** pending invitations stay. Acceptance re-checks that the office is still active and the role still fits it.
- **Joining:** through the emailed link, or from an in-app "Invitations for you" list shown to a signed-in person whose verified email matches the invitation.

**Acceptance:** No unrelated presidency can invite into selected tenant. Concurrent acceptance/use-limit/capacity races cannot duplicate a membership or exceed seats. Repeated invitation actions follow their stable command contract; failure messages distinguish authorization from duplicate/conflict. Development three-identity restrictions are not copied into production.

## W-04 — Public workspace request and delegated approval

**Purpose:** A prospective Team Leader requests an office inside an existing tenant. This is not founder tenant signup or ordinary member onboarding.

**Entry:** President-shared tenant link or verified branded-domain context. Bind the tenant through trusted link/domain resolution, not a posted tenant ID.

**Request fields:** Full name, email, phone, team name and searchable self-reported rank. Account/password/NIN/email verification are not prerequisites to requesting. Submit → truthful Awaiting approval receipt. Request submission cannot activate office, membership, wallet, subscription or privilege.

**Review:** President approves/rejects by default. A World Team Member may approve only with explicit President delegation within scope, not by World Team role alone. Recheck authority/delegation on decisions/retries; preserve reviewer identity, reason, timestamps and request history.

**Rank:** Approved profile options include Member, Distributor, Manager, Senior Manager, Executive Manager, Director, Emerald Director, Sapphire Director, 1–5 Ruby Director, generic Diamond Director, and the published 1–5 Diamond Director titles. Use the approved canonical option catalog; do not invent missing exact titles. Search/keyboard/empty-result support is required. Rank never grants a role.

**Contract boundary:** Required capability, but full trusted persistence/idempotency, anti-abuse, delegation key, office placement and post-approval verified account/invitation/activation contract are U-04. Do not manufacture an automatic office on approval from a synthetic preview.

**Acceptance:** Cross-tenant request/approval is denied; repeated submission/decision does not create duplicate activation; revoked delegation loses queue/action access; no account prerequisites are silently added to the public request-first form.

## W-05 — Offices and membership lifecycle

**Actor:** Appropriate explicit organizational/membership capability plus hierarchy scope. Generic `manage_members` does not implicitly grant `move_membership`, `suspend_membership` or `end_membership`.

**Behavior:** Create/rename offices, assign leaders, manage classifications and inspect hierarchy through reviewed commands. Preserve permitted hierarchy and same-tenant parent/child links; never create cycles. President is tenant-level, not a fabricated hierarchy office. Show visible offices as table/list/card with server-side filtering/pagination.

"Classification" means a membership's organizational role (Notion main spec: "Change member classifications"); there is no separate classification catalogue or permission. Because a membership has one fixed role, changing a role is carried out as a replacement (end the old membership, create the new one), never an in-place edit.

**Owner decisions (2026-10-07):**
- President Team Members create offices of every type in the app, including World Team offices. A leader is required when an office is created.
- Changing an office's leader **replaces** the leader: the outgoing leader's leadership membership for that office ends, and the incoming leader receives a new active leadership membership for it (ending any membership they held in that same office). Other memberships, the wallet and all financial provenance are untouched. If the outgoing leader should stay in the network, that is a separate add-membership action.
- A reason is mandatory to move, suspend or end a membership and to change a leader; it is recorded with actor and time.
- Office money views and reports show the **total for the office and everything below it** (full descendant subtree), per currency, never mixing currencies.

**Owner decisions (2026-10-08):**
- Offices have no fixed chain. An office sits at the top of the tenant or under an office of a strictly higher kind (World Team > Director > Team Leader). A President Team Member can later place an office (with its subtree) under a new higher office, for example a World Team added above an existing Team Leader office. Reason and step-up required; money provenance is unchanged and subtree views follow the current tree.
- Ordinary `member` memberships may sit in any office kind.
- An office may have several leaders: every active membership holding the office kind's leader role is a leader, and an active office keeps at least one. Leaders can be added, or replaced one-for-one under the replacement rule above; the last leader cannot be ended or moved.
- Only President Team Members add or remove President Team Members, with reason and step-up; at least one always remains.
- Moving, suspending and ending a membership require step-up (the PIN) in addition to the reason.
- **Close office (owner decision 2026-10-08):** the President Team closes an office with a reason and step-up, only when it has no active members (its leaders aside), no open offices below it and no money held in it (posted or reserved, any currency). Memberships still on it (its leaders, suspended members) are archived (ended with the reason); pending invitations into it are revoked and reviewer assignments held through those memberships end. A closed office is read-only: no memberships, invitations or child offices can be added, and it shows why and when it closed.
- **Role change (owner decision 2026-10-08):** changes the role only, never the office (member ↔ the office's leader role), as a replacement (end + new membership) with a reason and step-up, under the leader-placement rule below; the last leader cannot step down. Changing office is done only through Move. Move, suspend and end membership each require the reason and the PIN step-up.
- Adding or replacing an office leader follows the W-03 invitation rule: leaders are placed only in offices strictly below the actor's own office (the President Team: any office), so a Team Leader cannot add or replace a co-leader of their own office. Office member counts roll up over the office's whole subtree (distinct people), like office money.

Add membership preserves another active relationship; move ends the old and creates/activates the destination while preserving history. Suspend affects that specific relationship; end means belonging ceased. Track actor/reason/time and invalidate authorization caches. One role/membership and one primary membership/tenant must remain consistent. Reorganization does not rewrite origin on old money/evidence or create a second wallet.

**Acceptance:** TL/Director cannot use generic member management to gain default W/P lifecycle powers. Reorganization/move preserves historical reporting and current scope checks. Ending all memberships does not delete wallet/history. Concurrent leadership/membership changes maintain constraints and distinct-seat counting. Mixed President/other-role wallet transitions follow reviewed U-08 semantics, never destructive inference.

## W-06 — Role policies, scoped access and reviewer assignment

**Actors:** President for protected exact-role policy/governance; scoped `manage_access_rules` holders for allowed grants/denies; President for Financial Evidence Reviewers.

**Behavior:** Seed A-03 exact defaults when creating a tenant. Permit customization only of configurable permissions for the five fixed roles. Never edit protected catalog semantics or derive new roles from rank.

Cross-access editor selects subject with active tenant membership, grantable permission(s), effect, explicit scope, start, optional grant expiry and reason. One row/permission/effect/scope; group under one assignment for review and bulk revocation. Denies cannot auto-expire. Validate proposed scope is within manager's own current effective authority. Display scoped effects without leaking private resolver internals. A reason is mandatory for every grant or deny (owner decision 2026-10-07). Access rules are managed alongside members and invitations; an assignment list shows subject, permission(s), effect, scope, start/expiry, created by, reason and revoked state (frozen resolver record fields). The owner accepted this field set (2026-10-07).

Reviewer assignment selects specific active people, not a broad role label. That one assignment controls notifications, queue and clear/reject authority. Keep own-operation exclusion. Changing assignments preserves historical decisions; open visibility and retries use current authority.

Workspace-request approval delegation is separate from evidence-review assignment and general World Team membership. Protected high-risk changes use A-05.

**Acceptance:** Deny wins over grant/default; grant expiry and bulk revocation take effect on initial calls/retries. Protected permission delegation, inactive subjects, beyond-scope management and self-review fail. Sibling-office approval-only grant permits only its exact approved actions, not all module choices/initiation. Empty-policy bootstrap fails closed rather than client bypass.

## W-07 — Dashboards, wallet, pockets and activity

**Actor:** Holder self-service or authorized selected leadership context. Use backend capabilities, not frontend role selectors.

**Personal:** Personal Home replaces duplicate My Wallet. Show posted/reserved/available value, relevant actions, pocket balances and recent activity for the explicit currency. Full wallet can aggregate compatible segments for UX while each command chooses one authoritative eligible source. No member conversion action is inferred from an old wireframe.

**Leadership:** President dashboard prioritizes finances then member insights. **Built 2026-10-08 (Blueprint 08):** one team overview read for every leadership workspace (Paper T01/T04): income this month and last, reserved, available, weekly income, active people vs memberships and pending invitations, per currency, with excluded scope reported; withdrawal figures arrive with W-09. Other dashboards show only authorized managed resources. Use actual aggregate safe read models—not sums over truncated recent rows—to compute totals. Distinguish memberships from distinct users and label counts accurately. Keep currencies separate; excluded/denied scope cannot contribute silently to a total.

**Pockets:** One selected NGN/USD context where supported, clear balances and transfer entry, and navigable detail/transfer/review/result steps. Exact charts, cards, route presentation and visual composition are undecided. **Owner decisions (2026-10-08):** each network's pockets come from its own catalogue (default Point Value, Business Investment, Personal Investment, Upkeep, Savings, in that display order, plus Debt; 01 D-01). Ordinary pockets send and receive, are withdrawable and never go below zero; Debt may be negative, receives transfers only up to zero, is never a source and is never withdrawn (01 F-01).

**Visibility (owner decisions 2026-10-08):** a person can always see their own money, read-only, even after leaving a network or while it is suspended. Money recorded under an office that is later closed stays visible to the President Team and the leaders above it (close office: W-05).

**Activity:** Chronological records with signed currency amounts, explicit durable status, search and Money in/Money out controls, plus currency/status/pocket/date filters. Mobile/desktop composition and control styling will be decided later. Detail shows type/from/to/date/reference and correction links, without a redundant visible Transaction heading. Follow authorized cursor pagination including equal-timestamp tie-breaks. **Built 2026-10-08 (Blueprint 08):** compositions from Paper M03/M04/M05 (desktop side panel, mobile full-page detail); search matches income source, provider reference, reference (any case, dashes optional) and exact amount; the status filter offers the durable statuses that exist (`posted` until W-15/W-09 add theirs); month and date filters use the browser's time zone, sent explicitly; month money in/out per currency comes from an aggregate read. **Owner decisions (2026-10-08, Paper v4 Q01–Q05):** backend search and status filter; the mobile filter sheet also has the type filter, as on desktop; reversals appear both as their own row (REV, opposite sign) and as a "Reversed" status with a link on the original transaction (Q03); leaders' member wallets are reachable from their own menu item and from Members, show the per-pocket breakdown, and list the available balance per currency, never mixed.

**Acceptance:** Zero differs from unavailable/restricted/unconfigured. No cross-currency total, scope leak, self-wallet leadership listing or cached prior-workspace flash. Currency/privacy/filter changes never alter actual ledger data. Loading, empty, narrow/dark and recoverable errors remain usable.

## W-08 — Record income and allocate immediately

**Actor:** Current scoped `record_income` holder managing someone else's wallet.

**Input:** Intended member/reference, supported currency, positive exact recorded amount, approved source/date/notes/fee facts and mandatory receipt(s). Target membership/wallet/provenance and allocation policy are resolved by the server.

**Flow:**
1. Read authorized targets and configured currencies/policy; report real missing setup rather than fabricate a wallet.
2. Create approved pre-post upload intent bound to actor, target and immutable command key; upload/finalize trusted evidence. Upload is not a financial income row.
3. On explicit confirm, reauthorize, verify required evidence/content, snapshot active tenant policy, calculate exact allocations and deterministic remainder.
4. Atomically create posted Income/financial transaction, balanced inflow journal, pocket lines, projections, key/result, audit and outbox.
5. Success is `posted`. No separate income approval or durable financial pending state is introduced. Failed validation/authorization posts nothing.

Store exact allocated lines/policy and structured facts separately from receipts. Upstream evidence supports the point value enters Wallet; do not model every prior provider movement automatically.

**Owner decisions (2026-10-08):**
- **Fields:** amount, currency (NGN or USD, both 2 decimal places), source (free text), date received, optional provider reference, optional notes and an optional fee. The fee is recorded only and never deducted.
- **Receipts:** PDF, JPEG or PNG, at most 10 MB each, 1–5 per income. Uploads not used by an income expire after 2 hours.
- **PIN:** recording income needs step-up (the PIN within the five-minute window).
- **Allocation:** the network's active policy version (W-23), largest-remainder method with ties broken by pocket display order (01 F-01). Income never goes into Debt.
- **Refused targets:** income is refused for suspended or ended memberships and for suspended or deactivated accounts; it is allowed for restricted accounts.

**Recovery:** Keep attempt ID before dispatch. Unknown outcome cannot start a replacement attempt. Approved cancellation serializes against posting and either recovers the committed result under current authority or permanently cancels the unposted attempt. Clean up expired unposted uploads safely.

**Built (2026-10-08, Blueprint 09 + 09b):** member/leader UI at `/app/income` (Paper v4 J01–J05, owner approved): exact split preview mirroring the server allocation, receipts uploaded and byte-verified on confirm with the PIN, `INC` result, and unknown-outcome recovery (same-key re-check or trusted cancel) that survives reload. **Owner decisions (2026-10-08):** the target picker searches the whole network (UID, name or office; server-side, same authorization and eligibility); a stuck attempt may stay on the recorder's device for 24 h, including after sign-out.

**Acceptance:** Missing evidence/invalid target/self-target/absent policy denies without money. Policy change does not recalculate posted allocations. Concurrent/replayed income posts once. Later correction uses W-15 then a new ordinary Income, never mutable balances or current-policy reversal.

## W-09 — Withdrawal request, approval, rejection and cancellation

**Actors:** Holder via `initiate_own_withdrawal`; optionally authorized non-owner via `withdraw_on_behalf`; scoped approver via `approve_withdrawal`.

**Input:** One eligible exact wallet/origin membership segment, one source pocket, positive NGN amount and one verified eligible payout account. **Owner decision (2026-10-05):** withdrawals can be requested in Naira (NGN) only; USD value cannot be withdrawn directly, so request screens show no currency choice. Server resolves provenance/owner/destination eligibility. UI source references do not supply authority.

**Request:** Show per-currency Available to withdraw, Posted and Reserved. Ask only for necessary source/currency/amount/account. Review explains the exact consequence: submission immediately reserves requested value, posted balance changes only at final payout completion. Snapshot destination immutably on accepted request.

**Core states:**
- `requested → approved → completed`
- `requested → cancelled` (holder's own request) or `requested → rejected` (authorized approver with reason)
- `approved → cancelled` only through authorized no-external-payout cancellation and child-state checks.

Submission atomically creates request + exact reservation; it posts no withdrawal journal. Approval retains reservation, records original approver, and posts no final debit. A non-owner with initiation and approval permission can perform both; no universal maker/checker split. Multiple open requests are allowed if exact reservations prove sufficient funds.

**Funding/fees:** No combining arbitrary pockets/tenants/currencies. Request amount is maximum Wallet value authorized to leave that segment. Record beneficiary amount and explicit known fees separately. No total debit beyond active authorized reservation; additional member-borne value requires explicit authorization/reapproval.

**Cancellation:** Requested cancellation/rejection releases hold without ledger effect. Approved cancellation requires the authorized actor to establish no external payout occurred. Verifying/correction-required/reviewing payout evidence must first be resolved/rejected; disputed evidence never automatically frees funds. Posted linked conversion remains historical; release its current destination reservation only.

**Acceptance:** Simultaneous withdrawal/transfer cannot spend held value. Account edits do not rewrite destination snapshots. Replays reauthorize and never reserve twice. Missing source/account gets actionable setup states, not a misleading membership error. Completed withdrawal cannot be cancelled/edited.

## W-10 — Manual payout recording and strict verification

**Actor:** The original approving/sending actor, with current `approve_withdrawal` scope and required fresh step-up. Approval is not an authority transferable by a UI dropdown.

**Preconditions:** Approved Withdrawal, active exact funding reservation and eligible snapshot. Read queues/details through approved reporting/approval/reviewer capabilities with masks and deterministic pagination.

**Flow:**
1. The original approver performs the external payout outside Wallet; the app does not initiate automated bank payout in this wave.
2. Exact destination reveal is available only to original approver with current approval authority, selected-context visibility, approved state, reservation and fresh step-up. Audit identifier-only access before responding. Clear revealed details on context switch/navigation/expiry; ordinary lists stay masked.
3. Record actual beneficiary amount/currency, payment date/status, destination/name, provider/reference where available, known fee facts and receipt through payout-specific actor/withdrawal/intent staging.
4. Trusted finalization verifies actual private bytes. Bind durable verification job to immutable submitted revision and snapshot.
5. OpenAI extracts bounded facts; trusted comparison enforces E-03. Extraction is not payment authorization.
6. Match → atomic completion. First material mismatch → one correction. Second mismatch → assigned independent review. Technical failures → bounded worker recovery, not a used correction.
7. Only verified/cleared current assertion can atomically lock reservation, post exact balanced payout debit, consume hold, update projections, mark `completed`, persist result/audit/outbox.

**Rejection:** Rejecting assertion closes that attempt with no posting; Withdrawal remains approved/funded. Obtain valid replacement evidence or explicitly cancel once no payout is established. Do not release disputed external payment funds just because a receipt was rejected.

**Acceptance:** Wrong amount/currency/full account/name/status/date, low confidence, masked facts or multiple receipts cannot auto-complete. Leading zeros are preserved; no fuzzy name match or prompt anchoring. Worker technical failure and stale-revision completion post nothing. Only original currently authorized approver can correct/requeue under the approved contract. Receipt upload alone never shows Completed.

## W-11 — Independent financial-evidence review

**Actor:** Current specifically assigned active Financial Evidence Reviewer, within tenant/scope, not submitter of that financial operation.

**Queue/detail:** Show assigned unresolved cases, original/current structured facts, evidence revisions, extracted values/confidence, mismatch reasons, provider, provenance, submitter/times and verification/correction history. Do not hardcode Director routing.

**Decision:** Clear with identity/time/audited substantiation reason or reject with reason. Clearance preserves automated mismatch and allows the normal atomic posting boundary after final validations; it does not post by directly editing a balance. Never silently rewrite leader submission. A required factual override is explicit before/after audited behavior or reject/re-entry under approved policy.

**Domain consequences:** Rejected conversion/return/adjustment has no posting. Rejected payout assertion leaves the parent Withdrawal funded. Current assignment/step-up/state requirements remain authoritative for replay and concurrent reviewers.

**Acceptance:** Self-review, revoked assignment, wrong tenant and duplicate/conflicting decisions fail safely. A late clear cannot complete a replaced evidence revision. Preserve all attempts/reasons, including rejected ones. Required notification routing runs after commit and may also appear in the approved in-app notification bell.

## W-12 — Currency conversion (standalone or linked)

**Built 2026-10-09 (Blueprint 12):** the leader records the rate actually used with evidence (owner decision 2026-10-08: no rate tolerance or reference-rate check); the converted amount is held from submission; the case goes straight to the assigned Financial Evidence Reviewer (no automated comparison policy exists, U-07), who clears (posts both journals) or rejects (hold released). Linked withdrawal conversion is not built: withdrawals are Naira only (owner decision 2026-10-05).

**Actor:** Scoped non-owner `perform_currency_conversion` holder; not a default holder self-service action.

**Facts:** Target wallet/origin, logical pocket, different supported source/destination currencies, positive exact source and actual received destination amounts, quoted/provider rate where available, derived effective rate, provider, observed timestamp, evidence, optional external reference and explicit known fee/currency/deduction facts.

**Behavior:** Value already exists in Wallet before conversion. Human performs/observes external conversion and submits facts/evidence. Preserve owner, provenance and logical pocket; changing pocket is a separate Transfer. Validate availability, consistent amounts/rate/fees/rounding and evidence, then verify → one correction → independent review as E-02. Unverified states have no ledger effect. Actual destination received is the recorded result; quoted/effective rates may differ because of documented fees/rounding. Do not fabricate a fee from unexplained difference.

**Posting:** One atomic Financial Transaction contains separately balanced source-currency and destination-currency journals using FX counter-accounts, with exact structured facts, immutable evidence/policy links, projections/result/audit/outbox.

**Linked withdrawal:** Authorized approved request can link conversion. On conversion commit, consume/release source reservation and create replacement reservation for actual destination amount atomically; there is never a temporarily spendable converted gap. Withdrawal stays approved/funded in payout currency. One receipt may prove both conversion and payout only if it actually substantiates both facts; otherwise require separate supporting evidence.

**Cancellation/correction:** Failed/abandoned unposted conversion has no effect. Cancelling later withdrawal leaves posted converted funds/history and releases current hold. Real reconversion is a new conversion; erroneous recording uses exact protected reversal and new correct command without fabricating an external undo.

**Acceptance:** No cross-provenance/pocket change, unsupported rate/scale guess, stale evidence post or partial multi-currency journal. Recheck available value and approval at final posting. Strict payout criteria do not substitute for an unapproved conversion-specific comparison policy (U-07).

## W-13 — Pocket transfer request and atomic approval

**Actor:** Holder via `transfer_between_own_pockets` or non-owner scoped `transfer_between_pockets_on_behalf`; approver via `approve_pocket_transfer`.

**Input:** One wallet, origin membership/tenant context, currency, distinct source/destination pockets and exact positive amount. Validate authoritative direction flags and available source.

**States:** `requested → completed`; terminal `requested → cancelled` or `requested → rejected`. Request immediately reserves exact source. Approval and posting are one atomic action: source −X, destination +X, balanced same-currency journal, reservation consumption and durable result/audit/outbox. There is no durable approved-but-unposted state or receipt workflow.

Before approval, **wallet holder or initiating actor** may cancel; authorized approver may reject. Release hold with no journal. A non-owner with both initiation/approval permissions can do both on the same transfer. Multiple open transfers are allowed when reservations are sufficient.

**Directions:** Debt cannot be source. It may receive only enough to reach zero; excess remains source, never positive Debt. Ordinary pockets both send and receive (owner decision 2026-10-08, 01 F-01). Cross-currency/provenance is excluded.

**UI:** Leadership review of pocket transfers lives in the **Transfers** module, separate from the withdrawal queue (Notion main spec 2026-10-03; tenant configuration 2026-10-04). On mobile the leadership bottom-bar tab is **Approvals**, with Transfers and Withdrawals as its two segments. Source/destination/amount → review → authoritative result, with accessible navigation between steps. Full-screen versus inline/dialog presentation and styling are undecided. Pending/unknown result retains amount and route; do not describe reservation as final balance change.

**Acceptance:** Wallet value in the currency is conserved; cross-context/own-wallet leadership/forbidden source fails. Withdrawal races cannot overspend. Either eligible cancelling actor works, not requester-only inference. Same-key recovery/completed-state labeling follow canonical rules, not conflicting old implementation.

## W-14 — Administrative adjustment

**Owner decision (2026-10-08), built 2026-10-09 (Blueprint 12):** reason, PIN and at least one evidence file always (no evidence setting); the case goes straight to the assigned Financial Evidence Reviewer; the member is notified (slice 8 sends it from the audit event).

**Actor:** Scoped non-owner `manual_credit_debit_adjustment` holder; W/P defaults; always step-up. Evidence is always required (owner decision above).

**Purpose:** Exceptional correction not represented by Income/Transfer/Conversion/Withdrawal/Returned Funds. A known wrong posted transaction uses W-15, not a disguising adjustment.

**Input:** One wallet/origin/currency, credit or debit, positive total amount, reason/category and evidence according to snapshotted requirement. Snapshot active tenant allocation-policy version at submission; system computes exact percentage pocket lines. Operator cannot select arbitrary pocket amounts or redistribute debit shortage.

**Evidence:** Required → verify/one correction/review; reliably non-machine-verifiable evidence may route directly to independent review. Optional → reason still required and attachments remain traceable. Changing requirement/policy later does not change submitted exact lines/requirements. No separate ordinary adjustment approval permission.

**Posting:** No unresolved reservation. Revalidate availability under lock at final posting. For debit, every non-Debt line must fit available balance or whole command fails; Debt may become more negative. Credit to Debt caps at zero, redistributing excess deterministically over eligible non-Debt weights under approved rounding. Balanced adjustment counter-journal, projections/key/audit/outbox commit together.

**Acceptance:** Insufficient one-pocket share fails without shifting it elsewhere. Self-target/no step-up/no reason fails. Later policy change cannot alter pending allocation snapshot. Evidence rejection has no money effect. Posted adjustment correction is exact reversal/new proper command.

## W-15 — Reversal, correction and reinstatement

**Owner decision (2026-10-08):** in activity a reversal is its own row (REV reference, opposite sign) and the original shows a "Reversed" status with a link to it (Blueprint 08 reads `metadata.reversesTransactionId` on the reversal's ledger transaction).

**Built 2026-10-09 (Blueprint 12):** the high-risk confirmation is the original reference typed back; income, pocket moves, conversions, adjustments, returned funds and reversals (reinstatement) can be reversed; a completed withdrawal cannot (use W-16).

**Actor:** Tenant's President via protected non-delegable `reverse_transaction`, fresh step-up, high-risk confirmation and mandatory reason/category.

**Target:** An eligible effective posted Financial Transaction, not a pending request/evidence workflow. Pending workflows use their cancellation/rejection paths.

**Behavior:** Lock original and affected balances. Copy exact original journal structure with opposite signs, same accounts/currencies/wallet/provenance/pockets/counter-accounts. Check current availability including reservations; any ordinary pocket shortfall fails whole reversal. No policy/rate recalculation, redistribution, Debt fallback or consuming another hold.

Preserve original and new reversal with `reverses_transaction_id`. Correct replacement uses its normal domain lifecycle, linked by `corrects_transaction_id`/chain. One effective transaction cannot be directly reversed twice. Wrong reversal is corrected by explicit reinstatement/reversal-of-reversal creating immutable history.

**External boundary:** Internal recording error can be negated with original ledger facts + reason. Real paid withdrawal returning later is Returned Funds, not pretending payout never happened. Real currency conversion back is a new Conversion. An externally backed erroneous-record reversal requiring an external fact also requires evidence/approved verification.

**Acceptance:** Same-key reversal posts once; double-reversal/race/conflicting key is prevented. Current funds/holds are respected. Original line amounts survive policy changes. History displays Original → Reversal → Corrected/Reinstatement, never deleted rows.

## W-16 — Returned funds after completed payout

**Built 2026-10-09 (Blueprint 12):** remaining returnable = sent + fee − returns in effect (a reversed return no longer counts); open returns count against it at submission; the case goes straight to the assigned Financial Evidence Reviewer.

**Actor:** Non-owner scoped `record_returned_funds`; TL/D/W/P defaults, separate from original approver authority.

**Input:** Completed Withdrawal reference, positive exact return amount in original final-debit currency, actual observed time, provider/source/reference where known and mandatory evidence.

**Behavior:** Inherit original wallet/provenance and restore the same logical pocket/member-value account finally debited. Prior linked conversion remains unchanged. Partial and multiple returns are allowed, but under lock:
`remaining returnable = original final Wallet debit − sum(posted returns)`.
Never exceed remaining returnable; excess real receipts use a separate correct command. Different-currency provider returns require an explicitly designed conversion-aware flow, not an invented rate.

Verify/one correction/independent review; no ledger until verified/cleared. Post new balanced external-return inflow atomically with domain/result/projections/audit/outbox. No reservation; never edit original Withdrawal. Corrections use W-15.

**Acceptance:** Concurrent partial returns cannot exceed original debit. No restoring pre-conversion source currency. Rejected evidence/no source payout/self-target produces no credit. Original completed payout/history remains intact after full return.

## W-17 — Payout accounts, verification and primary selection

**Actor:** Eligible holder via protected `manage_own_payout_accounts`; step-up for add/replace/deactivate/primary changes. No general leader permission to edit another person's reusable accounts.

**Data:** Country/currency/rail, institution code/name, account number or secure provider reference, resolved name, verification state/method/source, times, primary/lifecycle and replacement links. Ownership uses stable account/wallet, not email/profile name.

**NUBAN path:** Current owned active wallet/context + fresh step-up precedes exact bank-code/account-number provider lookup (Paystack Resolve Account Number, banks from the Paystack bank list; owner decision 2026-10-08). Preserve leading zeros and actual provider resolved name; do not use legacy profile-name matching or a permissive fallback. The resolved name must match the verified NIN name under the W-02 name-match rule; a mismatch blocks saving, and an account saved before the NIN exists is "identity check pending", usable, and re-checked automatically when the NIN lands. Store immutable actor/wallet/context/bank/account-bound proof valid **15 minutes**. Explicit name confirmation atomically creates/verifies owned pending account; never auto-sets primary or posts funds. Expired unconfirmed proof is terminal under lock; confirmed same-key result stays recoverable after proof expiry under current authorization.

**Manual/provider-neutral:** Deferred (owner decision 2026-10-08): only Nigerian NUBAN accounts can be added for now. When foreign/manual accounts are built, they remain pending until approved verification and are never labelled machine-verified. Account verification method and status are separate. Select for Withdrawal only if current policy permits it.

**Owner decisions (2026-10-08):**
- **Storage:** the account number is stored encrypted, with an HMAC fingerprint for matching and the last 4 digits for display.
- **Limits:** 10 lookups per hour and 30 per day per person; at most 5 active accounts per person. Two people may save the same account.
- **Reasons:** replacing or removing an account needs a reason (3–500 characters).
- **Cooling-off (new rule):** an account that was just added or replaced cannot receive a withdrawal for 24 hours. A person's first account is exempt.

**Lifecycle:** Multiple accounts; at most one primary per supported currency/rail. Verified account-number change creates new verified replacement and preserves old record. Deactivate/replace never modifies submitted withdrawal snapshots. Show masked numbers ordinarily; owner/exact authorized payout needs use narrow audited reveal.

Successful sensitive changes generate internal audit/security events and approved after-commit holder alerts; delivery failure does not undo change.

**Acceptance:** Lookup isn't confirmation; confirmation isn't primary selection. Wrong actor/proof/account/context, expired unconfirmed proof and duplicate races fail. Unknown confirmation remains bound to original key. Snapshot destination survives replacement. Full numbers stay out of analytics/logs/notifications. A NIN-name mismatch cannot be saved, lookups past the hourly/daily limit fail, and a non-first account inside its 24-hour cooling-off cannot receive a withdrawal.

## W-18 — Reports, transaction exports and statements

**Actors:** Holder `view_own_financials`/`export_own_statement`; leadership `view_scoped_financial_reports`/`export_scoped_reports` under selected scope and deny filtering.

**Queries:** Search, date range, type/status/pocket/currency/reference and related/reversal records. Authorized server-side pagination uses deterministic timestamp + unique-ID tie-breaks; no first-page-only export. Date boundaries/timezone semantics are explicit. Preserve existing inclusive UTC transaction-date contract for transaction CSV; label local calendar filters accurately rather than silently changing time basis.

**Outputs:** Personal CSV and PDF statements; custom/monthly/quarterly/annual periods. Leadership reports cover member/office income, allocation, withdrawals, balances/reservations, pocket distribution, activity and totals. Separate currencies and distinguish requested/approved/completed and posted versus available. Shared counts label memberships versus distinct users.

A transaction CSV is not an opening/closing balance statement. A complete financial statement must derive its relevant opening/closing/period figures consistently from authorized immutable financial history, show correction relationships and avoid conflating requests with posted movements.

Reports and statements carry the team logo, team name, Elivate Wallet branding and optional team contact details (Notion main spec §30). **Owner-accepted proposal (2026-10-07):** a statement covers one network (tenant) and one currency and carries that network's branding. A wallet holding funds from several networks gets one statement per network; the statement builder shows a network choice only when the person has more than one (owner confirmed 2026-10-07). Never mix networks or currencies on one statement.

Exports include only authorized data and safe destination/evidence fields. Complete traversal or fail clearly; never download a partial report as complete. Handle export limits as explicit limits, not silent truncation. Protect generated file access and long-running jobs.

**Built 2026-10-09 (Blueprint 15):** WAT periods and printed times (CSV also carries the UTC timestamp); personal PDF statements (Paper S01/S02/S07) and transaction CSVs; leadership office report PDF (S03/S04), transactions CSV and member balances CSV for the whole scope or one member; every file is one complete-or-fail background job (Postgres prepares every row in one transaction, the app Worker renders with Cloudflare Browser Rendering and stores in private R2 for 7 days); M15 + bell above 1,000 rows; hard limits PDF 5,000 / CSV 50,000 rows ("Too large"); downloads streamed by the app server, re-authorized and audited, with the PIN for leadership reports.

**Acceptance:** Equal timestamps do not skip records; mid-export authorization/read failure does not produce misleading partial output. Per-currency totals reconcile to their defined posted movements. PDF/CSV do not leak other tenants, full bank data, credentials or fake statement balances. Empty valid report differs from unavailable transport.

## W-19 — Subscription, capacity, Billing Owner and paid Extras

**Actor:** `manage_subscription` for administration; current Billing Owner is separate responsibility, not automatic authority.

**Read/UI:** Show authoritative plan version, yearly NGN price, covered-user band/count, status, current period facts where known, Billing Owner and only actually activated Extras. Core features are included across base size bands; do not invent tier feature gates.

**Capacity:** D-10 distinct-seat rules, tenant-level serialization on new membership activation. At cap, block new distinct user and offer legitimate upgrade/contact path; existing user's extra membership consumes no extra seat. Commercial suspended/effective cancelled state restricts catalogued new movement/activation while preserving otherwise-authorized history/reports/subscription operations.

**Billing Owner:** Step-up + current subscription authority + active target account/membership; atomically maintain one current owner and append history/audit. No role/wallet/configuration powers from assignment.

**Paystack:** Selected yearly plan provider, separate from deferred payout automation. Server-only amount/reference/buyer/NGN/environment verification and authenticated provider callbacks are required before accepted payment state. Validate raw-byte HMAC SHA-512 for applicable webhook contract; deduplicate provider events and durable purchase processing. Client success redirects are not payment truth. Payment does not credit wallet, mint arbitrary role, or directly activate production enrollment without U-03.

**Extras:** Data Migration, Custom Branding, Special Integrations and Enhanced Support have separate quote/activation lifecycle. Paid white-label entitlement does not imply domain ownership/TLS completion. Plan request/support-assisted upgrade does not pretend checkout exists.

**Scope exception:** Existing owner-authorized permanent Elivate development-tenant core access is a narrowly audited active subscription with no service end, not a general free plan or bypass. It does not activate undeveloped Extras or weaken scope/evidence/step-up/capacity.

**Acceptance:** Multiple memberships counted once; suspended retained users count; invitation alone doesn't count; President counts. Concurrency cannot over-activate seats. Forged amount/reference/environment/webhook/replayed payment cannot activate twice. Invoice/tax/trial/renewal/failure/overage/enrollment automation requires U-03, not guessed defaults.

**Built (Blueprint 16, owner decisions 2026-10-09):** trial, plans, Paystack checkout and subscription renewal, seat cap and prorated upgrade, expiry pause, Billing Owner and B01–B05 as specified in `docs/blueprints/16-billing.md`; Extras keep a quote path only (Support).

## W-20 — Team settings, branding and white-label

**Actor:** Current explicit configuration authority, ordinarily President/authorized tenant admin, plus step-up. Not ordinary Member or Billing Owner by assignment alone.

**Input:** Approved team-name/short-name/slogan/support/locale/timezone fields, controlled team-color choices (actual presets deferred with styling) and tenant-owned logo/icon variants. Validate HTTPS support links without embedded credentials; support URL remains optional. No unrestricted CSS/fonts/colors, modules/workflow/currency-format customization or per-office brand policy.

**Flow:** Read scoped safe config → edit permitted fields → purpose-scoped upload/finalize assets → validate/recheck entitlement → immutable new revision → audit/result. Rollback creates another revision. Expose only safe presentation fields to members; public unauthenticated config disabled unless separately approved. Configuration revisions appear in the President's read-only Audit log (owner decision 2026-10-06).

**Domain:** Paid entitlement and tenant-provided verified domain, at most one active per tenant. Live ownership verification, DNS/TLS, secure session/auth callback tenant binding, takeover prevention and retirement require U-05. Typed domain input or selected plan is not activation.

**Owner decisions (2026-10-10, built in Blueprint 17):** the actor is the protected President-only `manage_team_settings` (01 A-03), with the PIN to save or restore a revision. Team colour is one of six fixed themes (Ember default, Cobalt, Fern, Iris, Saffron, Rose; Paper TS01d) that colour the network's accent (buttons, links, highlights, tile) in dark and light; the Elivate mark stays coral and nobody enters a free colour. Logos (main, square icon, light version) are PNG/JPEG/WebP up to 1 MB, private, served to members through the app only. Language and time zone offer English (Nigeria) and Africa/Lagos only until the app is translated. Every save and restore is an immutable revision with tenant audit and T05 to the President Team; a paused network shows settings read-only. Statement and report PDFs carry the logo (or the initial on the theme colour) and the network support contact.

**Acceptance:** Ordinary Members cannot save shared colors; personal theme remains. Assets cannot point to another tenant/path. Rollback preserves old revision. Brand preference cannot self-grant a paid feature or modify financial/authentication rules. Missing branding uses approved fallback, not public private-asset URLs.

## W-21 — Support, documentation and transactional communications

**Support presentation:** Authenticated leadership shows selected active membership's network support; Personal shows each active network separately, never picks the first silently. Link only valid HTTPS no embedded credentials. Distinguish missing contact, read failure and configured destination. Elivate platform contact is not labeled tenant support, and tenant support is not labeled Elivate.

Chatwoot is the support integration. Share only reviewed permitted UID/team/current-screen/transaction/subscription context; never full evidence/bank/PIN/token data by default. Do not fabricate conversations, inbox, ticket counts or delivery claims. **Built (Blueprint 17, owner decisions 2026-10-08/10):** the Support page shows the network's own support contact (from team settings) separately from Elivate's app help (`support@elivatewallet.com` and the person's UID); Start a chat loads Chatwoot Cloud only on demand and shares only the UID (signed for Chatwoot identity validation), the network name and the current screen; no names, emails or money. Help topics wait for the help site.

**Documentation:** Searchable, role/context-aware getting-started, wallet/pockets, transactions/statements, network/governance, yearly billing, customization, backup/security and troubleshooting help. Contextual help may open where needed; routine financial UI does not gain verbose explanatory subtitles. `docs.elivatewallet.com` is a proposed destination requiring provisioning, not a live guarantee.

**Communications:** **Cloudflare Email Service / Email Sending is the chosen outbound email sender** for Auth verification/recovery email, invitations and approved income/withdrawal/security/subscription/account email alerts. Use its server-only Workers binding, REST API or SMTP through a reviewed adapter; inbound Email Routing is not a substitute for arbitrary-recipient outbound sending. Domain onboarding/authentication, least-privilege credentials and required paid-plan access must be verified (T-03/U-11).

Application follow-ups run through T-03 after durable commit; missing provider configuration means pending/failed delivery, not rolled-back money. Connect Supabase Auth emails to Cloudflare through supported SMTP or a reviewed Auth-email hook, retaining Supabase token issuance/validation and callback/template semantics. Auth delivery and application outbox delivery are distinct paths; do not send both for the same Auth event. Sender addresses, recipient/template/consent and delivery-status handling are U-11 where unspecified. A successful send API response does not by itself prove inbox delivery.

**Owner decisions (2026-10-08):**
- **Two paths, never both for one event.** Supabase Auth sends only its own verification emails (sign-up email confirmation and the PIN-reset sign-in link, both proving email ownership) through Cloudflare SMTP. Invitations and every other application email are sent by the application through the Cloudflare Email Sending **REST API** from the durable outbox; Supabase Auth invites are not used.
- **Credentials:** the REST API uses its own Email-Sending-only API token, separate from the Auth SMTP token, one per environment.
- **Worker:** pg_cron runs every minute and calls a worker Edge Function through pg_net; the worker secret is kept in Vault.
- **Sender:** `noreply@elivatewallet.com`, name "Elivate Wallet", no reply-to, in production. Development moves to `noreply@dev.elivatewallet.com` once that subdomain is onboarded in Cloudflare Email Sending; until then it may use the main domain.
- **Invitation email:** subject "You're invited to join <Network> on Elivate Wallet", using the P-06 email layout.

**Acceptance:** No context mixing, invalid URL or private anonymous branding disclosure. Cloudflare email retry uses stable downstream identity where supported and preserves attempt history; avoid duplicate sends after uncertain outcomes. Verify Auth confirmation/recovery/invitation links and actual external-recipient delivery separately from application-job execution. The approved in-app notification bell does not replace necessary review queues or security delivery, and must show only real durable events, never fake entries.

## W-22 — Profile, PIN, MFA, devices and sessions

**Actor:** Authenticated account owner for self-security; separately registered platform admin for account-status administration.

**Profile:** Editable display/first/last name, optional phone and timezone use self-owned safe CRUD/commands. Contact phone does not prove verified Auth identity. Email/password changes use supported verified Auth paths and leave UID/financial identity stable. Rank remains profile-only.

**Security:** No authenticator app (owner decision 2026-10-07). Every user's 4-digit PIN is asked for after the password at every sign-in and for step-up; see A-05. Display the actual verified-window state. PIN reset is by email link; account email changes go through support.

Transaction PIN is required product scope. Attempt limit (5), lockout, email reset and storage follow A-05. Account email changes go through support, not self-service (owner decision 2026-10-07). PIN does not replace authorization or MFA unless explicitly approved.

**Devices/sessions:** Show authorized active sessions/device information, approximate location/last activity where appropriate, suspicious login history, sign out one or all others. **Built (Blueprint 10, 2026-10-08):** device (from the user agent) and last activity, sign out one or all others. **Built (Blueprint 14, owner decisions 2026-10-09):** every sign-in records the IP, Cloudflare's approximate city/country and the device; records are kept (never deleted); the city and country are shown ("Lagos, Nigeria (approx.)"), the IP never; a sign-in from a city/country or a device never used by the account before is "unusual" (never the first sign-in), is listed under Unusual sign-ins and sends A07; changing the password while signed in needs the PIN only; Supabase Auth signs out every other session whenever the password changes (signed in or reset), and the app says so; A06 (password changed) and A08 (PIN changed) are sent. **Owner decisions (2026-10-08):** signing out all other devices asks for confirmation only, no PIN (Paper App v4 Z07); the profile has no time-zone field (display name, phone unless NIN-supplied, rank and photo are editable, Z04). **Change PIN (Blueprint 10):** current PIN, then the new PIN twice; a wrong current PIN counts against the same 5 attempts and lock; a change closes the PIN window on every other session. Revocation invalidates applicable elevated proof and action state; current-session/global invalidation follows supported Auth semantics.

**Account status:** Platform-admin command uses explicit registration, verified elevated actor, reason and current authorization; tenant role cannot grant itself this power. Record previous/new states and audit, idempotent replays without duplicate events. Never delete financial history. U-08 controls unresolved restricted/suspended reads and closure.

**Acceptance:** AAL1/older JWT cannot consume another session's elevation; proof retry does not extend five minutes. Session revocation stops sensitive replay. No secret QR/key/PIN in persisted logs/analytics/screenshots; form native POST and safe reset continuation are tested. Profile edits cannot change verified identity or immutable finance.

## W-23 — Platform administration, audit, flags and kill switches

**Actor:** Separately registered authorized platform operators, not tenant President merely by role. Use explicit capability matrix (U-09) before broad platform access.

**Surfaces:** Legitimate user/tenant/office/subscription/transaction/withdrawal/remittance/approval/security/config/backup operations and global search by UID/name/email/phone/bank account/transaction reference/team under proper scope (bank account is a search key; results show it masked). Deferred automated-payout/reconciliation tools must not appear active.

**Audit:** Immutable internal events record actor/action/target/time, safe before/after, reason, request/session correlation and linked objects. No full accounts, credentials, evidence bodies or private resolver metadata in general messages. Owner decision (2026-10-06): the tenant President gets a read-only, tenant-scoped Audit log showing these same safe fields; it never exposes platform/admin events, other tenants or raw backend controls. The personal notification bell remains separate (P-05); private admin audit is not removed.

**Controls:** Centralize approved supported currencies, limits, features, maintenance/security settings and backup/subscription policies. **Owner decision (2026-10-08):** allocation versions (pockets and split) are per network and edited by that network's President Team through the protected `manage_allocation` permission (01 A-03) with a reason and PIN step-up, not by Elivate admins. Every change (rename, add, retire at zero balance, reorder, percentages) is a new immutable version that applies to future income only; Debt is fixed. Platform admins may view every network's versions. Feature flags can roll out to tenants/roles/pilots/percentages/plans, but never grant permission or skip ledger/evidence/entitlement controls. Independent kill switches for withdrawals, transfers, remittance, conversion, income and future payouts stop relevant new operations without erasing existing state or breaking safe resolution/history.

**Owner decisions (2026-10-10, built in Blueprint 18):** the platform Admin app is a separate site (`admin.elivatewallet.com`, its own Worker, session cookie and secrets) from the same codebase; admins sign in with password + PIN (A-05) behind Cloudflare Access. Eight independent kill switches (withdrawals, payout recording, transfers, conversion, income, adjustments, reversals, returned funds), platform-wide and per network, all running by default, never restarting on their own, changed only with a reason and the PIN; a stop refuses new operations only (cancellations, rejections, payouts of withdrawals approved before the stop, reviews and recovery of committed commands keep working; reservations are untouched); members see a paused state, no email; a per-network stop shows in that President's Audit log as "Paused by Elivate". Feature flags are deferred again. The platform audit merges security and network events (read-only).

**Acceptance:** Tenant presidency can't administer global accounts/flags/secrets. Kill switch behavior preserves reservations and unknown-result recovery under reviewed policy. Sensitive config requires audit/step-up. Analytics/session replay masks financial/identity/account/evidence/PIN data. No hardcoded operational value quietly substitutes for an unresolved policy.

## W-24 — Platform disaster recovery and Team Backup Vault

**Platform recovery:** Elivate-owned PITR, scheduled DB backups, off-platform logical backups, Storage strategy, encryption, retention windows, restore procedures/docs/audit and periodic restore tests. RPO/RTO require explicit targets before broad rollout (U-06).

**Team Vault:** Independent authorized tenant-scoped export/backup, not a replacement for DR or permission to access private schemas. Package entitled/authorized membership/UID/config/policy/financial/history/report/evidence/subscription data. Exclude credentials, password hashes, Auth secrets, integration secrets and other tenants. Audit export access and minimize sensitive identifiers.

Each archive has tenant identity/name, timestamp, schema/backup version, counts, file manifest and checksums. Encrypt financial data. Show latest success/destination/size/retention/failure/retry from real jobs; never fake readiness.

Daily/weekly/monthly and Drive/OneDrive/Dropbox/S3-compatible/download are candidate choices, not approved launch defaults. Tier names/retention examples are not actual plan promises; resolve U-06.

**Restoration:** No initial one-click financial restore for team admins. Team requests restoration → validate archive/schema/integrity → dry-run/diff → differences presented → authorized reviewed recovery. **Owner decisions (2026-10-07):** President Team Members and World Team Members may request a restore, with a mandatory reason. **Only Elivate platform operators review the diff and run the restore**; no tenant user approves or performs it, and the requester never approves their own request. Statuses:

`requested → validating → in_review → restoring → completed`; terminal `rejected` (operator declines after review), `cancelled` (withdrawn by the requester before restoring), `failed` (validation or restore error, with safe reason). Each transition is audited and the requester is notified of the outcome. Never overwrite immutable financial history from a tenant browser upload. Separate platform recovery from a tenant's correction/import semantics.

**Owner decisions (2026-10-10, built in Blueprint 17):** Presidents (`manage_team_settings`) back up the whole network on demand ("Back up now"): one background job snapshots the network in one transaction (allowlisted fields only: no passwords, PINs, sessions, sign-ins, secrets, provider tokens, NINs, full bank account numbers or evidence file bodies; evidence is listed with name, size and SHA-256), writes one NDJSON file per section plus a manifest with counts and SHA-256 checksums into a ZIP in private storage, and is ready only if every row and file count reconciles. Archives are stored encrypted, downloaded after the PIN (audited) and **kept 90 days**, then removed automatically; above 500,000 records a backup is refused as "Too large". T02/T03 go to whoever started it. Restore requests use the protected `request_restore` key (World Team and President, 01 A-03), need a reason, carry an `RST` reference, allow one open request per network, can be cancelled by the requester or a President until restoring starts, and send T04 at each status change. Elivate moves the statuses (platform admin, PIN, reason) until the Admin app exists. A paused network keeps its vault. **Owner decision (2026-10-10, Blueprint 18): guided manual restore.** Validation is automatic in the Admin app (archive and per-file SHA-256, row counts against the manifest); in review only after a passing validation, with a read-only per-section comparison (added, removed, changed; money and history sections always kept); restoring is an operator procedure, then completed with notes. Nothing is written back automatically.

**Acceptance:** Restore drill meets approved measured targets; archive checksum/manifest reconciles to contents; partial upload/job failure is visible/recoverable. Scope/secret tests run on archives as well as live reads. Subscription lapse does not automatically delete backups/history; retention/deletion policy requires approval.

## W-25 — PWA, offline safety and mobile readiness

**PWA:** Installable Svelte app shell, icons/splash, safe areas, touch behavior, network state, update/version detection and new-version prompts. Offline shell may render, but financial data is explicitly stale/unverified and money movement is not silently queued offline. Do not cache sensitive Auth/token/evidence/financial responses indiscriminately.

**Offline data rule (owner decision 2026-10-08):** the app is an installable PWA (manifest, icons, splash, an iOS "Add to Home Screen" hint) with an update prompt on a new version. The last-loaded read-only data (balances, history, offices, members) may be cached on the device per user and workspace for at most 7 days, clearly labelled stale ("Last updated HH:MM · offline"), erased on sign-out and never shown under another workspace. Bank/account numbers, evidence files, tokens and Auth responses are never cached. A "Hide amounts" switch is available. All commands are disabled offline and never queued (W-00).

**Mobile readiness:** Stable versioned backend contracts, deep/universal/app links, mobile-compatible Auth, safe credential-storage plan, device/push architecture, minimum-supported version and feature rollout. The new frontend choice supersedes React-specific packaging assumptions. Native framework/package/timing and device biometric step-up are U-10/future decisions; do not declare Capacitor or React Native selected from older notes.

**Acceptance:** Network drops during write enter same-key recovery (W-00), never reissue under a new key on reconnect. App update preserves safe unresolved identifiers and does not discard domain reservations. 320px keyboard/focus/safe-area/contrast/motion and desktop parity pass. Backend upgrades don't assume every future installed client updates immediately.

## W-26 — Deferred payment automation boundary

Paystack DVA, automated member bank payouts, payout webhooks/transfer automation and Paystack-specific Wallet reconciliation remain deferred current wave. Keep current manual/external payout request/approval/evidence model.

Future discovery covers provider account ownership, inbound remittance mapping, recipients/account verification, KYC/fees/settlement, webhook authentication/deduplication, failures/reversals, limits and reconciliation matched/missing/duplicate/mismatched records. Do not ship these based on a backlog paragraph.

This does **not** defer Paystack subscription purchases in W-19, the selected account-name lookup in W-17 (Paystack Resolve Account Number) or the OpenAI adapter in W-10. Billing money, external wallet payments and internal ledger truth are distinct.

## W-27 — Release-wide acceptance checklist

Before declaring the application complete:
- Every required row of P-05 is implemented or explicitly blocked by a named unresolved contract; a pilot journey isn't the entire release.
- Relevant workflow acceptance checks and T-04 regressions pass on realistic nonempty safe fixtures, including external-failure and uncertain-outcome scenarios.
- End-to-end test covers income/evidence/allocation → owner request/reservation → scoped approval → external payout assertion → strict verification or independent review → immutable completion/history/export consistency.
- Transfers, conversion reservation migration, adjustment evidence/no-reservation, protected reversal and partial returns each prove their distinct accounting/state boundaries.
- No old implementation maker/checker, cross-workspace money transfer, one-open-request, hardcoded reviewer or mutable-balance rule is imported without approval. (NGN-only withdrawal is approved in W-09, owner decision 2026-10-05.)
- All required live forms/reads are connected and capability-derived; previews are isolated. Empty queue/read success doesn't prove real provider success or production readiness. Visual acceptance follows the approved Emberlit system and the Paper designs; unshown route compositions remain open under U-12.
- Svelte/Effect adapter tests, exact-money transports, authorization/RLS, new-database replay, generated drift, logs/privacy, build/runtime deployment, accessibility and hosted checks pass. Final visual acceptance is checked against the approved Emberlit system and Paper auth designs when the frontend is implemented; old screenshots/templates cannot satisfy it by assumption.
- Provider secrets/configuration, templates/callbacks, backups/restore, performance/load and operational alerts/kill switches are verified for the actual target environment.
- Unresolved U-01–U-12 contracts are resolved for the shipped affected features; don't rename a disabled placeholder “complete.”
