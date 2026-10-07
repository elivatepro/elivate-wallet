import { DomainError } from "../../../src/shared/domain_error.ts";

export function objectBody(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainError(
      "validation_error",
      "Workspace request input is invalid",
    );
  }
  return value as Record<string, unknown>;
}
export function requiredString(
  body: Record<string, unknown>,
  key: string,
): string {
  const value = body[key];
  if (typeof value !== "string" || !value.trim()) {
    throw new DomainError(
      "validation_error",
      "Workspace request input is invalid",
    );
  }
  return value.trim();
}
export async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(
    new Uint8Array(digest),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
}
