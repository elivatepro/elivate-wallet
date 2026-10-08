# Elivate Wallet 2.0 — Product Contract

Pack version: 1.1 · Compiled: 2026-10-04

## P-01 — Authority and how to use this pack

This is a self-contained product specification, not a changelog, implementation-status report, or declaration of production readiness. It consolidates approved product/domain rules and the owner's current frontend decision. The product's canonical spelling is **Elivate Wallet 2.0**, also called **Wallet by Elivate 2.0**.

The target frontend is **Svelte + TypeScript + Effect**. React, Next.js, React/Vite, and vinext descriptions in historical material are not the target frontend architecture. Effect means the TypeScript library, not Svelte's `$effect` rune. The owner has chosen the stack; do not reopen that decision during routine implementation. **The responsive visual system is approved in P-06; CSS framework, component library, and template choices remain open under U-12. Cloudflare Email Service is the chosen outbound email provider.** These owner decisions supersede earlier styling/template prescriptions and email-provider selection; the business, financial and security contracts remain unchanged.

Read this file for orientation; read `01-domain-rules.md` before protected or financial work; read the complete relevant workflows in `02-workflows.md`, including exceptions and acceptance checks. Follow local cross-references rather than reopening Notion for ordinary implementation. Do not treat an isolated workflow as permission to ignore shared rules.

Interpretation rules:
- **Must / must not** express requirements. **Required, contract incomplete** means the capability is in product scope but a named decision is needed before its unspecified part can ship.
- **Deferred** means not in the current wave. A pilot priority does not remove wider approved scope.
- Explicit owner decisions supersede the specific earlier decisions they change. Implementation age, existing code, sample screenshots, and successful deployment do not approve new business semantics.
- Repository migrations, generated interfaces, and tests supply implementation details where this pack is silent. They must not contradict the product contract. Surface conflicts rather than silently changing rules.
- Do not invent missing financial, authorization, identity, billing, or retention semantics. Consult P-09 and ask a narrow question when the affected contract is incomplete. Continue independent work.
- Update the relevant section when a decision changes; do not append a second competing rule or chronological checkpoint.

## P-02 — What the application is

Elivate Wallet is a multi-tenant financial operations SaaS for FHG/network teams. It gives eligible people one global wallet while letting authorized network leaders record income, distribute value into pockets, handle withdrawal requests and manual external payouts, manage organizational relationships, and report on financial activity.

It must support larger networks and grow toward roughly 10,000–20,000+ users without sacrificing financial correctness, tenant isolation, maintainability, or mobile usability. This is a design/load-test direction, not a measured capacity claim or an approved latency SLA.

The app records financial truth from the point income enters Wallet. It does not need to reproduce every earlier Fiverr, Payoneer, or other upstream movement as an internal transaction. Upstream receipts can support the recorded income. Wallet recording does not itself prove bank custody, initiate an external payment, or make an extraction provider financially authoritative.

Primary journey:
1. An account joins an authorized network/office through its approved enrollment flow.
2. A permitted non-owner operator records income with evidence.
3. Wallet posts exact allocations using the tenant's active policy.
4. The wallet holder requests a withdrawal from one eligible funding segment.
5. An authorized approver approves it and is responsible for the external/manual payout.
6. The approver records payout facts and evidence.
7. Verified or independently cleared evidence permits atomic ledger completion.
8. Wallet shows the resulting balances, status, history, and reports.

Elivate Network is the selected first pilot audience. Prioritizing this journey does not mean other approved modules are optional or the app is already production-ready.

## P-03 — Actors and boundaries

| Actor/concept | Meaning |
|---|---|
| Wallet holder | A person eligible for one global wallet; self-service is distinct from leadership authority. |
| `member` | Organizational membership normally anchored under a Team Leader office. |
| `team_leader` | Operational leadership over the authorized Team Leader office scope. |
| `director` | Operational/access management over an authorized Directorate subtree. |
| `world_team_member` | Broader World Team operations and membership management; workspace-request approval still needs specific delegation. |
| `president_team_member` | Tenant governance and operations; this membership grants no personal wallet. |
| Financial Evidence Reviewer | Specific active-person assignment configured by the President; not another organizational role. |
| Billing Owner | One commercial-contact/responsibility assignment; not a role and not authority by itself. |
| Platform operator/admin | Separately authorized Elivate-wide operations; tenant presidency does not grant platform powers. |

