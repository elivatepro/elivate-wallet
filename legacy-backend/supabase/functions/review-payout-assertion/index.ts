import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { isUuid, mapDatabaseError } from "../_shared/financial.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";

type ReviewRequest = Readonly<{
  idempotencyKey: string;
  payoutAssertionId: string;
  decision: "clear" | "reject";
  reviewNote: string;
  sessionId: string | null;
}>;

type CommandClient = Readonly<{
  schema: (name: string) => Readonly<{
    rpc: (
      name: string,
      args: Readonly<Record<string, unknown>>,
    ) => Promise<
      Readonly<{ data: unknown; error: Readonly<{ code?: string }> | null }>
    >;
  }>;
}>;

function parseBody(value: unknown): ReviewRequest {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  const body = value as Record<string, unknown>;
  const idempotencyKey = body.idempotencyKey;
  const payoutAssertionId = body.payoutAssertionId;
  const decision = body.decision;
  const reviewNote = body.reviewNote;
  const sessionId = body.sessionId ?? null;
  if (
    !isUuid(idempotencyKey) ||
    !isUuid(payoutAssertionId) ||
    (decision !== "clear" && decision !== "reject") ||
    typeof reviewNote !== "string" ||
    reviewNote.trim().length < 1 ||
    reviewNote.trim().length > 2000 ||
    (sessionId !== null && !isUuid(sessionId))
  ) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return {
    idempotencyKey,
    payoutAssertionId,
    decision,
    reviewNote: reviewNote.trim(),
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
      "review_payout_assertion",
      {
        p_idempotency_key: body.idempotencyKey,
        p_payout_assertion_id: body.payoutAssertionId,
        p_decision: body.decision,
        p_review_note: body.reviewNote,
        p_actor_user_id: userId,
        p_session_id: stepUpSessionId,
      },
    );
    if (error !== null) throw mapDatabaseError(error);
    return successResponse(request, requestId, data);
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
