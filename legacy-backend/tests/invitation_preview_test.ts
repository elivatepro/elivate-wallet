import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { handleInvitationPreview } from "../supabase/functions/invitation-preview/handler.ts";
import { invitationTokenDigest } from "../supabase/functions/_shared/invitation.ts";
const token = "A".repeat(43);
const request = (body: unknown) =>
  new Request("https://example.test/preview", {
    method: "POST",
    body: JSON.stringify(body),
    headers: { "x-request-id": "preview-test" },
  });
Deno.test("anonymous preview passes only exact token digest and emits only email", async () => {
  const response = await handleInvitationPreview(
    request({
      token,
      tenantId: "untrusted",
      role: "president_team_member",
      email: "fake@example.test",
    }),
    async (digest) => {
      assertEquals(digest, await invitationTokenDigest(token));
      return {
        data: {
          email: "invited@example.test",
          tenantId: "private",
          token_digest: "private",
        },
        error: null,
      };
    },
  );
  assertEquals(response.status, 200);
  assertEquals(await response.json(), {
    ok: true,
    requestId: "preview-test",
    data: { email: "invited@example.test" },
  });
  assertEquals(response.headers.get("cache-control"), "no-store");
});
Deno.test("missing malformed oversize tokens deny without lookup", async () => {
  for (
    const body of [null, [], {}, { token: "" }, { token: 42 }, {
      token: "x".repeat(513),
    }, { token: " ".repeat(16) }]
  ) {
    const response = await handleInvitationPreview(request(body), () => {
      throw new Error("No lookup");
    });
    assertEquals(response.status, 404);
    const data = await response.json();
    assertEquals(data.error.code, "not_found");
    assertEquals(data.error.message, "This invitation is unavailable");
  }
  const oversized = await handleInvitationPreview(
    new Request("https://example.test", {
      method: "POST",
      body: JSON.stringify({ token, extra: "x".repeat(2049) }),
    }),
    () => {
      throw new Error("No lookup");
    },
  );
  assertEquals(oversized.status, 404);
  const response = await handleInvitationPreview(
    new Request("https://example.test", { method: "POST", body: "{" }),
    () => {
      throw new Error("No lookup");
    },
  );
  assertEquals(response.status, 404);
});
Deno.test("unavailable SQL states share uniform safe response", async () => {
  const response = await handleInvitationPreview(
    request({ token }),
    () => Promise.resolve({ data: null, error: null }),
  );
  assertEquals(response.status, 404);
  assertEquals(
    (await response.json()).error.message,
    "This invitation is unavailable",
  );
});
Deno.test("database errors malformed output never reveal private details", async () => {
  for (
    const result of [{ data: null, error: { message: token } }, {
      data: {},
      error: null,
    }, { data: { email: 42 }, error: null }]
  ) {
    const response = await handleInvitationPreview(
      request({ token }),
      () => Promise.resolve(result),
    );
    assertEquals(response.status, 500);
    const payload = await response.json();
    assertEquals(payload.error.code, "internal_error");
    assertEquals(JSON.stringify(payload).includes(token), false);
  }
});
Deno.test("preview POST preflight and method denial skip lookup", async () => {
  for (const method of ["GET", "OPTIONS"]) {
    const response = await handleInvitationPreview(
      new Request("https://example.test", { method }),
      () => {
        throw new Error("No lookup");
      },
    );
    assertEquals(response.status, method === "GET" ? 400 : 204);
    assertEquals(
      response.headers.get("access-control-allow-methods"),
      "POST, OPTIONS",
    );
    assertEquals(response.headers.get("cache-control"), "no-store");
  }
});
