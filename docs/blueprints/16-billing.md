# Blueprint 16 — Billing (slice 7)

Status: **built under the member build plan** (`docs/member-build-plan.md`, "Billing (W-19, U-03, U-13)" and the owner decisions during the build, including the slice 7 answers of 2026-10-09 below). Contract: W-19 (subscription, capacity, Billing Owner), D-10 (commercial semantics), U-03 (checkout and activation), A-03 (`manage_subscription`), U-11 (B01–B05). Builds on Blueprints 02 (tenants, memberships, `org.check_seat_capacity` hook), 03 (invitations), 11 (withdrawals and payouts) and 13 (outbox, `notify.emit`, the bell). Migrations `2026100916xxxx`; pgTAP `160_`–`169_`.

Part A is for the owner. Part B is the build spec.

---

## Part A — What this slice does

### What's in it
1. **Founder setup** (Paper PL01–PL03). A signed-in person starts a network: they name it, then choose a plan. The **first network a founder ever starts can run a 7-day free trial** on the smallest band (up to 400 people); everything works during the trial, real money included. A founder can also skip the trial and pay for any launch band straight away. A founder who has already had a trial pays before the new network opens.
2. **Plans.** Only the three launch bands, yearly, in naira, VAT included: up to 400 people ₦700,000.00, up to 1,000 ₦1,000,000.00, 1,001+ ₦1,500,000.00.
3. **Paying** (PL03, payment confirmed and still confirming). "Pay" opens Paystack's checkout. The payment only counts when Elivate's server has checked it with Paystack (signed webhook, then a server-side check of amount, currency, reference and test/live mode). Coming back from Paystack never activates anything by itself. If the confirmation is slow, the screen says "Still confirming… don't pay again" with **Check again**. Every payment gets an Elivate **`PAY-XXXX-XXXX`** reference. Paystack's own reference is kept separately and never shown as the public reference.
4. **Renewal.** A card payment sets up a **Paystack subscription**: the next year is charged automatically a day before the year ends. Payments by transfer or USSD can't be charged again, so those networks renew by paying again. Reminders (B02) go out 30, 7 and 1 days before a renewal, and 3 and 1 days before a trial ends. **When the year or the trial ends unpaid, the network pauses at once**, with no grace period.
5. **Billing page** (PL04 trial, E01 active, PL05 upgrade). Status, plan, period, seats used, Billing Owner, the plans and the payments. Each payment opens its receipt (the "Payment confirmed" view). **Upgrade** works at any time and costs the price difference × days left in the paid year ÷ 365, to the kobo (PL05). Auto-renew can be turned off, and a smaller band can be chosen for the next renewal if the current seats fit. There are no refunds.
6. **Seats** (D-10). One seat per distinct person with an active or suspended membership; the President counts; an invitation alone doesn't. At the cap, new invitations ("Can't add members right now", E03) and accepting a pending invitation are refused until the plan is upgraded. B04 goes out once per period when seats reach 90%.
7. **Paused network** (PL06 and the pay-to-resume view). Members keep read-only access to their own money. Leaders keep read-only history, reports, queues and the audit log. Nobody can record income, withdraw, move between pockets, convert, adjust, reverse, invite or change the organization. Withdrawals approved before the pause can still be paid out and reviewed. Leaders and the Billing Owner see Billing with **Pay to resume**; a paused network that pays starts a full year at payment.
8. **Billing Owner** (v2 B01 "Change Billing Owner"). There is one current Billing Owner, with history and audit; the founder holds it at first. It is a responsibility, not a power. Changing it needs `manage_subscription` and the PIN; the new owner gets B03.
9. **Emails and bell** (B01 Payment received, B02 Renewal reminder, B03 Billing Owner assigned, B04 Seats almost full, B05 Plan paused). They go to the Billing Owner and the President Team, each with a bell item.

