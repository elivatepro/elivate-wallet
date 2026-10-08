import { assert, assertEquals } from "@std/assert";
import { createAccountCrypto } from "../supabase/functions/_shared/account_crypto.ts";
import { type FakeFixtures, fakeProvider } from "../supabase/functions/_shared/name_lookup.ts";
import {
  type Actor,
  createHandler,
  type Deps,
  type LogEntry,
  type RpcResult,
} from "../supabase/functions/payout/handler.ts";

const actor: Actor = {
  userId: "00000000-0000-0000-0000-0000000000a1",
  sessionId: "00000000-0000-0000-0000-00000000a0a1",
};
const membershipId = "00000000-0000-0000-0000-0000000000b1";
const accountId = "00000000-0000-0000-0000-0000000000c1";
const lookupId = "00000000-0000-0000-0000-0000000000d1";
const key = "key-0000000000000001";
const number = "0123456789";

const accountCrypto = await createAccountCrypto({
  encryption: new Map([[1, "11".repeat(32)]]),
  currentVersion: 1,
  fingerprint: "33".repeat(32),
});

type Responder = (fn: string, args: Record<string, unknown>) => RpcResult;

const ok = (data: unknown): RpcResult => ({ data, error: null });
const fail = (message: string, details: unknown = {}): RpcResult => ({
  data: null,
  error: { message, details: JSON.stringify(details) },
});

function lookupRow(status: string, extra: Record<string, unknown> = {}) {
  return {
    lookupId,
    status,
    bankCode: "058",
    bankName: "Guaranty Trust Bank",
    accountLast4: "6789",
    accountName: status === "resolved" ? "ADA OBI" : null,
    nameMatch: status === "resolved" ? "identity_pending" : null,
    replacesPayoutAccountId: null,
    expiresAt: "2026-10-08T10:15:00Z",
    confirmedPayoutAccountId: null,
    replayed: false,
    ...extra,
  };
}

/** Default database: a fresh pending proof, answered by record_account_lookup. */
const defaultDb: Responder = (fn, args) => {
  switch (fn) {
    case "prepare_account_lookup":
      return ok(lookupRow("pending"));
    case "record_account_lookup":
      return ok(lookupRow(args.p_outcome === "resolved" ? "resolved" : "not_found"));
    default:
      return ok({ ok: true });
  }
};

function setup(
  db: Responder = defaultDb,
  fixtures: FakeFixtures | null = { accounts: { [`058:${number}`]: "ADA OBI" } },
) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const logs: LogEntry[] = [];
  const provider = fixtures ? fakeProvider(fixtures) : null;
  const deps: Deps = {
    verifyToken: (token) => Promise.resolve(token === "good" ? actor : null),
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve(db(fn, args));
    },
    log: (entry) => logs.push(entry),
    allowedOrigins: ["https://app.elivatewallet.com"],
    provider,
    accountCrypto,
  };
  return { handler: createHandler(deps), calls, logs, provider };
}

