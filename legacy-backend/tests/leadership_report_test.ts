import { parseLeadershipReportQuery } from "../supabase/functions/_shared/leadership-report.ts";
import { DomainError } from "../src/shared/domain_error.ts";
const id = "81000000-0000-4000-8000-000000000001";
Deno.test("leadership report accepts bounded period and optional currency", () => {
  const value = parseLeadershipReportQuery(
    new URLSearchParams({
      membershipId: id,
      from: "2026-09-01",
      to: "2026-09-30",
      currency: "NGN",
    }),
  );
  if (value.currency !== "NGN" || value.from !== "2026-09-01") {
    throw new Error("query changed");
  }
});
Deno.test("leadership report rejects authority, duplicate and invalid period input", () => {
  for (
    const query of [
      "",
      `membershipId=${id}&from=2026-10-02&to=2026-10-01`,
      `membershipId=${id}&from=2026-10-01&to=2026-10-02&tenantId=${id}`,
      `membershipId=${id}&membershipId=${id}&from=2026-10-01&to=2026-10-02`,
      `membershipId=${id}&from=bad&to=2026-10-02`,
      `membershipId=${id}&from=2026-10-01&to=2026-10-02&currency=ngn`,
    ]
  ) {
    let rejected = false;
    try {
      parseLeadershipReportQuery(new URLSearchParams(query));
    } catch (error) {
      rejected = error instanceof DomainError &&
        error.code === "validation_error";
    }
    if (!rejected) throw new Error(`Accepted unsafe query: ${query}`);
  }
});
