import { DomainError } from "../../../src/shared/domain_error.ts";

export const financialEvidenceMimeTypes = new Set([
  "application/pdf",
  "image/jpeg",
  "image/png",
]);

export function isUuid(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(value);
}

export function isSha256Hex(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{64}$/i.test(value);
}

export function sha256Hex(bytes: ArrayBuffer): Promise<string> {
  return crypto.subtle.digest("SHA-256", bytes).then((digest) =>
    Array.from(
      new Uint8Array(digest),
      (byte) => byte.toString(16).padStart(2, "0"),
    )
      .join("")
  );
}

export function mapDatabaseError(error: { code?: string }): DomainError {
  switch (error.code) {
    case "P0401":
      return new DomainError(
        "step_up_required",
        "Verify this device before continuing",
      );
    case "22023":
    case "22003":
      return new DomainError("validation_error", "The request is invalid");
    case "23505":
      return new DomainError(
        "conflict",
        "The request conflicts with existing data",
      );
    case "23514":
      return new DomainError(
        "invariant_violation",
        "The request violates a domain rule",
      );
    case "42501":
      return new DomainError(
        "authorization_denied",
        "You are not authorized for this action",
      );
    case "P0002":
      return new DomainError("not_found", "The requested record was not found");
    case "P0001":
    case "40901":
      return new DomainError(
        "conflict",
        "The request conflicts with current state",
      );
    case "55000":
      return new DomainError(
        "invariant_violation",
        "The request violates a lifecycle rule",
      );
    default:
      return new DomainError(
        "internal_error",
        "The trusted database command failed",
      );
  }
}
