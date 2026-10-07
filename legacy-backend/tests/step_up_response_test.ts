import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { mapDatabaseError } from "../supabase/functions/_shared/financial.ts";
import { failureResponse } from "../supabase/functions/_shared/http.ts";

Deno.test("expired verification remains actionable without exposing database diagnostics", async () => {
  const error = mapDatabaseError({ code: "P0401" });
  const response = failureResponse(
    new Request("https://example.test"),
    "test-request",
    error,
  );
  assertEquals(response.status, 403);
  const body = await response.json();
  assertEquals(body.error.code, "step_up_required");
  assertEquals(body.error.message, "Verify this device before continuing");
  assertEquals(body.error.details, {});
  assertEquals(body.requestId, "test-request");
  assertEquals(
    mapDatabaseError({ code: "42501" }).code,
    "authorization_denied",
  );
});
