import { assert, assertEquals } from "@std/assert";
import { fakeNinProvider, type NinRecord } from "../supabase/functions/_shared/nin_provider.ts";
import {
  type Actor,
  createHandler,
  type LogEntry,
  type RpcResult,
} from "../supabase/functions/identity/handler.ts";

const actor: Actor = {
  userId: "00000000-0000-0000-0000-0000000000a1",
  sessionId: "00000000-0000-0000-0000-00000000a0a1",
};
const membershipId = "00000000-0000-0000-0000-0000000000b1";
const reviewId = "00000000-0000-0000-0000-0000000000c1";
const NIN = "12345678901";
const record: NinRecord = { givenName: "Ada", middleNames: [], surname: "Obi", phone: null };
const ok = (data: unknown): RpcResult => ({ data, error: null });
const fail = (message: string, details: unknown = {}): RpcResult => ({
  data: null,
  error: { message, details: JSON.stringify(details) },
});

type Responder = (fn: string, args: Record<string, unknown>) => RpcResult;

const defaultDb: Responder = (fn, args) => {
  switch (fn) {
    case "prepare_nin_check":
      return ok({ ready: true });
    case "record_nin_check":
      return ok(
        args.p_outcome === "verified"
          ? { status: "verified", identity: { status: "verified" } }
          : { status: "not_verified", checksRemaining: 1 },
      );
    case "my_profile":
      return ok({ uid: "EW-12345", photoKey: "photos/x/y.webp", rank: null });
    default:
      return ok({ ok: true });
  }
};

function setup(db: Responder = defaultDb, provider = fakeNinProvider({ [NIN]: record })) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const logs: LogEntry[] = [];
  const handler = createHandler({
    verifyToken: (token) => Promise.resolve(token === "good" ? actor : null),
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve(db(fn, args));
    },
    log: (entry) => logs.push(entry),
    allowedOrigins: [],
    provider,
    fingerprint: (nin) => Promise.resolve(nin.replace(/./g, "f").padEnd(64, "f")),
  });
  const request = (
    method: string,
    path: string,
    body?: unknown,
    headers: Record<string, string> = {},
  ) =>
    handler(
      new Request(`http://local/functions/v1/identity${path}`, {
        method,
        headers: { authorization: "Bearer good", ...headers },
        body: body === undefined ? null : JSON.stringify(body),
      }),
    );
  return { request, calls, logs, provider };
}

async function json(response: Response) {
  return await response.json() as {
    ok: boolean;
    data?: unknown;
    error?: { code: string; details: unknown };
  };
}

Deno.test("requires a session", async () => {
  const { request } = setup();
  const response = await request("GET", "/profile", undefined, { authorization: "Bearer bad" });
  assertEquals(response.status, 401);
});

Deno.test("profile hides the storage key", async () => {
  const { request } = setup();
  const body = await json(await request("GET", "/profile"));
  assertEquals(body.data, { uid: "EW-12345", rank: null, hasPhoto: true });
});

Deno.test("verify: fingerprint + last 4 only reach the database; found → verified", async () => {
  const { request, calls, logs } = setup();
  const body = await json(await request("POST", "/nin/verify", { nin: "123 4567 8901" }));
  assertEquals(body.ok, true);
  for (const call of calls) {
    assert(!JSON.stringify(call.args).includes(NIN), `${call.fn} saw the NIN`);
  }
  assertEquals(calls[1]?.args.p_last4, "8901");
  assertEquals(calls[1]?.args.p_given, "Ada");
  assert(!JSON.stringify(logs).includes(NIN));
});

Deno.test("verify: not found maps to nin_not_verified with checks left", async () => {
  const { request } = setup(defaultDb, fakeNinProvider({}));
  const response = await request("POST", "/nin/verify", { nin: NIN });
  assertEquals(response.status, 422);
  const body = await json(response);
  assertEquals(body.error?.code, "nin_not_verified");
  assertEquals(body.error?.details, { checksRemaining: 1 });
});

Deno.test("verify: provider outage records nothing", async () => {
  const { request, calls } = setup(defaultDb, fakeNinProvider({ [NIN]: "unavailable" }));
  const response = await request("POST", "/nin/verify", { nin: NIN });
  assertEquals(response.status, 503);
  assertEquals(calls.map((c) => c.fn), ["prepare_nin_check"]);
});

Deno.test("verify: blocked NIN never calls the provider", async () => {
  const db: Responder = (fn, args) =>
    fn === "prepare_nin_check" ? ok({ ready: false, blocked: "nin_in_use" }) : defaultDb(fn, args);
  const { request, provider } = setup(db);
  const body = await json(await request("POST", "/nin/verify", { nin: NIN }));
  assertEquals(body.error?.code, "nin_in_use");
  assertEquals(provider.calls.length, 0);
});

