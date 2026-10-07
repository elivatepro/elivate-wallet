import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { isUuid, mapDatabaseError } from "../_shared/financial.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";

type WithdrawalRequest = Readonly<{
  idempotencyKey: string;
  sourceLedgerAccountId: string;
  payoutAccountId: string;
  requestedAmount: string;
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

function parseBody(value: unknown): WithdrawalRequest {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  const body = value as Record<string, unknown>;
  const idempotencyKey = body.idempotencyKey;
  const sourceLedgerAccountId = body.sourceLedgerAccountId;
  const payoutAccountId = body.payoutAccountId;
  const requestedAmount = body.requestedAmount;
  const sessionId = body.sessionId ?? null;
  if (
    !isUuid(idempotencyKey) ||
    !isUuid(sourceLedgerAccountId) ||
    !isUuid(payoutAccountId) ||
    typeof requestedAmount !== "string" ||
    !/^(?:0|[1-9]\d*)(?:\.\d{1,18})?$/.test(requestedAmount) ||
    requestedAmount === "0" ||
    /^0+(?:\.0{1,18})?$/.test(requestedAmount) ||
    (sessionId !== null && !isUuid(sessionId))
  ) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return {
    idempotencyKey,
    sourceLedgerAccountId,
    payoutAccountId,
    requestedAmount,
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
      "submit_withdrawal",
      {
        p_idempotency_key: body.idempotencyKey,
        p_source_ledger_account_id: body.sourceLedgerAccountId,
        p_payout_account_id: body.payoutAccountId,
        p_requested_amount: body.requestedAmount,
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
