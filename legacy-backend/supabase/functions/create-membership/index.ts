import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { mapDatabaseError } from "../_shared/financial.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
import {
  type MembershipCommandClient,
  parseCreateMembership,
} from "../_shared/membership.ts";

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
    const body = parseCreateMembership(await request.json());
    const { client, userId, stepUpSessionId } =
      await authenticatedServiceSupabase(
        request,
      );
    const commandClient = client as unknown as MembershipCommandClient;
    const { data, error } = await commandClient.schema("command_api").rpc(
      "create_membership",
      {
        p_idempotency_key: body.idempotencyKey,
        p_actor_user_id: userId,
        p_session_id: stepUpSessionId,
        p_tenant_id: body.tenantId,
        p_target_user_id: body.targetUserId,
        p_office_id: body.officeId,
        p_role_key: body.roleKey,
      },
    );
    if (error !== null) throw mapDatabaseError(error);
    return successResponse(request, requestId, data);
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
