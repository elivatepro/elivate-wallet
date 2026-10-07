import {
  parseWithdrawalSourcesQuery,
  parseWithdrawalTargetQuery,
} from "../supabase/functions/_shared/withdrawal-sources.ts";
import { DomainError } from "../src/shared/domain_error.ts";
function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
const id = "81000000-0000-4000-8000-000000000001";
Deno.test("withdrawal source pagination preserves exact selectors and bounded defaults", () => {
  const initial = parseWithdrawalSourcesQuery(new URLSearchParams());
  assert(
    initial.after === null && initial.limit === 50 && initial.sourceId === null,
  );
  const next = parseWithdrawalSourcesQuery(
    new URLSearchParams({ after: id, limit: "100" }),
  );
  assert(next.after === id && next.limit === 100);
  assert(
    parseWithdrawalSourcesQuery(new URLSearchParams({ sourceId: id }))
      .sourceId === id,
  );
});
Deno.test("withdrawal sources reject client security context and malformed or repeated selectors", () => {
  for (
    const query of [
      "actorUserId=" + id,
      "tenantId=" + id,
      "after=garbage",
      "sourceId=garbage",
      "limit=0",
      "limit=101",
      "limit=-1",
      "limit=1e2",
      "limit=",
      "limit=01",
      "limit=1&limit=2",
      "after=" + id + "&sourceId=" + id,
    ]
  ) {
    let rejected = false;
    try {
      parseWithdrawalSourcesQuery(new URLSearchParams(query));
    } catch (error) {
      rejected = error instanceof DomainError &&
        error.code === "validation_error";
    }
    assert(rejected, query);
  }
});
Deno.test("withdrawal target query cannot be confused with history pagination or client identity", () => {
  assert(parseWithdrawalTargetQuery(new URLSearchParams()) === null);
  assert(
    parseWithdrawalTargetQuery(new URLSearchParams({ withdrawalId: id })) ===
      id,
  );
  for (
    const query of [
      "withdrawalId=garbage",
      "withdrawalId=" + id + "&cursor=a",
      "withdrawalId=" + id + "&actorUserId=" + id,
      "withdrawalId=" + id + "&withdrawalId=" + id,
    ]
  ) {
    let rejected = false;
    try {
      parseWithdrawalTargetQuery(new URLSearchParams(query));
    } catch (error) {
      rejected = error instanceof DomainError &&
        error.code === "validation_error";
    }
    assert(rejected, query);
  }
});
