// Blueprint 10 — POST /security/pin/change (B7 items 7–9).
import { assertEquals, assertFalse } from "@std/assert";
import {
  type Actor,
  createHandler,
  type Deps,
  type LogEntry,
  type RpcResult,
} from "../supabase/functions/security/handler.ts";

const actor: Actor = {
  userId: "00000000-0000-0000-0000-000000010001",
  sessionId: "00000000-0000-0000-0000-0000000100a1",
};

const readyState = {
  gate: "ready",
  uid: "EW-12345",
  accountStatus: "active",
  attemptsRemaining: 5,
  stepUpExpiresAt: null,
};

function setup(rpcResult: RpcResult = { data: { ok: true, state: readyState }, error: null }) {
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
  };
  return { handler: createHandler(deps), calls, logs };
}

const change = (body: unknown, token = "good") =>
  new Request("http://localhost/functions/v1/security/pin/change", {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });

Deno.test("change PIN sends both HMACs and the verified actor, never raw PINs", async () => {
  const { handler, calls, logs } = setup();
  const response = await handler(
    change({ currentPin: "1234", pin: "5678", pinConfirm: "5678" }),
  );
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.data.gate, "ready");
  assertEquals(calls[0]?.fn, "change_pin");
  assertEquals(calls[0]?.args.p_user_id, actor.userId);
  assertEquals(calls[0]?.args.p_session_id, actor.sessionId);
  assertEquals(calls[0]?.args.p_current_pin_hmac, "hmac(1234)");
  assertEquals(calls[0]?.args.p_new_pin_hmac, "hmac(5678)");
  const logged = JSON.stringify(logs);
  assertFalse(logged.includes("1234"));
  assertFalse(logged.includes("5678"));
});

Deno.test("change PIN validates before calling the database", async () => {
  const cases: [unknown, string, string | undefined][] = [
    [{ currentPin: "12a4", pin: "5678", pinConfirm: "5678" }, "currentPin", undefined],
    [{ currentPin: "1234", pin: "567", pinConfirm: "567" }, "pin", undefined],
    [{ currentPin: "1234", pin: "5678", pinConfirm: "5679" }, "pinConfirm", "mismatch"],
    [{ currentPin: "1234", pin: "1234", pinConfirm: "1234" }, "pin", "same_pin"],
    [{ currentPin: "1234", pin: "5678", pinConfirm: "5678", extra: 1 }, "extra", "unknown_field"],
  ];
  for (const [body, field, reason] of cases) {
    const { handler, calls } = setup();
    const response = await handler(change(body));
    assertEquals(response.status, 400);
    const error = (await response.json()).error;
    assertEquals(error.code, "validation_error");
    assertEquals(error.details.field, field);
    assertEquals(error.details.reason, reason);
    assertEquals(calls.length, 0);
  }
});

Deno.test("wrong current PIN maps to pin_incorrect / pin_locked with attempts", async () => {
  const wrong = setup({
    data: { ok: false, code: "pin_incorrect", attemptsRemaining: 3 },
    error: null,
  });
  const first = await wrong.handler(
    change({ currentPin: "1111", pin: "5678", pinConfirm: "5678" }),
  );
  assertEquals(first.status, 403);
  const firstError = (await first.json()).error;
  assertEquals(firstError.code, "pin_incorrect");
  assertEquals(firstError.details.attemptsRemaining, 3);

  const locked = setup({
    data: { ok: false, code: "pin_locked", attemptsRemaining: 0 },
    error: null,
  });
  const second = await locked.handler(
    change({ currentPin: "1111", pin: "5678", pinConfirm: "5678" }),
  );
  assertEquals(second.status, 423);
  assertEquals((await second.json()).error.code, "pin_locked");
});

Deno.test("change PIN needs a valid token", async () => {
  const { handler, calls } = setup();
  const response = await handler(
    change({ currentPin: "1234", pin: "5678", pinConfirm: "5678" }, "bad"),
  );
  assertEquals(response.status, 401);
  assertEquals(calls.length, 0);
});
