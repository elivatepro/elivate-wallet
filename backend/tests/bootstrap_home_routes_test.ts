// Blueprint 20 — B5: GET /security/bootstrap, GET /ledger/home and the own
// money reads by workspace (X-Membership instead of a tenant id).
import { assertEquals } from "@std/assert";
import {
  createHandler as createSecurity,
  type RpcResult,
} from "../supabase/functions/security/handler.ts";
import { createHandler as createLedger } from "../supabase/functions/ledger/handler.ts";

const actor = {
  userId: "00000000-0000-0000-0000-0000000000a1",
  sessionId: "00000000-0000-0000-0000-00000000a0a1",
};
const membershipId = "00000000-0000-0000-0000-0000000000b1";

const boot = {
  state: { gate: "ready" },
  profile: { uid: "EW-1", hasPhoto: false },
  workspace: { membershipId },
  capabilities: { membershipId, permissions: [] },
  brand: null,
};
const home = { network: null, activity: [], split: null };

function security(result: RpcResult = { data: boot, error: null }) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const handler = createSecurity({
    verifyToken: (token) => Promise.resolve(token === "good" ? actor : null),
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve(result);
    },
    pinHmac: (pin) => Promise.resolve(`hmac(${pin})`),
    sendResetLink: () => Promise.resolve(),
    log: () => {},
    allowedOrigins: [],
  });
  return { handler, calls };
}

function ledger(result: RpcResult = { data: home, error: null }) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const handler = createLedger({
    verifyToken: (token) => Promise.resolve(token === "good" ? actor : null),
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve(result);
    },
    signUpload: () => Promise.resolve(null),
    download: () => Promise.resolve(null),
    signDownload: () => Promise.resolve(null),
    openAccount: () => Promise.resolve(""),
    log: () => {},
    allowedOrigins: [],
  });
  return { handler, calls };
}

function request(fn: string, path: string, headers: Record<string, string> = {}): Request {
  return new Request(`http://localhost/functions/v1/${fn}${path}`, {
    method: "GET",
    headers: { authorization: "Bearer good", ...headers },
  });
}

async function code(response: Response): Promise<string> {
  return (await response.json()).error.code;
}

Deno.test("bootstrap: one call, the workspace header optional", async () => {
  const { handler, calls } = security();
  const without = await handler(request("security", "/bootstrap"));
  assertEquals(without.status, 200);
  assertEquals((await without.json()).data, boot);
  assertEquals(calls[0], {
    fn: "app_bootstrap",
    args: { p_user_id: actor.userId, p_session_id: actor.sessionId, p_membership_id: null },
  });
  const upper = membershipId.toUpperCase();
  await handler(request("security", "/bootstrap", { "x-membership": upper }));
  assertEquals(calls[1]?.args.p_membership_id, membershipId);
  assertEquals(calls.length, 2);
});

Deno.test("bootstrap: bad input is refused before the database", async () => {
  const { handler, calls } = security();
  assertEquals(
    await code(await handler(request("security", "/bootstrap", { "x-membership": "nope" }))),
    "workspace_invalid",
  );
  const query = await handler(request("security", "/bootstrap?membership=x"));
  assertEquals(query.status, 400);
  assertEquals((await query.json()).error.details, {
    field: "membership",
    reason: "unknown_field",
  });
  const anonymous = await handler(
    new Request("http://localhost/functions/v1/security/bootstrap", { method: "GET" }),
  );
  assertEquals(await code(anonymous), "authentication_required");
  assertEquals(calls.length, 0);
});

Deno.test("bootstrap: database errors keep their codes; odd output is an internal error", async () => {
  const failing = security({ data: null, error: { message: "workspace_invalid", details: "{}" } });
  assertEquals(
    await code(
      await failing.handler(request("security", "/bootstrap", { "x-membership": membershipId })),
    ),
    "workspace_invalid",
  );
  for (
    const data of [
      { ...boot, profile: { ...boot.profile, photoKey: "photos/x.jpg" } },
      { ...boot, extra: 1 },
      { ...boot, state: null },
      { ...boot, workspace: [] },
    ]
  ) {
    const odd = security({ data, error: null });
    assertEquals(
      await code(await odd.handler(request("security", "/bootstrap"))),
      "internal_error",
    );
  }
});

Deno.test("home: needs the workspace, takes no query, checks the shape", async () => {
  const { handler, calls } = ledger();
  assertEquals(await code(await handler(request("ledger", "/home"))), "workspace_invalid");
  const query = await handler(request("ledger", "/home?limit=5", { "x-membership": membershipId }));
  assertEquals(query.status, 400);
  assertEquals(calls.length, 0);
  const ok = await handler(request("ledger", "/home", { "x-membership": membershipId }));
  assertEquals(ok.status, 200);
  assertEquals((await ok.json()).data, home);
  assertEquals(calls[0], {
    fn: "home_view",
    args: { p_user_id: actor.userId, p_session_id: actor.sessionId, p_membership_id: membershipId },
  });
  const odd = ledger({ data: { network: null, activity: null, split: null }, error: null });
  assertEquals(
    await code(await odd.handler(request("ledger", "/home", { "x-membership": membershipId }))),
    "internal_error",
  );
});

Deno.test("own wallet and activity may name the workspace instead of a tenant", async () => {
  const { handler, calls } = ledger({ data: { items: [] }, error: null });
  await handler(request("ledger", "/me/wallet", { "x-membership": membershipId }));
  assertEquals(calls[0]?.args, {
    p_user_id: actor.userId,
    p_session_id: actor.sessionId,
    p_membership_id: membershipId,
  });
  await handler(request("ledger", "/me/activity?limit=5", { "x-membership": membershipId }));
  assertEquals(calls[1]?.args.p_membership_id, membershipId);
  assertEquals(calls[1]?.args.p_tenant_id, null);
  await handler(request("ledger", "/me/activity"));
  assertEquals("p_membership_id" in (calls[2]?.args ?? {}), false);
  const bad = await handler(request("ledger", "/me/wallet", { "x-membership": "nope" }));
  assertEquals(await code(bad), "workspace_invalid");
  assertEquals(calls.length, 3);
});
