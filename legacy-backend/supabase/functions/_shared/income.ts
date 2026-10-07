import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  financialEvidenceMimeTypes,
  isSha256Hex,
  isUuid,
} from "./financial.ts";

const invalid = () =>
  new DomainError("validation_error", "Check the income and receipt details");
export function parseIncomeUpload(value: unknown) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw invalid();
  }
  const b = value as Record<string, unknown>;
  const fields = [
    "idempotencyKey",
    "targetMembershipId",
    "currencyCode",
    "grossAmount",
    "originalFilename",
    "mimeType",
    "fileSizeBytes",
    "sha256Hex",
    "observedAt",
    "providerReference",
  ];
  if (
    Object.keys(b).some((key) => !fields.includes(key)) ||
    !isUuid(b.idempotencyKey) || !isUuid(b.targetMembershipId) ||
    typeof b.currencyCode !== "string" || !/^[A-Z]{3}$/.test(b.currencyCode) ||
    typeof b.grossAmount !== "string" ||
    !/^(0|[1-9][0-9]{0,19})(\.[0-9]{1,18})?$/.test(b.grossAmount) ||
    !/[1-9]/.test(b.grossAmount) ||
    typeof b.originalFilename !== "string" ||
    b.originalFilename.trim().length < 1 || b.originalFilename.length > 255 ||
    typeof b.mimeType !== "string" ||
    !financialEvidenceMimeTypes.has(b.mimeType) ||
    typeof b.fileSizeBytes !== "number" ||
    !Number.isSafeInteger(b.fileSizeBytes) || b.fileSizeBytes < 1 ||
    b.fileSizeBytes > 10485760 ||
    !isSha256Hex(b.sha256Hex) || typeof b.observedAt !== "string" ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(b.observedAt) ||
    !Number.isFinite(Date.parse(b.observedAt)) ||
    new Date(b.observedAt).toISOString() !== b.observedAt ||
    typeof b.providerReference !== "string" || b.providerReference.length > 200
  ) throw invalid();
  return {
    p_idempotency_key: b.idempotencyKey,
    p_target_membership_id: b.targetMembershipId,
    p_currency_code: b.currencyCode,
    p_gross_amount: b.grossAmount,
    p_original_filename: b.originalFilename.trim(),
    p_mime_type: b.mimeType,
    p_file_size_bytes: b.fileSizeBytes,
    p_sha256_hex: b.sha256Hex.toLowerCase(),
    p_observed_at: b.observedAt,
    p_provider_reference: b.providerReference.trim(),
  };
}
export function parseIncomeSubmit(value: unknown): string {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw invalid();
  }
  const body = value as Record<string, unknown>;
  if (Object.keys(body).length !== 1 || !isUuid(body.uploadIntentId)) {
    throw invalid();
  }
  return body.uploadIntentId;
}

export function validIncomeFile(bytes: ArrayBufferLike, mime: string): boolean {
  const b = new Uint8Array(bytes);
  if (mime === "application/pdf") {
    return b.length >= 5 && new TextDecoder().decode(b.slice(0, 5)) === "%PDF-";
  }
  if (mime === "image/jpeg") {
    return b.length >= 3 && b[0] === 255 && b[1] === 216 && b[2] === 255;
  }
  if (mime === "image/png") {
    return [137, 80, 78, 71, 13, 10, 26, 10].every((v, i) => b[i] === v);
  }
  return false;
}
