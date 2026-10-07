import type { CommandClient } from "../_shared/command-client.ts";
import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { mapDatabaseError } from "../_shared/financial.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
import { parseIncomeUpload } from "../_shared/income.ts";
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
    const input = parseIncomeUpload(await request.json());
    const { client, userId, stepUpSessionId } =
      await authenticatedServiceSupabase(request);
    const { data, error } = await (client as unknown as CommandClient).schema(
      "command_api",
    ).rpc("request_income_upload", {
      ...input,
      p_actor_user_id: userId,
      p_session_id: stepUpSessionId,
    });
    if (error) throw mapDatabaseError(error);
    if (data === null || typeof data !== "object") {
      throw new Error("Receipt intent is missing");
    }
    const intent = data as {
      upload_intent_id: string;
      bucket: string;
      path: string;
      expires_at: string;
    };
    const { data: signed, error: uploadError } = await client.storage.from(
      intent.bucket,
    ).createSignedUploadUrl(intent.path);
    if (uploadError || !signed) {
      throw new Error("Receipt upload could not be prepared");
    }
    return successResponse(request, requestId, {
      uploadIntentId: intent.upload_intent_id,
      bucket: intent.bucket,
      path: intent.path,
      token: signed.token,
      expiresAt: intent.expires_at,
    });
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
