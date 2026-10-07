import { DomainError } from "../../../src/shared/domain_error.ts";
import { isUuid, sha256Hex } from "./financial.ts";

export type AcceptInvitationCommand = Readonly<{
  idempotencyKey: string;
  token: string;
}>;

export type RevokeInvitationCommand = Readonly<{
  idempotencyKey: string;
  sessionId: string;
  invitationId: string;
}>;

export type InvitationCommandClient = Readonly<{
  schema: (name: string) => Readonly<{
    rpc: (
      name: string,
      args: Readonly<Record<string, string>>,
    ) => Promise<
      Readonly<{ data: unknown; error: Readonly<{ code?: string }> | null }>
    >;
  }>;
}>;

function parseObject(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return value as Record<string, unknown>;
}

function requiredUuid(body: Record<string, unknown>, key: string): string {
  const value = body[key];
  if (typeof value !== "string" || !isUuid(value)) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return value;
}

function requiredToken(body: Record<string, unknown>): string {
  const value = body.token;
  if (
    typeof value !== "string" ||
    value.trim().length < 16 ||
    value.length > 512
  ) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return value;
}

export function parseAcceptInvitation(
  value: unknown,
): AcceptInvitationCommand {
  const body = parseObject(value);
  return {
    idempotencyKey: requiredUuid(body, "idempotencyKey"),
    token: requiredToken(body),
  };
}

export function parseRevokeInvitation(
  value: unknown,
): RevokeInvitationCommand {
  const body = parseObject(value);
  return {
    idempotencyKey: requiredUuid(body, "idempotencyKey"),
    sessionId: requiredUuid(body, "sessionId"),
    invitationId: requiredUuid(body, "invitationId"),
  };
}

export async function invitationTokenDigest(token: string): Promise<string> {
  const bytes = new TextEncoder().encode(token).buffer as ArrayBuffer;
  return "\\x" + await sha256Hex(bytes);
}
