// Routes for the `security` Edge Function (Blueprint 01 — B4). Dependencies are
// injected so tests can exercise routing, validation and error mapping.

import {
  ApiError,
  corsHeaders,
  type Details,
  failure,
  isErrorCode,
  success,
} from "../_shared/http.ts";
import { sameSecret } from "../_shared/secret.ts";
import * as v from "../_shared/validate.ts";

export interface Actor {
  readonly userId: string;
  readonly sessionId: string;
}

export type RpcResult =
  | { readonly data: unknown; readonly error: null }
  | {
    readonly data: null;
    readonly error: { readonly message: string; readonly details?: string | null };
  };

export interface LogEntry {
  readonly requestId: string;
  readonly route: string;
  readonly status: number;
  readonly code?: string;
  readonly ms: number;
}

export interface Deps {
  /** Verifies the bearer token; returns null when it is not a valid session token. */
  verifyToken(token: string): Promise<Actor | null>;
  rpc(fn: string, args: Record<string, unknown>): Promise<RpcResult>;
  pinHmac(pin: string): Promise<string>;
  /** Asks Auth to email the single-use PIN reset link to the account email. */
  sendResetLink(userId: string): Promise<void>;
  log(entry: LogEntry): void;
  readonly allowedOrigins: readonly string[];
  /**
   * Blueprint 14: shared secret only the app server (the Worker) holds. Sign-in
   * records carry the IP and place Cloudflare saw, so a user token alone may
   * not write them. Null refuses every sign-in record (fail closed).
   */
  readonly appServerSecret?: string | null;
}

type Route = (
  request: Request,
  actor: Actor,
  requestId: string,
  id?: string,
) => Promise<unknown>;

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Routes with one UUID path segment, written as `:id` in the route key. */
function routeWithId(routeKey: string): { key: string; id?: string } {
  const found = routeKey.match(/^(POST \/admin\/outbox\/)([^/]+)(\/requeue)$/);
  if (!found || !uuidPattern.test(found[2] ?? "")) return { key: routeKey };
  return { key: `${found[1]}:id${found[3]}`, id: (found[2] ?? "").toLowerCase() };
}

const signInMethods: readonly string[] = ["password", "email_link", "recovery", "sign_up"];

const ipv4 = /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/;
const ipv6 = /^[0-9A-Fa-f:.]{2,45}$/;

/** Absent or null → null; otherwise one host address (Postgres makes the final check). */
function optionalIp(body: v.Body): string | null {
  const value = body.ip;
  if (value === undefined || value === null) return null;
  if (
    typeof value !== "string" || !(ipv4.test(value) || (value.includes(":") && ipv6.test(value)))
  ) {
    throw new ApiError("validation_error", { field: "ip" });
  }
  return value;
}

/** Display text without control characters (the database refuses them too). */
function plainText(body: v.Body, field: string, max: number): string {
  const value = v.text(body, field, max);
  // deno-lint-ignore no-control-regex
  if (/[\u0000-\u001f\u007f]/.test(value)) throw new ApiError("validation_error", { field });
  return value;
}

function optionalText(body: v.Body, field: string, max: number): string | null {
  const value = body[field];
  return value === undefined || value === null ? null : plainText(body, field, max);
}

function optionalCountry(body: v.Body): string | null {
  const value = body.country;
  if (value === undefined || value === null) return null;
  if (typeof value !== "string" || !/^[A-Z][A-Z0-9]$/.test(value)) {
    throw new ApiError("validation_error", { field: "country" });
  }
  return value;
}

function parseDetails(raw: string | null | undefined): Details {
  if (!raw) return {};
  try {
    const parsed: unknown = JSON.parse(raw);
    return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)
      ? parsed as Details
      : {};
  } catch {
    return {};
  }
}

function noQuery(request: Request): void {
  for (const key of new URL(request.url).searchParams.keys()) {
    throw new ApiError("validation_error", { field: key, reason: "unknown_field" });
  }
}

