import { DomainError } from "../../../src/shared/domain_error.ts";
import { isUuid } from "./financial.ts";
export function parseWithdrawalSourcesQuery(
  query: URLSearchParams,
): Readonly<{ after: string | null; sourceId: string | null; limit: number }> {
  for (const key of query.keys()) {
    if (
      !["after", "limit", "sourceId"].includes(key) ||
      query.getAll(key).length !== 1
    ) {
      throw new DomainError(
        "validation_error",
        "Withdrawal source query is invalid",
      );
    }
  }
  const after = query.get("after");
  const sourceId = query.get("sourceId");
  const rawLimit = query.get("limit");
  if (
    (after !== null && !isUuid(after)) ||
    (sourceId !== null && !isUuid(sourceId)) ||
    (sourceId !== null && after !== null) ||
    (rawLimit !== null && !/^[1-9]\d{0,2}$/.test(rawLimit))
  ) {
    throw new DomainError(
      "validation_error",
      "Withdrawal source query is invalid",
    );
  }
  const limit = rawLimit === null ? 50 : Number(rawLimit);
  if (limit > 100) {
    throw new DomainError(
      "validation_error",
      "Withdrawal source limit must be between 1 and 100",
    );
  }
  return { after, sourceId, limit };
}
export function parseWithdrawalTargetQuery(
  query: URLSearchParams,
): string | null {
  if (!query.has("withdrawalId")) return null;
  const id = query.get("withdrawalId");
  if (
    !isUuid(id) || [...query.keys()].some((key) => key !== "withdrawalId") ||
    query.getAll("withdrawalId").length !== 1
  ) {
    throw new DomainError(
      "validation_error",
      "Withdrawal target query is invalid",
    );
  }
  return id;
}
