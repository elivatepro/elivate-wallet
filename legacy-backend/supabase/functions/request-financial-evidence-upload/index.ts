import type { CommandClient } from "../_shared/command-client.ts";
import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import {
  financialEvidenceMimeTypes,
  isSha256Hex,
  isUuid,
  mapDatabaseError,
} from "../_shared/financial.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";

const targetTypes = new Set([
  "income_record",
  "currency_conversion_revision",
  "administrative_adjustment_revision",
  "returned_fund_revision",
]);
const evidenceTypes = new Set([
  "income",
  "currency_conversion",
  "administrative_adjustment",
  "returned_funds",
]);

type UploadRequest = Readonly<{
  idempotencyKey: string;
  targetType: string;
  targetId: string;
  evidenceType: string;
  originalFilename: string;
  mimeType: string;
  fileSizeBytes: number;
  sha256Hex: string;
}>;

function parseBody(value: unknown): UploadRequest {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  const body = value as Record<string, unknown>;
  const idempotencyKey = body.idempotencyKey;
  const targetType = body.targetType;
  const targetId = body.targetId;
  const evidenceType = body.evidenceType;
  const originalFilename = body.originalFilename;
  const mimeType = body.mimeType;
  const fileSizeBytes = body.fileSizeBytes;
  const sha256Hex = body.sha256Hex;
  if (
    !isUuid(idempotencyKey) || !isUuid(targetId) ||
    typeof targetType !== "string" || !targetTypes.has(targetType) ||
    typeof evidenceType !== "string" || !evidenceTypes.has(evidenceType) ||
    typeof originalFilename !== "string" ||
    originalFilename.trim().length < 1 ||
    originalFilename.trim().length > 255 ||
    typeof mimeType !== "string" || !financialEvidenceMimeTypes.has(mimeType) ||
    typeof fileSizeBytes !== "number" || !Number.isSafeInteger(fileSizeBytes) ||
    fileSizeBytes < 1 || fileSizeBytes > 52428800 || !isSha256Hex(sha256Hex)
  ) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return {
    idempotencyKey,
    targetType,
    targetId,
    evidenceType,
    originalFilename: originalFilename.trim(),
    mimeType,
    fileSizeBytes,
    sha256Hex: sha256Hex.toLowerCase(),
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
    const { data: intent, error } = await commandClient.schema("command_api")
      .rpc(
        "request_financial_evidence_upload",
        {
          p_idempotency_key: body.idempotencyKey,
          p_actor_user_id: userId,
          p_target_type: body.targetType,
          p_target_id: body.targetId,
          p_evidence_type: body.evidenceType,
          p_original_filename: body.originalFilename,
          p_mime_type: body.mimeType,
          p_file_size_bytes: body.fileSizeBytes,
          p_sha256_hex: body.sha256Hex,
        },
      );
    if (error !== null) throw mapDatabaseError(error);
    if (intent === null || typeof intent !== "object") {
      throw new Error("Upload intent response is missing");
    }
    const intentRecord = intent as {
      id: string;
      storage_bucket_id: string;
      storage_object_path: string;
      expires_at: string;
    };
    const { data: signedUpload, error: storageError } = await client.storage
      .from(intentRecord.storage_bucket_id)
      .createSignedUploadUrl(intentRecord.storage_object_path);
    if (storageError !== null || signedUpload === null) {
      throw new Error("Signed upload URL could not be created");
    }
    return successResponse(request, requestId, {
      uploadIntentId: intentRecord.id,
      expiresAt: intentRecord.expires_at,
      bucket: intentRecord.storage_bucket_id,
      path: intentRecord.storage_object_path,
      signedUrl: signedUpload.signedUrl,
      token: signedUpload.token,
    });
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