/** Blueprint 20: the selected workspace, optional; a malformed one is refused. */
function optionalMembership(request: Request): string | null {
  const value = request.headers.get("x-membership");
  if (value === null) return null;
  if (!uuidPattern.test(value)) throw new ApiError("workspace_invalid");
  return value.toLowerCase();
}

const bootstrapKeys = ["state", "profile", "workspace", "capabilities", "brand"] as const;

/** Output check: exactly the five parts, objects or null, and never a photo's storage key. */
function bootstrapShape(result: Record<string, unknown>): Record<string, unknown> {
  const keys = Object.keys(result).sort();
  const parts = bootstrapKeys.map((k) => result[k]);
  if (
    keys.join() !== [...bootstrapKeys].sort().join() ||
    typeof result.state !== "object" || result.state === null ||
    parts.some((p) => p !== null && (typeof p !== "object" || Array.isArray(p))) ||
    (typeof result.profile === "object" && result.profile !== null && "photoKey" in result.profile)
  ) {
    throw new Error("app_bootstrap returned an unexpected result");
  }
  return result;
}

export function createHandler(deps: Deps): (request: Request) => Promise<Response> {
  async function call(fn: string, args: Record<string, unknown>): Promise<unknown> {
    const { data, error } = await deps.rpc(fn, args);
    if (error) {
      if (isErrorCode(error.message)) {
        throw new ApiError(error.message, parseDetails(error.details));
      }
      throw new Error(`rpc ${fn} failed`);
    }
    // Every command returns a JSON object or array; anything else is contract drift.
    if (typeof data !== "object" || data === null) {
      throw new Error(`rpc ${fn} returned an unexpected result`);
    }
    return data;
  }

  const base = (actor: Actor, requestId: string) => ({
    p_user_id: actor.userId,
    p_session_id: actor.sessionId,
    p_request_id: requestId,
  });

  const routes: Record<string, Route> = {
    "GET /state": (_r, actor) =>
      call("security_state", { p_user_id: actor.userId, p_session_id: actor.sessionId }),

    // Blueprint 20: opening the app in one read — the state, then (once the
    // PIN gate is ready) the profile, the workspace, its capabilities and its
    // brand. The workspace (X-Membership) is optional.
    "GET /bootstrap": async (request, actor) => {
      noQuery(request);
      const result = await call("app_bootstrap", {
        p_user_id: actor.userId,
        p_session_id: actor.sessionId,
        p_membership_id: optionalMembership(request),
      }) as Record<string, unknown>;
      return bootstrapShape(result);
    },

    "POST /pin/set": async (request, actor, requestId) => {
      const pin = v.matchingPins(await v.readBody(request, ["pin", "pinConfirm"]));
      return call("set_pin", { ...base(actor, requestId), p_pin_hmac: await deps.pinHmac(pin) });
    },

    "POST /pin/verify": async (request, actor, requestId) => {
      const pin = v.pin(await v.readBody(request, ["pin"]), "pin");
      const result = await call("verify_pin", {
        ...base(actor, requestId),
        p_pin_hmac: await deps.pinHmac(pin),
      }) as { ok?: boolean; code?: unknown; attemptsRemaining?: unknown; state?: unknown };
      if (result?.ok === true) return result.state;
      if (result?.code === "pin_incorrect" || result?.code === "pin_locked") {
        throw new ApiError(result.code, { attemptsRemaining: result.attemptsRemaining });
      }
      throw new Error("verify_pin returned an unexpected result");
    },

    // Blueprint 10: change the PIN while signed in (current PIN, then the new one twice).
    "POST /pin/change": async (request, actor, requestId) => {
      const body = await v.readBody(request, ["currentPin", "pin", "pinConfirm"]);
      const current = v.pin(body, "currentPin");
      const next = v.matchingPins(body);
      if (next === current) {
        throw new ApiError("validation_error", { field: "pin", reason: "same_pin" });
      }
      const result = await call("change_pin", {
        ...base(actor, requestId),
        p_current_pin_hmac: await deps.pinHmac(current),
        p_new_pin_hmac: await deps.pinHmac(next),
      }) as { ok?: boolean; code?: unknown; attemptsRemaining?: unknown; state?: unknown };
      if (result?.ok === true) return result.state;
      if (result?.code === "pin_incorrect" || result?.code === "pin_locked") {
        throw new ApiError(result.code, { attemptsRemaining: result.attemptsRemaining });
      }
      throw new Error("change_pin returned an unexpected result");
    },

    "POST /pin/reset/request": async (request, actor, requestId) => {
      await v.readBody(request, []);
      const result = await call("request_pin_reset", base(actor, requestId));
      try {
        await deps.sendResetLink(actor.userId);
      } catch {
        // No email went out: withdraw the request so the 60-second cooldown
        // does not block an immediate retry, and say so explicitly.
        await call("cancel_pin_reset", base(actor, requestId)).catch(() => undefined);
        throw new ApiError("internal_error", { emailSent: false });
      }
      return result;
    },

    "POST /pin/reset/complete": async (request, actor, requestId) => {
      const pin = v.matchingPins(await v.readBody(request, ["pin", "pinConfirm"]));
      return call("complete_pin_reset", {
        ...base(actor, requestId),
        p_pin_hmac: await deps.pinHmac(pin),
      });
    },

    "GET /sessions": (_r, actor) =>
      call("list_sessions", { p_user_id: actor.userId, p_session_id: actor.sessionId }),

    "POST /sessions/revoke": async (request, actor, requestId) => {
      const body = await v.readBody(request, ["sessionId", "allOthers"]);
      const allOthers = body.allOthers === true;
      if (allOthers === ("sessionId" in body)) {
        throw new ApiError("validation_error", { field: "sessionId" });
      }
      return call("revoke_sessions", {
        ...base(actor, requestId),
        p_target_session_id: allOthers ? null : v.uuid(body, "sessionId"),
        p_all_others: allOthers,
      });
    },

    // Blueprint 14: the app server records each new Auth session (before the
    // PIN) with the IP and approximate location Cloudflare saw.
    "POST /sign-ins": async (request, actor, requestId) => {
      const given = request.headers.get("x-app-server-secret");
      if (!deps.appServerSecret || !given || !(await sameSecret(given, deps.appServerSecret))) {
        throw new ApiError("authorization_denied", { reason: "app_server_only" });
      }
      const body = await v.readBody(request, [
        "method",
        "ip",
        "city",
        "country",
        "device",
        "userAgent",
      ]);
      const method = v.text(body, "method", 20);
      if (!signInMethods.includes(method)) {
        throw new ApiError("validation_error", { field: "method" });
      }
      return call("record_sign_in", {
        ...base(actor, requestId),
        p_method: method,
        p_ip: optionalIp(body),
        p_city: optionalText(body, "city", 100),
        p_country: optionalCountry(body),
        p_device: plainText(body, "device", 60),
        p_user_agent: optionalText(body, "userAgent", 1000)?.slice(0, 300) ?? null,
      });
    },

    "GET /overview": (_r, actor) =>
      call("security_overview", { p_user_id: actor.userId, p_session_id: actor.sessionId }),

    // Blueprint 14: change the password while signed in. Step 1 proves the
    // PIN; the app server then saves the password through Supabase Auth and
    // records it (step 2). The password never reaches this function.
    "POST /password/authorize": async (request, actor, requestId) => {
      const pin = v.pin(await v.readBody(request, ["pin"]), "pin");
      const result = await call("authorize_password_change", {
        ...base(actor, requestId),
        p_pin_hmac: await deps.pinHmac(pin),
      }) as { ok?: boolean; code?: unknown; attemptsRemaining?: unknown; changeId?: unknown };
      if (result?.ok === true && typeof result.changeId === "string") {
        return { changeId: result.changeId };
      }
      if (result?.code === "pin_incorrect" || result?.code === "pin_locked") {
        throw new ApiError(result.code, { attemptsRemaining: result.attemptsRemaining });
      }
      throw new Error("authorize_password_change returned an unexpected result");
    },

    "POST /password/changed": async (request, actor, requestId) => {
      const body = await v.readBody(request, ["changeId", "recovery"]);
      const recovery = body.recovery === true;
      if (recovery === ("changeId" in body) || ("recovery" in body && !recovery)) {
        throw new ApiError("validation_error", { field: "changeId" });
      }
      return call("record_password_change", {
        ...base(actor, requestId),
        p_change_id: recovery ? null : v.uuid(body, "changeId"),
        p_recovery: recovery,
      });
    },

    "POST /admin/accounts/status": async (request, actor, requestId) => {
      const body = await v.readBody(request, ["targetUid", "status", "reason", "idempotencyKey"]);
      const status = v.text(body, "status", 20);
      if (!["active", "restricted", "suspended", "deactivated"].includes(status)) {
        throw new ApiError("validation_error", { field: "status" });
      }
      return call("set_account_status", {
        ...base(actor, requestId),
        p_target_uid: v.uid(body, "targetUid"),
        p_status: status,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    },

    "POST /admin/admins/grant": (request, actor, requestId) =>
      adminChange("grant_platform_admin", request, actor, requestId),
    "POST /admin/admins/revoke": (request, actor, requestId) =>
      adminChange("revoke_platform_admin", request, actor, requestId),

    // Blueprint 03: dead-lettered emails (platform admins).
    "GET /admin/outbox": (request, actor) => {
      const query = new URL(request.url).searchParams;
      for (const key of query.keys()) {
        if (key !== "limit") {
          throw new ApiError("validation_error", { field: key, reason: "unknown_field" });
        }
      }
      const limit = query.get("limit");
      if (limit !== null && !/^[0-9]{1,3}$/.test(limit)) {
        throw new ApiError("validation_error", { field: "limit" });
      }
      return call("outbox_dead_letters", {
        p_user_id: actor.userId,
        p_session_id: actor.sessionId,
        p_limit: limit === null ? null : Number(limit),
      });
    },

    "POST /admin/outbox/:id/requeue": async (request, actor, requestId, id) => {
      const body = await v.readBody(request, ["reason", "idempotencyKey"]);
      return call("outbox_requeue", {
        ...base(actor, requestId),
        p_event_id: id,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    },
  };

  async function adminChange(fn: string, request: Request, actor: Actor, requestId: string) {
    const body = await v.readBody(request, ["targetUid", "reason", "idempotencyKey"]);
    return call(fn, {
      ...base(actor, requestId),
      p_target_uid: v.uid(body, "targetUid"),
      p_reason: v.reason(body),
      p_idempotency_key: v.idempotencyKey(body),
    });
  }

  return async (request: Request): Promise<Response> => {
    const started = Date.now();
    const requestId = crypto.randomUUID();
    const cors = corsHeaders(request.headers.get("origin"), deps.allowedOrigins);
    const path = new URL(request.url).pathname.replace(/^.*?\/security(?=\/|$)/, "") || "/";
    const { key: routeKey, id } = routeWithId(`${request.method} ${path}`);

    const finish = (response: Response, code?: string): Response => {
      deps.log({
        requestId,
        route: routes[routeKey] ? routeKey : "unknown",
        status: response.status,
        ...(code ? { code } : {}),
        ms: Date.now() - started,
      });
      return response;
    };

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: cors });
    }

    const route = routes[routeKey];
    if (!route) return finish(failure("not_found", requestId, {}, cors), "not_found");

    try {
      const token = request.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1];
      const actor = token ? await deps.verifyToken(token) : null;
      if (!actor) throw new ApiError("authentication_required");
      return finish(success(await route(request, actor, requestId, id), requestId, cors));
    } catch (error) {
      if (error instanceof ApiError) {
        return finish(failure(error.code, requestId, error.details, cors), error.code);
      }
      return finish(failure("internal_error", requestId, {}, cors), "internal_error");
    }
  };
}
