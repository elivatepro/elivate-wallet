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
import {
  parseBankResolution,
  resolveAuthorizedBank,
} from "../_shared/bank-resolution.ts";
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
    const input = parseBankResolution(
      await request.json().catch(() => {
        throw new DomainError("validation_error", "Request body is invalid");
      }),
    );
    const { client, userId, stepUpSessionId } =
      await authenticatedServiceSupabase(request);
    const data = await resolveAuthorizedBank(
      client as unknown as CommandClient,
      input,
      userId,
      requireStepUpSession(stepUpSessionId),
      () => Deno.env.get("NUBAN_API_KEY") ?? "",
    );
    return reply(successResponse(request, id, data));
  } catch (error) {
    return reply(failureResponse(request, id, error));
  }
});
