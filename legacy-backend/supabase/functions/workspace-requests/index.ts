import { DomainError } from "../../../src/shared/domain_error.ts";
import { mapDatabaseError } from "../_shared/financial.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
type RpcClient = {
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
  const id = requestIdFor(request);
  if (request.method === "OPTIONS") return optionsResponse(request);
  if (request.method !== "GET") {
    return failureResponse(
      request,
      id,
      new DomainError("validation_error", "Method not allowed"),
    );
  }
  try {
    const membershipId = new URL(request.url).searchParams.get("membershipId");
    if (!membershipId) {
      throw new DomainError("validation_error", "Membership is required");
    }
    const { client, userId } = await authenticatedServiceSupabase(request);
    const { data, error } = await (client as unknown as RpcClient).schema(
      "read_api",
    ).rpc(
      "workspace_requests",
      { p_actor_user_id: userId, p_actor_membership_id: membershipId },
    );
    if (error) throw mapDatabaseError(error);
    return successResponse(request, id, data);
  } catch (error) {
    return failureResponse(request, id, error);
  }
});
