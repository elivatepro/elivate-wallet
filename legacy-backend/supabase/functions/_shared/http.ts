import { DomainError } from "../../../src/shared/domain_error.ts";

export type HttpSuccess<T> = Readonly<{
  ok: true;
  requestId: string;
  data: T;
}>;

export type HttpFailure = Readonly<{
  ok: false;
  requestId: string;
  error: Readonly<{
    code: string;
    message: string;
    retryable: boolean;
    details: Readonly<Record<string, unknown>>;
  }>;
}>;

const requestIdPattern = /^[A-Za-z0-9._:-]{1,128}$/;

export function requestIdFor(request: Request): string {
  const supplied = request.headers.get("x-request-id");
  return supplied !== null && requestIdPattern.test(supplied)
    ? supplied
    : crypto.randomUUID();
}

export function corsHeaders(request: Request): HeadersInit {
  let configuredOriginValue: string | undefined;
  try {
    configuredOriginValue = Deno.env.get("CORS_ORIGINS");
  } catch {
    configuredOriginValue = undefined;
  }
  const configuredOrigins = (configuredOriginValue ??
    "http://localhost:5173,https://app.elivatewallet.com")
    .split(",")
    .map((origin) => origin.trim())
    .filter((origin) => origin.length > 0);
  const requestOrigin = request.headers.get("origin");
  const allowOrigin = requestOrigin !== null &&
      configuredOrigins.includes(requestOrigin)
    ? requestOrigin
    : configuredOrigins[0] ?? "null";

  return {
    "access-control-allow-headers": "authorization, content-type, x-request-id",
    "access-control-allow-methods": "GET, OPTIONS",
    "access-control-allow-origin": allowOrigin,
    "content-type": "application/json; charset=utf-8",
    vary: "Origin",
  };
}

export function optionsResponse(request: Request): Response {
  return new Response(null, { status: 204, headers: corsHeaders(request) });
}

export function successResponse<T>(
  request: Request,
  requestId: string,
  data: T,
  status = 200,
): Response {
  const body: HttpSuccess<T> = { ok: true, requestId, data };
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(request), "x-request-id": requestId },
  });
}

export function failureResponse(
  request: Request,
  requestId: string,
  error: unknown,
): Response {
  const domainError = error instanceof DomainError
    ? error
    : new DomainError("internal_error", "An internal error occurred", {
      cause: error,
    });
  const body: HttpFailure = {
    ok: false,
    requestId,
    error: domainError.toJSON(),
  };
  const status = domainError.code === "authentication_required"
    ? 401
    : domainError.code === "authorization_denied" ||
        domainError.code === "step_up_required"
    ? 403
    : domainError.code === "not_found"
    ? 404
    : domainError.code === "conflict"
    ? 409
    : domainError.code === "validation_error"
    ? 400
    : 500;
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(request), "x-request-id": requestId },
  });
}
