import { DomainError } from "../../../src/shared/domain_error.ts";
import { isUuid } from "./financial.ts";
export function parseLeadershipPayoutsQuery(query: URLSearchParams): Readonly<{
  membershipId: string;
  status: string | null;
  beforeCreatedAt: string | null;
  beforeId: string | null;
  withdrawalId: string | null;
  search: string | null;
}> {
  const fail = () => {
    throw new DomainError("validation_error", "Payout query is invalid");
  };
  for (const key of query.keys()) {
    if (
      ![
        "membershipId",
        "status",
        "beforeCreatedAt",
        "beforeId",
        "withdrawalId",
        "search",
      ]
        .includes(key) || query.getAll(key).length !== 1
    ) fail();
  }
  const membershipId = query.get("membershipId");
  const status = query.get("status");
  const beforeCreatedAt = query.get("beforeCreatedAt");
  const beforeId = query.get("beforeId");
  const withdrawalId = query.get("withdrawalId");
  const search = query.get("search")?.trim().replace(/\s+/g, " ") || null;
  if (!isUuid(membershipId)) return fail();
  if (
    (search !== null && search.length > 200) ||
    (status !== null &&
      !["requested", "approved", "completed", "cancelled", "rejected"].includes(
        status,
      )) ||
    (beforeId !== null && !isUuid(beforeId)) ||
    (withdrawalId !== null && !isUuid(withdrawalId)) ||
    (beforeCreatedAt === null) !== (beforeId === null) ||
    (beforeCreatedAt !== null &&
      (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/
        .test(beforeCreatedAt) ||
        !Number.isFinite(Date.parse(beforeCreatedAt)))) ||
    (withdrawalId !== null &&
      (status !== null || beforeCreatedAt !== null || search !== null))
  ) return fail();
  return {
    membershipId,
    status,
    beforeCreatedAt,
    beforeId,
    withdrawalId,
    search,
  };
}
