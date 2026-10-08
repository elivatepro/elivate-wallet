import { assert, assertEquals } from "@std/assert";
import {
  type Actor,
  createHandler,
  type Deps,
  type LogEntry,
  type RpcResult,
} from "../supabase/functions/invitations/handler.ts";
import { tokenDigest } from "../supabase/functions/_shared/invite_token.ts";

const actor: Actor = {
  userId: "00000000-0000-0000-0000-0000000000a1",
  sessionId: "00000000-0000-0000-0000-00000000a0a1",
};
const membershipId = "00000000-0000-0000-0000-0000000000b1";
const officeId = "00000000-0000-0000-0000-0000000000c1";
const invitationId = "00000000-0000-0000-0000-0000000000d1";
const key = "key-0000000000000001";
const token = "A".repeat(43);
const issued = { tokenId: "00000000-0000-0000-0000-0000000000e1", digest: "f".repeat(64) };

function setup(rpcResult: RpcResult = { data: { ok: true }, error: null }) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const logs: LogEntry[] = [];
  const signIns: string[] = [];
  const deps: Deps = {
    verifyToken: (bearer) => Promise.resolve(bearer === "good" ? actor : null),
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve(rpcResult);
    },
    issueToken: () => Promise.resolve(issued),
    sendSignInLink: (email) => {
      signIns.push(email);
      return Promise.resolve();
    },
    log: (entry) => logs.push(entry),
    allowedOrigins: ["https://app.elivatewallet.com"],
  };
  return { handler: createHandler(deps), calls, logs, signIns };
}

