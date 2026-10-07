import { requireStepUpSession } from "../_shared/session.ts";
import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { isSha256Hex, isUuid, mapDatabaseError } from "../_shared/financial.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";

type CommandClient = Readonly<{
  schema: (name: string) => Readonly<{
    rpc: (
      name: string,
      args: Readonly<Record<string, string | number | null>>,
    ) => Promise<
      Readonly<{ data: unknown; error: Readonly<{ code?: string }> | null }>
    >;
  }>;
}>;

const assetKinds = new Set([
  "primary_logo",
  "square_app_icon",
  "light_logo",
  "dark_logo",
]);
const assetMimeTypes = new Set([
  "image/png",
  "image/jpeg",
  "image/webp",
  "image/svg+xml",
]);

type UploadRequest = Readonly<{
  idempotencyKey: string;
  tenantId: string;
  sessionId: string;
  assetKind: string;
  mimeType: string;
  fileSizeBytes: number;
  sha256Hex: string;
  widthPixels: number | null;
  heightPixels: number | null;
}>;

function optionalPositiveInteger(value: unknown): number | null {
  if (value === null || value === undefined) return null;
  if (
    typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0
  ) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return value;
}

function parseBody(value: unknown): UploadRequest {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  const body = value as Record<string, unknown>;
  const idempotencyKey = body.idempotencyKey;
  const tenantId = body.tenantId;
  const sessionId = body.sessionId;
  const assetKind = body.assetKind;
  const mimeType = body.mimeType;
  const fileSizeBytes = body.fileSizeBytes;
  const sha256Hex = body.sha256Hex;
  if (
    !isUuid(idempotencyKey) || !isUuid(tenantId) || !isUuid(sessionId) ||
    typeof assetKind !== "string" || !assetKinds.has(assetKind) ||
    typeof mimeType !== "string" || !assetMimeTypes.has(mimeType) ||
    typeof fileSizeBytes !== "number" ||
    !Number.isSafeInteger(fileSizeBytes) || fileSizeBytes < 1 ||
    fileSizeBytes > 5242880 || !isSha256Hex(sha256Hex)
  ) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return {
    idempotencyKey,
    tenantId,
    sessionId,
    assetKind,
    mimeType,
    fileSizeBytes,
    sha256Hex: sha256Hex.toLowerCase(),
    widthPixels: optionalPositiveInteger(body.widthPixels),
    heightPixels: optionalPositiveInteger(body.heightPixels),
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
    const { client, userId, stepUpSessionId } =
      await authenticatedServiceSupabase(
        request,
      );
    const commandClient = client as unknown as CommandClient;
    const { data: intent, error } = await commandClient
      .schema("command_api")
      .rpc(
        "request_brand_asset_upload",
        {
          p_idempotency_key: body.idempotencyKey,
          p_actor_user_id: userId,
          p_session_id: requireStepUpSession(stepUpSessionId),
          p_tenant_id: body.tenantId,
          p_asset_kind: body.assetKind,
          p_mime_type: body.mimeType,
          p_file_size_bytes: body.fileSizeBytes,
          p_sha256_hex: body.sha256Hex,
          p_width_pixels: body.widthPixels,
          p_height_pixels: body.heightPixels,
        },
      );
    if (error !== null) throw mapDatabaseError(error);
    if (intent === null || typeof intent !== "object") {
      throw new Error("Brand asset upload intent response is missing");
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
      throw new Error("Signed brand asset upload URL could not be created");
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
