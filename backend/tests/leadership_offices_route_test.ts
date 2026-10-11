// Blueprint 25 — B3: GET /ledger/overview/offices ("Offices this month").
import { assertEquals } from "@std/assert";
import { createHandler, type RpcResult } from "../supabase/functions/ledger/handler.ts";

const actor = {
  userId: "00000000-0000-0000-0000-0000000000a1",
  sessionId: "00000000-0000-0000-0000-00000000a0a1",
};
const membershipId = "00000000-0000-0000-0000-0000000000b1";

const view = {
  scope: { kind: "network", officeId: null, name: "Lagos Network" },
  period: { month: "2026-10", timeZone: "Africa/Lagos" },
  currencies: ["NGN", "USD"],
  offices: [{
    officeId: "00000000-0000-0000-0000-0000000000c1",
    name: "Team A",
    kind: "team_leader",
    parentOfficeId: null,
    status: "active",
    members: 2,
    income: [{ currency: "NGN", amount: "1000.00" }, {
      currency: "USD",
      amount: "0.00",
    }],
    excludedMembers: 0,
  }],
  excluded: { offices: 0, members: 0 },
};

function ledger(result: RpcResult = { data: view, error: null }) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const handler = createHandler({
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

function request(path: string, headers: Record<string, string> = {}): Request {
  return new Request(`http://localhost/functions/v1/ledger${path}`, {
    method: "GET",
    headers: { authorization: "Bearer good", ...headers },
  });
}

async function code(response: Response): Promise<string> {
  return (await response.json()).error.code;
}

Deno.test("offices this month: one call in the workspace", async () => {
  const { handler, calls } = ledger();
  const response = await handler(
    request("/overview/offices", {
      "x-membership": membershipId.toUpperCase(),
    }),
  );
  assertEquals(response.status, 200);
  assertEquals((await response.json()).data, view);
  assertEquals(calls, [{
    fn: "leadership_offices",
    args: {
      p_user_id: actor.userId,
      p_session_id: actor.sessionId,
      p_membership_id: membershipId,
    },
  }]);
});

Deno.test("offices this month: bad input is refused before the database", async () => {
  const { handler, calls } = ledger();
  assertEquals(
    await code(await handler(request("/overview/offices"))),
    "workspace_invalid",
  );
  assertEquals(
    await code(
      await handler(request("/overview/offices", { "x-membership": "nope" })),
    ),
    "workspace_invalid",
  );
  // The month is the network's own; the browser's time zone is not an input.
  const tz = await handler(
    request("/overview/offices?tz=UTC", { "x-membership": membershipId }),
  );
  assertEquals(tz.status, 400);
  assertEquals((await tz.json()).error.details, {
    field: "tz",
    reason: "unknown_field",
  });
  const anonymous = await handler(
    new Request("http://localhost/functions/v1/ledger/overview/offices", {
      method: "GET",
      headers: { "x-membership": membershipId },
    }),
  );
  assertEquals(await code(anonymous), "authentication_required");
  assertEquals(calls.length, 0);
});

Deno.test("offices this month: database errors keep their codes; odd output is internal", async () => {
  const denied = ledger({
    data: null,
    error: { message: "authorization_denied", details: "{}" },
  });
  const refused = await denied.handler(
    request("/overview/offices", { "x-membership": membershipId }),
  );
  assertEquals(refused.status, 403);
  assertEquals(await code(refused), "authorization_denied");
  for (
    const data of [
      { ...view, offices: null },
      { ...view, currencies: "NGN" },
      { ...view, excluded: null },
      [],
    ]
  ) {
    const odd = ledger({ data, error: null });
    const response = await odd.handler(
      request("/overview/offices", { "x-membership": membershipId }),
    );
    assertEquals(response.status, 500);
    assertEquals(await code(response), "internal_error");
  }
});