Deno.test("verify: review-required passes through; bad NIN refused locally", async () => {
  const db: Responder = (fn, args) =>
    fn === "prepare_nin_check" ? fail("nin_review_required") : defaultDb(fn, args);
  assertEquals(
    (await json(await setup(db).request("POST", "/nin/verify", { nin: NIN }))).error?.code,
    "nin_review_required",
  );
  const local = setup();
  assertEquals(
    (await json(await local.request("POST", "/nin/verify", { nin: 12345678901 }))).error?.code,
    "validation_error",
  );
  assertEquals(local.calls.length, 0);
});

Deno.test("review request needs X-Membership and sends the typed name", async () => {
  const { request, calls } = setup();
  const missing = await request("POST", "/nin/review", {
    nin: NIN,
    givenName: "Ada",
    surname: "Obi",
    idempotencyKey: "key-0000000000000001",
  });
  assertEquals((await json(missing)).error?.code, "workspace_invalid");
  await request("POST", "/nin/review", {
    nin: NIN,
    givenName: "Ada",
    middleNames: ["N"],
    surname: "Obi",
    idempotencyKey: "key-0000000000000001",
  }, { "x-membership": membershipId });
  assertEquals(calls[0]?.fn, "request_nin_review");
  assertEquals(calls[0]?.args.p_middle, ["N"]);
  assertEquals(calls[0]?.args.p_membership_id, membershipId);
});

Deno.test("decide: workspace route and admin route", async () => {
  const { request, calls } = setup();
  await request("POST", `/nin/reviews/${reviewId}/decide`, {
    decision: "approve",
    reason: "Checked",
    idempotencyKey: "key-0000000000000002",
  }, { "x-membership": membershipId });
  await request("POST", `/admin/nin/reviews/${reviewId}/decide`, {
    decision: "reject",
    reason: "Unreadable",
    idempotencyKey: "key-0000000000000003",
  });
  assertEquals(calls.map((c) => [c.fn, c.args.p_membership_id]), [
    ["decide_nin_review", membershipId],
    ["decide_nin_review", null],
  ]);
  const bad = await request("POST", `/admin/nin/reviews/${reviewId}/decide`, {
    decision: "maybe",
    reason: "x x x",
    idempotencyKey: "key-0000000000000004",
  });
  assertEquals((await json(bad)).error?.code, "validation_error");
});

Deno.test("photo key must be well formed", async () => {
  const { request } = setup();
  const bad = await request("POST", "/profile/photo", { photoKey: "../etc/passwd" });
  assertEquals((await json(bad)).error?.code, "validation_error");
});

// Blueprint 22: the light setup names the person.
Deno.test("profile: first and last name pass through, checked for length", async () => {
  const { request, calls } = setup();
  const saved = await request("PATCH", "/profile", {
    firstName: "Bola",
    lastName: "Ige",
    rank: "Diamond Director",
    idempotencyKey: "key-0000000000000001",
  });
  assertEquals(saved.status, 200);
  assertEquals(calls[0]?.fn, "update_profile");
  assertEquals(calls[0]?.args.p_changes, {
    firstName: "Bola",
    lastName: "Ige",
    rank: "Diamond Director",
  });
  const tooLong = await request("PATCH", "/profile", {
    firstName: "x".repeat(81),
    idempotencyKey: "key-0000000000000002",
  });
  assertEquals(tooLong.status, 400);
  assertEquals((await json(tooLong)).error?.details, { field: "firstName" });
  assertEquals(calls.length, 1);
});

Deno.test("profile: a locked name and the setup gate map to the envelope", async () => {
  const locked = setup((fn) =>
    fn === "update_profile" ? fail("conflict", { reason: "name_locked" }) : ok({})
  );
  const refused = await locked.request("PATCH", "/profile", {
    lastName: "Other",
    idempotencyKey: "key-0000000000000003",
  });
  assertEquals(refused.status, 409);
  assertEquals((await json(refused)).error?.details, { reason: "name_locked" });

  const gated = setup((fn) =>
    fn === "nin_reviews" ? fail("profile_required", { step: "profile", level: "light" }) : ok({})
  );
  const blocked = await gated.request("GET", "/nin/reviews", undefined, {
    "x-membership": membershipId,
  });
  assertEquals(blocked.status, 403);
  assertEquals((await json(blocked)).error?.code, "profile_required");
});
