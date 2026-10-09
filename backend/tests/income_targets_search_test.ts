// Blueprint 09 follow-up: GET /ledger/income/targets?q= (network-wide member
// search for Record income).
import { assertEquals } from "@std/assert";
import { type Actor, createHandler, type Deps } from "../supabase/functions/ledger/handler.ts";

const actor: Actor = {
  userId: "00000000-0000-0000-0000-0000000000a1",
  sessionId: "00000000-0000-0000-0000-00000000a0a1",
};
const membershipId = "00000000-0000-0000-0000-0000000000b1";

function setup() {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const deps: Deps = {
    verifyToken: (token) => Promise.resolve(token === "good" ? actor : null),
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve({ data: { items: [] }, error: null });
    },
    signUpload: () => Promise.resolve(null),
    download: () => Promise.resolve(null),
    signDownload: () => Promise.resolve(null),
    openAccount: () => Promise.reject(new Error("unused")),
    log: () => {},
    allowedOrigins: [],
  };
  return { handler: createHandler(deps), calls };
}

const get = (query: string) =>
  new Request(`http://localhost/functions/v1/ledger/income/targets${query}`, {
    headers: { authorization: "Bearer good", "x-membership": membershipId },
  });

Deno.test("income targets pass the search text to the database", async () => {
  const { handler, calls } = setup();
  const response = await handler(get("?q=Ada%20Nwosu&limit=20"));
  assertEquals(response.status, 200);
  assertEquals(calls[0]?.fn, "income_targets");
  assertEquals(calls[0]?.args.p_query, "Ada Nwosu");
  assertEquals(calls[0]?.args.p_limit, 20);
});

Deno.test("income targets without q search nothing", async () => {
  const { handler, calls } = setup();
  await handler(get(""));
  assertEquals(calls[0]?.args.p_query, null);
});

Deno.test("income target search text is bounded", async () => {
  const { handler, calls } = setup();
  for (const q of ["%20%20", "a".repeat(101)]) {
    const response = await handler(get(`?q=${q}`));
    assertEquals(response.status, 400);
  }
  assertEquals(calls.length, 0);
});
