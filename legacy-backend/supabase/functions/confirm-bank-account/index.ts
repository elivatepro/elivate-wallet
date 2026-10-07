import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
import { requireStepUpSession } from "../_shared/session.ts";
import type { CommandClient } from "../_shared/command-client.ts";
import { mapDatabaseError } from "../_shared/financial.ts";
import { parseBankConfirmation } from "../_shared/bank-resolution.ts";
function reply(response: Response) {
  response.headers.set("Cache-Control", "no-store");
  response.headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
  return response;
}
Deno.serve(async (request) => {
  const id = requestIdFor(request);
  if (request.method === "OPTIONS") return reply(optionsResponse(request));
  if (request.method !== "POST") {
    return reply(
      failureResponse(
        request,
        id,
        new DomainError("validation_error", "Method not allowed"),
      ),
    );
  }
  try {
    const input = parseBankConfirmation(
      await request.json().catch(() => {
        throw new DomainError("validation_error", "Request body is invalid");
      }),
    );
    const { client, userId, stepUpSessionId } =
      await authenticatedServiceSupabase(request);
    const result = await (client as unknown as CommandClient).schema(
      "command_api",
    ).rpc("confirm_bank_account", {
      ...input,
      p_actor_user_id: userId,
      p_session_id: requireStepUpSession(stepUpSessionId),
    });
    if (result.error) throw mapDatabaseError(result.error);
    return reply(successResponse(request, id, result.data));
  } catch (error) {
    return reply(failureResponse(request, id, error));
  }
});