Hierarchy: **Tenant → World Team office → Director office → Team Leader office → member membership**. A workspace is an office inside a tenant, not a separate tenant. Rank is self-reported profile information and never an organizational role or permission.

One person can have multiple memberships across offices/tenants and one primary membership per tenant. Each membership has exactly one fixed organizational role. One wallet does not pool every tenant's funds into an interchangeable spendable balance; financial value retains its origin, currency, and pocket.

A President-only account has no wallet. A person who also has an eligible non-President membership may still own the single global wallet; selecting the President workspace does not expose personal-wallet leadership actions.

## P-04 — Chosen technical and integration baseline

| Layer | Contract |
|---|---|
| Frontend | Svelte, TypeScript, and Effect. Svelte components present UI; Effect structures asynchronous application/service workflows, validated transport outcomes, cancellation, and controlled recovery. |
| App framework/runtime | The Svelte choice is settled. Exact app router/SSR adapter, version pins, and build/deployment mode need a compatible implementation decision; SvelteKit is not silently treated as separately approved. |
| Visual system | **Approved:** Emberlit, a responsive product system documented in the existing Paper file `Elivate Wallet`, pages `Design system` and `Authentication`. Dark is the default and light is fully supported. See P-06 for the durable visual decisions. |
| Styling implementation | CSS framework, component library and purchased template remain undecided (U-12). Initial authentication compositions are documented in Paper; exact compositions for routes not represented there or in the wallet/operations examples remain open. Functional usability, accessibility and responsive behavior remain required. |
| Identity/backend | Supabase Auth, PostgreSQL, Edge Functions, private Storage, and Realtime where useful. PostgreSQL owns authorization and financial truth. |
| Command boundary | Verified-JWT Edge Function → narrow trusted service transport → private authorized PostgreSQL command. |
| Email | **Cloudflare Email Service / Email Sending** for outbound transactional email. Application notifications use the durable after-commit adapter. Supabase remains the Auth/token authority; connect its Auth emails to Cloudflare through a supported, verified SMTP or Auth-email integration. Exact transport and secure account/domain setup remain implementation dependencies. |
| Support | Chatwoot; explicit safe contact/context integration. Not SalesIQ despite historical section titles. |
| Analytics | PostHog with sensitive-data masking/exclusion and a reviewed consent/event contract. |
| Plan purchases | Paystack, yearly billing; never confuse this with deferred automated Wallet bank payouts. |
| Account-name resolution | NUBAN adapter for approved bank lookup/confirmation. Provider-neutral/manual destinations remain explicit. |
| Receipt extraction | OpenAI for payout receipt extraction. Server comparison and atomic commands decide verification/completion. |
| Domains | Public website `elivatewallet.com`; app `app.elivatewallet.com`; target backend custom domain `api.elivatewallet.com`; separate platform-admin app `admin.elivatewallet.com` (owner decision 2026-10-05; its screens are designed in a later wave). Domain targets are not a claim that provisioning is complete. |

The app is greenfield against a new Supabase project/database. Legacy application/schema is behavioral reference only. No legacy records are imported by default. A quoted Data Migration Extra does not authorize an import automatically.

Keep account, organization, authorization, wallet, financial commands, commercial state, and integrations separate. Changing the frontend does not change the ledger or permission model. Client/server code must keep credentials and private capabilities out of browser bundles.

## P-05 — Complete capability map

All required capabilities below remain in product scope. Workflow IDs are in `02-workflows.md`.

