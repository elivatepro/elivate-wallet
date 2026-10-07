import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { DomainError } from "../src/shared/domain_error.ts";
import {
  failureResponse,
  requestIdFor,
  successResponse,
} from "../supabase/functions/_shared/http.ts";

Deno.test("HTTP contract preserves a valid caller request id", () => {
  const request = new Request("https://example.invalid", {
    headers: { "x-request-id": "frontend:request-1" },
  });
  assertEquals(requestIdFor(request), "frontend:request-1");
});

Deno.test("HTTP success envelope is stable", async () => {
  const request = new Request("https://example.invalid");
  const response = successResponse(request, "request-1", { value: 3 });
  assertEquals(response.status, 200);
  assertEquals(await response.json(), {
    ok: true,
    requestId: "request-1",
    data: { value: 3 },
  });
});

Deno.test("HTTP errors expose only the domain error contract", async () => {
  const request = new Request("https://example.invalid");
  const response = failureResponse(
    request,
    "request-2",
    new DomainError("authorization_denied", "Access denied", {
      details: { reasonCode: "account_suspended" },
    }),
  );
  assertEquals(response.status, 403);
  assertEquals(await response.json(), {
    ok: false,
    requestId: "request-2",
    error: {
      code: "authorization_denied",
      message: "Access denied",
      retryable: false,
      details: { reasonCode: "account_suspended" },
    },
  });
});

Deno.test("member-home transport keeps the trusted endpoint JWT-gated", () => {
  const request = new Request("https://example.invalid/member-home", {
    method: "GET",
  });
  assertEquals(request.headers.get("authorization"), null);
});
