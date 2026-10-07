import type { CommandClient } from "./command-client.ts";
import { DomainError } from "../../../src/shared/domain_error.ts";
import { mapDatabaseError, sha256Hex } from "./financial.ts";
import { validIncomeFile } from "./income.ts";

type Storage = {
  from: (
    bucket: string,
  ) => {
    download: (path: string) => Promise<{ data: Blob | null; error: unknown }>;
  };
};
export async function recordVerifiedIncome(
  client: CommandClient,
  storage: Storage,
  intentId: string,
  userId: string,
  stepUpSessionId: string | null,
): Promise<unknown> {
  const commands = client.schema("command_api");
  const { data, error } = await commands.rpc("income_upload_object", {
    p_intent_id: intentId,
    p_actor_user_id: userId,
    p_session_id: stepUpSessionId,
  });
  if (error) throw mapDatabaseError(error);
  if (data === null || typeof data !== "object") {
    throw new Error("Receipt intent is missing");
  }
  const object = data as {
    posted: boolean;
    bucket: string;
    path: string;
    file_size_bytes: number;
    mime_type: string;
    operation_reference: string;
    operation_id: string;
  };
  if (object.posted === true) {
    return {
      operation_reference: object.operation_reference,
      operation_id: object.operation_id,
      reused: true,
    };
  }
  if (
    object.posted !== false || object.bucket !== "financial-evidence" ||
    typeof object.path !== "string" || !object.path ||
    !Number.isSafeInteger(object.file_size_bytes) ||
    object.file_size_bytes < 1 || object.file_size_bytes > 10485760
  ) throw new Error("Receipt location is invalid");
  const { data: file, error: downloadError } = await storage.from(object.bucket)
    .download(object.path);
  if (downloadError || !file) {
    throw new DomainError(
      "validation_error",
      "Upload your receipt before recording income",
    );
  }
  if (file.size !== object.file_size_bytes || file.size > 10485760) {
    throw new DomainError(
      "validation_error",
      "The uploaded receipt does not match",
    );
  }
  const bytes = await file.arrayBuffer();
  if (!validIncomeFile(bytes, object.mime_type)) {
    throw new DomainError("validation_error", "Use a PDF, JPEG or PNG receipt");
  }
  const { data: result, error: recordError } = await commands.rpc(
    "record_uploaded_income",
    {
      p_intent_id: intentId,
      p_actor_user_id: userId,
      p_session_id: stepUpSessionId,
      p_verified_file_size_bytes: bytes.byteLength,
      p_verified_sha256_hex: await sha256Hex(bytes),
    },
  );
  if (recordError) throw mapDatabaseError(recordError);
  return result;
}