| Capability | Scope | Workflow |
|---|---|---|
| Login, founder entry, invitation completion, recovery, identity/profile onboarding | Required; production identity/enrollment contracts partly incomplete | W-01–W-03 |
| Public request-first office/workspace onboarding and approval delegation | Required; activation contract incomplete | W-04 |
| Offices, membership lifecycle, invitations, permanent UID | Required | W-03, W-05 |
| Role policies, selected-workspace capabilities, grants/denies, reviewer assignments | Required | W-06 |
| Personal/leadership dashboards, managed wallets, pockets, activity | Required | W-07 |
| Income recording and percentage allocation | Required | W-08 |
| Member withdrawals, optional on-behalf requests, approval, manual payout | Required | W-09–W-10 |
| Evidence verification, one correction, independent review | Required | W-10–W-11 |
| Currency conversion, including linked withdrawal conversion | Required; exact comparison contract must be verified | W-12 |
| Pocket transfers, including on-behalf initiation/approval | Required | W-13 |
| Administrative adjustments | Required | W-14 |
| Protected reversal/correction and returned funds | Required | W-15–W-16 |
| Verified payout accounts, primary selection, replacement, sensitive reveal | Required | W-17 |
| Searchable history, statements, leadership reports and exports | Required; a transaction CSV is not a full statement | W-18 |
| Size-based yearly subscription, capacity, Billing Owner, Extras | Required; collection/enrollment details incomplete | W-19 |
| Controlled team settings, branding, revisions, paid white-label domain | Required; domain provisioning contract incomplete | W-20 |
| Support, contextual documentation, essential communications | Required; external routing/data-sharing contracts incomplete | W-21 |
| Profile/security, transaction PIN, MFA, devices/sessions | Required; PIN/recovery policy partly incomplete | W-01, W-22 |
| Platform operations, immutable internal audit, feature flags, kill switches | Required; full operator matrix incomplete | W-23 |
| Platform disaster recovery and independent Team Backup Vault | Required; retention/destination/RPO/RTO contracts incomplete | W-24 |
| PWA, offline-safe shell, stable mobile-ready APIs | Required; native packaging/timing not yet settled | W-25 |
| Automated Wallet DVA/bank payouts and Paystack payout reconciliation | Deferred current wave; do not implement as active deliverables | W-26 |
| Native iOS/Android launch and device biometrics | Future delivery; preserve readiness without inventing launch scope | W-25 |

**In-app notifications (owner decision 2026-10-05):** a notification bell is required in the app shell on desktop and mobile. It surfaces durable after-commit events for the signed-in person (for example withdrawal status changes, income posted, assigned reviews, security alerts) within their current authority; exact event catalogue, retention and read-state contract remain open under U-11. It is not an audit-history feed.

**Billing visibility (owner decision 2026-10-05):** subscription and billing screens are visible to President Team Members and to the assigned Billing Owner only.

**Owner decision (2026-10-06):** a read-only, tenant-scoped Audit log is restored for the President. It shows the same safe internal audit fields (actor, action, target, time, reason, safe before/after) and never full accounts, credentials, evidence bodies or resolver internals. Wider access needs a reviewed permission; do not invent one.

**Deliberately excluded from current user-facing tenant/workspace surfaces:** raw Storage/asset management; arbitrary fonts/CSS; per-office branding; customizable module/workflow/currency-format preferences; public anonymous team configuration. Internal audit, evidence review queues, security alerts, and required after-commit channels are not removed by the navigation decision. Do not restore old audit-history previews; build from the 2026-10-06 decision above.

## P-06 — Functional experience and approved visual system

**Approved visual system:** Emberlit, documented in the existing Paper file `Elivate Wallet`, pages `Design system` and `Authentication`. The owner selected a near-black default theme with a complete light counterpart, a polished and premium tone, and the existing Elivate logo mark preserved in its coral `#FF7F4F`. The dark foundation uses canvas `#111314`, surface `#1A1D1E`, raised surface `#232728`, border `#343A3C`, and text `#F2F4F4`. The light foundation uses canvas `#F7F6F3`, surface `#FFFFFF`, raised surface `#EEF0F1`, border `#D8DDDE`, and text `#212628`. Use the deeper `#B74725` for small accent text and controls on light backgrounds. Lexend 400–700 is the primary typeface. Use a 4px spacing base (4, 8, 12, 16, 24, 32, 48px), 8/12/16/24px corners, and 44px minimum compact hit areas. Mobile examples use a bottom navigation bar; desktop examples use a capability-derived sidebar. The Paper system covers responsive product interfaces and core components; marketing is outside this design scope.

