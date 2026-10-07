import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
import type { CommandClient } from "../_shared/command-client.ts";
import { parsePayoutUpload, payoutStage } from "../_shared/payout-evidence.ts";
import { mapDatabaseError } from "../_shared/financial.ts";
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
    const input = parsePayoutUpload(await request.json());
    const { client, userId, stepUpSessionId } =
      await authenticatedServiceSupabase(request);
    const { data, error } = await (client as unknown as CommandClient).schema(
      "command_api",
    ).rpc("request_payout_evidence_upload", {
      ...input,
      p_actor_user_id: userId,
      p_session_id: stepUpSessionId,
    });
    if (error) throw mapDatabaseError(error);
    const stage = payoutStage(data);
    // A finalized retry has immutable objects and needs no fresh upload tokens.
    const uploads = [];
    if (!stage.finalized && !stage.expired) {
      for (const file of stage.files) {
        const { data: signed, error: signError } = await client.storage.from(
          file.bucket,
        ).createSignedUploadUrl(file.path);
        if (signError || !signed) {
          throw new Error("Receipt upload could not be prepared");
        }
        uploads.push({ ...file, token: signed.token });
      }
    }
    return successResponse(request, requestId, {
      stageId: stage.stageId,
      expiresAt: stage.expiresAt,
      finalized: stage.finalized,
      expired: stage.expired,
      uploads,
    });
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
