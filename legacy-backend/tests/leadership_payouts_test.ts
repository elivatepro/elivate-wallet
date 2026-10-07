import { parseLeadershipPayoutsQuery } from "../supabase/functions/_shared/leadership-payouts.ts";
import { DomainError } from "../src/shared/domain_error.ts";
const id = "81000000-0000-4000-8000-000000000001";
function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
Deno.test("payout query preserves exact cursor timestamp and UUID selectors", () => {
  const time = "2026-10-03T14:03:01.123456+00:00";
  const query = parseLeadershipPayoutsQuery(
    new URLSearchParams({
      membershipId: id,
      beforeCreatedAt: time,
      beforeId: id,
      status: "approved",
    }),
  );
  assert(
    query.beforeCreatedAt === time && query.beforeId === id &&
      query.membershipId === id,
  );
  assert(
    parseLeadershipPayoutsQuery(
      new URLSearchParams({ membershipId: id, withdrawalId: id }),
    ).withdrawalId === id,
  );
});
Deno.test("payout read rejects forged context, duplicated or incomplete cursors and detail-filter mixtures", () => {
  for (
    const suffix of [
      "&actorUserId=" + id,
      "&tenantId=" + id,
      "&officeId=" + id,
      "&membershipId=" + id,
      "&status=unknown",
      "&status=",
      "&beforeCreatedAt=2026-10-03T00:00:00Z",
      "&beforeId=" + id,
      "&beforeCreatedAt=infinity&beforeId=" + id,
      "&beforeCreatedAt=2026-10-03&beforeId=" + id,
      "&withdrawalId=" + id + "&status=requested",
      "&withdrawalId=bad",
      "&limit=100",
    ]
  ) {
    let denied = false;
    try {
      parseLeadershipPayoutsQuery(
        new URLSearchParams("membershipId=" + id + suffix),
      );
    } catch (error) {
      denied = error instanceof DomainError &&
        error.code === "validation_error";
    }
    assert(denied, suffix);
  }
});

Deno.test("payout search normalizes and remains bounded without treating literal wildcards as SQL", () => {
  const parsed = parseLeadershipPayoutsQuery(
    new URLSearchParams({ membershipId: id, search: "  Office   _%  " }),
  );
  assert(parsed.search === "Office _%");
  for (
    const query of [
      new URLSearchParams({ membershipId: id, search: "a".repeat(201) }),
      new URLSearchParams({
        membershipId: id,
        withdrawalId: id,
        search: "test",
      }),
    ]
  ) {
    let rejected = false;
    try {
      parseLeadershipPayoutsQuery(query);
    } catch (error) {
      rejected = error instanceof DomainError;
    }
    assert(rejected);
  }
});