**Approved mascot:** Root, a cream felt piggy-bank plush in a charcoal suit with a coral tie, documented on the Paper `Mascot` page (`Root — Mascot (locked)`; the AI-generated master reference is the source image for future poses). Personality is evenly serious and fun: composed boss posture with a raised brow and knowing half smile. Palette is limited to cream, charcoal and Elivate coral. Root appears on every onboarding screen and, by owner decision (2026-10-05), intelligently across the app: empty states, completed steps, tips, quick-action prompts and success results. Owner decision (2026-10-06): every screen and transactional email, including error, offline and pending states, gets its own Root pose (never repeated); keep Root out of dense data tables and away from destructive-action buttons. Owner decision (2026-10-07): transactional emails open with a grainy coral Root hero band, keep copy to a headline, one line and one button, and money emails may show the exact amount with currency and the public reference; balances, bank/account numbers, evidence and review reasons stay in Wallet. Owner decisions (2026-10-07, later): light mode is not drawn screen-by-screen; developers build it from the approved light tokens. Responsiveness is vital: every app, auth and onboarding screen must have mobile (390px, checked at 320px) and desktop (1440px) compositions. Owner decision (2026-10-07, latest): tablet (768px) compositions are not drawn; developers adapt layouts between the mobile and desktop compositions (the few tablet artboards already drawn for Offices are reference only). The platform-admin app (`admin.elivatewallet.com`) is designed on the Paper `Admin` page; every registered admin has full access (owner decision 2026-10-07). Root stays out of generated PDF statements and reports. Approved app-screen compositions are on the Paper `App` pages; the earlier `App Wireframe` page is superseded. The `Authentication v2` page is a proposed auth redesign (Paper GrainGradient shader background) pending explicit adoption over the `Authentication` page.

The Paper foundations, components, mobile wallet home, and desktop operations overview are visual references, not an implementation stack or a route-complete specification. The `Authentication` page records the initial desktop/mobile sign-in, light sign-in counterpart, founder sign-up, verification/recovery notices, invitation verification, verified-session password setup, unavailable-invitation response, and generic sign-in error compositions. These visuals do not decide the identity provider, NIN/UID policy, or delivery setup; those remain under U-02 and U-11. Other unshown route layouts and implementation choices remain U-12. The established product, financial, authorization, accessibility, privacy, and recovery contracts continue to govern every screen.

Functional experience requirements remain:
- A trustworthy financial product with short, actionable copy and progressive detail. Preserve necessary validation, recovery, restrictions, and financial consequences.
- Avoid redundant visible titles/introductory text; keep accessible names/headings and essential instructions. No decorative style is prescribed by this information-economy rule.
- Authentication retains the supported routes, validation, password visibility, safe continuation and privacy. Its initial visual compositions are documented on the Paper `Authentication` page; unresolved provider and identity policy remain U-02, and other route compositions remain U-12.
- **Quick search (owner decision 2026-10-07):** the tenant app's ⌘K search covers everything the person can already see in the selected workspace: members (name, UID, email, phone), offices, transactions and public references, withdrawals, transfers, returned funds, and pages/actions. Results never widen authority; sensitive values stay masked.
- Navigation is responsive and derived from validated active context and effective backend capabilities. Eligible personal context uses Personal Home instead of a duplicate My Wallet module. The approved system uses a mobile bottom bar and desktop sidebar; visibility remains capability-driven.
- Workspace and member views retain approved filtering/search and authorized presentation options without widening scope. Apply the approved system; route-specific composition remains open where not shown in Paper.
- Record detail views (owner decision, 2026-10-05): on desktop a record opens as a side peek by default, with center peek, full page and open-in-new-tab options; the chosen mode is remembered per user. On mobile, details open as a bottom sheet that drags up to full screen. Peek views keep previous/next navigation within the current list.
- Controls have semantic labels, keyboard operation, visible focus, appropriate dismissal/focus restoration and search for long option lists. No component library or custom/native rendering choice is selected.
- Minimum compact hit area is 44px. Validate at 320px, normal mobile widths, desktop, keyboard, reduced motion, long names/references and no horizontal overflow. Preserve dark, light and system-following theme capability. Aim for AAA where practical; do not claim certification without testing.
- Status has readable text and does not rely only on color. Approval is not completion; receipt upload is not payment verification.
- Money appears in an explicit currency or separate labeled currency totals. Never sum USD and NGN into a fake combined total. Privacy controls obscure sensitive amounts without changing underlying data.
- Show authoritative live data, a truthful empty state, or honest unavailable/restricted state. No fake balances, counts, reviews, payment successes, support conversations or mock interactions presented as live.
- Preview/demo routes are isolated for authorized development/staging reviewers. Sample ranks, pockets, rates, accounts and styling do not establish business or visual-design authority.

## P-07 — Definition of done

