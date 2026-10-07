import { DomainError } from "../src/shared/domain_error.ts";
import {
  handlePayoutVerificationRetry,
  parsePayoutVerificationRetry,
} from "../supabase/functions/_shared/payout-verification-retry.ts";
function assert(value: unknown): asserts value {
  if (!value) throw new Error("Assertion failed");
}
const actor = "99000000-0000-4000-8000-000000000001";
const membership = "99000000-0000-4000-8000-000000000002";
const assertion = "99000000-0000-4000-8000-000000000003";
const session = "99000000-0000-4000-8000-000000000004";
const key = "99000000-0000-4000-8000-000000000005";
const job = "99000000-0000-4000-8000-000000000006";
const input = {
  membershipId: membership,
  payoutAssertionId: assertion,
  idempotencyKey: key,
};
const request = (body: unknown = input) =>
  new Request("https://example.test/retry-payout-verification", {
    method: "POST",
    body: JSON.stringify(body),
  });
Deno.test("verification retry accepts frozen selectors only and rejects caller authority or revision", () => {
  assert(parsePayoutVerificationRetry(input).p_idempotency_key === key);
  for (
    const body of [
      null,
      [],
      { ...input, actorUserId: actor },
      { ...input, sessionId: session },
      { ...input, tenantId: actor },
      { ...input, revisionId: key },
      { ...input, jobId: job },
      { ...input, payoutAssertionId: "bad" },
      { ...input, idempotencyKey: null },
    ]
  ) {
    let rejected = false;
    try {
      parsePayoutVerificationRetry(body);
    } catch {
      rejected = true;
    }
    assert(rejected);
  }
});
Deno.test("verification retry forwards derived identity/session and retains exact target/key", async () => {
  const actual = request();
  let calls = 0;
  const response = await handlePayoutVerificationRetry(actual, (received) => {
    assert(received === actual);
    return Promise.resolve({
      userId: actor,
      stepUpSessionId: session,
      client: {
        schema: (schema) => {
          assert(schema === "command_api");
          return {
            rpc: (name, args) => {
              calls++;
              assert(name === "retry_payout_verification");
              assert(
                args.p_actor_user_id === actor &&
                  args.p_session_id === session &&
                  args.p_actor_membership_id === membership &&
                  args.p_assertion_id === assertion &&
                  args.p_idempotency_key === key &&
                  Object.keys(args).length === 5,
              );
              return Promise.resolve({
                data: {
                  jobId: job,
                  payoutAssertionId: assertion,
                  status: "queued",
                  reused: true,
                  secret: "must-not-leak",
                },
                error: null,
              });
            },
          };
        },
      },
    });
  });
  const text = await response.text();
  const body = JSON.parse(text);
  assert(response.status === 200 && calls === 1);
  assert(
    response.headers.get("Cache-Control") === "no-store" &&
      body.data.payoutAssertionId === assertion && body.data.reused === true &&
      !text.includes("must-not-leak"),
  );
});
Deno.test("verification retry rejects wrong target and malformed committed results as unknown server failures", async () => {
  for (
    const data of [
      null,
      { jobId: job, payoutAssertionId: actor, status: "queued", reused: true },
      {
        jobId: "bad",
        payoutAssertionId: assertion,
        status: "queued",
        reused: true,
      },
      {
        jobId: job,
        payoutAssertionId: assertion,
        status: "completed",
        reused: true,
      },
      {
        jobId: job,
        payoutAssertionId: assertion,
        status: "queued",
        reused: "yes",
      },
    ]
  ) {
    const response = await handlePayoutVerificationRetry(
      request(),
      () =>
        Promise.resolve({
          userId: actor,
          stepUpSessionId: session,
          client: {
            schema: () => ({
              rpc: () => Promise.resolve({ data, error: null }),
            }),
          },
        }),
    );
    assert(response.status === 500);
    assert(response.headers.get("Cache-Control") === "no-store");
  }
});
Deno.test("retry preserves step-up versus denial and never invokes RPC without verified authentication", async () => {
  for (
    const [sql, code] of [["P0401", "step_up_required"], [
      "42501",
      "authorization_denied",
    ]] as const
  ) {
    const response = await handlePayoutVerificationRetry(
      request(),
      () =>
        Promise.resolve({
          userId: actor,
          stepUpSessionId: null,
          client: {
            schema: () => ({
              rpc: () => Promise.resolve({ data: null, error: { code: sql } }),
            }),
          },
        }),
    );
    assert(
      response.status === 403 && (await response.json()).error.code === code,
    );
  }
  let authCalls = 0;
  const bad = await handlePayoutVerificationRetry(
    request({ ...input, actorUserId: actor }),
    () => {
      authCalls++;
      throw new Error("Invalid body must not dispatch");
    },
  );
  assert(bad.status === 400 && authCalls === 0);
  const unauthenticated = await handlePayoutVerificationRetry(request(), () => {
    throw new DomainError("authentication_required", "Sign in");
  });
  assert(unauthenticated.status === 401);
  const preflight = await handlePayoutVerificationRetry(
    new Request("https://example.test", { method: "OPTIONS" }),
    () => {
      throw new Error("No preflight authentication");
    },
  );
  assert(preflight.status === 204);
});
