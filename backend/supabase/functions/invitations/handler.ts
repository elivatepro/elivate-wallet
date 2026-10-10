// Routes for the `invitations` Edge Function (Blueprint 03 — B4). The gateway
// does not verify JWTs (`verify_jwt = false`) because `preview` and
// `verify-email` serve people who are not signed in; every other route
// verifies the bearer here, exactly like `org`. Dependencies are injected so
// tests can exercise routing, validation and error mapping.
//
// Blueprint 19 adds the founder entry: the public application (only the
// Wallet server may send it, after Turnstile) and the founder invitation link
// (`/founder#t=`), which mirrors the network invitation link.

import {
  ApiError,
  corsHeaders,
  type Details,
  failure,
  isErrorCode,
  success,
} from "../_shared/http.ts";
import * as v from "../_shared/validate.ts";
import { tokenDigest, tokenPattern } from "../_shared/invite_token.ts";
import { sameSecret } from "../_shared/secret.ts";

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
  /** Draws a fresh link: a token id and the digest of its token. */
  issueToken(): Promise<{ readonly tokenId: string; readonly digest: string }>;
  /**
   * Asks Auth to email a sign-in link to the invitation's email (W-02 step 3);
   * it lands on the network (`join`) or founder (`founder`) invitation page.
   */
  sendSignInLink(email: string, page: "join" | "founder"): Promise<void>;
  log(entry: LogEntry): void;
  readonly allowedOrigins: readonly string[];
  /** Shared with the Wallet server only; required for the public application. */
  readonly appServerSecret: string | null;
}

interface Context {
  readonly request: Request;
  readonly actor: Actor | null;
  readonly requestId: string;
  readonly params: Readonly<Record<string, string>>;
  readonly query: URLSearchParams;
}

type Handler = (context: Context) => Promise<unknown>;

interface Route {
  readonly method: string;
  readonly pattern: string;
  /** Public routes take no session. */
  readonly public: boolean;
  /** Only the Wallet server (x-app-server-secret) may call it. */
  readonly serverOnly?: boolean;
  readonly handler: Handler;
}

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const roles = [
  "member",
  "team_leader",
  "director",
  "world_team_member",
  "president_team_member",
] as const;
const statuses = ["pending", "accepted", "expired", "revoked"] as const;
const founderRanks = ["ruby_director_4", "ruby_director_5", "diamond_director"] as const;

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

function queryText(query: URLSearchParams, field: string, max: number): string | null {
  const value = query.get(field);
  if (value === null) return null;
  if (value.trim() === "" || value.length > max) throw new ApiError("validation_error", { field });
  return value;
}

function queryLimit(query: URLSearchParams): number | null {
  const value = query.get("limit");
  if (value === null) return null;
  if (!/^[0-9]{1,3}$/.test(value)) throw new ApiError("validation_error", { field: "limit" });
  return Number(value);
}

function queryUuid(query: URLSearchParams, field: string): string | null {
  const value = query.get(field);
  if (value === null) return null;
  if (!uuidPattern.test(value)) throw new ApiError("validation_error", { field });
  return value.toLowerCase();
}

function oneOf<T extends string>(value: string, field: string, allowed: readonly T[]): T {
  if (!(allowed as readonly string[]).includes(value)) {
    throw new ApiError("validation_error", { field });
  }
  return value as T;
}

function email(body: v.Body): string {
  const value = body.email;
  if (
    typeof value !== "string" || value.length > 254 ||
    !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(value.trim())
  ) {
    throw new ApiError("validation_error", { field: "email" });
  }
  return value.trim().toLowerCase();
}

function linkToken(body: v.Body): string {
  const value = body.token;
  if (typeof value !== "string" || !tokenPattern.test(value)) {
    throw new ApiError("validation_error", { field: "token" });
  }
  return value;
}

