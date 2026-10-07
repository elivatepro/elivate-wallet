import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { mapDatabaseError } from "../_shared/financial.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
import { parseLeadershipPayoutsQuery } from "../_shared/leadership-payouts.ts";
type ReadClient = Readonly<{
  schema: (name: string) => Readonly<{
    rpc: (
      name: string,
      args: Readonly<Record<string, string | number | null>>,
    ) => Promise<
      Readonly<{ data: unknown; error: Readonly<{ code?: string }> | null }>
    >;
  }>;
}>;
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
    const query = parseLeadershipPayoutsQuery(
      new URL(request.url).searchParams,
    );
    const { client, userId } = await authenticatedServiceSupabase(request);
    const readClient = client as unknown as ReadClient;
    const { data, error } = await readClient.schema("read_api").rpc(
      "leadership_payouts",
      {
        p_actor_user_id: userId,
        p_actor_membership_id: query.membershipId,
        p_status: query.status,
        p_before_created_at: query.beforeCreatedAt,
        p_before_withdrawal_id: query.beforeId,
        p_withdrawal_id: query.withdrawalId,
        p_search: query.search,
      },
    );
    if (error !== null) throw mapDatabaseError(error);
    const response = successResponse(request, requestId, data);
    response.headers.set("Cache-Control", "no-store");
    return response;
  } catch (error) {
    const response = failureResponse(request, requestId, error);
    response.headers.set("Cache-Control", "no-store");
    return response;
  }
});
