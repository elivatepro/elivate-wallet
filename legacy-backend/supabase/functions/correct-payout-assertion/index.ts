import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
import type { CommandClient } from "../_shared/command-client.ts";
import {
  finalizeVerifiedPayout,
  parsePayoutFinalize,
} from "../_shared/payout-evidence.ts";
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
    const stageId = parsePayoutFinalize(await request.json());
    const { client, userId, stepUpSessionId } =
      await authenticatedServiceSupabase(request);
    const result = await finalizeVerifiedPayout(
      client as unknown as CommandClient,
      client.storage,
      stageId,
      userId,
      stepUpSessionId,
      "correct",
    );
    return successResponse(request, requestId, result);
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
