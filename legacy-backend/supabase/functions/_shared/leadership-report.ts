import { DomainError } from "../../../src/shared/domain_error.ts";
import { isUuid } from "./financial.ts";

const datePattern = /^\d{4}-\d{2}-\d{2}$/;
export function parseLeadershipReportQuery(query: URLSearchParams): Readonly<{
  membershipId: string;
  from: string;
  to: string;
  currency: string | null;
}> {
  const fail = () => {
    throw new DomainError("validation_error", "Report query is invalid");
  };
  for (const key of query.keys()) {
    if (
      !["membershipId", "from", "to", "currency"].includes(key) ||
      query.getAll(key).length !== 1
    ) return fail();
  }
  const membershipId = query.get("membershipId"),
    from = query.get("from"),
    to = query.get("to"),
    currency = query.get("currency");
  if (
    !isUuid(membershipId) || from === null || to === null ||
    !datePattern.test(from) || !datePattern.test(to) ||
    !Number.isFinite(Date.parse(`${from}T00:00:00Z`)) ||
    !Number.isFinite(Date.parse(`${to}T00:00:00Z`)) || from > to ||
    (currency !== null && !/^[A-Z]{3}$/.test(currency))
  ) return fail();
  return { membershipId, from, to, currency };
}
