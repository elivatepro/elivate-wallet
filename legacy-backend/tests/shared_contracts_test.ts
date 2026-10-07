import {
  assertEquals,
  assertStringIncludes,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { DomainError } from "../src/shared/domain_error.ts";
import { createStructuredLogRecord } from "../src/shared/logger.ts";
import {
  parseCreateMembership,
  parseEndMembership,
} from "../supabase/functions/_shared/membership.ts";
import {
  parseAcceptInvitation,
  parseRevokeInvitation,
} from "../supabase/functions/_shared/invitation.ts";
import {
  parseAddPayoutAccount,
  parsePayoutAccountCommand,
} from "../supabase/functions/_shared/payout_account.ts";

Deno.test("DomainError serializes stable machine-readable fields", () => {
  const error = new DomainError("authorization_denied", "Access denied", {
    details: { reasonCode: "account_suspended" },
  });

  assertEquals(error.toJSON(), {
    code: "authorization_denied",
    message: "Access denied",
    retryable: false,
    details: { reasonCode: "account_suspended" },
  });
});

Deno.test("structured logs redact security and financial-sensitive fields", () => {
  const record = createStructuredLogRecord("info", "authorization.decision", {
    requestId: "request-1",
    actorUserId: "user-1",
    authorizationHeader: "Bearer secret",
    financialEvidence: { receiptUrl: "https://private.invalid/receipt" },
    payoutAccount: {
      institutionCode: "private-bank-code",
      accountReference: "private-account-reference",
      accountHolderName: "Private Person",
    },
    providerReference: "external-payout-123",
    storageObjectPath: "tenant/private/receipt.png",
    decision: "DENY",
  }, new Date("2026-09-19T00:00:00.000Z"));

  const serialized = JSON.stringify(record);
  assertStringIncludes(serialized, "[REDACTED]");
  assertEquals(record.context.authorizationHeader, "[REDACTED]");
  assertEquals(record.context.financialEvidence, "[REDACTED]");
  assertEquals(record.context.payoutAccount, "[REDACTED]");
  assertEquals(record.context.providerReference, "[REDACTED]");
  assertEquals(record.context.storageObjectPath, "[REDACTED]");
  assertEquals(record.context.decision, "DENY");
});

const addPayoutInput = {
  idempotencyKey: "91000000-0000-4000-8000-000000000501",
  membershipId: "30000000-0000-4000-8000-000000000501",
  countryCode: "NG",
  payoutCurrency: "NGN",
  payoutRail: "bank_transfer",
  institutionCode: "999",
  institutionName: "Test Bank",
  accountReference: "0123456789",
  accountHolderName: "Wallet Owner",
};

Deno.test("payout-account add accepts own-membership selector and preserves account digits", () => {
  const command = parseAddPayoutAccount({
    ...addPayoutInput,
    accountHolderName: " Wallet Owner ",
  });
  assertEquals(command.membershipId, addPayoutInput.membershipId);
  assertEquals(command.fields.accountReference, "0123456789");
  assertEquals(command.fields.accountHolderName, "Wallet Owner");
  assertEquals("makePrimary" in command.fields, false);
});

Deno.test("payout-account add rejects all client security context and verification fields", () => {
  for (
    const key of [
      "actorUserId",
      "sessionId",
      "tenantId",
      "walletId",
      "makePrimary",
      "verificationStatus",
      "verifiedAt",
      "unknown",
    ]
  ) {
    assertThrows(
      () => parseAddPayoutAccount({ ...addPayoutInput, [key]: "untrusted" }),
      DomainError,
    );
  }
});

Deno.test("payout-account add rejects oversized, empty, control-character and malformed fields", () => {
  for (
    const [key, limit] of Object.entries({
      countryCode: 2,
      payoutCurrency: 3,
      payoutRail: 32,
      institutionCode: 64,
      institutionName: 160,
      accountReference: 128,
      accountHolderName: 160,
    })
  ) {
    for (const value of ["x".repeat(limit + 1), "", " ", "a\nb"]) {
      assertThrows(
        () => parseAddPayoutAccount({ ...addPayoutInput, [key]: value }),
        DomainError,
      );
    }
  }
  for (
    const patch of [
      { membershipId: "invalid" },
      { idempotencyKey: null },
      { countryCode: "ng" },
      { payoutCurrency: "ngn" },
      { payoutRail: "bank transfer" },
      { accountReference: 1234567890 },
    ]
  ) {
    assertThrows(
      () => parseAddPayoutAccount({ ...addPayoutInput, ...patch }),
      DomainError,
    );
  }
});

Deno.test("payout-account add accepts each documented maximum length", () => {
  for (
    const [key, limit] of Object.entries({
      payoutRail: 32,
      institutionCode: 64,
      institutionName: 160,
      accountReference: 128,
      accountHolderName: 160,
    })
  ) {
    const command = parseAddPayoutAccount({
      ...addPayoutInput,
      [key]: "a".repeat(limit),
    });
    assertEquals(
      command.fields[key as keyof typeof command.fields].length,
      limit,
    );
  }
});

Deno.test("payout-account transport rejects malformed lifecycle selectors", () => {
  try {
    parsePayoutAccountCommand({
      idempotencyKey: "not-a-uuid",
      sessionId: "70000000-0000-4000-8000-000000000501",
      tenantId: "10000000-0000-4000-8000-000000000501",
      payoutAccountId: "85000000-0000-4000-8000-000000000501",
    });
    throw new Error("expected parser to reject malformed input");
  } catch (error) {
    assertEquals(error instanceof DomainError, true);
  }
});

Deno.test("membership transport preserves the database-owned lifecycle payload", () => {
  const command = parseCreateMembership({
    idempotencyKey: "91000000-0000-4000-8000-000000000601",
    sessionId: "70000000-0000-4000-8000-000000000601",
    tenantId: "10000000-0000-4000-8000-000000000601",
    targetUserId: "00000000-0000-4000-8000-000000000601",
    officeId: "20000000-0000-4000-8000-000000000601",
    roleKey: "member",
    actorUserId: "client-supplied-actor-is-ignored",
  });

  assertEquals(command.roleKey, "member");
  assertEquals("actorUserId" in command, false);
});

Deno.test("membership end transport allows an omitted replacement primary", () => {
  const command = parseEndMembership({
    idempotencyKey: "91000000-0000-4000-8000-000000000602",
    sessionId: "70000000-0000-4000-8000-000000000602",
    membershipId: "30000000-0000-4000-8000-000000000602",
  });

  assertEquals(command.replacementPrimaryMembershipId, null);
});

Deno.test("invitation acceptance transport accepts a raw token without exposing its digest", () => {
  const command = parseAcceptInvitation({
    idempotencyKey: "91000000-0000-4000-8000-000000000701",
    token: "organization-valid-invitation-token",
  });

  assertEquals(command.token, "organization-valid-invitation-token");
  assertEquals("tokenDigest" in command, false);
});

Deno.test("invitation revocation transport validates the invitation selector", () => {
  const command = parseRevokeInvitation({
    idempotencyKey: "91000000-0000-4000-8000-000000000702",
    sessionId: "70000000-0000-4000-8000-000000000702",
    invitationId: "40000000-0000-4000-8000-000000000702",
  });

  assertEquals(command.invitationId, "40000000-0000-4000-8000-000000000702");
});
