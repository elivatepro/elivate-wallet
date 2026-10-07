import { DomainError } from "../../../src/shared/domain_error.ts";
import { isUuid, mapDatabaseError } from "./financial.ts";
import type { CommandClient } from "./command-client.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "./http.ts";
export function parsePayoutDestination(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainError("validation_error", "Select a payout to execute");
  }
  const body = value as Record<string, unknown>;
  if (
    Object.keys(body).some((key) =>
      !["membershipId", "withdrawalId"].includes(key)
    ) || !isUuid(body.membershipId) || !isUuid(body.withdrawalId)
  ) throw new DomainError("validation_error", "Select a payout to execute");
  return {
    p_actor_membership_id: body.membershipId,
    p_withdrawal_id: body.withdrawalId,
  };
}
type Authenticate = (
  request: Request,
) => Promise<
  { client: CommandClient; userId: string; stepUpSessionId: string | null }
>;
function protectedResponse(response: Response) {
  response.headers.set("Cache-Control", "no-store");
  response.headers.set("access-control-allow-methods", "POST, OPTIONS");
  response.headers.set(
    "access-control-allow-headers",
    "authorization, apikey, content-type, x-request-id",
  );
  return response;
}
export async function handlePayoutDestination(
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
    const input = parsePayoutDestination(await request.json());
    const { client, userId, stepUpSessionId } = await authenticate(request);
    const { data, error } = await client.schema("command_api").rpc(
      "payout_destination",
      { ...input, p_actor_user_id: userId, p_session_id: stepUpSessionId },
    );
    if (error) throw mapDatabaseError(error);
    if (data === null || typeof data !== "object" || Array.isArray(data)) {
      throw new Error("Payout destination is unavailable");
    }
    return protectedResponse(successResponse(request, requestId, data));
  } catch (error) {
    return protectedResponse(failureResponse(request, requestId, error));
  }
}
