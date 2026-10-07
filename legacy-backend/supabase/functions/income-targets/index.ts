import { isUuid } from "../_shared/financial.ts";
import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { mapDatabaseError } from "../_shared/financial.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
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
    const query = new URL(request.url).searchParams;
    const membership = query.get("membershipId");
    const after = query.get("after");
    if (!isUuid(membership) || (after !== null && !isUuid(after))) {
      throw new DomainError("validation_error", "Choose a workspace");
    }
    const { client, userId } = await authenticatedServiceSupabase(request);
    const readClient = client as unknown as {
      schema: (
        schema: string,
      ) => {
        rpc: (
          name: string,
          args: Record<string, unknown>,
        ) => Promise<{ data: unknown; error: { code?: string } | null }>;
      };
    };
    const { data, error } = await readClient.schema("read_api").rpc(
      "income_targets",
      {
        p_actor_user_id: userId,
        p_actor_membership_id: membership,
        p_after_id: after,
      },
    );
    if (error) throw mapDatabaseError(error);
    return successResponse(request, requestId, data);
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
