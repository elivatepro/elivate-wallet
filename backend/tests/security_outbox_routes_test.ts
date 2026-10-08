// Blueprint 03: admin dead-letter routes on the `security` function.
import { assertEquals } from "@std/assert";
import {
  type Actor,
  createHandler,
  type Deps,
  type RpcResult,
} from "../supabase/functions/security/handler.ts";

const actor: Actor = {
  userId: "00000000-0000-0000-0000-0000000000a1",
  sessionId: "00000000-0000-0000-0000-00000000a0a1",
};
const eventId = "00000000-0000-0000-0000-0000000000f1";
const key = "key-0000000000000001";

function setup(rpcResult: RpcResult = { data: [], error: null }) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const deps: Deps = {
    verifyToken: (token) => Promise.resolve(token === "good" ? actor : null),
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve(rpcResult);
    },
    pinHmac: (pin) => Promise.resolve(`hmac(${pin})`),
    sendResetLink: () => Promise.resolve(),
    log: () => {},
    allowedOrigins: [],
  };
  return { handler: createHandler(deps), calls };
}

function request(method: string, path: string, body?: unknown): Request {
  return new Request(`http://localhost/functions/v1/security${path}`, {
    method,
    headers: { authorization: "Bearer good", "content-type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

Deno.test("dead-letter list passes the limit and rejects unknown query fields", async () => {
  const { handler, calls } = setup();
  assertEquals((await handler(request("GET", "/admin/outbox?limit=20"))).status, 200);
  assertEquals(calls[0], {
    fn: "outbox_dead_letters",
    args: { p_user_id: actor.userId, p_session_id: actor.sessionId, p_limit: 20 },
  });
  assertEquals((await handler(request("GET", "/admin/outbox?to=x"))).status, 400);
  assertEquals((await handler(request("GET", "/admin/outbox?limit=abc"))).status, 400);
});

Deno.test("requeue takes the event id from the path with reason and key", async () => {
  const { handler, calls } = setup({ data: { status: "pending" }, error: null });
  const response = await handler(
    request("POST", `/admin/outbox/${eventId}/requeue`, {
      reason: "Sender fixed",
      idempotencyKey: key,
    }),
  );
  assertEquals(response.status, 200);
  assertEquals(calls[0]?.fn, "outbox_requeue");
  assertEquals(calls[0]?.args.p_event_id, eventId);
  assertEquals(calls[0]?.args.p_reason, "Sender fixed");
  const bad = await handler(
    request("POST", "/admin/outbox/not-a-uuid/requeue", { reason: "x", idempotencyKey: key }),
  );
  assertEquals(bad.status, 404);
});
