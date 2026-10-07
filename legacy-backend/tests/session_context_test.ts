import {
  assertEquals,
  assertRejects,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { DomainError } from "../src/shared/domain_error.ts";
import {
  requireStepUpSession,
  verifySession,
} from "../supabase/functions/_shared/session.ts";
const actor = "00000000-0000-4000-8000-000000000001";
const session = "10000000-0000-4000-8000-000000000001";
const now = 1_790_000_000;
const claims = {
  sub: actor,
  aal: "aal2",
  session_id: session,
  role: "authenticated",
  aud: "authenticated",
  exp: now + 60,
};
function token(payload: unknown) {
  return `header.${
    btoa(JSON.stringify(payload)).replaceAll("+", "-").replaceAll("/", "_")
      .replace(/=+$/, "")
  }.signature`;
}
Deno.test("session context verifies the exact bearer before trusting its session", async () => {
  const bearer = token(claims);
  let seen = "";
  const result = await verifySession(bearer, (value) => {
    seen = value;
    return Promise.resolve(actor);
  }, now);
  assertEquals(seen, bearer);
  assertEquals(result, {
    userId: actor,
    sessionId: session,
    stepUpSessionId: session,
  });
});
Deno.test("a valid-looking payload cannot bypass failed Auth verification", async () => {
  await assertRejects(
    () => verifySession(token(claims), () => Promise.resolve(null), now),
    DomainError,
    "authenticated session",
  );
});
Deno.test("separate logins for one user keep independent session identities", async () => {
  const other = "10000000-0000-4000-8000-000000000002";
  const a = await verifySession(
    token(claims),
    () => Promise.resolve(actor),
    now,
  );
  const b = await verifySession(
    token({ ...claims, session_id: other }),
    () => Promise.resolve(actor),
    now,
  );
  assertEquals(a.sessionId, session);
  assertEquals(b.sessionId, other);
});
Deno.test("expired, missing, mismatched and privileged claims fail closed", async () => {
  for (
    const change of [
      { sub: "another-user" },
      { session_id: null },
      { session_id: "client-value" },
      { exp: now },
      { exp: "9999999999" },
      { role: "service_role" },
      { aud: "other" },
    ]
  ) {
    await assertRejects(
      () =>
        verifySession(
          token({ ...claims, ...change }),
          () => Promise.resolve(actor),
          now,
        ),
      DomainError,
    );
  }
});
Deno.test("malformed verified responses never expose raw bearer material", async () => {
  for (const bearer of ["secret-token", "a.@@@.b", token(null), token([])]) {
    const error = await assertRejects(
      () => verifySession(bearer, () => Promise.resolve(actor), now),
      DomainError,
    );
    assertEquals(error.message.includes(bearer), false);
  }
});
Deno.test("standard array audience claims retain the current authenticated session", async () => {
  assertEquals(
    await verifySession(
      token({ ...claims, aud: ["authenticated"] }),
      () => Promise.resolve(actor),
      now,
    ),
    { userId: actor, sessionId: session, stepUpSessionId: session },
  );
});

Deno.test("an older password-only bearer cannot consume an upgraded session window", async () => {
  const result = await verifySession(
    token({ ...claims, aal: "aal1" }),
    () => Promise.resolve(actor),
    now,
  );
  assertEquals(result.sessionId, session);
  assertEquals(result.stepUpSessionId, null);
});

Deno.test("mandatory verification reports step-up instead of malformed-input errors", () => {
  const error = assertThrows(() => requireStepUpSession(null), DomainError);
  assertEquals(error.code, "step_up_required");
  assertEquals(requireStepUpSession(session), session);
});