A required capability is complete only when:
1. Its approved behavior, roles/scope, inputs, transitions, exceptions, and financial effects are implemented.
2. Its trusted reads/commands and current-authorization retries work; no direct private access is introduced.
3. Tests cover happy paths, denial, owner/non-owner distinctions, multiple memberships/tenants, revocation/expiry, stale sessions, concurrency, duplicate requests, exact decimals, and partial failure where relevant.
4. Data loading, pagination, errors, unknown outcomes, refresh/context switching, accessibility, and mobile/dark states work.
5. External dependencies and secure configuration required by the workflow are verified; unavailable integration is not labeled success.
6. Database migrations replay from empty, RLS/privileges and generated-interface drift checks pass, and Svelte/TypeScript/Effect builds/tests pass for the chosen deployed runtime.
7. Financial conservation and ledger/projection consistency are demonstrated for representative test journeys, not just empty queues.
8. Review, environment-scoped deployment, and hosted verification distinguish read-only testing, synthetic fixtures, and actual operations. No production money movement is inferred from a successful build.

Financial safety and tenant isolation outrank raw speed. Paginate and filter large datasets server-side; load-test auth spikes, dashboards, histories, allocation, withdrawal/transfer races, reviews, and entitlements. Benchmark authorization and implement safe cache invalidation without stale allows.

## P-08 — Agent quick answers

- **Does a higher role inherit lower-role permissions?** No; load the exact-role policy.
- **Can leaders operate their own wallet?** Through eligible self-service, not leadership money-management permissions.
- **Does changing membership move old funds?** No; financial provenance/history is retained.
- **Must every withdrawal/transfer have a different maker and checker?** No; permitted non-owner actors may hold both ordinary initiation and approval permissions. Evidence self-review is still forbidden.
- **Can we post income before a second approval?** Yes: approved income is a direct command with mandatory evidence, not a second income-approval workflow.
- **Does receipt upload complete a payout?** No; verification/clearance precedes atomic posting.
- **Can the frontend or Effect own the balance?** No; both present/orchestrate the authoritative backend outcome.
- **Is Paystack entirely deferred?** No. Plan purchases are selected; DVA/automated Wallet payouts and their reconciliation remain deferred.
- **Do we need Notion on every task?** No. Use this pack; ask only about a material conflict/missing decision not settled here or by consistent repository contracts.

## P-09 — Named unresolved contracts (do not guess)

| ID | Missing contract | What it blocks |
|---|---|---|
| U-01 | Production pocket catalogue/names, direction flags, exact default percentages, deterministic rounding/remainder tie-breaks, and unsupported Debt edge cases | New financial configuration/algorithms unless the approved repository contract supplies them; do not invent Savings/Spend/A/B as production semantics. |
| U-02 | Production NIN verification provider, exact UID format, duplicate identity handling, NIN retry limits and leader-review mechanics, and transaction-PIN storage/attempt/step-up policy. **Decided by owner (2026-10-05):** members verify identity with NIN; the verification returns and locks only the legal name and, optionally, the phone number; when no phone is returned the member enters it manually, and the profile photo is always uploaded by the member; the transaction PIN is 4 digits. **Decided by owner (2026-10-07):** UID and public reference formats (01 D-01); PIN attempt limit 5 with email reset (01 A-05). **Decided by owner (2026-10-08):** PIN storage per 01 A-05 (keyed hash with a server-side secret, then bcrypt; locked until email reset). | Claims of verified identity, PIN security completion, and complete production onboarding. |
| U-03 | Verified Paystack purchase → durable payment/receipt → account-bound enrollment/tenant activation; invoice/tax/trial/renewal/overage/plan-change rules | Production checkout activation and commercial automation; yearly prices/provider are already decided. |
| U-04 | Public workspace-request anti-abuse, tenant binding, persistence, exact delegated permission, post-approval account/office activation and rollback contract | Full production request-first journey; accepted request must not itself grant a role. |
| U-05 | Paid white-label price, DNS/domain-control verification, TLS, routing/session/callback isolation and retirement lifecycle | Live custom-domain activation; one verified active domain/tenant is approved. |
| U-06 | Backup destinations, schedule/retention/entitlements, restore conflict treatment (requester, Elivate-only review/restore and statuses decided 2026-10-07, see W-24), RPO/RTO (not answered in Notion as of 2026-10-07; destinations, frequencies and Standard/Professional/Enterprise retention there are marked "potential") | Full Backup Vault and DR readiness; named destinations and tier examples are not defaults. |
| U-07 | Exact supported currency scales, financial thresholds/limits, provider-fee edge cases, conversion/adjustment/return comparison criteria not specified in the payout policy | Unsupported cases and security thresholds; preserve existing approved backend settings where available. |
| U-08 | Account restriction/read-access truth table where worksheet language conflicts with frozen global-suspension denial; account closure and mixed-role presidency transitions | Broadening suspended-account access or inventing closure/membership/wallet deletion behavior. Retain frozen deny until explicitly resolved. |
| U-09 | Sign-in PIN recovery beyond the email reset (the authenticator app was dropped 2026-10-07; PIN storage and lockout decided 2026-10-08, see 01 A-05). **Decided by owner (2026-10-07):** every registered platform admin has full access to every admin surface and action; there is no per-capability operator matrix. | Recovery/bypass only. |
| U-10 | Svelte app-level runtime/version pins/SSR adapter, verified hosting/PWA plan, native packaging and launch dates | Final deployment/mobile claim; **not** reconsideration of Svelte + Effect. |
| U-11 | In-app notification event catalogue, retention and read-state contract; Cloudflare Email Sending domain/account onboarding, paid-plan availability, secure Workers/API/SMTP adapter, Supabase Auth email connection, sender/template/recipient rules, PostHog taxonomy/consent and Chatwoot data sharing. **Done 2026-10-08 (development project):** `elivatewallet.com` is onboarded for Cloudflare Email Sending (SPF/DKIM/DMARC ready) and Supabase Auth email uses Cloudflare SMTP (`smtp.mx.cloudflare.net`, sender `noreply@elivatewallet.com`) with a key scoped to Email Sending; Resend is no longer used. Real external delivery and the paid-plan check remain to be confirmed at the first real sign-up. | Live delivery and monitoring beyond reviewed adapters; Cloudflare is already the selected sender, not an open provider choice. |
| U-12 | Styling implementation and remaining route specs: CSS framework, component library, template use, and exact layouts for routes not represented in the current Paper examples | Those implementation and route-level decisions only. P-06's visual foundation, typography, palette, responsive navigation conventions, wallet/operations examples, and initial authentication compositions are approved; do not reuse old template decisions as defaults. |
| U-13 | Remaining plan bands: the 3 additional bands' caps and prices (owner: skip for now, 2026-10-07). Other organization/navigation items checked in Notion were decided by the owner on 2026-10-07 (W-05, W-06, W-18, W-24, P-06). | Plan picker beyond the three launch bands. |

