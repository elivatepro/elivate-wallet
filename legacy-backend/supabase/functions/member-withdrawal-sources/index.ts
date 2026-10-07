import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { mapDatabaseError } from "../_shared/financial.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
import { parseWithdrawalSourcesQuery } from "../_shared/withdrawal-sources.ts";
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
    const query = parseWithdrawalSourcesQuery(
      new URL(request.url).searchParams,
    );
    const { client, userId } = await authenticatedServiceSupabase(request);
    const readClient = client as unknown as ReadClient;
    const { data, error } = await readClient.schema("read_api").rpc(
      "member_withdrawal_sources",
      {
        p_actor_user_id: userId,
        p_after: query.after,
        p_limit: query.limit,
        p_source_ledger_account_id: query.sourceId,
      },
    );
    if (error !== null) throw mapDatabaseError(error);
    return successResponse(request, requestId, data);
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
