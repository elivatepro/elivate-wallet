// Minimal runtime validation for untrusted request bodies.

import { ApiError } from "./http.ts";

export type Body = Readonly<Record<string, unknown>>;

export async function readBody(
  request: Request,
  allowed: readonly string[],
): Promise<Body> {
  let parsed: unknown;
  try {
    const text = await request.text();
    parsed = text.trim() === "" ? {} : JSON.parse(text);
  } catch {
    throw new ApiError("validation_error", { field: "body" });
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new ApiError("validation_error", { field: "body" });
  }
  for (const key of Object.keys(parsed)) {
    if (!allowed.includes(key)) {
      throw new ApiError("validation_error", { field: key, reason: "unknown_field" });
    }
  }
  return parsed as Body;
}

export function pin(body: Body, field: string): string {
  const value = body[field];
  if (typeof value !== "string" || !/^[0-9]{4}$/.test(value)) {
    throw new ApiError("validation_error", { field });
  }
  return value;
}

export function matchingPins(body: Body): string {
  const first = pin(body, "pin");
  if (pin(body, "pinConfirm") !== first) {
    throw new ApiError("validation_error", { field: "pinConfirm", reason: "mismatch" });
  }
  return first;
}

export function text(body: Body, field: string, max: number): string {
  const value = body[field];
  if (typeof value !== "string" || value.trim().length === 0 || value.length > max) {
    throw new ApiError("validation_error", { field });
  }
  return value;
}

export function uuid(body: Body, field: string): string {
  const value = body[field];
  if (
    typeof value !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
  ) {
    throw new ApiError("validation_error", { field });
  }
  return value.toLowerCase();
}

export function idempotencyKey(body: Body): string {
  const value = body.idempotencyKey;
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{16,100}$/.test(value)) {
    throw new ApiError("validation_error", { field: "idempotencyKey" });
  }
  return value;
}

export function uid(body: Body, field: string): string {
  const value = body[field];
  if (typeof value !== "string" || !/^EW-[1-9][0-9]{4,}$/i.test(value.trim())) {
    throw new ApiError("validation_error", { field });
  }
  return value.trim().toUpperCase();
}
