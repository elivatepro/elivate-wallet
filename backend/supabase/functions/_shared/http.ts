// Wire envelope and error codes (Blueprint 01 — B5, Blueprint 02 — B5).

export const errorStatus = {
  validation_error: 400,
  authentication_required: 401,
  pin_setup_required: 403,
  pin_required: 403,
  pin_incorrect: 403,
  pin_locked: 423,
  step_up_required: 403,
  account_blocked: 403,
  authorization_denied: 403,
  not_found: 404,
  idempotency_conflict: 409,
  conflict: 409,
  rate_limited: 429,
  internal_error: 500,
  workspace_invalid: 403,
  hierarchy_invalid: 422,
  role_office_mismatch: 422,
  membership_exists: 409,
  last_president: 409,
  last_leader: 409,
  network_not_active: 409,
  scope_exceeds_authority: 403,
  permission_not_grantable: 422,
  self_target_forbidden: 403,
} as const;

export type ErrorCode = keyof typeof errorStatus;

const messages: Record<ErrorCode, string> = {
  validation_error: "The request is invalid.",
  authentication_required: "Sign in to continue.",
  pin_setup_required: "Set your PIN to continue.",
  pin_required: "Enter your PIN to continue.",
  pin_incorrect: "That PIN is incorrect.",
  pin_locked: "Your PIN is locked. Reset it by email.",
  step_up_required: "Enter your PIN to confirm this action.",
  account_blocked: "This account cannot be used right now.",
  authorization_denied: "You don't have permission to do this.",
  not_found: "Not found.",
  idempotency_conflict: "This request key was already used for a different request.",
  conflict: "This can't be done in the current state.",
  rate_limited: "Too many requests. Try again shortly.",
  internal_error: "Something went wrong. Try again.",
  workspace_invalid: "Choose one of your active workspaces.",
  hierarchy_invalid: "An office can only sit under a higher kind of office.",
  role_office_mismatch: "That role doesn't fit this kind of office.",
  membership_exists: "This person already has that membership.",
  last_president: "The network must keep at least one President Team Member.",
  last_leader: "The office must keep at least one leader.",
  network_not_active: "This network isn't active.",
  scope_exceeds_authority: "You can only give access within what you manage.",
  permission_not_grantable: "This permission can't be changed or given.",
  self_target_forbidden: "You can't do this to yourself.",
};

export type Details = Readonly<Record<string, unknown>>;

export class ApiError extends Error {
  constructor(
    readonly code: ErrorCode,
    readonly details: Details = {},
  ) {
    super(code);
    this.name = "ApiError";
  }
}

export function isErrorCode(value: unknown): value is ErrorCode {
  return typeof value === "string" && Object.hasOwn(errorStatus, value);
}

const baseHeaders = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff",
};

export function success(
  data: unknown,
  requestId: string,
  headers: HeadersInit = {},
): Response {
  return new Response(JSON.stringify({ ok: true, data, requestId }), {
    status: 200,
    headers: { ...baseHeaders, ...headers },
  });
}

export function failure(
  code: ErrorCode,
  requestId: string,
  details: Details = {},
  headers: HeadersInit = {},
): Response {
  const body = {
    ok: false,
    error: {
      code,
      message: messages[code],
      retryable: code === "internal_error" || code === "rate_limited",
      details,
    },
    requestId,
  };
  return new Response(JSON.stringify(body), {
    status: errorStatus[code],
    headers: { ...baseHeaders, ...headers },
  });
}

export function corsHeaders(
  origin: string | null,
  allowedOrigins: readonly string[],
): Record<string, string> {
  if (!origin || !allowedOrigins.includes(origin)) return {};
  return {
    "access-control-allow-origin": origin,
    "access-control-allow-headers":
      "authorization, content-type, apikey, x-client-info, x-membership",
    "access-control-allow-methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
    "access-control-max-age": "600",
    vary: "Origin",
  };
}
