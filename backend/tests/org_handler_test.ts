import { assertEquals } from "@std/assert";
import {
  type Actor,
  createHandler,
  type Deps,
  type LogEntry,
  type RpcResult,
} from "../supabase/functions/org/handler.ts";

const actor: Actor = {
  userId: "00000000-0000-0000-0000-0000000000a1",
  sessionId: "00000000-0000-0000-0000-00000000a0a1",
};
const membershipId = "00000000-0000-0000-0000-0000000000b1";
const officeId = "00000000-0000-0000-0000-0000000000c1";
const key = "key-0000000000000001";

function setup(rpcResult: RpcResult = { data: { ok: true }, error: null }) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const logs: LogEntry[] = [];
  const deps: Deps = {
    verifyToken: (token) => Promise.resolve(token === "good" ? actor : null),
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve(rpcResult);
    },
    log: (entry) => logs.push(entry),
    allowedOrigins: ["https://app.elivatewallet.com"],
  };
  return { handler: createHandler(deps), calls, logs };
}

function request(
  method: string,
  path: string,
  body?: unknown,
  headers: Record<string, string> = { "x-membership": membershipId },
): Request {
  return new Request(`http://localhost/functions/v1/org${path}`, {
    method,
    headers: { authorization: "Bearer good", "content-type": "application/json", ...headers },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

Deno.test("actor and workspace come from the token and header, never the body", async () => {
  const { handler, calls } = setup();
  const response = await handler(
    request("POST", "/memberships", { officeId, memberUid: "ew-48213", idempotencyKey: key }),
  );
  assertEquals(response.status, 200);
  assertEquals(calls[0]?.fn, "add_membership");
  assertEquals(calls[0]?.args.p_user_id, actor.userId);
  assertEquals(calls[0]?.args.p_session_id, actor.sessionId);
  assertEquals(calls[0]?.args.p_membership_id, membershipId);
  assertEquals(calls[0]?.args.p_member_uid, "EW-48213");
});

Deno.test("workspace header is required and must be a UUID", async () => {
  const { handler, calls } = setup();
  for (const headers of [{}, { "x-membership": "not-a-uuid" }]) {
    const response = await handler(request("GET", "/offices", undefined, headers));
    assertEquals(response.status, 403);
    assertEquals((await response.json()).error.code, "workspace_invalid");
  }
  assertEquals(calls.length, 0);
});

Deno.test("routes without a workspace do not need the header", async () => {
  const { handler, calls } = setup({ data: [], error: null });
  const response = await handler(request("GET", "/workspaces", undefined, {}));
  assertEquals(response.status, 200);
  assertEquals(calls[0]?.fn, "my_workspaces");
});

Deno.test("path ids must be UUIDs", async () => {
  const { handler, calls } = setup();
  const response = await handler(
    request("POST", "/memberships/123/end", { reason: "Left", idempotencyKey: key }),
  );
  assertEquals(response.status, 404);
  assertEquals(calls.length, 0);
});

Deno.test("path params reach the command", async () => {
  const { handler, calls } = setup();
  await handler(
    request("POST", `/offices/${officeId.toUpperCase()}/place`, {
      parentOfficeId: null,
      reason: "Top level",
      idempotencyKey: key,
    }),
  );
  assertEquals(calls[0]?.fn, "place_office");
  assertEquals(calls[0]?.args.p_office_id, officeId);
  assertEquals(calls[0]?.args.p_parent_office_id, null);
});

Deno.test("unknown body and query fields are rejected", async () => {
  const { handler, calls } = setup();
  const body = await handler(
    request("POST", "/memberships", {
      officeId,
      memberUid: "EW-48213",
      idempotencyKey: key,
      tenantId: officeId,
    }),
  );
  assertEquals(body.status, 400);
  assertEquals((await body.json()).error.details.field, "tenantId");
  const query = await handler(request("GET", "/offices?tenantId=x"));
  assertEquals(query.status, 400);
  assertEquals(calls.length, 0);
});

Deno.test("leader UIDs, roles and access rules are shape-checked", async () => {
  const { handler, calls } = setup();
  const bad = [
    request("POST", "/offices", {
      type: "team_leader",
      name: "Team",
      leaderUids: [],
      idempotencyKey: key,
    }),
    request("POST", "/offices", {
      type: "president",
      name: "Team",
      leaderUids: ["EW-48213"],
      idempotencyKey: key,
    }),
    request("PUT", "/role-permissions", {
      role: "admin",
      permission: "record_income",
      allowed: true,
      reason: "Test",
      idempotencyKey: key,
    }),
    request("POST", "/access", {
      subjectUid: "EW-48213",
      rules: [{ permission: "record_income", effect: "maybe", scopeType: "tenant" }],
      reason: "Test",
      idempotencyKey: key,
    }),
    request("POST", "/access", {
      subjectUid: "EW-48213",
      rules: [{ permission: "record_income", effect: "allow", scopeType: "tenant", extra: 1 }],
      reason: "Test",
      idempotencyKey: key,
    }),
  ];
  for (const r of bad) assertEquals((await handler(r)).status, 400);
  assertEquals(calls.length, 0);
});

Deno.test("database error codes map to the envelope", async () => {
  const { handler } = setup({
    data: null,
    error: { message: "last_leader", details: null },
  });
  const response = await handler(
    request("POST", `/memberships/${membershipId}/end`, { reason: "Left", idempotencyKey: key }),
  );
  assertEquals(response.status, 409);
  const json = await response.json();
  assertEquals(json.ok, false);
  assertEquals(json.error.code, "last_leader");
});

Deno.test("unexpected database results are internal errors", async () => {
  const { handler } = setup({ data: null, error: null });
  const response = await handler(request("GET", "/capabilities"));
  assertEquals(response.status, 500);
  assertEquals((await response.json()).error.code, "internal_error");
});

Deno.test("logs carry the route pattern, never ids", async () => {
  const { handler, logs } = setup();
  await handler(
    request("POST", `/memberships/${membershipId}/end`, { reason: "Left", idempotencyKey: key }),
  );
  assertEquals(logs[0]?.route, "POST /memberships/:id/end");
  assertEquals(JSON.stringify(logs).includes(membershipId), false);
  assertEquals(JSON.stringify(logs).includes(actor.userId), false);
});
