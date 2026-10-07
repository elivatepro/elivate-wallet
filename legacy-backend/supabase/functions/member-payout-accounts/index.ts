import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
import { DomainError } from "../../../src/shared/domain_error.ts";

type ReadApiClient = Readonly<{
  schema: (name: string) => Readonly<{
    rpc: (
      name: string,
      args: Readonly<{ p_actor_user_id: string }>,
    ) => Promise<
      Readonly<{ data: unknown; error: Readonly<{ message: string }> | null }>
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
    const { client, userId } = await authenticatedServiceSupabase(request);
    const readClient = client as unknown as ReadApiClient;
    const { data, error } = await readClient.schema("read_api").rpc(
      "member_payout_accounts",
      { p_actor_user_id: userId },
    );
    if (error !== null) throw error;
    return successResponse(request, requestId, data ?? { items: [] });
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
