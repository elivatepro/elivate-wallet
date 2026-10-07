import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { isUuid, mapDatabaseError } from "../_shared/financial.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";

type CancellationRequest = Readonly<{
  idempotencyKey: string;
  withdrawalId: string;
  reason: string;
  sessionId: string | null;
}>;

type CommandClient = Readonly<{
  schema: (name: string) => Readonly<{
    rpc: (
      name: string,
      args: Readonly<Record<string, string | null>>,
    ) => Promise<
      Readonly<{ data: unknown; error: Readonly<{ code?: string }> | null }>
    >;
  }>;
}>;

function parseBody(value: unknown): CancellationRequest {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  const body = value as Record<string, unknown>;
  const idempotencyKey = body.idempotencyKey;
  const withdrawalId = body.withdrawalId;
  const reason = body.reason;
  const sessionId = body.sessionId ?? null;
  if (
    !isUuid(idempotencyKey) ||
    !isUuid(withdrawalId) ||
    typeof reason !== "string" ||
    reason.trim().length < 1 ||
    reason.trim().length > 500 ||
    (sessionId !== null && !isUuid(sessionId))
  ) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return {
    idempotencyKey,
    withdrawalId,
    reason: reason.trim(),
    sessionId,
  };
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
    const body = parseBody(await request.json());
    const { client, userId, stepUpSessionId } =
      await authenticatedServiceSupabase(
        request,
      );
    const commandClient = client as unknown as CommandClient;
    const { data, error } = await commandClient.schema("command_api").rpc(
      "cancel_withdrawal",
      {
        p_idempotency_key: body.idempotencyKey,
        p_withdrawal_id: body.withdrawalId,
        p_actor_user_id: userId,
        p_reason: body.reason,
        p_session_id: stepUpSessionId,
      },
    );
    if (error !== null) throw mapDatabaseError(error);
    return successResponse(request, requestId, data);
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
