import { DomainError } from "../../../src/shared/domain_error.ts";
import { isUuid } from "./financial.ts";

const roleKeys = new Set([
  "member",
  "team_leader",
  "director",
  "world_team_member",
  "president_team_member",
]);

export type MembershipCommand = Readonly<{
  idempotencyKey: string;
  sessionId: string;
  membershipId: string;
}>;

export type CreateMembershipCommand = Readonly<{
  idempotencyKey: string;
  sessionId: string;
  tenantId: string;
  targetUserId: string;
  officeId: string;
  roleKey: string;
}>;

export type EndMembershipCommand =
  & MembershipCommand
  & Readonly<{
    replacementPrimaryMembershipId: string | null;
  }>;

export type MoveMembershipCommand =
  & MembershipCommand
  & Readonly<{
    destinationOfficeId: string;
    destinationRoleKey: string;
  }>;

export type MembershipCommandClient = Readonly<{
  schema: (name: string) => Readonly<{
    rpc: (
      name: string,
      args: Readonly<Record<string, string | null>>,
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

function requiredRole(body: Record<string, unknown>, key: string): string {
  const value = body[key];
  if (typeof value !== "string" || !roleKeys.has(value)) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return value;
}

function parseBase(body: Record<string, unknown>): MembershipCommand {
  return {
    idempotencyKey: requiredUuid(body, "idempotencyKey"),
    sessionId: requiredUuid(body, "sessionId"),
    membershipId: requiredUuid(body, "membershipId"),
  };
}

export function parseCreateMembership(value: unknown): CreateMembershipCommand {
  const body = parseObject(value);
  return {
    idempotencyKey: requiredUuid(body, "idempotencyKey"),
    sessionId: requiredUuid(body, "sessionId"),
    tenantId: requiredUuid(body, "tenantId"),
    targetUserId: requiredUuid(body, "targetUserId"),
    officeId: requiredUuid(body, "officeId"),
    roleKey: requiredRole(body, "roleKey"),
  };
}

export function parseMembershipCommand(value: unknown): MembershipCommand {
  return parseBase(parseObject(value));
}

export function parseEndMembership(value: unknown): EndMembershipCommand {
  const body = parseObject(value);
  const base = parseBase(body);
  const replacement = body.replacementPrimaryMembershipId;
  if (replacement === undefined || replacement === null) {
    return { ...base, replacementPrimaryMembershipId: null };
  }
  if (typeof replacement !== "string" || !isUuid(replacement)) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return { ...base, replacementPrimaryMembershipId: replacement };
}

export function parseMoveMembership(value: unknown): MoveMembershipCommand {
  const body = parseObject(value);
  const base = parseBase(body);
  return {
    ...base,
    destinationOfficeId: requiredUuid(body, "destinationOfficeId"),
    destinationRoleKey: requiredRole(body, "destinationRoleKey"),
  };
}
