import type { CommandClient } from "../_shared/command-client.ts";
import { DomainError } from "../../../src/shared/domain_error.ts";
import { parseIncomeSubmit } from "../_shared/income.ts";
import { mapDatabaseError } from "../_shared/financial.ts";
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
    const { client, userId } = await authenticatedServiceSupabase(request);
    const { data, error } = await (client as unknown as CommandClient).schema(
      "command_api",
    ).rpc("cancel_income_upload", {
      p_intent_id: intentId,
      p_actor_user_id: userId,
    });
    if (error) throw mapDatabaseError(error);
    return successResponse(request, requestId, data);
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
