import {
  parseAccessRead,
  parseCreateAccess,
  parseRevokeAccess,
} from "../supabase/functions/_shared/access-management.ts";
import { DomainError } from "../src/shared/domain_error.ts";
const a = "81000000-0000-4000-8000-000000000001",
  b = "81000000-0000-4000-8000-000000000002";
Deno.test("access transport parses bounded read and commands", () => {
  if (
    parseAccessRead(new URLSearchParams({ membershipId: a })).membershipId !== a
  ) throw new Error("read changed");
  const created = parseCreateAccess({
    idempotencyKey: a,
    membershipId: a,
    subjectUserId: b,
    reason: "Cover",
    rules: [{
      permission_key: "invite_members",
      effect: "deny",
      scope_type: "tenant",
    }],
  });
  if (created.rules[0]?.effect !== "deny") throw new Error("rule changed");
  if (
    parseRevokeAccess({ idempotencyKey: a, membershipId: a, assignmentId: b })
      .assignmentId !== b
  ) throw new Error("revoke changed");
});
Deno.test("access transport rejects expiring denies and client authority", () => {
  for (
    const value of [{
      idempotencyKey: a,
      membershipId: a,
      subjectUserId: b,
      reason: "x",
      rules: [{
        permission_key: "invite_members",
        effect: "deny",
        scope_type: "tenant",
        expires_at: new Date().toISOString(),
      }],
    }, {
      idempotencyKey: a,
      membershipId: a,
      subjectUserId: b,
      reason: "x",
      tenantId: a,
      rules: [{
        permission_key: "invite_members",
        effect: "allow",
        scope_type: "tenant",
      }],
    }]
  ) {
    let rejected = false;
    try {
      parseCreateAccess(value);
    } catch (error) {
      rejected = error instanceof DomainError &&
        error.code === "validation_error";
    }
    if (!rejected) throw new Error("unsafe access input accepted");
  }
});