### Decisions (owner answers 2026-10-09)
| # | Question | Answer |
|---|---|---|
| Q1 | Networks already on dev | **Grandfathered** as the W-19 development scope exception: active, no end date, no seat cap, audited per network, no trial used. Networks still awaiting payment follow the new rules. |
| Q2 | Payment model | **Paystack subscriptions** (automatic yearly renewal on the saved card). |
| Q3 | When a paid year starts | **At the end of the current trial or period**, so paying early loses no days. |
| Q4 | Paying to reactivate a paused network | **The year starts at payment.** |
| Q5 | Reminders | **B02 at 30, 7 and 1 days** before a renewal; **trial: 3 and 1 days** before it ends; **B04 at 90%** of seats, once per period. |
| Q6 | Downgrades, cancelling, refunds | **No refunds.** Auto-renew can be turned off (the network pauses at the end of the year), and a smaller band can be chosen for the next renewal only if the current seats fit. Upgrades apply at once. |
| Q7 | Who pays | **`manage_subscription` holders and the current Billing Owner** can pay, upgrade and reactivate; only `manage_subscription` changes the Billing Owner. **The founder is the default Billing Owner.** B01–B05 go to the Billing Owner and the President Team. |
| Q8 | Seat cap and unpaid trial | **New invitations and acceptances are refused at the cap**; pending invitations stay valid until they expire. An unpaid trial pauses exactly like an expiry. |
| Q9 | Platform-admin activation | **Kept for support**: a platform admin (PIN + reason) can grant a complimentary period with an end date, or the development exception. It is audited, never counted as a payment, and sends no B01. |
| Q10 | Leaders on a paused network | **Read-only + Billing** (W-19): history, reports, statements, queues and the audit log stay; every write is off except paying out and reviewing withdrawals approved before the pause. |
| Q11 | B05 copy | **"History stays available. Pay to turn it back on."** with the button **Review billing** (the drawn "Talk to us to resume / Contact Elivate" is replaced). |
| Q12 | Voluntary upgrades | **Pay directly**: "Request" becomes "Upgrade", which opens the PL05 dialog at any time. The v2 "Request plan change" dialog is not built. |

Paper drafts approved 2026-10-09 (App v4, bottom row): **PL07d** Billing · paused, pay to resume; **PL08d** Billing · active with the Renewal card (replaces Extras; "Ask about extras" moves to Support) and Upgrade buttons; **PL09d** Manage renewal; **PL10d** Payment not completed; **PL11d/PL11** Choose a plan, trial used. Mobile follows the drawn mobile layouts (E02, v2 B06/B08, PL02) with the same copy. B05's Paper copy now reads "Pay to turn it back on" / "Review billing".

### Decisions I applied (say if you want them changed)
- **Paying during a trial** sets the chosen band at once (a bigger band lifts the 400 cap immediately). The paid year runs from the trial's end, so the remaining free days are kept.
- **Proration days** count from today to the last paid day, in WAT, as in PL05: until 13 Mar 2027 from 9 Oct 2026 is 155 days, so ₦300,000.00 × 155 ÷ 365 = ₦127,397.26. Rounding is half-up to the kobo. A quote is honoured for the amount actually charged; a new quote is made each WAT day. On the last paid day an upgrade is free and applies at once.
- **Auto-renew** charges the card one day before the year ends, so a successful renewal never pauses the network. If that charge fails, the network pauses at the end of the year, B05 goes out, and paying from Billing reactivates it.
- **A late renewal charge** that arrives after the pause reactivates the network and is treated like any reactivation (the year starts at payment).
- **Payout accounts** stay readable on a paused network but can't be added, replaced or removed until it is reactivated (the existing rule for a suspended network).
- **Pending money items on a paused network** (requested withdrawals and pocket moves, conversions and adjustments waiting for review) stay as they are until the network is reactivated. Only payouts for already-approved withdrawals carry on.
- **The Paystack customer** is the person who pays. Their card renews the subscription even if the Billing Owner changes later; the new owner can pay again or upgrade with their own card.
- **A payment that arrives late** (for example a checkout paid in an old tab) is never lost: a year payment always adds a year from the end of the current one, and an upgrade that no longer fits (already upgraded) is recorded as paid but not applied and flagged in the audit log for support to refund by hand (no automatic refunds).

### Not in it
- Bands 4–6 (U-13), Extras and their quotes ("Ask about extras" opens support chat), tax invoices.
- Refunds and partial-year downgrades.
- The Admin app screens; the support activation is an `api.*` route only.
- Changing the saved card: the person pays again from Billing, which moves the subscription to the new card.

---

## Part B — Build spec