function request(
  method: string,
  path: string,
  body?: unknown,
  headers: Record<string, string> = { "x-membership": membershipId },
): Request {
  return new Request(`http://localhost/functions/v1/payout${path}`, {
    method,
    headers: { authorization: "Bearer good", "content-type": "application/json", ...headers },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

const lookupBody = { bankCode: "058", accountNumber: number, idempotencyKey: key };

Deno.test("missing or invalid token is authentication_required", async () => {
  const { handler, calls } = setup();
  const response = await handler(
    new Request("http://localhost/functions/v1/payout/accounts", {
      headers: { "x-membership": membershipId },
    }),
  );
  assertEquals(response.status, 401);
  assertEquals(calls.length, 0);
});

Deno.test("actor and workspace come from the token and header, never the body", async () => {
  const { handler, calls } = setup();
  const response = await handler(request("GET", "/accounts"));
  assertEquals(response.status, 200);
  assertEquals(calls[0]?.fn, "list_payout_accounts");
  assertEquals(calls[0]?.args, {
    p_user_id: actor.userId,
    p_session_id: actor.sessionId,
    p_membership_id: membershipId,
  });
});

Deno.test("X-Membership is required except for the bank list", async () => {
  const { handler, calls } = setup((fn) =>
    ok(fn === "list_banks" ? { banks: [{ code: "058", name: "GTB" }], stale: false } : {})
  );
  for (const headers of [{}, { "x-membership": "nope" }]) {
    const response = await handler(request("GET", "/accounts", undefined, headers));
    assertEquals((await response.json()).error.code, "workspace_invalid");
  }
  assertEquals(calls.length, 0);
  const banks = await handler(request("GET", "/banks", undefined, {}));
  assertEquals(banks.status, 200);
  assertEquals(calls[0]?.fn, "list_banks");
});

Deno.test("unknown body and query fields are rejected", async () => {
  const { handler, calls } = setup();
  const body = await handler(request("POST", "/lookups", { ...lookupBody, userId: actor.userId }));
  assertEquals(body.status, 400);
  assertEquals((await body.json()).error.details.field, "userId");
  const query = await handler(request("GET", "/accounts?ownerId=x"));
  assertEquals(query.status, 400);
  assertEquals(calls.length, 0);
});

Deno.test("account numbers must be 10-digit strings and bank codes well formed", async () => {
  const { handler, calls } = setup();
  for (
    const body of [
      { ...lookupBody, accountNumber: 123456789 },
      { ...lookupBody, accountNumber: "123456789" },
      { ...lookupBody, accountNumber: "01234 6789" },
      { ...lookupBody, accountNumber: "01234567890" },
      { ...lookupBody, bankCode: "05-8" },
      { ...lookupBody, bankCode: 58 },
      { ...lookupBody, idempotencyKey: "short" },
      { ...lookupBody, replacesPayoutAccountId: "nope" },
    ]
  ) {
    assertEquals((await handler(request("POST", "/lookups", body))).status, 400);
  }
  assertEquals(calls.length, 0);
});

Deno.test("lookup: only sealed data reaches the database; the result is masked", async () => {
  const { handler, calls, provider } = setup();
  const response = await handler(request("POST", "/lookups", lookupBody));
  assertEquals(response.status, 200);
  const json = await response.json();
  assertEquals(json.data.accountName, "ADA OBI");
  assertEquals(json.data.accountLast4, "6789");
  assertEquals("replayed" in json.data, false);
  assertEquals(provider?.calls, ["resolve:058"]);

  const prepare = calls[0];
  assert(prepare);
  assertEquals(prepare.fn, "prepare_account_lookup");
  assertEquals(prepare.args.p_account_last4, "6789");
  assertEquals(prepare.args.p_key_version, 1);
  assertEquals(/^[0-9a-f]{64}$/.test(String(prepare.args.p_account_fingerprint)), true);
  assertEquals(
    await accountCrypto.open(actor.userId, String(prepare.args.p_account_ciphertext), 1),
    number,
  );
  assertEquals(calls[1]?.fn, "record_account_lookup");
  assertEquals(calls[1]?.args.p_outcome, "resolved");
  assertEquals(calls[1]?.args.p_account_name, "ADA OBI");
  for (const call of calls) assertEquals(JSON.stringify(call.args).includes(number), false);
});

Deno.test("lookup: a stored answer is reused without calling the provider", async () => {
  const { handler, calls, provider } = setup((fn) =>
    fn === "prepare_account_lookup" ? ok(lookupRow("resolved", { replayed: true })) : ok({})
  );
  const response = await handler(request("POST", "/lookups", lookupBody));
  assertEquals(response.status, 200);
  assertEquals(provider?.calls, []);
  assertEquals(calls.map((c) => c.fn), ["prepare_account_lookup"]);
});

Deno.test("lookup: provider not_found is account_not_found", async () => {
  const { handler, calls } = setup(defaultDb, { accounts: {} });
  const response = await handler(request("POST", "/lookups", lookupBody));
  assertEquals(response.status, 422);
  assertEquals((await response.json()).error.code, "account_not_found");
  assertEquals(calls[1]?.args.p_outcome, "not_found");
});

Deno.test("lookup: provider down is retryable and records nothing; same key retries", async () => {
  const fixtures = { accounts: { [`058:${number}`]: "unavailable" } } as const;
  const { handler, calls } = setup(defaultDb, fixtures);
  const response = await handler(request("POST", "/lookups", lookupBody));
  assertEquals(response.status, 503);
  const json = await response.json();
  assertEquals(json.error.code, "provider_unavailable");
  assertEquals(json.error.retryable, true);
  assertEquals(json.error.details.retryAfterSeconds, 30);
  assertEquals(calls.map((c) => c.fn), ["prepare_account_lookup"]);

  const retry = setup(defaultDb);
  const second = await retry.handler(request("POST", "/lookups", lookupBody));
  assertEquals(second.status, 200);
  assertEquals(retry.calls[0]?.args.p_idempotency_key, key);
});

Deno.test("lookup: without a Paystack key the answer is provider_unavailable", async () => {
  const { handler } = setup(defaultDb, null);
  const response = await handler(request("POST", "/lookups", lookupBody));
  assertEquals(response.status, 503);
  assertEquals((await response.json()).error.code, "provider_unavailable");
});

Deno.test("bank list: fresh cache is served without the provider", async () => {
  const cached = { banks: [{ code: "058", name: "GTB" }], refreshedAt: "x", stale: false };
  const { handler, provider, calls } = setup(() => ok(cached));
  const response = await handler(request("GET", "/banks"));
  assertEquals((await response.json()).data, cached);
  assertEquals(provider?.calls, []);
  assertEquals(calls.length, 1);
});

Deno.test("bank list: stale cache is refreshed from the provider", async () => {
  let refreshed = false;
  const { handler, calls } = setup(
    (fn) => {
      if (fn === "refresh_banks") {
        refreshed = true;
        return ok({ refreshed: true, count: 1 });
      }
      return ok({ banks: [], stale: !refreshed });
    },
    { accounts: {}, banks: [{ code: "044", name: "Access Bank", slug: "access" }] },
  );
  const response = await handler(request("GET", "/banks"));
  assertEquals(response.status, 200);
  assertEquals(calls.map((c) => c.fn), ["list_banks", "refresh_banks", "list_banks"]);
  assertEquals(calls[1]?.args.p_provider, "paystack");
  assertEquals(calls[1]?.args.p_banks, [{ code: "044", name: "Access Bank", slug: "access" }]);
});

Deno.test("bank list: provider down serves the stale cache, or fails when empty", async () => {
  const stale = { banks: [{ code: "058", name: "GTB" }], stale: true };
  const withCache = setup(() => ok(stale), { accounts: {}, banks: "unavailable" });
  const served = await withCache.handler(request("GET", "/banks"));
  assertEquals((await served.json()).data, stale);

  const empty = setup(() => ok({ banks: [], stale: true }), null);
  const response = await empty.handler(request("GET", "/banks"));
  assertEquals(response.status, 503);
  assertEquals((await response.json()).error.code, "provider_unavailable");
});

Deno.test("confirm needs confirmed: true and passes an optional reason", async () => {
  const { handler, calls } = setup();
  const missing = await handler(request("POST", "/accounts", { lookupId, idempotencyKey: key }));
  assertEquals(missing.status, 400);
  const notTrue = await handler(
    request("POST", "/accounts", { lookupId, confirmed: "yes", idempotencyKey: key }),
  );
  assertEquals(notTrue.status, 400);
  assertEquals(calls.length, 0);
  await handler(request("POST", "/accounts", { lookupId, confirmed: true, idempotencyKey: key }));
  assertEquals(calls[0]?.fn, "confirm_payout_account");
  assertEquals(calls[0]?.args.p_reason, null);
  await handler(
    request("POST", "/accounts", {
      lookupId,
      confirmed: true,
      reason: "Moved banks",
      idempotencyKey: key,
    }),
  );
  assertEquals(calls[1]?.args.p_reason, "Moved banks");
});

Deno.test("primary and deactivate routes pass the path id", async () => {
  const { handler, calls } = setup();
  await handler(
    request("POST", `/accounts/${accountId.toUpperCase()}/primary`, { idempotencyKey: key }),
  );
  assertEquals(calls[0]?.fn, "set_primary_payout_account");
  assertEquals(calls[0]?.args.p_payout_account_id, accountId);
  const noReason = await handler(
    request("POST", `/accounts/${accountId}/deactivate`, { idempotencyKey: key }),
  );
  assertEquals(noReason.status, 400);
  await handler(
    request("POST", `/accounts/${accountId}/deactivate`, { reason: "Closed", idempotencyKey: key }),
  );
  assertEquals(calls[1]?.fn, "deactivate_payout_account");
  const badId = await handler(request("POST", "/accounts/123/primary", { idempotencyKey: key }));
  assertEquals(badId.status, 404);
});

Deno.test("reveal decrypts in Edge for the owner, with no-store", async () => {
  const sealed = await accountCrypto.seal(actor.userId, "058", number);
  const { handler, calls } = setup((fn) =>
    fn === "reveal_payout_account"
      ? ok({ payoutAccountId: accountId, ciphertext: sealed.ciphertext, keyVersion: 1 })
      : ok({})
  );
  const response = await handler(request("POST", `/accounts/${accountId}/reveal`));
  assertEquals(response.status, 200);
  assertEquals(response.headers.get("cache-control"), "no-store");
  assertEquals((await response.json()).data, { payoutAccountId: accountId, accountNumber: number });
  assertEquals(calls[0]?.args.p_payout_account_id, accountId);
});

Deno.test("reveal of a ciphertext bound to someone else is an internal error", async () => {
  const sealed = await accountCrypto.seal("00000000-0000-0000-0000-0000000000ff", "058", number);
  const { handler } = setup(() =>
    ok({ payoutAccountId: accountId, ciphertext: sealed.ciphertext, keyVersion: 1 })
  );
  const response = await handler(request("POST", `/accounts/${accountId}/reveal`));
  assertEquals(response.status, 500);
  assertEquals((await response.json()).error.code, "internal_error");
});

Deno.test("database error codes map to the envelope", async () => {
  const cases: [string, number, unknown][] = [
    ["bank_unknown", 422, {}],
    ["payout_lookup_expired", 409, {}],
    ["payout_name_mismatch", 422, { explanation: "bank_name_does_not_match_nin" }],
    ["payout_account_exists", 409, {}],
    ["rate_limited", 429, { retryAfterSeconds: 120 }],
    ["step_up_required", 403, {}],
  ];
  for (const [code, status, details] of cases) {
    const { handler } = setup(() => fail(code, details));
    const response = await handler(
      request("POST", "/accounts", { lookupId, confirmed: true, idempotencyKey: key }),
    );
    assertEquals(response.status, status);
    const json = await response.json();
    assertEquals(json.error.code, code);
    assertEquals(json.error.details, details);
  }
});

Deno.test("unexpected database results are internal errors", async () => {
  const { handler } = setup(() => ok(null));
  const response = await handler(request("GET", "/accounts"));
  assertEquals(response.status, 500);
});

Deno.test("logs carry the route pattern only: no ids, numbers, names or bank codes", async () => {
  const { handler, logs } = setup();
  await handler(request("POST", "/lookups", lookupBody));
  await handler(request("POST", `/accounts/${accountId}/primary`, { idempotencyKey: key }));
  const text = JSON.stringify(logs.map(({ requestId: _requestId, ...rest }) => rest));
  assertEquals(logs.map((l) => l.route), ["POST /lookups", "POST /accounts/:id/primary"]);
  for (const secret of [number, "6789", "ADA OBI", "058", accountId, actor.userId]) {
    assertEquals(text.includes(secret), false);
  }
});

Deno.test("no response except reveal carries the full number", async () => {
  const { handler } = setup();
  for (
    const r of [
      request("POST", "/lookups", lookupBody),
      request("GET", "/accounts"),
      request("POST", "/accounts", { lookupId, confirmed: true, idempotencyKey: key }),
    ]
  ) {
    assertEquals((await (await handler(r)).text()).includes(number), false);
  }
});