function optionalReason(body: v.Body): string | null {
  return body.reason === undefined || body.reason === null ? null : v.reason(body);
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
    if (typeof data !== "object" || data === null) {
      throw new Error(`rpc ${fn} returned an unexpected result`);
    }
    return data;
  }

  const signedIn = (c: Context): Actor => {
    if (!c.actor) throw new ApiError("authentication_required");
    return c.actor;
  };
  const actorArgs = (c: Context) => {
    const actor = signedIn(c);
    return { p_user_id: actor.userId, p_session_id: actor.sessionId };
  };
  const commandInWorkspace = (c: Context) => ({
    ...actorArgs(c),
    p_membership_id: workspace(c.request),
    p_request_id: c.requestId,
  });

  const route = (
    method: string,
    pattern: string,
    handler: Handler,
    isPublic = false,
    serverOnly = false,
  ): Route => ({ method, pattern, public: isPublic, serverOnly, handler });

  const routes: Route[] = [
    route("GET", "/", (c) => {
      onlyQuery(c.query, ["officeId", "status", "cursor", "limit"]);
      const status = queryText(c.query, "status", 20);
      return call("list_invitations", {
        ...actorArgs(c),
        p_membership_id: workspace(c.request),
        p_office_id: queryUuid(c.query, "officeId"),
        p_status: status === null ? null : oneOf(status, "status", statuses),
        p_cursor: queryText(c.query, "cursor", 500),
        p_limit: queryLimit(c.query),
      });
    }),

    route("POST", "/", async (c) => {
      const body = await v.readBody(c.request, [
        "officeId",
        "role",
        "email",
        "reason",
        "idempotencyKey",
      ]);
      const args = {
        ...commandInWorkspace(c),
        p_office_id: v.uuid(body, "officeId"),
        p_role: oneOf(v.text(body, "role", 30), "role", roles),
        p_email: email(body),
        p_reason: optionalReason(body),
        p_idempotency_key: v.idempotencyKey(body),
      };
      const link = await deps.issueToken();
      return call("create_invitation", {
        ...args,
        p_token_id: link.tokenId,
        p_token_digest: link.digest,
      });
    }),

    route("POST", "/:id/reissue", async (c) => {
      const body = await v.readBody(c.request, ["idempotencyKey"]);
      const args = {
        ...commandInWorkspace(c),
        p_invitation_id: c.params.id,
        p_idempotency_key: v.idempotencyKey(body),
      };
      const link = await deps.issueToken();
      return call("reissue_invitation", {
        ...args,
        p_token_id: link.tokenId,
        p_token_digest: link.digest,
      });
    }),

    route("POST", "/:id/revoke", async (c) => {
      const body = await v.readBody(c.request, ["reason", "idempotencyKey"]);
      return call("revoke_invitation", {
        ...commandInWorkspace(c),
        p_invitation_id: c.params.id,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/preview", async (c) => {
      const token = linkToken(await v.readBody(c.request, ["token"]));
      const result = await call("invitation_preview", {
        p_token_digest: await tokenDigest(token),
      }) as { email?: unknown };
      if (typeof result.email !== "string") {
        throw new Error("preview returned an unexpected result");
      }
      return { email: result.email };
    }, true),

    route("POST", "/verify-email", async (c) => {
      // No email field: the server derives it from the invitation (W-02 step 3).
      const token = linkToken(await v.readBody(c.request, ["token"]));
      const result = await call("request_invitation_verification", {
        p_token_digest: await tokenDigest(token),
      }) as { email?: unknown };
      if (typeof result.email !== "string") {
        throw new Error("verification returned an unexpected result");
      }
      await deps.sendSignInLink(result.email, "join");
      return { sent: true };
    }, true),

    // ── Founder entry (Blueprint 19) ──

    route(
      "POST",
      "/founder-applications",
      async (c) => {
        const body = await v.readBody(c.request, [
          "fullName",
          "email",
          "phone",
          "teamName",
          "rank",
        ]);
        await call("submit_founder_application", {
          p_full_name: v.text(body, "fullName", 100, 2),
          p_email: email(body),
          p_phone: v.text(body, "phone", 24, 7),
          p_team_name: v.text(body, "teamName", 100, 2),
          p_rank: oneOf(v.text(body, "rank", 30), "rank", founderRanks),
        });
        // The same reply whether or not a new application was stored (W-01).
        return { received: true };
      },
      true,
      true,
    ),

    route("POST", "/founder/preview", async (c) => {
      const token = linkToken(await v.readBody(c.request, ["token"]));
      const result = await call("founder_invitation_preview", {
        p_token_digest: await tokenDigest(token),
      }) as { email?: unknown; teamName?: unknown };
      if (typeof result.email !== "string" || typeof result.teamName !== "string") {
        throw new Error("preview returned an unexpected result");
      }
      return { email: result.email, teamName: result.teamName };
    }, true),

    route("POST", "/founder/verify-email", async (c) => {
      const token = linkToken(await v.readBody(c.request, ["token"]));
      const result = await call("request_founder_verification", {
        p_token_digest: await tokenDigest(token),
      }) as { email?: unknown };
      if (typeof result.email !== "string") {
        throw new Error("verification returned an unexpected result");
      }
      await deps.sendSignInLink(result.email, "founder");
      return { sent: true };
    }, true),

    route("POST", "/founder/accept", async (c) => {
      const body = await v.readBody(c.request, ["token", "idempotencyKey"]);
      return call("accept_founder_invitation", {
        ...actorArgs(c),
        p_token_digest: await tokenDigest(linkToken(body)),
        p_idempotency_key: v.idempotencyKey(body),
        p_request_id: c.requestId,
      });
    }),

    route("GET", "/mine", (c) => {
      onlyQuery(c.query, []);
      return call("my_invitations", actorArgs(c));
    }),

    route("POST", "/accept", async (c) => {
      const body = await v.readBody(c.request, ["token", "invitationId", "idempotencyKey"]);
      if (("token" in body) === ("invitationId" in body)) {
        throw new ApiError("validation_error", { field: "token" });
      }
      const digest = "token" in body ? await tokenDigest(linkToken(body)) : null;
      return call("accept_invitation", {
        ...actorArgs(c),
        p_token_digest: digest,
        p_invitation_id: digest === null ? v.uuid(body, "invitationId") : null,
        p_idempotency_key: v.idempotencyKey(body),
        p_request_id: c.requestId,
      });
    }),
  ];

  return async (request: Request): Promise<Response> => {
    const started = Date.now();
    const requestId = crypto.randomUUID();
    const cors = corsHeaders(request.headers.get("origin"), deps.allowedOrigins);
    const url = new URL(request.url);
    const path = url.pathname.replace(/^.*?\/invitations(?=\/|$)/, "").replace(/\/$/, "") || "/";

    let found: { route: Route; params: Record<string, string> } | null = null;
    for (const candidate of routes) {
      if (candidate.method !== request.method) continue;
      const params = match(
        candidate.pattern === "/" ? "" : candidate.pattern,
        path === "/" ? "" : path,
      );
      if (params) {
        found = { route: candidate, params };
        break;
      }
    }

    const finish = (response: Response, code?: string): Response => {
      deps.log({
        requestId,
        route: found ? `${found.route.method} ${found.route.pattern}` : "unknown",
        status: response.status,
        ...(code ? { code } : {}),
        ms: Date.now() - started,
      });
      return response;
    };

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: cors });
    }
    if (!found) return finish(failure("not_found", requestId, {}, cors), "not_found");

    try {
      if (found.route.serverOnly) {
        const given = request.headers.get("x-app-server-secret");
        if (!deps.appServerSecret || !given || !(await sameSecret(given, deps.appServerSecret))) {
          throw new ApiError("authorization_denied", { reason: "app_server_only" });
        }
      }
      let actor: Actor | null = null;
      if (!found.route.public) {
        const token = request.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1];
        actor = token ? await deps.verifyToken(token) : null;
        if (!actor) throw new ApiError("authentication_required");
      }
      const data = await found.route.handler({
        request,
        actor,
        requestId,
        params: found.params,
        query: url.searchParams,
      });
      return finish(success(data, requestId, cors));
    } catch (error) {
      if (error instanceof ApiError) {
        return finish(failure(error.code, requestId, error.details, cors), error.code);
      }
      return finish(failure("internal_error", requestId, {}, cors), "internal_error");
    }
  };
}
