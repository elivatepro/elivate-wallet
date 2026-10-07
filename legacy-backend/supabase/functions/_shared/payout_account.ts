import { DomainError } from "../../../src/shared/domain_error.ts";
import { isUuid } from "./financial.ts";

export type PayoutAccountFields = Readonly<{
  countryCode: string;
  payoutCurrency: string;
  payoutRail: string;
  institutionCode: string;
  institutionName: string;
  accountReference: string;
  accountHolderName: string;
  makePrimary: boolean;
}>;

export type PayoutAccountCommand = Readonly<{
  idempotencyKey: string;
  sessionId: string;
  tenantId: string;
  payoutAccountId: string;
}>;

export type AddPayoutAccountCommand = Readonly<{
  idempotencyKey: string;
  membershipId: string;
  fields: Omit<PayoutAccountFields, "makePrimary">;
}>;

export type ReplacePayoutAccountCommand = Readonly<{
  idempotencyKey: string;
  sessionId: string;
  tenantId: string;
  existingPayoutAccountId: string;
  fields: PayoutAccountFields;
}>;

export type PayoutAccountCommandClient = Readonly<{
  schema: (name: string) => Readonly<{
    rpc: (
      name: string,
      args: Readonly<Record<string, string | boolean>>,
    ) => Promise<
      Readonly<{ data: unknown; error: Readonly<{ code?: string }> | null }>
    >;
  }>;
}>;

function requiredString(
  body: Record<string, unknown>,
  key: string,
): string | null {
  const value = body[key];
  return typeof value === "string" && value.trim().length > 0 ? value : null;
}

function parseFields(body: Record<string, unknown>): PayoutAccountFields {
  const countryCode = requiredString(body, "countryCode");
  const payoutCurrency = requiredString(body, "payoutCurrency");
  const payoutRail = requiredString(body, "payoutRail");
  const institutionCode = requiredString(body, "institutionCode");
  const institutionName = requiredString(body, "institutionName");
  const accountReference = requiredString(body, "accountReference");
  const accountHolderName = requiredString(body, "accountHolderName");
  const makePrimary = body.makePrimary ?? false;
  if (
    countryCode === null ||
    !/^[A-Z]{2}$/.test(countryCode) ||
    payoutCurrency === null ||
    !/^[A-Z]{3}$/.test(payoutCurrency) ||
    payoutRail === null ||
    !/^[a-z][a-z0-9_]*$/.test(payoutRail) ||
    institutionCode === null ||
    institutionName === null ||
    accountReference === null ||
    accountHolderName === null ||
    typeof makePrimary !== "boolean"
  ) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return {
    countryCode,
    payoutCurrency,
    payoutRail,
    institutionCode: institutionCode.trim(),
    institutionName: institutionName.trim(),
    accountReference: accountReference.trim(),
    accountHolderName: accountHolderName.trim(),
    makePrimary,
  };
}

function parseObject(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return value as Record<string, unknown>;
}

// This unreleased endpoint accepts resource selection, never security context.
const addFieldLimits = {
  countryCode: 2,
  payoutCurrency: 3,
  payoutRail: 32,
  institutionCode: 64,
  institutionName: 160,
  accountReference: 128,
  accountHolderName: 160,
} as const;

export function parseAddPayoutAccount(
  value: unknown,
): AddPayoutAccountCommand {
  const body = parseObject(value);
  const allowed = new Set([
    "idempotencyKey",
    "membershipId",
    ...Object.keys(addFieldLimits),
  ]);
  if (Object.keys(body).some((key) => !allowed.has(key))) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  const idempotencyKey = body.idempotencyKey;
  const membershipId = body.membershipId;
  if (!isUuid(idempotencyKey) || !isUuid(membershipId)) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  for (const [key, maxLength] of Object.entries(addFieldLimits)) {
    const field = body[key];
    if (
      typeof field !== "string" || field.length > maxLength ||
      field.trim().length === 0 || Array.from(field).some((character) =>
        character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127
      )
    ) {
      throw new DomainError("validation_error", "Request body is invalid");
    }
  }
  const fields = parseFields(body);
  return {
    idempotencyKey,
    membershipId,
    fields: {
      countryCode: fields.countryCode,
      payoutCurrency: fields.payoutCurrency,
      payoutRail: fields.payoutRail,
      institutionCode: fields.institutionCode,
      institutionName: fields.institutionName,
      accountReference: fields.accountReference,
      accountHolderName: fields.accountHolderName,
    },
  };
}

export function parseReplacePayoutAccount(
  value: unknown,
): ReplacePayoutAccountCommand {
  const body = parseObject(value);
  const idempotencyKey = requiredString(body, "idempotencyKey");
  const sessionId = requiredString(body, "sessionId");
  const tenantId = requiredString(body, "tenantId");
  const existingPayoutAccountId = requiredString(
    body,
    "existingPayoutAccountId",
  );
  if (
    idempotencyKey === null ||
    sessionId === null ||
    tenantId === null ||
    existingPayoutAccountId === null ||
    !isUuid(idempotencyKey) ||
    !isUuid(sessionId) ||
    !isUuid(tenantId) ||
    !isUuid(existingPayoutAccountId)
  ) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return {
    idempotencyKey,
    sessionId,
    tenantId,
    existingPayoutAccountId,
    fields: parseFields(body),
  };
}

export function parsePayoutAccountCommand(
  value: unknown,
): PayoutAccountCommand {
  const body = parseObject(value);
  const idempotencyKey = requiredString(body, "idempotencyKey");
  const sessionId = requiredString(body, "sessionId");
  const tenantId = requiredString(body, "tenantId");
  const payoutAccountId = requiredString(body, "payoutAccountId");
  if (
    idempotencyKey === null ||
    sessionId === null ||
    tenantId === null ||
    payoutAccountId === null ||
    !isUuid(idempotencyKey) ||
    !isUuid(sessionId) ||
    !isUuid(tenantId) ||
    !isUuid(payoutAccountId)
  ) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return { idempotencyKey, sessionId, tenantId, payoutAccountId };
}