function request(
  method: string,
  path: string,
  body?: unknown,
  headers: Record<string, string> = { authorization: "Bearer good", "x-membership": membershipId },
): Request {
  return new Request(`http://localhost/functions/v1/invitations${path}`, {
    method,
    headers: { "content-type": "application/json", ...headers },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

Deno.test("create: actor from the token, workspace from the header, server-made link", async () => {
  const { handler, calls } = setup();
  const response = await handler(
    request("POST", "", {
      officeId,
      role: "member",
      email: " New@Example.test ",
      idempotencyKey: key,
    }),
  );
  assertEquals(response.status, 200);
  assertEquals(calls[0]?.fn, "create_invitation");
  assertEquals(calls[0]?.args, {
    p_user_id: actor.userId,
    p_session_id: actor.sessionId,
    p_membership_id: membershipId,
    p_request_id: calls[0]?.args.p_request_id,
    p_office_id: officeId,
    p_role: "member",
    p_email: "new@example.test",
    p_reason: null,
    p_idempotency_key: key,
    p_token_id: issued.tokenId,
    p_token_digest: issued.digest,
  });
});

Deno.test("create: unknown fields and bad values are rejected before the database", async () => {
  const { handler, calls } = setup();
  for (
    const body of [
      { officeId, role: "member", email: "a@b.co", idempotencyKey: key, token: "x" },
      { officeId, role: "boss", email: "a@b.co", idempotencyKey: key },
      { officeId, role: "member", email: "not-an-email", idempotencyKey: key },
      { officeId: "1", role: "member", email: "a@b.co", idempotencyKey: key },
      { officeId, role: "member", email: "a@b.co", idempotencyKey: "short" },
      { officeId, role: "member", email: "a@b.co", reason: "x".repeat(501), idempotencyKey: key },
    ]
  ) {
    const response = await handler(request("POST", "", body));
    assertEquals(response.status, 400);
    assertEquals((await response.json()).error.code, "validation_error");
  }
  assertEquals(calls.length, 0);
});

Deno.test("leader routes need a session and a workspace", async () => {
  const { handler, calls } = setup();
  const noSession = await handler(request("GET", "", undefined, { "x-membership": membershipId }));
  assertEquals(noSession.status, 401);
  const noWorkspace = await handler(
    request("GET", "", undefined, { authorization: "Bearer good" }),
  );
  assertEquals((await noWorkspace.json()).error.code, "workspace_invalid");
  const badBearer = await handler(
    request("POST", `/${invitationId}/revoke`, { reason: "Wrong", idempotencyKey: key }, {
      authorization: "Bearer bad",
      "x-membership": membershipId,
    }),
  );
  assertEquals(badBearer.status, 401);
  assertEquals(calls.length, 0);
});

Deno.test("reissue and revoke route the invitation id from the path", async () => {
  const { handler, calls } = setup();
  await handler(request("POST", `/${invitationId}/reissue`, { idempotencyKey: key }));
  await handler(
    request("POST", `/${invitationId}/revoke`, { reason: "Wrong", idempotencyKey: key }),
  );
  assertEquals(calls[0]?.fn, "reissue_invitation");
  assertEquals(calls[0]?.args.p_invitation_id, invitationId);
  assertEquals(calls[0]?.args.p_token_digest, issued.digest);
  assertEquals(calls[1]?.fn, "revoke_invitation");
  assertEquals(calls[1]?.args.p_reason, "Wrong");
  const bad = await handler(request("POST", "/123/revoke", { reason: "x", idempotencyKey: key }));
  assertEquals(bad.status, 404);
});

Deno.test("preview works without a session and sends only the digest", async () => {
  const { handler, calls } = setup({ data: { email: "new@example.test" }, error: null });
  const response = await handler(request("POST", "/preview", { token }, {}));
  assertEquals(response.status, 200);
  assertEquals((await response.json()).data, { email: "new@example.test" });
  assertEquals(calls[0]?.args, { p_token_digest: await tokenDigest(token) });
});

Deno.test("verify-email never takes an email field and never echoes the email", async () => {
  const { handler, calls, signIns } = setup({ data: { email: "new@example.test" }, error: null });
  const rejected = await handler(
    request("POST", "/verify-email", { token, email: "attacker@example.test" }, {}),
  );
  assertEquals(rejected.status, 400);
  assertEquals(calls.length, 0);

  const response = await handler(request("POST", "/verify-email", { token }, {}));
  assertEquals(response.status, 200);
  assertEquals((await response.json()).data, { sent: true });
  assertEquals(signIns, ["new@example.test"]);
});

Deno.test("malformed tokens are rejected", async () => {
  const { handler, calls } = setup();
  for (const bad of ["", "short", "A".repeat(44), "A".repeat(42) + "!"]) {
    const response = await handler(request("POST", "/preview", { token: bad }, {}));
    assertEquals(response.status, 400);
  }
  assertEquals(calls.length, 0);
});

Deno.test("accept takes exactly one of token or invitation id", async () => {
  const { handler, calls } = setup();
  const both = await handler(
    request("POST", "/accept", { token, invitationId, idempotencyKey: key }, {
      authorization: "Bearer good",
    }),
  );
  assertEquals(both.status, 400);
  const neither = await handler(
    request("POST", "/accept", { idempotencyKey: key }, { authorization: "Bearer good" }),
  );
  assertEquals(neither.status, 400);
  const anonymous = await handler(request("POST", "/accept", { token, idempotencyKey: key }, {}));
  assertEquals(anonymous.status, 401);
  assertEquals(calls.length, 0);

  await handler(
    request("POST", "/accept", { token, idempotencyKey: key }, { authorization: "Bearer good" }),
  );
  assertEquals(calls[0]?.args.p_token_digest, await tokenDigest(token));
  assertEquals(calls[0]?.args.p_invitation_id, null);
  await handler(
    request("POST", "/accept", { invitationId, idempotencyKey: key }, {
      authorization: "Bearer good",
    }),
  );
  assertEquals(calls[1]?.args.p_token_digest, null);
  assertEquals(calls[1]?.args.p_invitation_id, invitationId);
});

Deno.test("database errors map to the envelope; unknown ones become internal_error", async () => {
  const unavailable = setup({ data: null, error: { message: "invitation_unavailable" } });
  const gone = await unavailable.handler(request("POST", "/preview", { token }, {}));
  assertEquals(gone.status, 410);
  assertEquals((await gone.json()).error.code, "invitation_unavailable");

  const broken = setup({ data: null, error: { message: "relation does not exist" } });
  const response = await broken.handler(request("GET", "/mine", undefined, {
    authorization: "Bearer good",
  }));
  assertEquals(response.status, 500);
  assertEquals((await response.json()).error.code, "internal_error");
});

Deno.test("logs carry no token, digest or email", async () => {
  const { handler, logs } = setup({ data: { email: "new@example.test" }, error: null });
  await handler(request("POST", "/verify-email", { token }, {}));
  const text = JSON.stringify(logs);
  assert(!text.includes(token));
  assert(!text.includes(await tokenDigest(token)));
  assert(!text.includes("new@example.test"));
  assertEquals(logs[0]?.route, "POST /verify-email");
});
