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
  role_not_invitable: 403,
  invitation_unavailable: 410,
  invitation_exists: 409,
  invitation_email_mismatch: 403,
  email_unverified: 403,
  no_wallet: 409,
  target_not_eligible: 409,
  currency_not_supported: 422,
  allocation_policy_missing: 409,
  policy_invalid: 422,
  evidence_required: 422,
  evidence_invalid: 422,
  attempt_cancelled: 409,
  insufficient_funds: 409,
  bank_unknown: 422,
  account_not_found: 422,
  provider_unavailable: 503,
  payout_lookup_expired: 409,
  payout_name_mismatch: 422,
  payout_account_exists: 409,
  payout_account_unusable: 409,
  nin_not_verified: 422,
  nin_in_use: 409,
  nin_review_required: 409,
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
  role_not_invitable: "You can't invite someone to that role.",
  invitation_unavailable: "This invitation is no longer available.",
  invitation_exists: "This person already has a pending invitation for that office and role.",
  invitation_email_mismatch: "This invitation was sent to a different email address.",
  email_unverified: "Verify your email address to continue.",
  no_wallet: "This account has no wallet.",
  target_not_eligible: "Income can't be recorded for this membership.",
  currency_not_supported: "This currency isn't supported.",
  allocation_policy_missing: "This network has no pocket split yet.",
  policy_invalid: "The pockets and percentages aren't valid.",
  evidence_required: "Attach at least one receipt.",
  evidence_invalid: "A receipt can't be used.",
  attempt_cancelled: "This attempt was cancelled.",
  insufficient_funds: "There isn't enough available in this pocket.",
  bank_unknown: "Choose a bank from the list.",
  account_not_found: "No account with that number was found at this bank.",
  provider_unavailable: "Bank lookup isn't available right now. Try again shortly.",
  payout_lookup_expired: "This account check has expired. Look the account up again.",
  payout_name_mismatch: "The name on this bank account doesn't match the name on your NIN.",
  payout_account_exists: "You've already saved this bank account.",
  payout_account_unusable: "This bank account can't receive withdrawals right now.",
  nin_not_verified: "This NIN didn't match a national ID record.",
  nin_in_use: "This NIN can't be used on this account. Contact support.",
  nin_review_required: "Ask a leader to review your NIN.",
};

const retryableCodes: ReadonlySet<ErrorCode> = new Set<ErrorCode>([
  "internal_error",
  "rate_limited",
  "provider_unavailable",
]);

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
      retryable: retryableCodes.has(code),
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
