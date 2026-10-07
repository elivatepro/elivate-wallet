import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  financialEvidenceMimeTypes,
  isSha256Hex,
  isUuid,
  mapDatabaseError,
  sha256Hex,
} from "./financial.ts";
import { validIncomeFile } from "./income.ts";
import type { CommandClient } from "./command-client.ts";

const invalid = () =>
  new DomainError("validation_error", "Check the payout and receipt details");
function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw invalid();
  }
  return value as Record<string, unknown>;
}
function only(body: Record<string, unknown>, fields: readonly string[]) {
  if (Object.keys(body).some((key) => !fields.includes(key))) throw invalid();
}
const decimal = /^(0|[1-9][0-9]{0,19})(\.[0-9]{1,18})?$/;
function amount(value: unknown, positive: boolean) {
  if (
    typeof value !== "string" || !decimal.test(value) ||
    (positive && !/[1-9]/.test(value))
  ) throw invalid();
  return value;
}
function optionalText(value: unknown, limit: number) {
  if (value == null) return null;
  if (typeof value !== "string" || value.length > limit) throw invalid();
  return value.trim() || null;
}
export function parsePayoutUpload(value: unknown) {
  const body = record(value);
  only(body, [
    "idempotencyKey",
    "withdrawalId",
    "operation",
    "payoutAssertionId",
    "facts",
    "files",
  ]);
  if (
    !isUuid(body.idempotencyKey) || !isUuid(body.withdrawalId) ||
    (body.operation !== "submit" && body.operation !== "correct") ||
    (body.operation === "correct"
      ? !isUuid(body.payoutAssertionId)
      : body.payoutAssertionId != null)
  ) throw invalid();
  const facts = record(body.facts);
  only(facts, [
    "walletDebitAmount",
    "beneficiaryPayoutAmount",
    "payoutCurrency",
    "provider",
    "paidAt",
    "providerFeeAmount",
    "providerReference",
    "notes",
  ]);
  if (
    typeof facts.payoutCurrency !== "string" ||
    !/^[A-Z]{3}$/.test(facts.payoutCurrency) ||
    typeof facts.provider !== "string" || facts.provider.trim().length < 1 ||
    facts.provider.length > 100 ||
    typeof facts.paidAt !== "string" ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(facts.paidAt) ||
    !Number.isFinite(Date.parse(facts.paidAt)) ||
    new Date(facts.paidAt).toISOString() !== facts.paidAt ||
    !Array.isArray(body.files) || body.files.length < 1 ||
    body.files.length > 20
  ) throw invalid();
  const files = body.files.map((value: unknown) => {
    const file = record(value);
    only(file, ["originalFilename", "mimeType", "fileSizeBytes", "sha256Hex"]);
    if (
      typeof file.originalFilename !== "string" ||
      !file.originalFilename.trim() || file.originalFilename.length > 255 ||
      typeof file.mimeType !== "string" ||
      !financialEvidenceMimeTypes.has(file.mimeType) ||
      typeof file.fileSizeBytes !== "number" ||
      !Number.isSafeInteger(file.fileSizeBytes) || file.fileSizeBytes < 1 ||
      file.fileSizeBytes > 10485760 ||
      !isSha256Hex(file.sha256Hex)
    ) throw invalid();
    return {
      originalFilename: file.originalFilename.trim(),
      mimeType: file.mimeType,
      fileSizeBytes: file.fileSizeBytes,
      sha256Hex: file.sha256Hex.toLowerCase(),
    };
  });
  return {
    p_idempotency_key: body.idempotencyKey,
    p_withdrawal_id: body.withdrawalId,
    p_operation: body.operation,
    p_payout_assertion_id: body.payoutAssertionId ?? null,
    p_facts: {
      walletDebitAmount: amount(facts.walletDebitAmount, true),
      beneficiaryPayoutAmount: amount(facts.beneficiaryPayoutAmount, true),
      payoutCurrency: facts.payoutCurrency,
      provider: facts.provider.trim(),
      paidAt: facts.paidAt,
      providerFeeAmount: amount(facts.providerFeeAmount, false),
      providerReference: optionalText(facts.providerReference, 255),
      notes: optionalText(facts.notes, 2000),
    },
    p_files: files,
  };
}
export function parsePayoutFinalize(value: unknown) {
  const body = record(value);
  only(body, ["stageId", "idempotencyKey"]);
  if (!isUuid(body.stageId) || body.idempotencyKey !== body.stageId) {
    throw invalid();
  }
  return body.stageId;
}
export function parsePayoutDownload(value: unknown) {
  const body = record(value);
  only(body, ["membershipId", "evidenceId"]);
  if (!isUuid(body.membershipId) || !isUuid(body.evidenceId)) throw invalid();
  return {
    p_actor_membership_id: body.membershipId,
    p_evidence_id: body.evidenceId,
  };
}
export type PayoutFile = {
  fileId: string;
  bucket: "financial-evidence";
  path: string;
  originalFilename: string;
  mimeType: string;
  fileSizeBytes: number;
  sha256Hex: string;
};
export function payoutStage(value: unknown) {
  const stage = record(value);
  if (
    !isUuid(stage.stageId) || typeof stage.expiresAt !== "string" ||
    typeof stage.finalized !== "boolean" ||
    typeof stage.expired !== "boolean" || (stage.finalized && stage.expired) ||
    (stage.operation !== "submit" && stage.operation !== "correct") ||
    !Array.isArray(stage.files) ||
    (stage.expired ? stage.files.length !== 0 : stage.files.length < 1) ||
    stage.files.length > 20
  ) throw new Error("Receipt stage is invalid");
  const files: PayoutFile[] = stage.files.map((value: unknown) => {
    const file = record(value);
    if (
      !isUuid(file.fileId) || file.bucket !== "financial-evidence" ||
      typeof file.path !== "string" ||
      !/^[0-9a-f-]{36}\/payout\/[0-9a-f-]{36}\/[0-9a-f-]{36}$/.test(
        file.path,
      ) ||
      typeof file.originalFilename !== "string" ||
      typeof file.mimeType !== "string" ||
      !financialEvidenceMimeTypes.has(file.mimeType) ||
      typeof file.fileSizeBytes !== "number" ||
      !Number.isSafeInteger(file.fileSizeBytes) || file.fileSizeBytes < 1 ||
      file.fileSizeBytes > 10485760 || !isSha256Hex(file.sha256Hex)
    ) throw new Error("Receipt location is invalid");
    return {
      fileId: file.fileId,
      bucket: file.bucket,
      path: file.path,
      originalFilename: file.originalFilename,
      mimeType: file.mimeType,
      fileSizeBytes: file.fileSizeBytes,
      sha256Hex: file.sha256Hex,
    };
  });
  return {
    stageId: stage.stageId,
    expiresAt: stage.expiresAt,
    finalized: stage.finalized,
    expired: stage.expired,
    operation: stage.operation,
    files,
  };
}
type Storage = {
  from: (
    bucket: string,
  ) => {
    download: (path: string) => Promise<{ data: Blob | null; error: unknown }>;
  };
};
export async function finalizeVerifiedPayout(
  client: CommandClient,
  storage: Storage,
  stageId: string,
  userId: string,
  sessionId: string | null,
  expectedOperation?: "submit" | "correct",
) {
  const commands = client.schema("command_api");
  const lookup = await commands.rpc("payout_upload_objects", {
    p_stage_id: stageId,
    p_actor_user_id: userId,
    p_session_id: sessionId,
  });
  if (lookup.error) throw mapDatabaseError(lookup.error);
  const stage = payoutStage(lookup.data);
  if (
    stage.expired || stage.stageId !== stageId ||
    (expectedOperation && stage.operation !== expectedOperation)
  ) throw invalid();
  const verified = [];
  if (!stage.finalized) {
    // Sequential verification bounds peak memory to one maximum 10 MiB receipt.
    for (const expected of stage.files) {
      const { data: file, error } = await storage.from(expected.bucket)
        .download(expected.path);
      if (error || !file) {
        throw new DomainError(
          "validation_error",
          "Upload every receipt before submitting",
        );
      }
      if (
        file.size !== expected.fileSizeBytes || file.type !== expected.mimeType
      ) throw invalid();
      const bytes = await file.arrayBuffer();
      if (!validIncomeFile(bytes, expected.mimeType)) {
        throw new DomainError(
          "validation_error",
          "Use a PDF, JPEG or PNG receipt",
        );
      }
      const hash = await sha256Hex(bytes);
      if (hash !== expected.sha256Hex) {
        throw new DomainError(
          "validation_error",
          "The uploaded receipt does not match",
        );
      }
      verified.push({
        fileId: expected.fileId,
        mimeType: expected.mimeType,
        fileSizeBytes: bytes.byteLength,
        sha256Hex: hash,
      });
    }
  }
  const result = await commands.rpc("finalize_payout_evidence", {
    p_stage_id: stageId,
    p_actor_user_id: userId,
    p_session_id: sessionId,
    p_verified_files: verified,
  });
  if (result.error) throw mapDatabaseError(result.error);
  return result.data;
}
