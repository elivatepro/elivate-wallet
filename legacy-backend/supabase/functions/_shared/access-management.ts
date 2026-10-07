import { DomainError } from "../../../src/shared/domain_error.ts";
import { isUuid } from "./financial.ts";

export type AccessRuleInput = Readonly<{
  permission_key: string;
  effect: "allow" | "deny";
  scope_type: "tenant" | "office_subtree" | "member";
  scope_office_id?: string;
  scope_membership_id?: string;
  expires_at?: string;
}>;

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainError("validation_error", "Access input is invalid");
  }
  return value as Record<string, unknown>;
}
function exact(body: Record<string, unknown>, keys: string[]) {
  if (Object.keys(body).some((key) => !keys.includes(key))) {
    throw new DomainError("validation_error", "Access input is invalid");
  }
}
export function parseAccessRead(search: URLSearchParams) {
  if ([...search.keys()].some((key) => key !== "membershipId")) {
    throw new DomainError("validation_error", "Access query is invalid");
  }
  const values = search.getAll("membershipId");
  if (values.length !== 1 || !isUuid(values[0])) {
    throw new DomainError("validation_error", "Access query is invalid");
  }
  return { membershipId: values[0] };
}
export function parseCreateAccess(value: unknown) {
  const body = record(value);
  exact(body, [
    "idempotencyKey",
    "membershipId",
    "subjectUserId",
    "reason",
    "rules",
  ]);
  if (
    !isUuid(body.idempotencyKey) || !isUuid(body.membershipId) ||
    !isUuid(body.subjectUserId) || typeof body.reason !== "string" ||
    body.reason.trim().length < 1 || body.reason.trim().length > 1000 ||
    !Array.isArray(body.rules) || body.rules.length < 1 ||
    body.rules.length > 100
  ) {
    throw new DomainError("validation_error", "Access input is invalid");
  }
  const rules: AccessRuleInput[] = body.rules.map((value) => {
    const rule = record(value);
    exact(rule, [
      "permission_key",
      "effect",
      "scope_type",
      "scope_office_id",
      "scope_membership_id",
      "expires_at",
    ]);
    const permission = typeof rule.permission_key === "string" &&
        /^[a-z][a-z0-9_]*$/.test(rule.permission_key)
      ? rule.permission_key
      : null;
    const effect = rule.effect === "allow" || rule.effect === "deny"
      ? rule.effect
      : null;
    const scope =
      rule.scope_type === "tenant" || rule.scope_type === "office_subtree" ||
        rule.scope_type === "member"
        ? rule.scope_type
        : null;
    const office = rule.scope_office_id;
    const membership = rule.scope_membership_id;
    const expires = rule.expires_at;
    if (
      !permission || !effect || !scope ||
      (office !== undefined && !isUuid(office)) ||
      (membership !== undefined && !isUuid(membership)) ||
      (expires !== undefined &&
        (typeof expires !== "string" ||
          !Number.isFinite(Date.parse(expires)))) ||
      (scope === "tenant" &&
        (office !== undefined || membership !== undefined)) ||
      (scope === "office_subtree" &&
        (!isUuid(office) || membership !== undefined)) ||
      (scope === "member" && (office !== undefined || !isUuid(membership))) ||
      (effect === "deny" && expires !== undefined)
    ) {
      throw new DomainError("validation_error", "Access rule is invalid");
    }
    return {
      permission_key: permission,
      effect,
      scope_type: scope,
      ...(typeof office === "string" ? { scope_office_id: office } : {}),
      ...(typeof membership === "string"
        ? { scope_membership_id: membership }
        : {}),
      ...(typeof expires === "string" ? { expires_at: expires } : {}),
    };
  });
  return {
    idempotencyKey: body.idempotencyKey,
    membershipId: body.membershipId,
    subjectUserId: body.subjectUserId,
    reason: body.reason.trim(),
    rules,
  } as const;
}
export function parseRevokeAccess(value: unknown) {
  const body = record(value);
  exact(body, ["idempotencyKey", "membershipId", "assignmentId"]);
  if (
    !isUuid(body.idempotencyKey) || !isUuid(body.membershipId) ||
    !isUuid(body.assignmentId)
  ) {
    throw new DomainError("validation_error", "Access input is invalid");
  }
  return {
    idempotencyKey: body.idempotencyKey,
    membershipId: body.membershipId,
    assignmentId: body.assignmentId,
  } as const;
}
