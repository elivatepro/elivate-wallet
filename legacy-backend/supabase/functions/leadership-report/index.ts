import { DomainError } from "../../../src/shared/domain_error.ts";
import { mapDatabaseError } from "../_shared/financial.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { parseLeadershipReportQuery } from "../_shared/leadership-report.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
type ReadClient = Readonly<
  {
    schema: (
      name: string,
    ) => Readonly<
      {
        rpc: (
          name: string,
          args: Readonly<Record<string, string | null>>,
        ) => Promise<
          Readonly<{ data: unknown; error: Readonly<{ code?: string }> | null }>
        >;
      }
    >;
  }
>;
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
    const query = parseLeadershipReportQuery(new URL(request.url).searchParams);
    const { client, userId } = await authenticatedServiceSupabase(request);
    const { data, error } = await (client as unknown as ReadClient).schema(
      "read_api",
    ).rpc("leadership_report", {
      p_actor_user_id: userId,
      p_actor_membership_id: query.membershipId,
      p_from: query.from,
      p_to: query.to,
      p_currency_code: query.currency,
    });
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
