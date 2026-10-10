// Routes for the `identity` Edge Function (Blueprint 06 — B3): the signed-in
// person's profile, NIN verification and leader review, and the bell
// (Blueprint 13). The raw NIN exists
// only in memory here: the database receives a keyed fingerprint and the last
// 4 digits. Logs carry route, status, code and latency only.

import {
  ApiError,
  corsHeaders,
  type Details,
  failure,
  isErrorCode,
  success,
} from "../_shared/http.ts";
import { ninPattern, type NinProvider } from "../_shared/nin_provider.ts";
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
  readonly providerShape?: readonly string[];
}

export interface Deps {
  verifyToken(token: string): Promise<Actor | null>;
  rpc(fn: string, args: Record<string, unknown>): Promise<RpcResult>;
  log(entry: LogEntry): void;
  readonly allowedOrigins: readonly string[];
  /** Null when NUBAN_KYC_API_KEY is not configured: checks answer provider_unavailable. */
  readonly provider: NinProvider | null;
  fingerprint(nin: string): Promise<string>;
}

interface Context {
  readonly request: Request;
  readonly actor: Actor;
  readonly requestId: string;
  readonly params: Readonly<Record<string, string>>;
  readonly query: URLSearchParams;
  /** Set by a route to record the provider's key shape on an unusable answer. */
  providerShape?: readonly string[];
}

type Handler = (context: Context) => Promise<unknown>;

interface Route {
  readonly method: string;
  readonly pattern: string;
  readonly handler: Handler;
}

type Json = Readonly<Record<string, unknown>>;

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const photoKeyPattern =
  /^photos\/[0-9a-f-]{36}\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$/;

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

function match(pattern: string, path: string): Record<string, string> | null {
  const want = pattern.split("/");
  const got = path.split("/");
  if (want.length !== got.length) return null;
  const params: Record<string, string> = {};
  for (let i = 0; i < want.length; i++) {
    const w = want[i] ?? "";
    const g = got[i] ?? "";
    if (w.startsWith(":")) {
      if (!uuidPattern.test(g)) return null;
      params[w.slice(1)] = g.toLowerCase();
    } else if (w !== g) {
      return null;
    }
  }
  return params;
}

function workspace(request: Request): string {
  const value = request.headers.get("x-membership");
  if (!value || !uuidPattern.test(value)) throw new ApiError("workspace_invalid");
  return value.toLowerCase();
}

function onlyQuery(query: URLSearchParams, allowed: readonly string[]): void {
  for (const key of query.keys()) {
    if (!allowed.includes(key)) {
      throw new ApiError("validation_error", { field: key, reason: "unknown_field" });
    }
  }
}

/** 11 digits, given as a string (spaces allowed; numbers would lose leading zeros). */
function nin(body: v.Body): string {
  const value = body.nin;
  const digits = typeof value === "string" ? value.replace(/\s/g, "") : "";
  if (!ninPattern.test(digits)) throw new ApiError("validation_error", { field: "nin" });
  return digits;
}

function middleNames(body: v.Body): string[] {
  const value = body.middleNames;
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value) || value.length > 4) {
    throw new ApiError("validation_error", { field: "middleNames" });
  }
  return value.map((part) => {
    if (typeof part !== "string" || part.trim().length < 1 || part.trim().length > 80) {
      throw new ApiError("validation_error", { field: "middleNames" });
    }
    return part;
  });
}

function asObject(value: unknown): Json {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("unexpected result shape");
  }
  return value as Json;
}

