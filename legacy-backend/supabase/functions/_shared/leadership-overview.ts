import { DomainError } from "../../../src/shared/domain_error.ts";
import { isUuid } from "./financial.ts";

export function parseLeadershipOverviewQuery(query: URLSearchParams): string {
  const entries = [...query.entries()];
  const membershipId = query.get("membershipId");
  if (
    entries.length !== 1 || entries[0]?.[0] !== "membershipId" ||
    !isUuid(membershipId)
  ) {
    throw new DomainError("validation_error", "Choose a workspace");
  }
  return membershipId;
}
