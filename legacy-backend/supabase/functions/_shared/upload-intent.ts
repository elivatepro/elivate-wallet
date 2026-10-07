import { DomainError } from "../../../src/shared/domain_error.ts";
import type { CommandClient } from "./command-client.ts";
import { mapDatabaseError } from "./financial.ts";

// The lookup authorizes ownership before privileged Storage access. Never accept
// a bucket or object path from the request body.
export async function authorizedUploadIntent(
  client: CommandClient,
  kind: "brand" | "financial",
  intentId: string,
  actorUserId: string,
  sessionId?: string,
): Promise<{ storage_bucket_id: string; storage_object_path: string }> {
  const { data, error } = await client.schema("command_api").rpc(
    kind === "brand"
      ? "read_brand_asset_upload_intent"
      : "read_financial_upload_intent",
    {
      p_intent_id: intentId,
      p_actor_user_id: actorUserId,
      ...(kind === "brand" ? { p_session_id: sessionId } : {}),
    },
  );
  if (error !== null) throw mapDatabaseError(error);
  if (data === null || typeof data !== "object" || Array.isArray(data)) {
    throw new DomainError(
      "internal_error",
      "Upload intent response is invalid",
    );
  }
  const record = data as Record<string, unknown>;
  const expectedBucket = kind === "brand"
    ? "tenant-brand-assets"
    : "financial-evidence";
  if (
    record.storage_bucket_id !== expectedBucket ||
    typeof record.storage_object_path !== "string" ||
    !/^[0-9a-f-]{36}\/[0-9a-f-]{36}$/i.test(record.storage_object_path)
  ) {
    throw new DomainError(
      "internal_error",
      "Upload intent response is invalid",
    );
  }
  return {
    storage_bucket_id: expectedBucket,
    storage_object_path: record.storage_object_path,
  };
}

type UploadStorage = Readonly<{
  from: (bucket: string) => Readonly<{
    download: (path: string) => Promise<
      Readonly<{ data: Blob | null; error: unknown }>
    >;
  }>;
}>;

export async function downloadAuthorizedUpload(
  client: CommandClient,
  storage: UploadStorage,
  kind: "brand" | "financial",
  intentId: string,
  actorUserId: string,
  sessionId?: string,
): Promise<Blob> {
  const intent = await authorizedUploadIntent(
    client,
    kind,
    intentId,
    actorUserId,
    sessionId,
  );
  const { data, error } = await storage.from(intent.storage_bucket_id)
    .download(intent.storage_object_path);
  if (error !== null || data === null) {
    throw new DomainError(
      "validation_error",
      "The uploaded object is not available",
    );
  }
  return data;
}
