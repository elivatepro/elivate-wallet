import {
  objectBody,
  requiredString,
  sha256,
} from "../supabase/functions/_shared/workspace-requests.ts";
import { DomainError } from "../src/shared/domain_error.ts";

Deno.test("workspace request transport hashes entry tokens and reads strings", async () => {
  const body = objectBody({ membershipId: " membership " });
  if (requiredString(body, "membershipId") !== "membership") {
    throw new Error("string was not normalized");
  }
  if (
    await sha256("entry-token") !==
      "6542129571f4a727f1cfbd6f12e0d1fb63451b4526ea8f99abeb360360511e23"
  ) throw new Error("digest changed");
});
Deno.test("workspace request transport rejects missing values", () => {
  let rejected = false;
  try {
    requiredString({}, "tenantId");
  } catch (error) {
    rejected = error instanceof DomainError &&
      error.code === "validation_error";
  }
  if (!rejected) throw new Error("missing value accepted");
});