This pack preserves known contracts and exposes genuine gaps. It is not a guarantee that source material already answers every production decision.

## P-10 — Compilation provenance (audit only; not required reading)

Approved rules were consolidated from the following workspace sources. Links are provenance, not runtime dependencies; agents should not load them routinely:
- Main product and superseding payout/transfer decisions. [^https://app.notion.com/p/3d3dede2e75e81f2a811eeb4b049e8d2]
- Frozen domain/financial/commercial specification. [^https://app.notion.com/p/3dfdede2e75e81a187dce76d1d46fa0d]
- Frozen authorization resolver and complete 31-row permission matrix. [^https://app.notion.com/p/3dbdede2e75e815abcb6c22f1aa31aba] [^https://app.notion.com/p/653420b12a494cb2baeeffdab688f541]
- Backend transport/account/evidence worksheet. [^https://app.notion.com/p/3e1dede2e75e81be89c4da3c009889b6]
- Tenant configuration and removed navigation surfaces. [^https://app.notion.com/p/3e1dede2e75e81d3bb67e879e391e4df]
- Design, role/module inventory, and superseding auth presentation. [^https://app.notion.com/p/3e2dede2e75e817d96d7fac925c60179] [^https://app.notion.com/p/3e4dede2e75e81738dd3c527f3a9980d]
- Invitation-bound completion and scoped development exception. [^https://app.notion.com/p/3e6dede2e75e812e9541c18fe861945f]
- Private/RLS implementation boundaries, used only where consistent with frozen rules and later decisions. [^https://app.notion.com/p/3dcdede2e75e818d9c74f97575787670]

The Svelte + Effect choice, styling deferral and Cloudflare email-sending choice come directly from the owner in the compilation conversation. Historical design sources supply functional requirements only where consistent with those current decisions. Effect conventions are pack-level implementation guidance, not a claim that legacy Effect integration already exists.

Cloudflare Email Service supports outbound sending through Workers bindings, REST API or SMTP; Email Routing alone is not the outbound solution. Sender domain onboarding uses Cloudflare DNS and email-authentication records. Sending to arbitrary customer recipients requires the Workers Paid plan; current limits/pricing must be checked during provisioning rather than hardcoded into the product contract. [^https://developers.cloudflare.com/email-service/get-started/send-emails] [^https://developers.cloudflare.com/email-service/platform/pricing/]
