# Blueprint 06 — Identity (NIN) and profile

Status: **owner instructed "build everything now" (2026-10-08)**; decisions below were answered in the session that built it. Contract: W-01 step 5, W-02 (first-use wizard steps 3–5, NIN name match), W-17 (name rule, "identity check pending"), W-22 (profile), U-02 (partly resolved here), A-01–A-05, T-01. Builds on Blueprints 01 (accounts, PIN gate, step-up, `identity.replay`), 02 (memberships, office closure) and 05 (`identity.legal_name` plug-in point, `payout.recheck_name_match`). Migrations `2026100905xxxx`; pgTAP `060_`–`069_`.

## Part A — What this slice does

1. **Verify your NIN.** The person types their 11-digit NIN. The server asks the NIN provider for the record. If a record comes back, the legal name (first, middle, surname) and, when returned, the phone number are locked to the account. Nothing else from the record is stored: no photo, address, date of birth or the NIN itself.
2. **The NIN is never stored.** Only a keyed fingerprint (HMAC with a server secret) and the last 4 digits. The fingerprint enforces **one NIN, one account**.
3. **Two tries, then a leader.** After a failed check the person can try again or ask for a review. After **2 failed checks** only a review is possible. A NIN already verified on another account is refused, and nothing about that account is revealed.
4. **Leader review.** The person submits their NIN and their legal name as printed on the ID. A **President Team Member of that network, a World Team Member above the person's office, or an Elivate admin** approves or rejects it, with a reason and their PIN. An approval locks the typed name as *leader-confirmed* (method `leader_review`), never as provider-verified.
5. **Bank accounts follow automatically.** When a legal name is locked, every saved payout account is re-checked under the W-17 name rule ("identity check pending" accounts resolve; mismatches lose primary and the owner is alerted). This fills Blueprint 05's plug-in point.
6. **Profile.** Read your own profile (UID, names, phone, rank, photo, identity status). Change your display name, rank and phone; the phone is locked when the NIN record supplied it. Upload a profile photo.
7. **Photos live in Cloudflare R2** (owner decision), in a private bucket. The app server (Cloudflare Worker) stores the image and serves it only to the signed-in owner. The database keeps only the object key.

