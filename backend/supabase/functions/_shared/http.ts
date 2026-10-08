// Wire envelope and error codes (Blueprint 01 — B5).

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
    "access-control-allow-headers": "authorization, content-type, apikey, x-client-info",
    "access-control-allow-methods": "GET, POST, OPTIONS",
    "access-control-max-age": "600",
    vary: "Origin",
  };
}