/** Profile as the client sees it: the storage key never leaves the server side. */
function publicProfile(profile: Json): Json {
  const { photoKey, ...rest } = profile;
  return { ...rest, hasPhoto: typeof photoKey === "string" };
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
  const callObject = async (fn: string, args: Record<string, unknown>) =>
    asObject(await call(fn, args));

  const actorArgs = ({ actor }: Context) => ({
    p_user_id: actor.userId,
    p_session_id: actor.sessionId,
  });

  const route = (method: string, pattern: string, handler: Handler): Route => ({
    method,
    pattern,
    handler,
  });

  async function decide(c: Context, membershipId: string | null): Promise<Json> {
    const body = await v.readBody(c.request, ["decision", "reason", "idempotencyKey"]);
    const decision = body.decision;
    if (decision !== "approve" && decision !== "reject") {
      throw new ApiError("validation_error", { field: "decision" });
    }
    return callObject("decide_nin_review", {
      ...actorArgs(c),
      p_membership_id: membershipId,
      p_review_id: c.params.id,
      p_decision: decision,
      p_reason: v.reason(body),
      p_idempotency_key: v.idempotencyKey(body),
      p_request_id: c.requestId,
    });
  }

  const routes: Route[] = [
    route("GET", "/profile", async (c) => {
      onlyQuery(c.query, []);
      return publicProfile(await callObject("my_profile", actorArgs(c)));
    }),

    // Server-side only (the app server streams the photo): includes the key.
    route("GET", "/profile/photo-key", async (c) => {
      onlyQuery(c.query, []);
      const profile = await callObject("my_profile", actorArgs(c));
      return { photoKey: typeof profile.photoKey === "string" ? profile.photoKey : null };
    }),

    // Wizard Welcome (allowed before the PIN): the caller's own membership.
    route("GET", "/onboarding/workspace", (c) => {
      onlyQuery(c.query, []);
      return call("onboarding_workspace", {
        ...actorArgs(c),
        p_membership_id: workspace(c.request),
      });
    }),

    route("PATCH", "/profile", async (c) => {
      const body = await v.readBody(c.request, [
        "displayName",
        "firstName",
        "lastName",
        "phone",
        "rank",
        "idempotencyKey",
      ]);
      const changes: Record<string, unknown> = {};
      if ("displayName" in body) {
        changes.displayName = body.displayName === null ? null : v.text(body, "displayName", 80);
      }
      // Blueprint 22: the light setup names the person (refused once a NIN locked it).
      if ("firstName" in body) changes.firstName = v.text(body, "firstName", 80);
      if ("lastName" in body) changes.lastName = v.text(body, "lastName", 80);
      if ("phone" in body) changes.phone = v.text(body, "phone", 20, 7);
      if ("rank" in body) changes.rank = v.text(body, "rank", 40);
      if (Object.keys(changes).length === 0) {
        throw new ApiError("validation_error", { field: "changes" });
      }
      return publicProfile(
        await callObject("update_profile", {
          ...actorArgs(c),
          p_changes: changes,
          p_idempotency_key: v.idempotencyKey(body),
          p_request_id: c.requestId,
        }),
      );
    }),

    route("POST", "/profile/photo", async (c) => {
      const body = await v.readBody(c.request, ["photoKey"]);
      const key = body.photoKey;
      if (typeof key !== "string" || !photoKeyPattern.test(key)) {
        throw new ApiError("validation_error", { field: "photoKey" });
      }
      return callObject("set_profile_photo", {
        ...actorArgs(c),
        p_photo_key: key,
        p_request_id: c.requestId,
      });
    }),

    route("POST", "/nin/verify", async (c) => {
      const body = await v.readBody(c.request, ["nin"]);
      const value = nin(body);
      const fingerprint = await deps.fingerprint(value);
      const last4 = value.slice(-4);

      const ready = await callObject("prepare_nin_check", {
        ...actorArgs(c),
        p_fingerprint: fingerprint,
        p_last4: last4,
      });
      if (ready.blocked === "nin_in_use") throw new ApiError("nin_in_use");
      if (ready.ready !== true) throw new Error("unexpected prepare result");

      if (!deps.provider) throw new ApiError("provider_unavailable");
      const outcome = await deps.provider.verify(value);
      if (outcome.kind === "unavailable") {
        if (outcome.shape) c.providerShape = outcome.shape;
        throw new ApiError("provider_unavailable");
      }
      const result = await callObject("record_nin_check", {
        ...actorArgs(c),
        p_fingerprint: fingerprint,
        p_last4: last4,
        p_outcome: outcome.kind === "found" ? "verified" : "not_found",
        p_given: outcome.kind === "found" ? outcome.record.givenName : null,
        p_middle: outcome.kind === "found" ? outcome.record.middleNames : null,
        p_surname: outcome.kind === "found" ? outcome.record.surname : null,
        p_phone: outcome.kind === "found" ? outcome.record.phone : null,
        p_request_id: c.requestId,
      });
      if (result.status === "in_use") throw new ApiError("nin_in_use");
      if (result.status === "not_verified") {
        throw new ApiError("nin_not_verified", { checksRemaining: result.checksRemaining });
      }
      if (result.status !== "verified") throw new Error("unexpected record result");
      return { status: "verified", identity: result.identity };
    }),

    route("POST", "/nin/review", async (c) => {
      const body = await v.readBody(c.request, [
        "nin",
        "givenName",
        "middleNames",
        "surname",
        "idempotencyKey",
      ]);
      const value = nin(body);
      return callObject("request_nin_review", {
        ...actorArgs(c),
        p_membership_id: workspace(c.request),
        p_fingerprint: await deps.fingerprint(value),
        p_last4: value.slice(-4),
        p_given: v.text(body, "givenName", 80),
        p_middle: middleNames(body),
        p_surname: v.text(body, "surname", 80),
        p_idempotency_key: v.idempotencyKey(body),
        p_request_id: c.requestId,
      });
    }),

    route("GET", "/nin/reviews", (c) => {
      onlyQuery(c.query, []);
      return call("nin_reviews", { ...actorArgs(c), p_membership_id: workspace(c.request) });
    }),

    route("POST", "/nin/reviews/:id/decide", (c) => decide(c, workspace(c.request))),

    // Blueprint 13: the bell for the selected workspace (its network plus
    // personal items). The badge poll does not count as activity.
    route("GET", "/notifications", (c) => {
      onlyQuery(c.query, ["view", "cursor", "limit"]);
      const view = c.query.get("view") ?? "all";
      if (view !== "all" && view !== "unread") {
        throw new ApiError("validation_error", { field: "view" });
      }
      const cursor = c.query.get("cursor");
      if (cursor !== null && !/^[A-Za-z0-9+/=]{1,400}$/.test(cursor)) {
        throw new ApiError("validation_error", { field: "cursor" });
      }
      const limit = c.query.get("limit");
      if (limit !== null && !/^[1-9][0-9]?$|^100$/.test(limit)) {
        throw new ApiError("validation_error", { field: "limit" });
      }
      return callObject("my_notifications", {
        ...actorArgs(c),
        p_membership_id: workspace(c.request),
        p_view: view,
        p_cursor: cursor,
        p_limit: limit === null ? null : Number(limit),
      });
    }),

    route("GET", "/notifications/unread", (c) => {
      onlyQuery(c.query, []);
      return callObject("my_notification_count", {
        ...actorArgs(c),
        p_membership_id: workspace(c.request),
      });
    }),

    route("POST", "/notifications/read", async (c) => {
      const body = await v.readBody(c.request, ["ids", "all"]);
      const all = body.all === true;
      if (body.all !== undefined && typeof body.all !== "boolean") {
        throw new ApiError("validation_error", { field: "all" });
      }
      let ids: string[] | null = null;
      if (body.ids !== undefined) {
        const value = body.ids;
        if (
          !Array.isArray(value) || value.length < 1 || value.length > 100 ||
          !value.every((id) => typeof id === "string" && uuidPattern.test(id))
        ) {
          throw new ApiError("validation_error", { field: "ids" });
        }
        ids = value.map((id: string) => id.toLowerCase());
      }
      if (all === (ids !== null)) throw new ApiError("validation_error", { field: "ids" });
      return callObject("mark_notifications_read", {
        ...actorArgs(c),
        p_membership_id: workspace(c.request),
        p_ids: ids,
        p_all: all,
      });
    }),

    route("GET", "/admin/nin/reviews", (c) => {
      onlyQuery(c.query, []);
      return call("admin_nin_reviews", actorArgs(c));
    }),

    route("POST", "/admin/nin/reviews/:id/decide", (c) => decide(c, null)),
  ];

  return async (request: Request): Promise<Response> => {
    const started = Date.now();
    const requestId = crypto.randomUUID();
    const cors = corsHeaders(request.headers.get("origin"), deps.allowedOrigins);
    const url = new URL(request.url);
    const path = url.pathname.replace(/^.*?\/identity(?=\/|$)/, "") || "/";

    let found: { route: Route; params: Record<string, string> } | null = null;
    for (const candidate of routes) {
      if (candidate.method !== request.method) continue;
      const params = match(candidate.pattern, path);
      if (params) {
        found = { route: candidate, params };
        break;
      }
    }

    let context: Context | null = null;
    const finish = (response: Response, code?: string): Response => {
      deps.log({
        requestId,
        route: found ? `${found.route.method} ${found.route.pattern}` : "unknown",
        status: response.status,
        ...(code ? { code } : {}),
        ms: Date.now() - started,
        ...(context?.providerShape ? { providerShape: context.providerShape } : {}),
      });
      return response;
    };

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: cors });
    }
    if (!found) return finish(failure("not_found", requestId, {}, cors), "not_found");

    try {
      const token = request.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1];
      const actor = token ? await deps.verifyToken(token) : null;
      if (!actor) throw new ApiError("authentication_required");
      context = { request, actor, requestId, params: found.params, query: url.searchParams };
      const data = await found.route.handler(context);
      return finish(success(data, requestId, cors));
    } catch (error) {
      if (error instanceof ApiError) {
        return finish(failure(error.code, requestId, error.details, cors), error.code);
      }
      return finish(failure("internal_error", requestId, {}, cors), "internal_error");
    }
  };
}
