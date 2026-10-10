import { assertEquals } from "@std/assert";
import {
  accountNumberIn,
  type Actor,
  createHandler,
  type Deps,
  type LogEntry,
  type RpcResult,
} from "../supabase/functions/admin/handler.ts";

const actor: Actor = {
  userId: "00000000-0000-0000-0000-0000000000a1",
  sessionId: "00000000-0000-0000-0000-00000000a0a1",
};
const tenantId = "00000000-0000-0000-0000-0000000000c1";
const restoreId = "00000000-0000-0000-0000-0000000000d1";
const key = "key-0000000000000001";
const secret = "app-server-secret-value";

function setup(
  rpc: (fn: string) => RpcResult = () => ({ data: { ok: true }, error: null }),
) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const logs: LogEntry[] = [];
  const fingerprinted: string[] = [];
  const deps: Deps = {
    verifyToken: (token) => Promise.resolve(token === "good" ? actor : null),
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve(rpc(fn));
    },
    bankFingerprint: (bankCode, accountNumber) => {
      fingerprinted.push(`${bankCode}:${accountNumber}`);
      return Promise.resolve(bankCode.padEnd(64, "a"));
    },
    log: (entry) => logs.push(entry),
    allowedOrigins: ["https://admin.elivatewallet.com"],
    appServerSecret: secret,
  };
  return { handler: createHandler(deps), calls, logs, fingerprinted };
}

