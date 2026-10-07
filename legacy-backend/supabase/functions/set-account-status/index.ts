import type { CommandClient } from "../_shared/command-client.ts";
import { requireStepUpSession } from "../_shared/session.ts";
import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const allowedStatuses = new Set([
  "active",
  "restricted",
  "suspended",
  "deactivated",
]);
type AdministrativeStatus =
  | "active"
  | "restricted"
  | "suspended"
  | "deactivated";

type AccountStatusRequest = Readonly<{
  idempotencyKey: string;
  sessionId: string;
  targetUserId: string;
  newStatus: AdministrativeStatus;
  reason: string;
}>;

function requestBody(value: unknown): AccountStatusRequest {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  const body = value as Record<string, unknown>;
  const fields = [
    "idempotencyKey",
    "sessionId",
    "targetUserId",
    "newStatus",
    "reason",
  ] as const;
  for (const field of fields) {
    if (typeof body[field] !== "string" || body[field].trim().length === 0) {
      throw new DomainError("validation_error", "Request body is invalid");
    }
  }
  const parsed = body as Record<(typeof fields)[number], string>;
  if (
    !uuidPattern.test(parsed.idempotencyKey) ||
    !uuidPattern.test(parsed.sessionId) ||
    !uuidPattern.test(parsed.targetUserId) ||
    !allowedStatuses.has(parsed.newStatus) ||
    parsed.reason.trim().length > 500
  ) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return { ...parsed, newStatus: parsed.newStatus as AdministrativeStatus };
}

function mapDatabaseError(error: { code?: string }): DomainError {
  switch (error.code) {
    case "22023":
      return new DomainError("validation_error", "Request body is invalid");
    case "23505":
      return new DomainError(
        "conflict",
        "The command conflicts with existing data",
      );
    case "42501":
      return new DomainError(
        "authorization_denied",
        "You are not authorized to change account status",
      );
    case "P0002":
      return new DomainError("not_found", "The target account was not found");
    default:
      return new DomainError(
        "internal_error",
        "The account status command failed",
      );
  }
}

Deno.serve(async (request) => {
  const requestId = requestIdFor(request);
  if (request.method === "OPTIONS") return optionsResponse(request);
  if (request.method !== "POST") {
    return failureResponse(
      request,
      requestId,
      new DomainError("validation_error", "Method not allowed"),
    );
  }

  try {
    const body = requestBody(await request.json());
    const { client, userId, stepUpSessionId } =
      await authenticatedServiceSupabase(
        request,
      );
    const commandClient = client as unknown as CommandClient;
    const { data, error } = await commandClient.schema("command_api").rpc(
      "set_account_status",
      {
        p_idempotency_key: body.idempotencyKey,
        p_actor_user_id: userId,
        p_session_id: requireStepUpSession(stepUpSessionId),
        p_target_user_id: body.targetUserId,
        p_new_status: body.newStatus,
        p_reason: body.reason.trim(),
      },
    );
    if (error !== null) throw mapDatabaseError(error);
    return successResponse(request, requestId, data);
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