### B1. Data (`billing` schema, private)
| Object | Rules |
|---|---|
| `billing.plans` | Immutable, versioned: `id`, `key` (`band_400`, `band_1000`, `band_1001_plus`), `version`, `name`, `seat_cap` (400, 1000, null), `price numeric(14,2)`, `currency` = `NGN`, `launch` (offered). Seeded with the three launch bands; rows never change. |
| `billing.provider_plans` | `plan_id`, `environment` (`test`/`live`), `plan_code` (Paystack `PLN_…`); filled the first time a plan is needed (the function finds or creates the Paystack plan, interval `annually`, amount in kobo). |
| `billing.subscriptions` | One per tenant: `tenant_id` PK, `status` (`pending`, `trial`, `active`, `paused`), `kind` (`trial`, `paid`, `complimentary`, `development`), `plan_id`, `period_start`, `period_end` (null only for `development`), `paused_at`, `auto_renew`, `next_plan_id` (smaller band at the next renewal), `provider_customer_code`, `provider_subscription_code`, `provider_email_token` (never returned to clients), `sync_state` (`none`, `pending`, `failed`), `sync_attempts`, `sync_after`, `updated_at`. Tenant status mirrors it: `pending` → `pending_payment`, `trial`/`active` → `active`, `paused` → `suspended`. |
| `billing.periods` | History: every trial, paid year, upgrade, complimentary grant and pause (`tenant_id`, `kind`, `plan_id`, `starts_at`, `ends_at`, `payment_id`, `actor_user_id`, `created_at`). Append-only. |
| `billing.trials` | `user_id` PK → `tenant_id`, `started_at`: **one trial per founder, ever**. |
| `billing.payments` | `id`, `tenant_id`, `reference` (`PAY-…`, `refs.issued`), `purpose` (`start`, `renew`, `upgrade`, `reactivate`, `auto_renewal`), `plan_id`, `from_plan_id`, `amount numeric(14,2)`, `currency`, `days_left` (upgrades), `status` (`open`, `paid`, `failed`, `abandoned`, `superseded`), `applied`, `needs_review`, `provider_reference` (unique; opaque `ewp_…` we send for checkouts, or Paystack's for renewals), `provider_transaction_id`, `environment`, `authorization_url` (open checkouts only), `initiated_by`, `idempotency_key`, `covers_from`/`covers_to` (set when applied), `paid_at`, timestamps. One `open` checkout per tenant: a new checkout supersedes the old one. |
| `billing.provider_events` | Webhook log for deduplication: `dedupe_key` unique (`event` + Paystack id/reference), `event`, `body_sha256`, `outcome`, `tenant_id`, `received_at`. Raw bodies (emails, card details) are never stored. |
| `billing.owners` | `tenant_id`, `user_id`, `membership_id`, `assigned_by`, `assigned_at`, `ended_at`; unique current owner per tenant. |
| Templates + kinds | `billing.payment_received` (B01: `network`, `amount`, `currency`, `reference`, `path`), `billing.renewal_reminder` (B02: `network`, `amount`, `currency`, `due`, `chip`, `path`), `billing.owner_assigned` (B03: `network`, `path`), `billing.seats_almost_full` (B04: `network`, `used`, `cap`, `path`), `billing.paused` (B05: `network`, `path`); a kind for each, none a task. |

Migration `20261009160300` grandfathers every **active** tenant with no subscription as `development` (with a tenant audit row and a `periods` row). It reads only tenant ids and statuses; no user or financial row is read or changed. Pending tenants get a `pending` subscription on `band_400`. Every tenant gets its founder as Billing Owner.

### B2. Rules (Postgres owns them)
- **Start** (`api.start_network` gains `p_plan_key`, `p_trial`). With a trial, the founder must have no `billing.trials` row and the plan must be `band_400`; the network is active at once (`activation_source = 'trial'`), with the trial ending 7 days later. Without a trial, the network is `pending_payment` until the first payment. The founder becomes Billing Owner. Defaults (`band_400`, no trial) keep the old behaviour.
- **Seats** (`org.check_seat_capacity`, filled): a per-tenant advisory lock (`billing.seats:<tenant>`), never a tenant row lock. Distinct users with an `active` or `suspended` membership; a person who already counts passes. Cap: the plan's `seat_cap` (a trial is `band_400`; `development` has none). At the cap → `conflict` with `details.reason = 'seat_limit_reached'` (`used`, `cap`). Crossing 90% emits B04 once per period. Invitations: a trigger on new invitations refuses `seat_limit_reached` when the network is full and the invited email isn't already a counted person.
- **Prices** (`billing.quote`): `start`/`renew`/`reactivate`/`auto_renewal` cost the plan price. An `upgrade` costs `round((new − current) × days_left / 365, 2)` (half-up), where `days_left = (period_end − 1 day)::date − today` in Africa/Lagos. It must be a bigger band on an `active` paid period. During a trial, a bigger band is a `renew` at full price.
- **Applying a payment** (`billing.apply_payment`, subscription row locked, `open → paid` once): the verified amount and currency must equal the quoted ones, or the payment becomes `failed` (`needs_review`) and nothing activates. Start: year = [paid, paid + 1 year). Renew or auto-renewal: year from `period_end` when it is still in the future, otherwise from payment; a pending smaller band applies here. Reactivate (paused): year from payment, and the tenant goes back to `active`. Upgrade: plan changes now, period unchanged. A year payment always adds a year; an upgrade that no longer fits (already upgraded) is recorded `paid`, `applied = false`, `needs_review = true` and audited. Then: `periods` row, tenant audit, B01 + bell, and `sync_state = 'pending'` when the payment was by reusable card.
- **Lifecycle** (`billing.run_lifecycle()`, pg_cron every minute, pure SQL): `trial`/`active` (not `development`) with `period_end ≤ now()` → `paused` (tenant `suspended`, `paused_at`, `periods` row, audit, B05). B02 reminders at 30/7/1 days (trial 3/1), deduplicated per period and day. Open checkouts older than 24 hours → `abandoned`.
- **Paused gating.** `authz.decide` (reads) treats a suspended network like an active one. `authz.require` (writes) refuses a suspended network with `network_not_active`, except for: own-money reads, statements and reports, payout-account reads (changes refused), `manage_subscription`, and payouts/reviews where the withdrawal was approved before `paused_at`. `finance.require_payout_actor` passes `p_allow_paused` for those; entry reviews stay refused. `org.require_active_tenant` keeps refusing every organizational write. `manage_subscription` also passes on `pending_payment` networks (to pay). Invitation preview and acceptance already require an active network.
- **Billing access**: `billing.require_actor(user, workspace)`: the workspace's active membership, and `manage_subscription` (role policy or explicit grant) or being the current Billing Owner. Reads use the same check; `canManage` (owner change, auto-renew, next band) needs `manage_subscription`.
- **Billing Owner change** (`api.change_billing_owner`): `manage_subscription`, step-up (PIN), an active target membership with an active account, serialized on the subscription row; ends the current row, inserts the new one, writes a tenant audit row, sends B03 to the new owner. Same owner → `conflict` `already_owner`.
- **Support activation** (`api.activate_tenant`, platform admin, step-up, reason): new `p_until` (date) → `complimentary` period until then; null → `development` exception. Works on pending, trial and paused networks; audited; never a payment.

### B3. Commands and routes (`billing` Edge Function)
`verify_jwt = false` for the whole function: the webhook is signed by Paystack, the worker route uses `BILLING_WORKER_SECRET`, and user routes verify the bearer token themselves (`auth.getClaims`, as in `payout`) and take the workspace from `x-membership`.

| Route | `api.*` | Notes |
|---|---|---|
| `GET /setup` | `billing_setup` | Plans, whether the founder's trial is available, any network awaiting payment. |
| `GET /overview` | `billing_overview` | Status, plan, period, trial end, seats, owner, plans with the action and amount (upgrade quotes), payments, auto-renew, next band, `canPay`/`canManage`. Billing Owner or `manage_subscription` only. |
| `POST /checkout` `{purpose, planKey, idempotencyKey}` | `billing_checkout` → Paystack `transaction/initialize` → `billing_checkout_opened` | Server-computed amount (kobo), the payer's account email, `reference = provider_reference`, `callback_url = APP_ORIGIN/app/billing/payments/<id>` (founder setup: `/setup/payment/<id>`), metadata `{paymentId}` only. Returns `{paymentId, reference, authorizationUrl}`. A free upgrade (last paid day) is applied directly. |
| `GET /payments/:id` | `billing_payment` (+ server verify) | While `open`: verify with Paystack (`transaction/verify`) and apply if paid; never trusts the redirect. Returns status and the receipt fields. |
| `POST /auto-renew` `{enabled}` | `billing_set_auto_renew` | `manage_subscription`; marks a Paystack sync. |
| `POST /next-plan` `{planKey or null}` | `billing_set_next_plan` | Smaller band only, current seats must fit (`conflict` `seats_exceed_plan`). |
| `GET /owner-candidates?q=` | `billing_owner_candidates` | Active members of the network, by name or UID. |
| `POST /owner` `{membershipId, idempotencyKey}` | `change_billing_owner` | Step-up first (PIN), as for other PIN commands. |
| `POST /paystack/webhook` | `billing_record_event`, `billing_apply_verified`, `billing_provider_subscription` | Raw body ≤ 64 KB; `x-paystack-signature` = hex HMAC-SHA512 of the raw bytes with `PAYSTACK_SECRET_KEY`, compared in constant time, before parsing. A bad signature gets 401; duplicates get 200 with nothing done. `charge.success` and paid `invoice.update` → `transaction/verify` → amount, currency `NGN`, `status = success`, `domain` matching the key (`sk_test_` ↔ `test`), reference → apply. A renewal is matched by subscription code (invoice) or by the customer + plan pair when exactly one subscription fits. `subscription.disable`/`not_renew` → auto-renew off. Unknown events → 200, logged. Transient failures → 500 so Paystack retries. |
| `POST /worker/sync` | `billing_sync_claim`, `billing_sync_done` | pg_cron via Vault (`billing_worker_url`, `billing_worker_secret`). Creates or disables the Paystack subscription so it matches `auto_renew` and the band: disables the old one (code + email token), then creates `{customer, plan, start_date = period_end − 1 day}`. If no reusable card is saved, auto-renew turns off. Bounded retries. |

Founder start stays `POST /org/networks` (with `planKey` and `trial`); the admin activation stays `POST /org/admin/tenants/:id/activate` (with optional `until`). The app server's BFF proxies `/api/billing/*`.

### B4. Screens (frontend)
- `/setup` (auth background): PL01 name → PL02 plan (trial when available, otherwise the pay-first variant) → PL03 Paystack hand-off → `/setup/payment/[id]` (confirmed / still confirming / not completed).
- `/app/billing`: PL04 (trial), E01 (active), the paused variant (pay to resume), the PL05 upgrade dialog (at the cap and voluntary), the v2 B01 owner change (PIN), auto-renew and next-band controls, payments with receipts.
- `/app/billing/payments/[id]`: v2 B05/B06 confirmed (the receipt), B07/B08 still confirming, plus the not-completed state.
- Paused banner (PL06) on member home and leader screens (with "Review billing" for those who may pay); write actions hidden while paused. The E03 seat-limit dialog on invite and member add; the President or Billing Owner sees PL05 instead.
- Billing in the nav for the President Team and the Billing Owner (owner decision 2026-10-05).

### B5. Emails and bell
B01–B05 rendered from Paper "Emails — Transactional v2" with the shared layout (`_shared/email/layout.ts`), one template row, renderer and `notify.emit` call each (Blueprint 13). Recipients: the current Billing Owner plus every active President Team member, deduplicated. Money in emails is the exact amount with currency and the `PAY` reference only.

### B6. Tests
- pgTAP `160_billing_plans_and_start`: plans immutable; one trial per founder ever (second network pending, skip-trial allowed); trial only on `band_400`; founder is Billing Owner; grandfathering migration result.
- `161_seats`: memberships vs people, suspended counts, President counts, invitation alone doesn't, ended doesn't; cap refusal; invitation refusal at the cap; concurrency (two sessions, advisory lock) can't over-activate; B04 once at 90%.
- `162_payments`: proration in exact kobo (the PL05 example and edge days); start/renew/reactivate/upgrade period maths; replayed apply and duplicate provider reference can't activate twice; forged amount or currency refused; superseded and late payments flagged.
- `163_lifecycle_and_pause`: expiry pauses with no grace (trial and paid); B02/B05 once; a paused network refuses every catalogued money command (income, withdrawal request/approve, pocket move request/approve, conversion, adjustment, returned funds, reversal, entry review, invitations, org changes) but still records and reviews payouts for withdrawals approved before the pause and keeps own-money reads, statements and reports.
- `164_owner_and_access`: owner change needs `manage_subscription` + step-up and an active target; history and audit; Billing Owner can pay but not reassign; members without either see nothing; no cross-tenant reads or payments.
- `165_privileges`: no client access to the `billing` schema; worker and webhook functions are service-only.
- `169_billing_seat_race`: two real sessions (dblink, committed synthetic fixture) race for the last seat; the second waits on the lock and is refused.
- Deno: signature (valid, tampered, missing, wrong key), dedupe, forged amount, wrong domain, unknown event, verify-on-poll, sync worker, route validation.
- e2e: founder trial → billing page → upgrade dialog; skip-trial pay → fake Paystack checkout → signed webhook → confirmed; second network pay-first; seat cap dialog; paused member home banner. Screenshots of every new screen, plus B01–B05 in light, dark and 320 px.
