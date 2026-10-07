import { assertEquals, assertFalse } from "jsr:@std/assert@1.0.13";
import {
  type Actor,
  createHandler,
  type Deps,
  type LogEntry,
  type RpcResult,
} from "../supabase/functions/security/handler.ts";
import { createPinHasher } from "../supabase/functions/_shared/pin.ts";

const actor: Actor = {
  userId: "00000000-0000-0000-0000-0000000000a1",
  sessionId: "00000000-0000-0000-0000-00000000a0a1",
};

function setup(rpcResult: RpcResult = { data: { gate: "ready" }, error: null }) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const logs: LogEntry[] = [];
  const resets: string[] = [];
  const deps: Deps = {
    verifyToken: (token) => Promise.resolve(token === "good" ? actor : null),
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve(rpcResult);
    },
    pinHmac: (pin) => Promise.resolve(`hmac(${pin})`),
    sendResetLink: (userId) => {
      resets.push(userId);
      return Promise.resolve();
    },
    log: (entry) => logs.push(entry),
    allowedOrigins: ["https://app.elivatewallet.com"],
  };
  return { handler: createHandler(deps), calls, logs, resets };
}

function request(method: string, path: string, body?: unknown, token = "good"): Request {
  return new Request(`http://localhost/functions/v1/security${path}`, {
    method,
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

Deno.test("missing or invalid token is authentication_required", async () => {
  const { handler, calls } = setup();
  const response = await handler(request("GET", "/state", undefined, "bad"));
  assertEquals(response.status, 401);
  assertEquals((await response.json()).error.code, "authentication_required");
  assertEquals(calls.length, 0);
});

Deno.test("actor comes from the verified token, never the body", async () => {
  const { handler, calls } = setup();
  await handler(request("POST", "/pin/verify", { pin: "1234" }));
  assertEquals(calls[0]?.args.p_user_id, actor.userId);
  assertEquals(calls[0]?.args.p_session_id, actor.sessionId);
});

Deno.test("unknown body fields are rejected", async () => {
  const { handler, calls } = setup();
  const response = await handler(request("POST", "/pin/verify", { pin: "1234", userId: "x" }));
  assertEquals(response.status, 400);
  assertEquals((await response.json()).error.details.field, "userId");
  assertEquals(calls.length, 0);
});

Deno.test("PIN must be exactly four digits and match its confirmation", async () => {
  const { handler } = setup();
  for (
    const body of [{ pin: "123", pinConfirm: "123" }, { pin: "12a4", pinConfirm: "12a4" }, {
      pin: "1234",
      pinConfirm: "1235",
    }]
  ) {
    assertEquals((await handler(request("POST", "/pin/set", body))).status, 400);
  }
});

Deno.test("only the HMAC reaches the database", async () => {
  const { handler, calls } = setup();
  await handler(request("POST", "/pin/set", { pin: "1234", pinConfirm: "1234" }));
  assertEquals(calls[0]?.fn, "set_pin");
  assertEquals(calls[0]?.args.p_pin_hmac, "hmac(1234)");
  assertFalse(JSON.stringify(calls).includes('"1234"'));
});

Deno.test("wrong PIN maps to pin_incorrect with attempts remaining", async () => {
  const { handler } = setup({
    data: { ok: false, code: "pin_incorrect", attemptsRemaining: 3 },
    error: null,
  });
  const response = await handler(request("POST", "/pin/verify", { pin: "0000" }));
  const body = await response.json();
  assertEquals(response.status, 403);
  assertEquals(body.error.code, "pin_incorrect");
  assertEquals(body.error.details.attemptsRemaining, 3);
});

Deno.test("database error codes pass through with details", async () => {
  const { handler } = setup({
    data: null,
    error: { message: "rate_limited", details: '{"retryAfterSeconds":60}' },
  });
  const response = await handler(request("POST", "/pin/reset/request", {}));
  const body = await response.json();
  assertEquals(response.status, 429);
  assertEquals(body.error.code, "rate_limited");
  assertEquals(body.error.details.retryAfterSeconds, 60);
});

Deno.test("unexpected database errors become internal_error without internals", async () => {
  const { handler } = setup({
    data: null,
    error: { message: 'relation "identity.x" does not exist' },
  });
  const response = await handler(request("GET", "/state"));
  const text = await response.text();
  assertEquals(response.status, 500);
  assertFalse(text.includes("identity.x"));
});

Deno.test("reset request emails the link after recording the request", async () => {
  const { handler, resets, calls } = setup({ data: { expiresAt: "x" }, error: null });
  const response = await handler(request("POST", "/pin/reset/request", {}));
  assertEquals(response.status, 200);
  assertEquals(calls[0]?.fn, "request_pin_reset");
  assertEquals(resets, [actor.userId]);
});

Deno.test("session revoke needs exactly one of sessionId or allOthers", async () => {
  const { handler } = setup();
  assertEquals((await handler(request("POST", "/sessions/revoke", {}))).status, 400);
  assertEquals(
    (await handler(
      request("POST", "/sessions/revoke", { allOthers: true, sessionId: actor.sessionId }),
    )).status,
    400,
  );
  assertEquals(
    (await handler(request("POST", "/sessions/revoke", { allOthers: true }))).status,
    200,
  );
});

Deno.test("status change validates UID, status, reason and idempotency key", async () => {
  const { handler, calls } = setup();
  const ok = {
    targetUid: "ew-48213",
    status: "suspended",
    reason: "Fraud review",
    idempotencyKey: "key-0000000000000001",
  };
  assertEquals((await handler(request("POST", "/admin/accounts/status", ok))).status, 200);
  assertEquals(calls[0]?.args.p_target_uid, "EW-48213");
  for (
    const bad of [{ ...ok, status: "closed" }, { ...ok, reason: " " }, {
      ...ok,
      idempotencyKey: "short",
    }, { ...ok, targetUid: "48213" }]
  ) {
    assertEquals((await handler(request("POST", "/admin/accounts/status", bad))).status, 400);
  }
});

Deno.test("logs carry no PIN, token or user identifiers", async () => {
  const { handler, logs } = setup();
  await handler(request("POST", "/pin/verify", { pin: "4321" }));
  const logged = JSON.stringify(logs);
  for (const secret of ["4321", "good", actor.userId, actor.sessionId]) {
    assertFalse(logged.includes(secret));
  }
});

Deno.test("CORS only for allowed origins; unknown routes are not_found", async () => {
  const { handler } = setup();
  const allowed = await handler(
    new Request("http://localhost/functions/v1/security/state", {
      method: "OPTIONS",
      headers: { origin: "https://app.elivatewallet.com" },
    }),
  );
  assertEquals(allowed.headers.get("access-control-allow-origin"), "https://app.elivatewallet.com");
  const other = await handler(
    new Request("http://localhost/functions/v1/security/state", {
      method: "OPTIONS",
      headers: { origin: "https://evil.example" },
    }),
  );
  assertEquals(other.headers.get("access-control-allow-origin"), null);
  assertEquals((await handler(request("GET", "/nope"))).status, 404);
});

Deno.test("PIN HMAC is deterministic per key and differs across keys", async () => {
  const a = await createPinHasher("11".repeat(32));
  const b = await createPinHasher("22".repeat(32));
  assertEquals(await a("1234"), await a("1234"));
  assertFalse((await a("1234")) === (await b("1234")));
  assertEquals((await a("1234")).length, 64);
});
