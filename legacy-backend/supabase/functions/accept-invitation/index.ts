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
  type InvitationCommandClient,
  invitationTokenDigest,
  parseAcceptInvitation,
} from "../_shared/invitation.ts";

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
    const body = parseAcceptInvitation(await request.json());
    const { client, userId } = await authenticatedServiceSupabase(request);
    const { data: identity, error: identityError } = await client.auth.admin
      .getUserById(userId);
    if (identityError || !identity.user?.email_confirmed_at) {
      throw new DomainError(
        "authorization_denied",
        "Confirm your email before accepting an invitation",
      );
    }
    const commandClient = client as unknown as InvitationCommandClient;
    const tokenDigest = await invitationTokenDigest(body.token);
    const { data, error } = await commandClient.schema("command_api").rpc(
      "accept_invitation",
      {
        p_idempotency_key: body.idempotencyKey,
        p_actor_user_id: userId,
        p_token_digest: tokenDigest,
      },
    );
    if (error !== null) throw mapDatabaseError(error);
    return successResponse(request, requestId, data);
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
