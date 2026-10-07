import { DomainError } from "../../../src/shared/domain_error.ts";
import { parseAccessRead } from "../_shared/access-management.ts";
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
      args: Record<string, string>,
    ) => Promise<{ data: unknown; error: { code?: string } | null }>;
  };
};
Deno.serve(async (request) => {
  const requestId = requestIdFor(request);
  if (request.method === "OPTIONS") return optionsResponse(request);
  if (request.method !== "GET") {
    return failureResponse(
      request,
      requestId,
      new DomainError("validation_error", "Method not allowed"),
    );
  }
  try {
    const query = parseAccessRead(new URL(request.url).searchParams);
    const { client, userId } = await authenticatedServiceSupabase(request);
    const { data, error } = await (client as unknown as Client).schema(
      "read_api",
    ).rpc("access_management", {
      p_actor_user_id: userId,
      p_actor_membership_id: query.membershipId,
    });
    if (error) throw mapDatabaseError(error);
    const response = successResponse(request, requestId, data);
    response.headers.set("Cache-Control", "no-store");
    return response;
  } catch (error) {
    const response = failureResponse(request, requestId, error);
    response.headers.set("Cache-Control", "no-store");
    return response;
  }
});