### Not in it
- Review emails ("we'll email you"): the template and recipient rules are U-11. Status shows in the app; copy on the review screen must not promise an email until a template is approved.
- Leaders seeing other people's photos (member lists): later.
- Reviewer UI in the admin app (the admin app doesn't exist yet); API routes exist.
- Re-verification or NIN change after locking: support only.

### Owner decisions (2026-10-08)
| # | Question | Decision |
|---|---|---|
| Q1 | NIN provider | The one the earlier Wallet by Elivate used: **NUBAN KYC data API** (`GET {NUBAN_KYC_BASE_URL}/api/nin-data?nin_no=…`, `Authorization: Bearer NUBAN_KYC_API_KEY`). |
| Q2 | Failed checks before review | **2.** |
| Q3 | NIN already verified on another account | **Block.** |
| Q4 | Who reviews | **President Team, World Team, or an Elivate admin.** |
| Q5 | Photo storage | **Cloudflare R2**, private. |

## Part B — Build spec

### B1. Data (`identity` schema, private, RLS on)
| Table | Columns | Rules |
|---|---|---|
| `identity.nin_records` | `user_id` PK, `nin_fingerprint` (64 hex, **unique**), `nin_last4`, `given_name`, `middle_names text[]`, `surname`, `phone` (nullable), `method` (`provider`/`leader_review`), `review_id`, `verified_at` | Immutable (update/delete/truncate rejected). One per account. |
| `identity.nin_attempts` | `id`, `user_id`, `nin_last4`, `outcome` (`verified`/`not_found`/`in_use`), `at` | Append-only. `not_found` rows are the failures counted against the limit of 2. Provider outages are not recorded and cost nothing. |
| `identity.nin_reviews` | `id`, `user_id`, `tenant_id`, `membership_id`, `nin_fingerprint`, `nin_last4`, typed `given_name`/`middle_names`/`surname`, `status` (`pending`/`approved`/`rejected`), `requested_at`, `decided_at`, `decided_by`, `decision_reason` | At most one pending per person. A rejected review may be followed by a new request. |
| `identity.profiles` (+) | `photo_key`, `photo_updated_at`, `phone_source` (`nin`/`self`) | `photo_key` matches `photos/<user uuid>/<uuid>.(jpg\|png\|webp)`. |

`identity.legal_name(user)` now returns `{ given, middle: [..], surname, verifiedAt, method }` from `nin_records`. Locking a name also sets `profiles.first_name`/`last_name` (display) and, when the record has a phone, `profiles.phone` with `phone_source = 'nin'`.

### B2. Commands (`api.*`, definer, service_role only)
| Command | Checks | Result |
|---|---|---|
| `my_profile(user, session)` | gate `ready` | Profile + `identity { status: unverified/verified/review_pending, method, verifiedAt, legalName, ninLast4, failedChecks, checksRemaining, review { status, requestedAt, decidedAt } }`. |
| `update_profile(user, session, changes jsonb, key, req)` | gate; keys `displayName` (1–80 or null), `phone` (`+?[0-9]{7,15}`; refused with `conflict` when `phone_source = 'nin'`), `rank` (W-02 list) | Updated profile. Idempotent. |
| `set_profile_photo(user, session, key, req)` | gate; key pattern bound to the caller's own uuid | `{ photoKey, previousPhotoKey }` (the server deletes the old object). |
| `prepare_nin_check(user, session, fingerprint)` | gate; not verified (`conflict`/`already_verified`); no pending review (`conflict`/`review_pending`); failures < 2 (`nin_review_required`); fingerprint verified on another account → attempt `in_use` + `nin_in_use` | `{ ready: true }` (the Edge then calls the provider). |
| `record_nin_check(user, session, fingerprint, last4, outcome, given, middle, surname, phone, req)` | Same checks again under the account lock | `verified` → record + profile + payout re-check + audit; returns `{ status: 'verified', … }`. `not_found` → attempt row, returns `{ status: 'not_verified', checksRemaining }` (returned, not raised, so the attempt is kept). |
| `request_nin_review(user, session, membership, fingerprint, last4, given, middle, surname, key, req)` | gate; workspace; ≥ 1 failed check; not verified; none pending; fingerprint not taken (`nin_in_use`) | Pending review. |
| `nin_reviews(user, session, membership)` | President Team (whole network) or World Team (offices at/below theirs) | Pending reviews they may decide: id, requester UID + display/legal-name-as-typed, office, NIN last 4, requested at. |
| `admin_nin_reviews(user, session)` | platform admin | All pending. |
| `decide_nin_review(user, session, membership \| null, review, decision, reason, key, req)` | step-up; reason; reviewer authority (above; `null` membership = platform admin); not self (`self_target_forbidden`); pending (`conflict`) | `approved` → record (`leader_review`) + profile + payout re-check; `rejected` → reason kept. Audit both. |

New error codes (append-only, `_shared/http.ts` and the frontend list): `nin_not_verified` (422, `details.checksRemaining`), `nin_in_use` (409), `nin_review_required` (409).

### B3. Edge Function `identity` (`verify_jwt = true`)
`GET /profile`, `GET /onboarding/workspace` (`X-Membership`; gate `ready` or `pin_setup_required`; the caller's own membership only: network, office, role, because the wizard Welcome comes before the PIN), `PATCH /profile`, `POST /profile/photo`, `POST /nin/verify` `{ nin }`, `POST /nin/review` (`X-Membership`) `{ nin, givenName, middleNames?, surname, idempotencyKey }`, `GET /nin/reviews` (`X-Membership`), `POST /nin/reviews/:id/decide` (`X-Membership`) `{ decision, reason, idempotencyKey }`, `GET /admin/nin/reviews`, `POST /admin/nin/reviews/:id/decide`.

The raw NIN exists only in memory in the Edge Function: fingerprint = hex HMAC-SHA256(`NIN_FINGERPRINT_KEY`, `"nin:v1:" + nin`). Provider adapter `_shared/nin_provider.ts`: 2xx with a first name and surname → `found`; 2xx without names → `unavailable` (never burns a check; logs only the key shape); 400/404/422 → `not_found`; 401/403/429/5xx/network/timeout (10 s) → `unavailable` (`provider_unavailable`). No NIN, name, phone or response body in logs.

Secrets (names only): `NUBAN_KYC_API_KEY`, `NUBAN_KYC_BASE_URL` (optional, default `https://api-kycdata.nuban.com.ng`), `NIN_FINGERPRINT_KEY` (32 random bytes hex). Without the API key, `/nin/verify` answers `provider_unavailable`; everything else works.

### B4. Photos (frontend Worker)
R2 binding `PHOTOS` on the app Worker (bucket `elivate-wallet-dev-photos` for dev; R2 must be enabled on the Cloudflare account first). Upload: multipart form → server checks size ≤ 5 MB and magic bytes (JPEG/PNG/WebP) → `PUT photos/<user>/<uuid>.<ext>` → `POST /identity/profile/photo` → delete the previous object. Read: `GET /api/profile/photo` streams the caller's own photo, `cache-control: private, no-store`. No public bucket, no signed URLs.

### B5. Tests
pgTAP `060_identity_nin.sql`: check limits (2), in-use blocking, verified locking + profile/phone + immutability, attempts kept on failure, payout re-check called (pending → matched), review authority matrix (PT, WT above, WT sibling refused, TL refused, admin, self refused), approve/reject, idempotency. `061_profile.sql`: read, update rules, rank list, NIN phone lock, photo key ownership. `062_identity_privileges.sql`: definer/privilege rules. Deno: provider adapter mapping, fingerprint, handler routing/validation/no NIN in logs.
