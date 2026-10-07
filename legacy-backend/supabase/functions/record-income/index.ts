import type { CommandClient } from "../_shared/command-client.ts";
import { DomainError } from "../../../src/shared/domain_error.ts";
import { parseIncomeSubmit } from "../_shared/income.ts";
import { recordVerifiedIncome } from "../_shared/record-income.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
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
    const intentId = parseIncomeSubmit(await request.json());
    const { client, userId, stepUpSessionId } =
      await authenticatedServiceSupabase(request);
    const result = await recordVerifiedIncome(
      client as unknown as CommandClient,
      client.storage,
      intentId,
      userId,
      stepUpSessionId,
    );
    return successResponse(request, requestId, result);
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