function request(
  method: string,
  path: string,
  body?: unknown,
  headers: Record<string, string> = { "x-app-server-secret": secret },
): Request {
  return new Request(`http://localhost/functions/v1/admin${path}`, {
    method,
    headers: {
      authorization: "Bearer good",
      "content-type": "application/json",
      ...headers,
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

Deno.test("every route needs the app-server secret, even with a valid token", async () => {
  const { handler, calls } = setup();
  const missing = await handler(request("GET", "/overview", undefined, {}));
  assertEquals(missing.status, 403);
  assertEquals((await missing.json()).error.details.reason, "app_server_only");
  const wrong = await handler(
    request("GET", "/overview", undefined, { "x-app-server-secret": "nope" }),
  );
  assertEquals(wrong.status, 403);
  assertEquals(calls.length, 0);
});

Deno.test("a missing or bad token is refused before anything runs", async () => {
  const { handler, calls } = setup();
  const response = await handler(
    new Request("http://localhost/functions/v1/admin/overview", {
      headers: { authorization: "Bearer bad", "x-app-server-secret": secret },
    }),
  );
  assertEquals(response.status, 401);
  assertEquals(calls.length, 0);
});

Deno.test("no secret configured refuses everything (fail closed)", async () => {
  const { calls } = setup();
  const handler = createHandler({
    verifyToken: () => Promise.resolve(actor),
    rpc: () => Promise.resolve({ data: {}, error: null }),
    bankFingerprint: () => Promise.resolve(""),
    log: () => {},
    allowedOrigins: [],
    appServerSecret: null,
  });
  assertEquals((await handler(request("GET", "/me"))).status, 403);
  assertEquals(calls.length, 0);
});

Deno.test("actor comes from the token, never the body", async () => {
  const { handler, calls } = setup();
  const response = await handler(
    request("POST", "/switches", {
      key: "withdrawals",
      stopped: true,
      reason: "Bank partner outage",
      idempotencyKey: key,
    }),
  );
  assertEquals(response.status, 200);
  assertEquals(calls[0]?.fn, "admin_set_switch");
  assertEquals(calls[0]?.args.p_user_id, actor.userId);
  assertEquals(calls[0]?.args.p_session_id, actor.sessionId);
  assertEquals(calls[0]?.args.p_tenant_id, null);
  assertEquals(calls[0]?.args.p_stopped, true);
});

Deno.test("switch keys, flags and unknown fields are validated", async () => {
  const { handler, calls } = setup();
  for (
    const body of [
      {
        key: "remittance",
        stopped: true,
        reason: "Outage",
        idempotencyKey: key,
      },
      { key: "income", stopped: "yes", reason: "Outage", idempotencyKey: key },
      {
        key: "income",
        stopped: true,
        reason: "Outage",
        idempotencyKey: key,
        extra: 1,
      },
      {
        key: "income",
        stopped: true,
        reason: "Outage",
        idempotencyKey: key,
        tenantId: "x",
      },
    ]
  ) {
    assertEquals(
      (await handler(request("POST", "/switches", body))).status,
      400,
    );
  }
  assertEquals(calls.length, 0);
});

Deno.test("account routes take a UID path segment", async () => {
  const { handler, calls } = setup();
  assertEquals(
    (await handler(request("GET", "/accounts/ew-48213"))).status,
    200,
  );
  assertEquals(calls[0]?.args.p_uid, "EW-48213");
  assertEquals((await handler(request("GET", "/accounts/48213"))).status, 404);
  const status = await handler(
    request("POST", "/accounts/EW-48213/status", {
      status: "suspended",
      reason: "Fraud review",
      idempotencyKey: key,
    }),
  );
  assertEquals(status.status, 200);
  assertEquals(calls[1]?.fn, "set_account_status");
  assertEquals(calls[1]?.args.p_target_uid, "EW-48213");
});

Deno.test("list filters are checked against their choices", async () => {
  const { handler, calls } = setup();
  assertEquals(
    (await handler(request("GET", "/tenants?state=paused&q=cedar"))).status,
    200,
  );
  assertEquals(calls[0]?.args.p_state, "paused");
  assertEquals(calls[0]?.args.p_query, "cedar");
  assertEquals(
    (await handler(request("GET", "/tenants?state=frozen"))).status,
    400,
  );
  assertEquals(
    (await handler(request("GET", "/accounts?status=gone"))).status,
    400,
  );
  assertEquals((await handler(request("GET", "/audit?group=all"))).status, 400);
  assertEquals(
    (await handler(request("GET", "/audit?from=2026-13-01"))).status,
    400,
  );
  assertEquals(
    (await handler(request("GET", "/audit?actor=EW-1"))).status,
    400,
  );
  assertEquals(
    (await handler(request("GET", "/tenants?sort=name"))).status,
    400,
  );
  assertEquals(calls.length, 1);
});

Deno.test("a searched account number is fingerprinted, never sent to the database", async () => {
  const { handler, calls, fingerprinted } = setup((fn) =>
    fn === "admin_bank_codes"
      ? { data: ["058", "044"], error: null }
      : { data: { accounts: [] }, error: null }
  );
  const response = await handler(request("GET", "/search?q=0123%20456%20789"));
  assertEquals(response.status, 200);
  assertEquals(fingerprinted, ["058:0123456789", "044:0123456789"]);
  const search = calls.find((c) => c.fn === "admin_search");
  assertEquals(search?.args.p_query, "•••• 6789");
  assertEquals((search?.args.p_bank_fingerprints as string[]).length, 2);
  assertEquals(JSON.stringify(calls).includes("0123456789"), false);
});

Deno.test("ordinary searches pass the text and no fingerprints", async () => {
  const { handler, calls } = setup();
  assertEquals((await handler(request("GET", "/search?q=Okafor"))).status, 200);
  assertEquals(calls[0]?.fn, "admin_search");
  assertEquals(calls[0]?.args.p_bank_fingerprints, null);
  assertEquals((await handler(request("GET", "/search?q=x"))).status, 400);
});

Deno.test("account numbers are recognised only with exactly 10 digits", () => {
  assertEquals(accountNumberIn("0123456789"), "0123456789");
  assertEquals(accountNumberIn("0123-456-789"), "0123456789");
  assertEquals(accountNumberIn("012345678"), null);
  assertEquals(accountNumberIn("EW-48213"), null);
});

Deno.test("support activation: until is optional (development exception)", async () => {
  const { handler, calls } = setup();
  await handler(
    request("POST", `/tenants/${tenantId}/activate`, {
      reason: "Partner pilot",
      until: "2026-12-31",
      idempotencyKey: key,
    }),
  );
  await handler(
    request("POST", `/tenants/${tenantId}/activate`, {
      reason: "Dev",
      idempotencyKey: key,
    }),
  );
  assertEquals(calls[0]?.args.p_until, "2026-12-31");
  assertEquals(calls[1]?.args.p_until, null);
});

Deno.test("restore steps: no manual in_review, rows and report are validated", async () => {
  const { handler, calls } = setup();
  const skip = await handler(
    request("POST", `/restores/${restoreId}/advance`, {
      status: "in_review",
      reason: "Skip",
      idempotencyKey: key,
    }),
  );
  assertEquals(skip.status, 400);
  const rows = await handler(
    request("POST", `/restores/${restoreId}/rows`, {
      section: "offices",
      rows: [{ id: "1" }],
    }),
  );
  assertEquals(rows.status, 200);
  assertEquals(calls[0]?.fn, "admin_restore_rows");
  assertEquals(
    (await handler(
      request("POST", `/restores/${restoreId}/rows`, {
        section: "Offices!",
        rows: [],
      }),
    )).status,
    400,
  );
  assertEquals(
    (await handler(
      request("POST", `/restores/${restoreId}/rows`, {
        section: "x_y",
        rows: [1],
      }),
    ))
      .status,
    400,
  );
  const done = await handler(
    request("POST", `/restores/${restoreId}/validated`, {
      ok: false,
      failReason: "checksum_mismatch",
      sections: [{ section: "offices", rows: 3, sha256Ok: false }],
    }),
  );
  assertEquals(done.status, 200);
  assertEquals(calls[1]?.args.p_report, {
    sections: [{ section: "offices", rows: 3, sha256Ok: false }],
  });
});

Deno.test("database error codes pass through with their details", async () => {
  const { handler } = setup(() => ({
    data: null,
    error: { message: "conflict", details: '{"reason":"operation_paused"}' },
  }));
  const response = await handler(request("GET", "/overview"));
  assertEquals(response.status, 409);
  assertEquals(
    (await response.json()).error.details.reason,
    "operation_paused",
  );
});

Deno.test("logs carry the route pattern, never ids or search text", async () => {
  const { handler, logs } = setup();
  await handler(request("GET", "/accounts/EW-48213"));
  await handler(request("GET", "/search?q=Okafor"));
  assertEquals(logs[0]?.route, "GET /accounts/:uid");
  assertEquals(JSON.stringify(logs).includes("Okafor"), false);
  assertEquals(JSON.stringify(logs).includes("48213"), false);
});
