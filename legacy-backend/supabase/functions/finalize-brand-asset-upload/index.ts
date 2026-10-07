import type { CommandClient } from "../_shared/command-client.ts";
import { downloadAuthorizedUpload } from "../_shared/upload-intent.ts";
import { requireStepUpSession } from "../_shared/session.ts";
import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { isUuid, mapDatabaseError, sha256Hex } from "../_shared/financial.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";

type FinalizeRequest = Readonly<{
  uploadIntentId: string;
  sessionId: string;
}>;

function parseBody(value: unknown): FinalizeRequest {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  const body = value as Record<string, unknown>;
  if (!isUuid(body.uploadIntentId) || !isUuid(body.sessionId)) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return { uploadIntentId: body.uploadIntentId, sessionId: body.sessionId };
}

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
    const body = parseBody(await request.json());
    const { client, userId, stepUpSessionId } =
      await authenticatedServiceSupabase(
        request,
      );
    const commandClient = client as unknown as CommandClient;
    const object = await downloadAuthorizedUpload(
      commandClient,
      client.storage,
      "brand",
      body.uploadIntentId,
      userId,
      requireStepUpSession(stepUpSessionId),
    );
    const bytes = await object.arrayBuffer();
    const { data: asset, error } = await commandClient
      .schema("command_api")
      .rpc("finalize_brand_asset_upload", {
        p_intent_id: body.uploadIntentId,
        p_actor_user_id: userId,
        p_session_id: requireStepUpSession(stepUpSessionId),
        p_verified_file_size_bytes: bytes.byteLength,
        p_verified_sha256_hex: await sha256Hex(bytes),
      });
    if (error !== null) throw mapDatabaseError(error);
    return successResponse(request, requestId, asset);
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
