import { DomainError } from "../src/shared/domain_error.ts";
import {
  handlePayoutDestination,
  parsePayoutDestination,
} from "../supabase/functions/_shared/payout-destination.ts";
function assert(value: unknown): asserts value {
  if (!value) throw new Error("Assertion failed");
}
const actor = "99000000-0000-4000-8000-000000000001";
const membership = "99000000-0000-4000-8000-000000000002";
const withdrawal = "99000000-0000-4000-8000-000000000003";
const session = "99000000-0000-4000-8000-000000000004";
const input = { membershipId: membership, withdrawalId: withdrawal };
Deno.test("execution destination accepts selectors only, never caller security context", () => {
  assert(parsePayoutDestination(input).p_actor_membership_id === membership);
  for (
    const body of [
      null,
      [],
      { ...input, actorUserId: actor },
      { ...input, sessionId: session },
      { ...input, tenantId: actor },
      { ...input, officeId: actor },
      { ...input, accountReference: "sensitive" },
      { ...input, withdrawalId: "bad" },
    ]
  ) {
    let denied = false;
    try {
      parsePayoutDestination(body);
    } catch {
      denied = true;
    }
    assert(denied);
  }
});
Deno.test("destination request authenticates exact request and forwards only derived actor/session", async () => {
  const request = new Request("https://example.test/payout-destination", {
    method: "POST",
    body: JSON.stringify(input),
  });
  let calls = 0;
  const data = {
    withdrawal_id: withdrawal,
    destination: { account_reference: "0123456789" },
  };
  const response = await handlePayoutDestination(request, (actual) => {
    assert(actual === request);
    return Promise.resolve({
      userId: actor,
      stepUpSessionId: session,
      client: {
        schema: (schema) => {
          assert(schema === "command_api");
          return {
            rpc: (name, args) => {
              calls++;
              assert(name === "payout_destination");
              assert(
                args.p_actor_user_id === actor && args.p_session_id === session,
              );
              assert(
                args.p_actor_membership_id === membership &&
                  args.p_withdrawal_id === withdrawal &&
                  Object.keys(args).length === 4,
              );
              return Promise.resolve({ data, error: null });
            },
          };
        },
      },
    });
  });
  assert(
    response.status === 200 &&
      response.headers.get("Cache-Control") === "no-store",
  );
  assert(
    (await response.json()).data.destination.account_reference ===
        "0123456789" && calls === 1,
  );
});
Deno.test("destination challenge and denial are no-store safe errors without raw details", async () => {
  for (
    const [sqlCode, code] of [["P0401", "step_up_required"], [
      "42501",
      "authorization_denied",
    ]] as const
  ) {
    const response = await handlePayoutDestination(
      new Request("https://example.test", {
        method: "POST",
        body: JSON.stringify(input),
      }),
      () =>
        Promise.resolve({
          userId: actor,
          stepUpSessionId: null,
          client: {
            schema: () => ({
              rpc: () =>
                Promise.resolve({ data: null, error: { code: sqlCode } }),
            }),
          },
        }),
    );
    const body = await response.json();
    assert(response.status === 403 && body.error.code === code);
    assert(
      response.headers.get("Cache-Control") === "no-store" &&
        !JSON.stringify(body).includes("0123456789"),
    );
  }
});
Deno.test("invalid or unauthenticated destination request cannot invoke a privileged command", async () => {
  let authentications = 0;
  const bad = await handlePayoutDestination(
    new Request("https://example.test", {
      method: "POST",
      body: JSON.stringify({ ...input, actorUserId: actor }),
    }),
    () => {
      authentications++;
      throw new Error("Must not authenticate invalid body");
    },
  );
  assert(
    bad.status === 400 && authentications === 0 &&
      bad.headers.get("Cache-Control") === "no-store",
  );
  const absent = await handlePayoutDestination(
    new Request("https://example.test", {
      method: "POST",
      body: JSON.stringify(input),
    }),
    () => {
      throw new DomainError("authentication_required", "Sign in");
    },
  );
  assert(
    absent.status === 401 && absent.headers.get("Cache-Control") === "no-store",
  );
  const options = await handlePayoutDestination(
    new Request("https://example.test", { method: "OPTIONS" }),
    () => {
      throw new Error("Must not authenticate preflight");
    },
  );
  assert(
    options.status === 204 &&
      options.headers.get("Cache-Control") === "no-store" &&
      options.headers.get("access-control-allow-methods") === "POST, OPTIONS",
  );
});
