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

/**
 * Text whose length, counted like Postgres `length(btrim(value))` (characters,
 * spaces trimmed), is between `min` and `max`. Matches the database rules, so
 * the Edge never accepts what Postgres rejects or the reverse.
 */
export function text(body: Body, field: string, max: number, min = 1): string {
  const value = body[field];
  if (typeof value !== "string") throw new ApiError("validation_error", { field });
  const length = [...value.replace(/^ +| +$/g, "")].length;
  if (length < min || length > max) throw new ApiError("validation_error", { field });
  return value;
}

/** A reason for a protected change: 3–500 characters (identity.require_reason). */
export function reason(body: Body, field = "reason"): string {
  return text(body, field, 500, 3);
}

/** A network or office name: 2–100 characters (org.require_text). */
export function name(body: Body, field = "name"): string {
  return text(body, field, 100, 2);
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

/** A decimal amount as a string, never a JSON number; the database checks scale and sign. */
export function decimal(body: Body, field: string): string {
  const value = body[field];
  if (
    typeof value !== "string" || !/^[0-9]{1,20}(\.[0-9]{1,18})?$/.test(value)
  ) {
    throw new ApiError("validation_error", { field });
  }
  return value;
}

export function currency(body: Body, field: string): string {
  const value = body[field];
  if (typeof value !== "string" || !/^[A-Z]{3}$/.test(value)) {
    throw new ApiError("validation_error", { field });
  }
  return value;
}

/** A calendar date `YYYY-MM-DD` that exists. */
export function date(body: Body, field: string): string {
  const value = body[field];
  if (
    typeof value !== "string" || !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(value)
  ) {
    throw new ApiError("validation_error", { field });
  }
  const parsed = new Date(`${value}T00:00:00Z`);
  if (
    Number.isNaN(parsed.getTime()) ||
    parsed.toISOString().slice(0, 10) !== value
  ) {
    throw new ApiError("validation_error", { field });
  }
  return value;
}

export function integer(
  body: Body,
  field: string,
  min: number,
  max: number,
): number {
  const value = body[field];
  if (
    typeof value !== "number" || !Number.isInteger(value) || value < min ||
    value > max
  ) {
    throw new ApiError("validation_error", { field });
  }
  return value;
}

/** Distinct UUIDs, lower-cased, between `min` and `max` of them. */
export function uuidList(
  body: Body,
  field: string,
  min: number,
  max: number,
): string[] {
  const value = body[field];
  if (!Array.isArray(value) || value.length < min || value.length > max) {
    throw new ApiError("validation_error", { field });
  }
  const ids = value.map((_, i) => uuid(value as unknown as Body, String(i)));
  if (new Set(ids).size !== ids.length) {
    throw new ApiError("validation_error", { field });
  }
  return ids;
}
