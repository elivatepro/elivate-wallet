import { parseLeadershipOverviewQuery } from "../supabase/functions/_shared/leadership-overview.ts";
import { DomainError } from "../src/shared/domain_error.ts";
const id = "81000000-0000-4000-8000-000000000001";
Deno.test("leadership overview accepts only the selected membership selector", () => {
  if (
    parseLeadershipOverviewQuery(new URLSearchParams({ membershipId: id })) !==
      id
  ) throw new Error("selector changed");
});
Deno.test("leadership overview rejects duplicate selectors and client identity or tenant authority", () => {
  for (
    const query of [
      "",
      "membershipId=bad",
      `membershipId=${id}&membershipId=${id}`,
      `membershipId=${id}&tenantId=${id}`,
      `membershipId=${id}&actorUserId=${id}`,
      `membershipId=${id}&limit=5`,
    ]
  ) {
    let rejected = false;
    try {
      parseLeadershipOverviewQuery(new URLSearchParams(query));
    } catch (error) {
      rejected = error instanceof DomainError &&
        error.code === "validation_error";
    }
    if (!rejected) throw new Error(`Accepted unsafe query: ${query}`);
  }
});
