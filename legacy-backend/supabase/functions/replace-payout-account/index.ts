import { requireStepUpSession } from "../_shared/session.ts";
import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
import { mapDatabaseError } from "../_shared/financial.ts";
import {
  parseReplacePayoutAccount,
  type PayoutAccountCommandClient,
} from "../_shared/payout_account.ts";

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
    const body = parseReplacePayoutAccount(await request.json());
    const { client, userId, stepUpSessionId } =
      await authenticatedServiceSupabase(
        request,
      );
    const commandClient = client as unknown as PayoutAccountCommandClient;
    const { data, error } = await commandClient.schema("command_api").rpc(
      "replace_payout_account",
      {
        p_idempotency_key: body.idempotencyKey,
        p_actor_user_id: userId,
        p_session_id: requireStepUpSession(stepUpSessionId),
        p_tenant_id: body.tenantId,
        p_existing_payout_account_id: body.existingPayoutAccountId,
        p_country_code: body.fields.countryCode,
        p_payout_currency: body.fields.payoutCurrency,
        p_payout_rail: body.fields.payoutRail,
        p_institution_code: body.fields.institutionCode,
        p_institution_name: body.fields.institutionName,
        p_account_reference: body.fields.accountReference,
        p_account_holder_name: body.fields.accountHolderName,
        p_make_primary: body.fields.makePrimary,
      },
    );
    if (error !== null) throw mapDatabaseError(error);
    return successResponse(request, requestId, data);
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
