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
}

type Route = (request: Request, actor: Actor, requestId: string) => Promise<unknown>;

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

export function createHandler(deps: Deps): (request: Request) => Promise<Response> {
  async function call(fn: string, args: Record<string, unknown>): Promise<unknown> {
    const { data, error } = await deps.rpc(fn, args);
    if (error) {
      if (isErrorCode(error.message)) {
        throw new ApiError(error.message, parseDetails(error.details));
      }
      throw new Error(`rpc ${fn} failed`);
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

    "POST /pin/reset/request": async (request, actor, requestId) => {
      await v.readBody(request, []);
      const result = await call("request_pin_reset", base(actor, requestId));
      await deps.sendResetLink(actor.userId);
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
        p_reason: v.text(body, "reason", 500),
        p_idempotency_key: v.idempotencyKey(body),
      });
    },

    "POST /admin/admins/grant": (request, actor, requestId) =>
      adminChange("grant_platform_admin", request, actor, requestId),
    "POST /admin/admins/revoke": (request, actor, requestId) =>
      adminChange("revoke_platform_admin", request, actor, requestId),
  };

  async function adminChange(fn: string, request: Request, actor: Actor, requestId: string) {
    const body = await v.readBody(request, ["targetUid", "reason", "idempotencyKey"]);
    return call(fn, {
      ...base(actor, requestId),
      p_target_uid: v.uid(body, "targetUid"),
      p_reason: v.text(body, "reason", 500),
      p_idempotency_key: v.idempotencyKey(body),
    });
  }

  return async (request: Request): Promise<Response> => {
    const started = Date.now();
    const requestId = crypto.randomUUID();
    const cors = corsHeaders(request.headers.get("origin"), deps.allowedOrigins);
    const path = new URL(request.url).pathname.replace(/^.*?\/security(?=\/|$)/, "") || "/";
    const routeKey = `${request.method} ${path}`;

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
      return finish(success(await route(request, actor, requestId), requestId, cors));
    } catch (error) {
      if (error instanceof ApiError) {
        return finish(failure(error.code, requestId, error.details, cors), error.code);
      }
      return finish(failure("internal_error", requestId, {}, cors), "internal_error");
    }
  };
}
