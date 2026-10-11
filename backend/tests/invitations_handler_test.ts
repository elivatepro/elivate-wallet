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
const serverSecret = "app-server-secret-value";
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
    sendSignInLink: (email, page) => {
      signIns.push(page === "join" ? email : `${page}:${email}`);
      return Promise.resolve();
    },
    log: (entry) => logs.push(entry),
    allowedOrigins: ["https://app.elivatewallet.com"],
    appServerSecret: serverSecret,
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
    p_replaces_membership_id: null,
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

// ── Founder entry (Blueprint 19) ──

const application = {
  fullName: "Adaeze Okafor",
  email: " Adaeze@Example.test ",
  phone: "0803 555 0142",
  teamName: "Harmony Builders",
  rank: "ruby_director_4",
};

Deno.test("founder application: only the Wallet server may send it", async () => {
  for (const headers of [{}, { "x-app-server-secret": "wrong" }]) {
    const { handler, calls } = setup();
    const response = await handler(request("POST", "/founder-applications", application, headers));
    assertEquals(response.status, 403);
    assertEquals(calls.length, 0);
  }
});

Deno.test("founder application: no session, cleaned email, always the same reply", async () => {
  const { handler, calls } = setup({ data: { received: true }, error: null });
  const response = await handler(
    request("POST", "/founder-applications", application, { "x-app-server-secret": serverSecret }),
  );
  assertEquals(response.status, 200);
  assertEquals((await response.json()).data, { received: true });
  assertEquals(calls[0]?.fn, "submit_founder_application");
  assertEquals(calls[0]?.args, {
    p_full_name: "Adaeze Okafor",
    p_email: "adaeze@example.test",
    p_phone: "0803 555 0142",
    p_team_name: "Harmony Builders",
    p_rank: "ruby_director_4",
  });
});

Deno.test("founder application: unknown rank or field is refused before the database", async () => {
  for (
    const body of [
      { ...application, rank: "ruby_director_3" },
      { ...application, proof: "x" },
      { ...application, phone: "1" },
    ]
  ) {
    const { handler, calls } = setup();
    const response = await handler(
      request("POST", "/founder-applications", body, { "x-app-server-secret": serverSecret }),
    );
    assertEquals(response.status, 400);
    assertEquals(calls.length, 0);
  }
});

Deno.test("founder link: preview and verify are public; the email lands on /founder", async () => {
  const preview = setup({ data: { email: "a@example.test", teamName: "Harmony" }, error: null });
  const shown = await preview.handler(request("POST", "/founder/preview", { token }, {}));
  assertEquals(shown.status, 200);
  assertEquals((await shown.json()).data, { email: "a@example.test", teamName: "Harmony" });
  assertEquals(preview.calls[0]?.args, { p_token_digest: await tokenDigest(token) });

  const verify = setup({ data: { email: "a@example.test" }, error: null });
  const sent = await verify.handler(request("POST", "/founder/verify-email", { token }, {}));
  assertEquals(sent.status, 200);
  assertEquals(verify.calls[0]?.fn, "request_founder_verification");
  assertEquals(verify.signIns, ["founder:a@example.test"]);
});

Deno.test("founder link: accepting needs a session and sends only the digest", async () => {
  const anonymous = setup();
  const refused = await anonymous.handler(
    request("POST", "/founder/accept", { token, idempotencyKey: key }, {}),
  );
  assertEquals(refused.status, 401);
  assertEquals(anonymous.calls.length, 0);

  const { handler, calls } = setup();
  const response = await handler(
    request("POST", "/founder/accept", { token, idempotencyKey: key }),
  );
  assertEquals(response.status, 200);
  assertEquals(calls[0]?.fn, "accept_founder_invitation");
  assertEquals(calls[0]?.args.p_token_digest, await tokenDigest(token));
  assertEquals(calls[0]?.args.p_user_id, actor.userId);
  assert(!JSON.stringify(calls[0]?.args).includes(token));
});

// Blueprint 27: a leader invitation that replaces a current leader on accept.
Deno.test("create: carries the leader it replaces", async () => {
  const { handler, calls } = setup();
  const replaces = "00000000-0000-0000-0000-0000000000f1";
  const response = await handler(
    request("POST", "", {
      officeId,
      role: "team_leader",
      email: "next@example.test",
      reason: "Handover",
      replacesMembershipId: replaces,
      idempotencyKey: key,
    }),
  );
  assertEquals(response.status, 200);
  assertEquals(calls[0]?.args.p_replaces_membership_id, replaces);
  const bad = await handler(
    request("POST", "", {
      officeId,
      role: "team_leader",
      email: "next@example.test",
      reason: "Handover",
      replacesMembershipId: "nope",
      idempotencyKey: key,
    }),
  );
  assertEquals(bad.status, 400);
  assertEquals(calls.length, 1);
});

// Blueprint 27: a new office whose leader is invited by email.
Deno.test("create office inviting its leader: a server-made link, no reason from the client", async () => {
  const { handler, calls } = setup();
  const response = await handler(
    request("POST", "/office", {
      type: "team_leader",
      name: "Team C",
      parentOfficeId: officeId,
      email: " Lead@Example.test ",
      idempotencyKey: key,
    }),
  );
  assertEquals(response.status, 200);
  assertEquals(calls[0]?.fn, "create_office_inviting_leader");
  assertEquals(calls[0]?.args, {
    p_user_id: actor.userId,
    p_session_id: actor.sessionId,
    p_membership_id: membershipId,
    p_request_id: calls[0]?.args.p_request_id,
    p_type: "team_leader",
    p_name: "Team C",
    p_parent_office_id: officeId,
    p_email: "lead@example.test",
    p_idempotency_key: key,
    p_token_id: issued.tokenId,
    p_token_digest: issued.digest,
  });
  for (
    const body of [
      { type: "team_leader", name: "Team C", email: "a@b.co", idempotencyKey: key, reason: "x" },
      { type: "boss", name: "Team C", email: "a@b.co", idempotencyKey: key },
      { type: "team_leader", name: "Team C", email: "not-an-email", idempotencyKey: key },
    ]
  ) {
    assertEquals((await handler(request("POST", "/office", body))).status, 400);
  }
  assertEquals(calls.length, 1);
});
