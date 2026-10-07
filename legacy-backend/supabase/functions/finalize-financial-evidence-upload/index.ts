import { downloadAuthorizedUpload } from "../_shared/upload-intent.ts";
import type { CommandClient } from "../_shared/command-client.ts";
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
  observedAt: string;
  provider?: string;
  providerReference?: string;
  notes?: string;
}>;

function parseBody(value: unknown): FinalizeRequest {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  const body = value as Record<string, unknown>;
  if (
    !isUuid(body.uploadIntentId) || typeof body.observedAt !== "string" ||
    Number.isNaN(Date.parse(body.observedAt))
  ) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  const optionalFields = ["provider", "providerReference", "notes"] as const;
  for (const field of optionalFields) {
    if (body[field] !== undefined && typeof body[field] !== "string") {
      throw new DomainError("validation_error", "Request body is invalid");
    }
    if (typeof body[field] === "string" && body[field].trim().length > 500) {
      throw new DomainError("validation_error", "Request body is invalid");
    }
  }
  return {
    uploadIntentId: body.uploadIntentId,
    observedAt: new Date(body.observedAt).toISOString(),
    ...(typeof body.provider === "string"
      ? { provider: body.provider.trim() }
      : {}),
    ...(typeof body.providerReference === "string"
      ? { providerReference: body.providerReference.trim() }
      : {}),
    ...(typeof body.notes === "string" ? { notes: body.notes.trim() } : {}),
  };
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
    const { client, userId } = await authenticatedServiceSupabase(request);
    const commandClient = client as unknown as CommandClient;
    const object = await downloadAuthorizedUpload(
      commandClient,
      client.storage,
      "financial",
      body.uploadIntentId,
      userId,
    );
    const bytes = await object.arrayBuffer();
    const verifiedFileSizeBytes = bytes.byteLength;
    const verifiedSha256Hex = await sha256Hex(bytes);
    const rpcArgs = {
      p_intent_id: body.uploadIntentId,
      p_actor_user_id: userId,
      p_verified_file_size_bytes: verifiedFileSizeBytes,
      p_verified_sha256_hex: verifiedSha256Hex,
      p_observed_at: body.observedAt,
      ...(body.provider === undefined ? {} : { p_provider: body.provider }),
      ...(body.providerReference === undefined
        ? {}
        : { p_provider_reference: body.providerReference }),
      ...(body.notes === undefined ? {} : { p_notes: body.notes }),
    };
    const { data: evidence, error } = await commandClient.schema("command_api")
      .rpc(
        "finalize_financial_evidence_upload",
        rpcArgs,
      );
    if (error !== null) throw mapDatabaseError(error);
    return successResponse(request, requestId, evidence);
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
