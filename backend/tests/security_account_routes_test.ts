// Blueprint 14 — security routes for sign-ins, the overview and the
// signed-in password change (B2): validation, the verified actor, error
// mapping, and no PIN or IP in logs.
import { assertEquals, assertFalse } from "@std/assert";
import {
  type Actor,
  createHandler,
  type Deps,
  type LogEntry,
  type RpcResult,
} from "../supabase/functions/security/handler.ts";

const actor: Actor = {
  userId: "00000000-0000-0000-0000-000000140001",
  sessionId: "00000000-0000-0000-0000-0000001400a1",
};

const APP_SECRET = "app-server-secret-for-tests";

function setup(
  rpcResult: RpcResult = { data: { unusual: false }, error: null },
  appServerSecret: string | null = APP_SECRET,
) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const logs: LogEntry[] = [];
  const deps: Deps = {
    verifyToken: (token) => Promise.resolve(token === "good" ? actor : null),
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve(rpcResult);
    },
    pinHmac: (pin) => Promise.resolve(`hmac(${pin})`),
    sendResetLink: () => Promise.resolve(),
    log: (entry) => logs.push(entry),
    allowedOrigins: [],
    appServerSecret,
  };
  return { handler: createHandler(deps), calls, logs };
}

const post = (path: string, body: unknown, token = "good", secret: string | null = APP_SECRET) =>
  new Request(`http://localhost/functions/v1/security${path}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      ...(secret ? { "x-app-server-secret": secret } : {}),
    },
    body: JSON.stringify(body),
  });

const signIn = {
  method: "password",
  ip: "102.89.1.10",
  city: "Lagos",
  country: "NG",
  device: "Mac · Chrome",
  userAgent: "Mozilla/5.0 (Macintosh) Chrome/130",
};

Deno.test("record a sign-in: the verified session, every field, and no IP in the log", async () => {
  const { handler, calls, logs } = setup();
  const response = await handler(post("/sign-ins", signIn));
  assertEquals(response.status, 200);
  assertEquals((await response.json()).data, { unusual: false });
  assertEquals(calls[0]?.fn, "record_sign_in");
  assertEquals(calls[0]?.args.p_user_id, actor.userId);
  assertEquals(calls[0]?.args.p_session_id, actor.sessionId);
  assertEquals(calls[0]?.args.p_ip, "102.89.1.10");
  assertEquals(calls[0]?.args.p_country, "NG");
  assertEquals(calls[0]?.args.p_device, "Mac · Chrome");
  assertFalse(JSON.stringify(logs).includes("102.89"));
});

Deno.test("record a sign-in: location and IP are optional; IPv6 accepted; UA capped", async () => {
  const { handler, calls } = setup();
  const response = await handler(
    post("/sign-ins", {
      method: "email_link",
      ip: "2001:db8::1",
      city: null,
      device: "iPhone · Safari",
      userAgent: "x".repeat(900),
    }),
  );
  assertEquals(response.status, 200);
  assertEquals(calls[0]?.args.p_ip, "2001:db8::1");
  assertEquals(calls[0]?.args.p_city, null);
  assertEquals(calls[0]?.args.p_country, null);
  assertEquals((calls[0]?.args.p_user_agent as string).length, 300);
});

Deno.test("record a sign-in: bad input never reaches the database", async () => {
  const cases: [Record<string, unknown>, string][] = [
    [{ ...signIn, method: "magic" }, "method"],
    [{ ...signIn, ip: "999.1.1.1" }, "ip"],
    [{ ...signIn, ip: "10.0.0.0/8" }, "ip"],
    [{ ...signIn, ip: 42 }, "ip"],
    [{ ...signIn, country: "Nigeria" }, "country"],
    [{ ...signIn, city: "La\ngos" }, "city"],
    [{ ...signIn, city: "x".repeat(101) }, "city"],
    [{ ...signIn, device: "" }, "device"],
    [{ ...signIn, device: "x".repeat(61) }, "device"],
    [{ ...signIn, extra: true }, "extra"],
  ];
  for (const [body, field] of cases) {
    const { handler, calls } = setup();
    const response = await handler(post("/sign-ins", body));
    assertEquals(response.status, 400, field);
    assertEquals((await response.json()).error.details.field, field);
    assertEquals(calls.length, 0, field);
  }
});

Deno.test("routes need a valid token", async () => {
  for (const path of ["/sign-ins", "/password/authorize", "/password/changed"]) {
    const { handler, calls } = setup();
    const response = await handler(post(path, {}, "bad"));
    assertEquals(response.status, 401, path);
    assertEquals(calls.length, 0);
  }
});

Deno.test("overview reads for the verified session", async () => {
  const { handler, calls } = setup({
    data: { passwordChangedAt: null, unusualSignIns: [] },
    error: null,
  });
  const response = await handler(
    new Request("http://localhost/functions/v1/security/overview", {
      headers: { authorization: "Bearer good" },
    }),
  );
  assertEquals(response.status, 200);
  assertEquals(calls[0]?.fn, "security_overview");
  assertEquals(calls[0]?.args, { p_user_id: actor.userId, p_session_id: actor.sessionId });
});

Deno.test("authorize a password change: PIN as HMAC only, change id back", async () => {
  const id = "0b6d2a52-1d0c-4c55-9a3e-6f5f1c2e9a10";
  const { handler, calls, logs } = setup({ data: { ok: true, changeId: id }, error: null });
  const response = await handler(post("/password/authorize", { pin: "4821" }));
  assertEquals(response.status, 200);
  assertEquals((await response.json()).data, { changeId: id });
  assertEquals(calls[0]?.fn, "authorize_password_change");
  assertEquals(calls[0]?.args.p_pin_hmac, "hmac(4821)");
  assertFalse(JSON.stringify(logs).includes("4821"));
});

Deno.test("authorize a password change: wrong and locked PINs map like verify", async () => {
  const wrong = setup({
    data: { ok: false, code: "pin_incorrect", attemptsRemaining: 3 },
    error: null,
  });
  const r1 = await wrong.handler(post("/password/authorize", { pin: "0000" }));
  assertEquals(r1.status, 403);
  assertEquals((await r1.json()).error.details, { attemptsRemaining: 3 });
  const locked = setup({
    data: { ok: false, code: "pin_locked", attemptsRemaining: 0 },
    error: null,
  });
  const r2 = await locked.handler(post("/password/authorize", { pin: "0000" }));
  assertEquals(r2.status, 423);
  const raw = setup();
  const r3 = await raw.handler(post("/password/authorize", { pin: "12345", password: "x" }));
  assertEquals(r3.status, 400);
  assertEquals(raw.calls.length, 0);
});

Deno.test("record a password change: exactly one of changeId or recovery", async () => {
  const id = "0b6d2a52-1d0c-4c55-9a3e-6f5f1c2e9a10";
  const ok = setup({ data: { changedAt: "2026-10-09T10:00:00Z" }, error: null });
  assertEquals((await ok.handler(post("/password/changed", { changeId: id }))).status, 200);
  assertEquals(ok.calls[0]?.args.p_change_id, id);
  assertEquals(ok.calls[0]?.args.p_recovery, false);
  const rec = setup({ data: { changedAt: "2026-10-09T10:00:00Z" }, error: null });
  assertEquals((await rec.handler(post("/password/changed", { recovery: true }))).status, 200);
  assertEquals(rec.calls[0]?.args.p_change_id, null);
  assertEquals(rec.calls[0]?.args.p_recovery, true);
  for (
    const body of [{}, { changeId: id, recovery: true }, { recovery: false }, { changeId: "x" }]
  ) {
    const bad = setup();
    const response = await bad.handler(post("/password/changed", body));
    assertEquals(response.status, 400, JSON.stringify(body));
    assertEquals(bad.calls.length, 0);
  }
});

Deno.test("record a password change: database conflicts keep their reason", async () => {
  const { handler } = setup({
    data: null,
    error: {
      message: "conflict",
      details: JSON.stringify({ reason: "password_change_not_authorized" }),
    },
  });
  const response = await handler(post("/password/changed", { recovery: true }));
  assertEquals(response.status, 409);
  assertEquals((await response.json()).error.details.reason, "password_change_not_authorized");
});

Deno.test("record a sign-in: only the app server may write one (shared secret)", async () => {
  for (
    const [secret, configured] of [
      [null, APP_SECRET],
      ["wrong-secret", APP_SECRET],
      [APP_SECRET, null],
    ] as const
  ) {
    const { handler, calls } = setup(undefined, configured);
    const response = await handler(post("/sign-ins", signIn, "good", secret));
    assertEquals(response.status, 403);
    assertEquals((await response.json()).error.details, { reason: "app_server_only" });
    assertEquals(calls.length, 0);
  }
});
