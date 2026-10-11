# Blueprint 34 — Support chat with context (slice 34)

Status: **owner decisions 2026-10-11** (a separate Chatwoot inbox for the app; support sees name,
email and account context; a topic picked before chatting; Mon–Fri 9–5 Lagos). Built in slice 34.
Supersedes the "UID, network name and screen only" part of Blueprint 17 / W-21.

## Chatwoot (account "Wallet by Elivate", 184772)
- **Inbox "Elivate Wallet — App"** (website inbox, `https://app.elivatewallet.com`), separate from
  the marketing site's "Elivate Wallet" inbox, which is unchanged. Ember `#FF7F4F`, title
  "Elivate support", "usually replies in a few hours", greeting on, CSAT on, email collection
  off, continuity by email on, auto-assignment on.
- **Identity validation required** (`hmac_mandatory`): only the app server, holding the inbox's
  HMAC token, can name a contact.
- **Working hours** Monday–Friday 09:00–17:00 `Africa/Lagos`, with an away message.
- **Pre-chat form:** one required list, **Topic** (conversation attribute `topic`): Withdrawal or
  payout · Income or records · Transfers or returned funds · PIN or signing in · Members or
  invitations · Billing or plan · Something else. Name, email and phone fields are off (the app
  already sends them; Chatwoot hides them for an identified contact anyway).
- **Labels and automation:** one rule per topic (conversation created in this inbox) adds
  `app-chat` and the topic's label (`withdrawal`, `income`, `transfers`, `pin-sign-in`,
  `members`, `billing`, `other`).
- **Contact attributes** (defined in the account): `uid`, `network`, `network_id`,
  `network_status`, `plan`, `role`, `office`, `account_status`, `security_gate`, `screen`,
  `device`, `installed_app`, `app_version`, `language`, `timezone`, `last_error`,
  `last_error_request`, `last_error_at`.

## What the app sends
- **Server (`GET /api/support/chat`, one `app_bootstrap` read):** the signed UID; the contact
  name (shown name, or the UID before there is one) and the account email; network name and ID,
  network status, role, office (name and type), account status and security gate; the plan and
  subscription status only for people who can read billing (Billing Owner or
  `manage_subscription`; nobody else triggers a refused billing call).
- **Browser:** `screen` is the screen the person was on before Support (route pattern, never ids
  or queries); device ("Phone · Android 14 · Chrome 141", from the user agent), installed app
  (home-screen mode), app build, language, timezone; and the **last error** the app showed in
  this tab: its code, request ID (for the logs), screen and time. A PIN owed is not an error, and
  neither is a background poll the person never sees fail (the bell). A plan that can't be read
  just then shows as "unavailable (<code>)", unlike no plan line for people without billing access.
- Still never: money, balances, bank details, evidence, PINs or tokens.

## How
- `transport.ts`: the reply observer is now a set, with `refused(code, requestId)` and
  `failed(reason)` (timeouts, network, unexpected bodies; not aborts). The PIN lock is one
  observer; `watchErrors` in `chat.ts` is the other (started by the app layout).
- The app layout remembers the last non-Support route (`afterNavigate` → `rememberScreen`).
- Worker secrets `CHATWOOT_WEBSITE_TOKEN` and `CHATWOOT_HMAC_TOKEN` now hold the app inbox's
  values (set from the Chatwoot API without printing them).

## Not in it
- Topic picker in the app's own UI (Chatwoot's pre-chat form is used instead).
- Clearing an older `last_error` on the contact: `last_error_at` shows when it happened.
