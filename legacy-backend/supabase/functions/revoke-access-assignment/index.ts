import { DomainError } from "../../../src/shared/domain_error.ts";
import { parseRevokeAccess } from "../_shared/access-management.ts";
import { mapDatabaseError } from "../_shared/financial.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
type Client = {
  schema: (
    name: string,
  ) => {
    rpc: (
      name: string,
      args: Record<string, unknown>,
    ) => Promise<{ data: unknown; error: { code?: string } | null }>;
  };
};
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
    const input = parseRevokeAccess(await request.json());
    const { client, userId, stepUpSessionId } =
      await authenticatedServiceSupabase(request);
    const { data, error } = await (client as unknown as Client).schema(
      "command_api",
    ).rpc("revoke_access_assignment", {
      p_idempotency_key: input.idempotencyKey,
      p_actor_user_id: userId,
      p_session_id: stepUpSessionId,
      p_actor_membership_id: input.membershipId,
      p_assignment_id: input.assignmentId,
    });
    if (error) throw mapDatabaseError(error);
    const response = successResponse(request, requestId, {
      assignment_id: data,
    });
    response.headers.set("Cache-Control", "no-store");
    return response;
  } catch (error) {
    const response = failureResponse(request, requestId, error);
    response.headers.set("Cache-Control", "no-store");
    return response;
  }
});
