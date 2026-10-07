import { DomainError } from "../../../src/shared/domain_error.ts";
import { isUuid, mapDatabaseError } from "./financial.ts";
import type { CommandClient } from "./command-client.ts";
import { resolveNubanAccount } from "../../../src/integrations/nuban.ts";
function invalid(): never {
  throw new DomainError("validation_error", "Check the bank account details");
}
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) invalid();
  return value as Record<string, unknown>;
}
function only(body: Record<string, unknown>, keys: readonly string[]) {
  if (Object.keys(body).some((key) => !keys.includes(key))) invalid();
}
export function parseBankResolution(value: unknown) {
  const body = object(value);
  only(body, [
    "idempotencyKey",
    "membershipId",
    "bankCode",
    "accountNumber",
    "payoutAccountId",
    "countryCode",
    "payoutCurrency",
    "payoutRail",
  ]);
  if (
    !isUuid(body.idempotencyKey) || !isUuid(body.membershipId) ||
    body.countryCode !== "NG" || body.payoutCurrency !== "NGN" ||
    body.payoutRail !== "bank_transfer"
  ) invalid();
  const existing = Object.hasOwn(body, "payoutAccountId");
  if (
    existing
      ? (!isUuid(body.payoutAccountId) || Object.hasOwn(body, "bankCode") ||
        Object.hasOwn(body, "accountNumber"))
      : (typeof body.bankCode !== "string" ||
        !/^[0-9]{3,6}$/.test(body.bankCode) ||
        typeof body.accountNumber !== "string" ||
        !/^[0-9]{10}$/.test(body.accountNumber))
  ) invalid();
  return {
    p_idempotency_key: body.idempotencyKey,
    p_membership_id: body.membershipId,
    p_country_code: "NG",
    p_payout_currency: "NGN",
    p_payout_rail: "bank_transfer",
    p_bank_code: existing ? null : body.bankCode,
    p_account_number: existing ? null : body.accountNumber,
    p_payout_account_id: existing ? body.payoutAccountId : null,
  };
}
export function parseBankConfirmation(value: unknown) {
  const body = object(value);
  only(body, ["resolutionId", "membershipId", "idempotencyKey", "confirmed"]);
  if (
    !isUuid(body.resolutionId) || !isUuid(body.membershipId) ||
    !isUuid(body.idempotencyKey) || body.confirmed !== true
  ) invalid();
  return {
    p_resolution_id: body.resolutionId,
    p_membership_id: body.membershipId,
    p_idempotency_key: body.idempotencyKey,
    p_confirmed: true,
  };
}
function intent(value: unknown) {
  const body = object(value);
  if (
    !isUuid(body.resolutionId) || typeof body.bankCode !== "string" ||
    !/^[0-9]{3,6}$/.test(body.bankCode) ||
    typeof body.accountNumber !== "string" ||
    !/^[0-9]{10}$/.test(body.accountNumber) ||
    body.accountReferenceMasked !== "••••" + body.accountNumber.slice(-4) ||
    typeof body.expiresAt !== "string" || typeof body.resolved !== "boolean" ||
    typeof body.confirmed !== "boolean" || typeof body.expired !== "boolean" ||
    (body.resolved &&
      (typeof body.accountHolderName !== "string" ||
        typeof body.institutionName !== "string")) ||
    (body.confirmed && !isUuid(body.payoutAccountId))
  ) throw new Error("Bank resolution contract is invalid");
  return {
    resolutionId: body.resolutionId,
    bankCode: body.bankCode,
    accountNumber: body.accountNumber,
    accountReferenceMasked: body.accountReferenceMasked,
    accountHolderName: body.accountHolderName,
    institutionName: body.institutionName,
    expiresAt: body.expiresAt,
    resolved: body.resolved,
    confirmed: body.confirmed,
    expired: body.expired,
    payoutAccountId: body.payoutAccountId,
  };
}
/** Only authorized stored identifiers reach the provider; full account numbers never leave this server response filter. */
export async function resolveAuthorizedBank(
  client: CommandClient,
  input: ReturnType<typeof parseBankResolution>,
  actor: string,
  session: string,
  getKey: () => string,
  fetcher: typeof fetch = fetch,
) {
  const commands = client.schema("command_api");
  const prepared = await commands.rpc("prepare_bank_resolution", {
    ...input,
    p_actor_user_id: actor,
    p_session_id: session,
  });
  if (prepared.error) throw mapDatabaseError(prepared.error);
  let result = intent(prepared.data);
  if (result.resolutionId !== input.p_idempotency_key) {
    throw new Error("Bank resolution identity is invalid");
  }
  if (!result.resolved && !result.confirmed && !result.expired) {
    const resolved = await resolveNubanAccount(
      getKey(),
      result.bankCode,
      result.accountNumber,
      fetcher,
    );
    const recorded = await commands.rpc("record_bank_resolution", {
      p_resolution_id: result.resolutionId,
      p_actor_user_id: actor,
      p_session_id: session,
      p_membership_id: input.p_membership_id,
      p_bank_code: resolved.bankCode,
      p_account_number: resolved.accountNumber,
      p_account_holder_name: resolved.accountHolderName,
      p_institution_name: resolved.institutionName,
    });
    if (recorded.error) throw mapDatabaseError(recorded.error);
    result = intent(recorded.data);
    if (result.resolutionId !== input.p_idempotency_key) {
      throw new Error("Bank resolution identity is invalid");
    }
  }
  const { accountNumber: _privateAccountNumber, ...safe } = result;
  return safe;
}
