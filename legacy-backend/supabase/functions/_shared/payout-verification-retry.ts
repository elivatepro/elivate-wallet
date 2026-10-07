import { DomainError } from "../../../src/shared/domain_error.ts";
import type { CommandClient } from "./command-client.ts";
import { isUuid, mapDatabaseError } from "./financial.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "./http.ts";

export function parsePayoutVerificationRetry(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainError("validation_error", "Select a receipt to retry");
  }
  const body = value as Record<string, unknown>;
  if (
    Object.keys(body).length !== 3 ||
    Object.keys(body).some((key) =>
      !["membershipId", "payoutAssertionId", "idempotencyKey"].includes(key)
    ) || !isUuid(body.membershipId) || !isUuid(body.payoutAssertionId) ||
    !isUuid(body.idempotencyKey)
  ) throw new DomainError("validation_error", "Select a receipt to retry");
  return {
    p_actor_membership_id: body.membershipId,
    p_assertion_id: body.payoutAssertionId,
    p_idempotency_key: body.idempotencyKey,
  };
}
type Authenticate = (request: Request) => Promise<{
  client: CommandClient;
  userId: string;
  stepUpSessionId: string | null;
}>;
function protectedResponse(response: Response) {
  response.headers.set("Cache-Control", "no-store");
  response.headers.set("access-control-allow-methods", "POST, OPTIONS");
  response.headers.set(
    "access-control-allow-headers",
    "authorization, apikey, content-type, x-request-id",
  );
  return response;
}
export async function handlePayoutVerificationRetry(
  request: Request,
  authenticate: Authenticate,
): Promise<Response> {
  const requestId = requestIdFor(request);
  if (request.method === "OPTIONS") {
    return protectedResponse(optionsResponse(request));
  }
  try {
    if (request.method !== "POST") {
      throw new DomainError("validation_error", "Method not allowed");
    }
    const input = parsePayoutVerificationRetry(await request.json());
    const { client, userId, stepUpSessionId } = await authenticate(request);
    const { data, error } = await client.schema("command_api").rpc(
      "retry_payout_verification",
      { ...input, p_actor_user_id: userId, p_session_id: stepUpSessionId },
    );
    if (error) throw mapDatabaseError(error);
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      throw new Error("Verification retry result unavailable");
    }
    const result = data as Record<string, unknown>;
    if (
      !isUuid(result.jobId) ||
      result.payoutAssertionId !== input.p_assertion_id ||
      result.status !== "queued" || typeof result.reused !== "boolean"
    ) throw new Error("Verification retry result unavailable");
    // Return the narrow command result, never private lease or receipt fields.
    return protectedResponse(successResponse(request, requestId, {
      jobId: result.jobId,
      payoutAssertionId: result.payoutAssertionId,
      status: result.status,
      reused: result.reused,
    }));
  } catch (error) {
    return protectedResponse(failureResponse(request, requestId, error));
  }
}
