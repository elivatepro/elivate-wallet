import { assertEquals } from "@std/assert";
import { fakeNinProvider } from "../supabase/functions/_shared/nin_provider.ts";
import {
  type Actor,
  createHandler,
  type RpcResult,
} from "../supabase/functions/identity/handler.ts";

const actor: Actor = {
  userId: "00000000-0000-0000-0000-0000000000a1",
  sessionId: "00000000-0000-0000-0000-00000000a0a1",
};
const membershipId = "00000000-0000-0000-0000-0000000000b1";
const itemId = "00000000-0000-0000-0000-0000000000C1";

function setup() {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const handler = createHandler({
    verifyToken: (token) => Promise.resolve(token === "good" ? actor : null),
    rpc: (fn, args): Promise<RpcResult> => {
      calls.push({ fn, args });
      return Promise.resolve({ data: { actions: [], items: [], unread: 0 }, error: null });
    },
    log: () => {},
    allowedOrigins: [],
    provider: fakeNinProvider({}),
    fingerprint: () => Promise.resolve("f".repeat(64)),
  });
  const request = (method: string, path: string, body?: unknown, workspace = true) =>
    handler(
      new Request(`http://local/functions/v1/identity${path}`, {
        method,
        headers: {
          authorization: "Bearer good",
          ...(workspace ? { "x-membership": membershipId } : {}),
        },
        body: body === undefined ? null : JSON.stringify(body),
      }),
    );
  return { request, calls };
}

const code = async (response: Response) =>
  ((await response.json()) as { error?: { code: string; details: { field?: string } } }).error;

Deno.test("bell list passes view, cursor and limit in the workspace", async () => {
  const { request, calls } = setup();
  assertEquals(
    (await request("GET", "/notifications?view=unread&limit=20&cursor=eyJzIjoiMSJ9")).status,
    200,
  );
  assertEquals(calls[0], {
    fn: "my_notifications",
    args: {
      p_user_id: actor.userId,
      p_session_id: actor.sessionId,
      p_membership_id: membershipId,
      p_view: "unread",
      p_cursor: "eyJzIjoiMSJ9",
      p_limit: 20,
    },
  });
  assertEquals((await request("GET", "/notifications")).status, 200);
  assertEquals(calls[1]?.args.p_view, "all");
  assertEquals(calls[1]?.args.p_limit, null);
});

Deno.test("bell list rejects unknown views, limits, cursors and fields", async () => {
  const { request, calls } = setup();
  for (
    const [query, field] of [
      ["view=new", "view"],
      ["limit=0", "limit"],
      ["limit=101", "limit"],
      ["cursor=%3Cscript%3E", "cursor"],
      ["userId=x", "userId"],
    ]
  ) {
    const error = await code(await request("GET", `/notifications?${query}`));
    assertEquals([error?.code, error?.details.field], ["validation_error", field], query);
  }
  assertEquals(calls.length, 0);
});

Deno.test("badge count and mark read need the workspace", async () => {
  const { request } = setup();
  assertEquals(
    (await code(await request("GET", "/notifications/unread", undefined, false)))?.code,
    "workspace_invalid",
  );
  assertEquals(
    (await code(await request("POST", "/notifications/read", { all: true }, false)))?.code,
    "workspace_invalid",
  );
});

Deno.test("mark read takes ids or all, never both", async () => {
  const { request, calls } = setup();
  assertEquals((await request("POST", "/notifications/read", { ids: [itemId] })).status, 200);
  assertEquals(calls[0]?.args.p_ids, [itemId.toLowerCase()]);
  assertEquals(calls[0]?.args.p_all, false);
  assertEquals((await request("POST", "/notifications/read", { all: true })).status, 200);
  assertEquals([calls[1]?.args.p_ids, calls[1]?.args.p_all], [null, true]);
  for (
    const body of [
      {},
      { ids: [], all: false },
      { ids: [itemId], all: true },
      { ids: ["nope"] },
      { ids: Array.from({ length: 101 }, () => itemId) },
      { all: "yes" },
      { all: true, userId: actor.userId },
    ]
  ) {
    assertEquals(
      (await code(await request("POST", "/notifications/read", body)))?.code,
      "validation_error",
      JSON.stringify(body).slice(0, 40),
    );
  }
  assertEquals(calls.length, 2);
});

Deno.test("bell routes need a signed-in caller", async () => {
  const { calls } = setup();
  const handler = createHandler({
    verifyToken: () => Promise.resolve(null),
    rpc: () => Promise.resolve({ data: null, error: null }),
    log: () => {},
    allowedOrigins: [],
    provider: null,
    fingerprint: () => Promise.resolve(""),
  });
  const response = await handler(new Request("http://local/functions/v1/identity/notifications"));
  assertEquals(response.status, 401);
  assertEquals(calls.length, 0);
});
