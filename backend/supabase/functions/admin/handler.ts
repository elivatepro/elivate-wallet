// Routes for the `admin` Edge Function (Blueprint 18 — B4): every platform
// Admin app read and command. Every request needs a verified user token AND
// the app-server secret (only the admin site's server holds it), and the
// database checks the caller is an active platform admin. Dependencies are
// injected so tests can exercise routing, validation and error mapping.

import {
  ApiError,
  corsHeaders,
  type Details,
  failure,
  isErrorCode,
  success,
} from "../_shared/http.ts";
import { sha256Hex } from "../_shared/evidence.ts";
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
    readonly error: {
      readonly message: string;
      readonly details?: string | null;
    };
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
  /** HMAC fingerprint of one bank code + 10-digit account number (never stored or logged). */
  bankFingerprint(bankCode: string, accountNumber: string): Promise<string>;
  /** Draws a founder invitation link: a token id and the digest of its token (Blueprint 19). */
  issueToken(): Promise<{ readonly tokenId: string; readonly digest: string }>;
  log(entry: LogEntry): void;
  readonly allowedOrigins: readonly string[];
  /** APP_SERVER_SECRET; null refuses every request (fail closed). */
  readonly appServerSecret: string | null;
}

interface Context {
  readonly request: Request;
  readonly actor: Actor;
  readonly requestId: string;
  readonly params: Readonly<Record<string, string>>;
  readonly query: URLSearchParams;
}

type Handler = (context: Context) => Promise<unknown>;

interface Route {
  readonly method: string;
  readonly pattern: string;
  readonly handler: Handler;
}

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const uidPattern = /^EW-[1-9][0-9]{4,}$/i;
// deno-lint-ignore no-control-regex
const controlCharacters = /[\u0000-\u001f\u007f]/;

export const switchKeys: readonly string[] = [
  "withdrawals",
  "payouts",
  "transfers",
  "conversion",
  "income",
  "adjustments",
  "reversals",
  "returned_funds",
];
const restoreSteps: readonly string[] = [
  "validating",
  "restoring",
  "completed",
  "rejected",
  "failed",
];
const tenantStates: readonly string[] = [
  "active",
  "trial",
  "paused",
  "pending_payment",
  "deactivated",
];
const accountStatuses: readonly string[] = [
  "active",
  "restricted",
  "suspended",
  "deactivated",
];
const applicationStatuses: readonly string[] = ["waiting", "approved", "rejected"];
const auditGroups: readonly string[] = [
  "controls",
  "accounts",
  "money",
  "backups",
  "network",
];

function parseDetails(raw: string | null | undefined): Details {
  if (!raw) return {};
  try {
    const parsed: unknown = JSON.parse(raw);
    return typeof parsed === "object" && parsed !== null &&
        !Array.isArray(parsed)
      ? parsed as Details
      : {};
  } catch {
    return {};
  }
}

/** `:id` segments must be UUIDs, `:uid` segments Wallet UIDs. */
function match(pattern: string, path: string): Record<string, string> | null {
  const want = pattern.split("/");
  const got = path.split("/");
  if (want.length !== got.length) return null;
  const params: Record<string, string> = {};
  for (let i = 0; i < want.length; i++) {
    const w = want[i] ?? "";
    const g = got[i] ?? "";
    if (w === ":uid") {
      if (!uidPattern.test(g)) return null;
      params.uid = g.toUpperCase();
    } else if (w.startsWith(":")) {
      if (!uuidPattern.test(g)) return null;
      params[w.slice(1)] = g.toLowerCase();
    } else if (w !== g) {
      return null;
    }
  }
  return params;
}

function onlyQuery(query: URLSearchParams, allowed: readonly string[]): void {
  for (const key of query.keys()) {
    if (!allowed.includes(key)) {
      throw new ApiError("validation_error", {
        field: key,
        reason: "unknown_field",
      });
    }
  }
}

function queryText(
  query: URLSearchParams,
  field: string,
  max: number,
): string | null {
  const value = query.get(field);
  if (value === null) return null;
  if (value.trim() === "" || value.length > max || controlCharacters.test(value)) {
    throw new ApiError("validation_error", { field });
  }
  return value.trim();
}

function queryChoice(
  query: URLSearchParams,
  field: string,
  choices: readonly string[],
): string | null {
  const value = query.get(field);
  if (value === null) return null;
  if (!choices.includes(value)) {
    throw new ApiError("validation_error", { field });
  }
  return value;
}

function queryLimit(query: URLSearchParams): number | null {
  const value = query.get("limit");
  if (value === null) return null;
  if (!/^[0-9]{1,3}$/.test(value)) {
    throw new ApiError("validation_error", { field: "limit" });
  }
  return Number(value);
}

function queryUuid(query: URLSearchParams, field: string): string | null {
  const value = query.get(field);
  if (value === null) return null;
  if (!uuidPattern.test(value)) {
    throw new ApiError("validation_error", { field });
  }
  return value.toLowerCase();
}

function queryDate(query: URLSearchParams, field: string): string | null {
  const value = query.get(field);
  if (value === null) return null;
  return v.date({ [field]: value }, field);
}

function queryCursor(query: URLSearchParams): string | null {
  const value = query.get("cursor");
  if (value === null) return null;
  if (!/^[A-Za-z0-9+/=]{1,400}$/.test(value)) {
    throw new ApiError("validation_error", { field: "cursor" });
  }
  return value;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** The validation run a staging or completion call belongs to. */
function runIdOf(body: Record<string, unknown>): string {
  if (typeof body.runId !== "string" || !UUID.test(body.runId)) {
    throw new ApiError("validation_error", { field: "runId" });
  }
  return body.runId;
}

/** A searched 10-digit account number (spaces and dashes allowed), else null. */
export function accountNumberIn(query: string): string | null {
  const digits = query.replace(/[\s-]/g, "");
  return /^[0-9]{10}$/.test(digits) ? digits : null;
}

export function createHandler(
  deps: Deps,
): (request: Request) => Promise<Response> {
  async function call(
    fn: string,
    args: Record<string, unknown>,
  ): Promise<unknown> {
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

  const actorArgs = ({ actor }: Context) => ({
    p_user_id: actor.userId,
    p_session_id: actor.sessionId,
  });
  const commandArgs = (c: Context) => ({
    ...actorArgs(c),
    p_request_id: c.requestId,
  });

  const route = (method: string, pattern: string, handler: Handler): Route => ({
    method,
    pattern,
    handler,
  });

  async function search(c: Context): Promise<unknown> {
    onlyQuery(c.query, ["q"]);
    const q = queryText(c.query, "q", 100);
    if (q === null || q.length < 2) {
      throw new ApiError("validation_error", { field: "q" });
    }
    // Bank account (W-23): fingerprint the number for every bank that has a
    // saved account; the number itself never reaches the database or logs.
    // The same 10 digits may be a phone number: send only its hash.
    let fingerprints: string[] | null = null;
    let phoneSha256: string | null = null;
    const number = accountNumberIn(q);
    if (number !== null) {
      phoneSha256 = await sha256Hex(new TextEncoder().encode(`phone:${number}`));
      const codes = await call("admin_bank_codes", actorArgs(c));
      if (
        !Array.isArray(codes) || codes.some((code) => typeof code !== "string")
      ) {
        throw new Error("admin_bank_codes returned an unexpected result");
      }
      fingerprints = await Promise.all(
        (codes as string[]).slice(0, 500).map((code) => deps.bankFingerprint(code, number)),
      );
    }
    return call("admin_search", {
      ...actorArgs(c),
      p_query: number === null ? q : `•••• ${number.slice(-4)}`,
      p_bank_fingerprints: fingerprints,
      p_phone_sha256: phoneSha256,
    });
  }

  const routes: Route[] = [
    route("GET", "/me", (c) => {
      onlyQuery(c.query, []);
      return call("admin_me", actorArgs(c));
    }),

    route("GET", "/overview", (c) => {
      onlyQuery(c.query, []);
      return call("admin_overview", actorArgs(c));
    }),

    route("GET", "/search", search),

    // ── Networks ──
    route("GET", "/tenants", (c) => {
      onlyQuery(c.query, ["q", "state", "cursor", "limit"]);
      return call("admin_tenants", {
        ...actorArgs(c),
        p_query: queryText(c.query, "q", 100),
        p_state: queryChoice(c.query, "state", tenantStates),
        p_cursor: queryCursor(c.query),
        p_limit: queryLimit(c.query),
      });
    }),

    route("GET", "/tenants/:id", (c) => {
      onlyQuery(c.query, []);
      return call("admin_tenant", {
        ...actorArgs(c),
        p_tenant_id: c.params.id,
      });
    }),

    route("GET", "/tenants/:id/allocation-versions", (c) => {
      onlyQuery(c.query, []);
      return call("admin_allocation_versions", {
        ...actorArgs(c),
        p_tenant_id: c.params.id,
      });
    }),

    // Blueprint 16 Q9: complimentary period until a WAT day, or the development exception.
    route("POST", "/tenants/:id/activate", async (c) => {
      const body = await v.readBody(c.request, [
        "reason",
        "until",
        "idempotencyKey",
      ]);
      return call("activate_tenant", {
        ...commandArgs(c),
        p_tenant_id: c.params.id,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
        p_until: body.until === undefined || body.until === null ? null : v.date(body, "until"),
      });
    }),

    // ── Accounts ──
    route("GET", "/accounts", (c) => {
      onlyQuery(c.query, ["q", "status", "cursor", "limit"]);
      return call("admin_accounts", {
        ...actorArgs(c),
        p_query: queryText(c.query, "q", 100),
        p_status: queryChoice(c.query, "status", accountStatuses),
        p_cursor: queryCursor(c.query),
        p_limit: queryLimit(c.query),
      });
    }),

    route("GET", "/accounts/:uid", (c) => {
      onlyQuery(c.query, []);
      return call("admin_account", { ...actorArgs(c), p_uid: c.params.uid });
    }),

    route("POST", "/accounts/:uid/status", async (c) => {
      const body = await v.readBody(c.request, [
        "status",
        "reason",
        "idempotencyKey",
      ]);
      const status = body.status;
      if (typeof status !== "string" || !accountStatuses.includes(status)) {
        throw new ApiError("validation_error", { field: "status" });
      }
      return call("set_account_status", {
        ...commandArgs(c),
        p_target_uid: c.params.uid,
        p_status: status,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    // ── Kill switches (W-23) ──
    route("GET", "/switches", (c) => {
      onlyQuery(c.query, ["tenantId"]);
      return call("admin_switches", {
        ...actorArgs(c),
        p_tenant_id: queryUuid(c.query, "tenantId"),
      });
    }),

    route("POST", "/switches", async (c) => {
      const body = await v.readBody(c.request, [
        "key",
        "tenantId",
        "stopped",
        "reason",
        "idempotencyKey",
      ]);
      const key = body.key;
      if (typeof key !== "string" || !switchKeys.includes(key)) {
        throw new ApiError("validation_error", { field: "key" });
      }
      if (typeof body.stopped !== "boolean") {
        throw new ApiError("validation_error", { field: "stopped" });
      }
      return call("admin_set_switch", {
        ...commandArgs(c),
        p_key: key,
        p_tenant_id: body.tenantId === undefined || body.tenantId === null
          ? null
          : v.uuid(body, "tenantId"),
        p_stopped: body.stopped,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    // ── Audit ──
    route("GET", "/audit", (c) => {
      onlyQuery(c.query, [
        "q",
        "group",
        "actor",
        "tenantId",
        "from",
        "to",
        "cursor",
        "limit",
      ]);
      const actor = c.query.get("actor");
      if (actor !== null && !uidPattern.test(actor)) {
        throw new ApiError("validation_error", { field: "actor" });
      }
      return call("admin_audit", {
        ...actorArgs(c),
        p_query: queryText(c.query, "q", 100),
        p_group: queryChoice(c.query, "group", auditGroups),
        p_actor_uid: actor === null ? null : actor.toUpperCase(),
        p_tenant_id: queryUuid(c.query, "tenantId"),
        p_from: queryDate(c.query, "from"),
        p_to: queryDate(c.query, "to"),
        p_cursor: queryCursor(c.query),
        p_limit: queryLimit(c.query),
      });
    }),

    // ── Platform admins ──
    route("GET", "/admins", (c) => {
      onlyQuery(c.query, []);
      return call("admin_admins", actorArgs(c));
    }),

    route(
      "POST",
      "/admins/grant",
      (c) => adminChange("grant_platform_admin", c),
    ),
    route(
      "POST",
      "/admins/revoke",
      (c) => adminChange("revoke_platform_admin", c),
    ),

    // ── Restores (W-24, owner answer Q7) ──
    route("GET", "/restores", (c) => {
      onlyQuery(c.query, []);
      return call("admin_restores", actorArgs(c));
    }),

    route("GET", "/restores/:id", (c) => {
      onlyQuery(c.query, []);
      return call("admin_restore", {
        ...actorArgs(c),
        p_restore_id: c.params.id,
      });
    }),

    route("POST", "/restores/:id/advance", async (c) => {
      const body = await v.readBody(c.request, [
        "status",
        "reason",
        "idempotencyKey",
      ]);
      const status = body.status;
      if (typeof status !== "string" || !restoreSteps.includes(status)) {
        throw new ApiError("validation_error", { field: "status" });
      }
      return call("platform_advance_restore", {
        ...commandArgs(c),
        p_restore_id: c.params.id,
        p_status: status,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/restores/:id/source", async (c) => {
      await v.readBody(c.request, []);
      return call("admin_restore_source", {
        ...actorArgs(c),
        p_restore_id: c.params.id,
      });
    }),

    route("POST", "/restores/:id/rows", async (c) => {
      const body = await v.readBody(c.request, ["runId", "section", "rows"]);
      const section = body.section;
      if (typeof section !== "string" || !/^[a-z_]{2,40}$/.test(section)) {
        throw new ApiError("validation_error", { field: "section" });
      }
      const rows = body.rows;
      if (
        !Array.isArray(rows) || rows.length > 1000 ||
        rows.some((row) => typeof row !== "object" || row === null || Array.isArray(row))
      ) {
        throw new ApiError("validation_error", { field: "rows" });
      }
      return call("admin_restore_rows", {
        ...actorArgs(c),
        p_restore_id: c.params.id,
        p_run_id: runIdOf(body),
        p_section: section,
        p_rows: rows,
      });
    }),

    route("POST", "/restores/:id/validated", async (c) => {
      const body = await v.readBody(c.request, [
        "runId",
        "ok",
        "failReason",
        "sections",
      ]);
      if (typeof body.ok !== "boolean") {
        throw new ApiError("validation_error", { field: "ok" });
      }
      const failReason = body.failReason ?? null;
      if (
        failReason !== null &&
        (typeof failReason !== "string" || !/^[a-z_]{3,40}$/.test(failReason))
      ) {
        throw new ApiError("validation_error", { field: "failReason" });
      }
      const sections = body.sections;
      if (
        !Array.isArray(sections) || sections.length > 100 ||
        sections.some((s) => {
          if (typeof s !== "object" || s === null) return true;
          const item = s as Record<string, unknown>;
          return typeof item.section !== "string" ||
            !/^[a-z_]{2,40}$/.test(item.section) ||
            !Number.isInteger(item.rows) || typeof item.sha256Ok !== "boolean";
        })
      ) {
        throw new ApiError("validation_error", { field: "sections" });
      }
      return call("admin_restore_validated", {
        ...commandArgs(c),
        p_restore_id: c.params.id,
        p_run_id: runIdOf(body),
        p_ok: body.ok,
        p_fail_reason: failReason,
        p_report: {
          sections: sections.map((s) => {
            const item = s as Record<string, unknown>;
            return {
              section: item.section,
              rows: item.rows,
              sha256Ok: item.sha256Ok,
            };
          }),
        },
      });
    }),

    // ── Failed emails (T-03) ──
    route("GET", "/outbox", (c) => {
      onlyQuery(c.query, ["limit"]);
      return call("outbox_dead_letters", {
        ...actorArgs(c),
        p_limit: queryLimit(c.query),
      });
    }),

    route("POST", "/outbox/:id/requeue", async (c) => {
      const body = await v.readBody(c.request, ["reason", "idempotencyKey"]);
      return call("outbox_requeue", {
        ...commandArgs(c),
        p_event_id: c.params.id,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    // ── NIN reviews ──
    route("GET", "/nin/reviews", (c) => {
      onlyQuery(c.query, []);
      return call("admin_nin_reviews", actorArgs(c));
    }),

    route("POST", "/nin/reviews/:id/decide", async (c) => {
      const body = await v.readBody(c.request, [
        "decision",
        "reason",
        "idempotencyKey",
      ]);
      const decision = body.decision;
      if (decision !== "approve" && decision !== "reject") {
        throw new ApiError("validation_error", { field: "decision" });
      }
      return call("decide_nin_review", {
        ...commandArgs(c),
        p_membership_id: null,
        p_review_id: c.params.id,
        p_decision: decision,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    // ── Founder applications (Blueprint 19) ──
    route("GET", "/founder-applications", (c) => {
      onlyQuery(c.query, ["status", "cursor", "limit"]);
      return call("admin_founder_applications", {
        ...actorArgs(c),
        p_status: queryChoice(c.query, "status", applicationStatuses),
        p_cursor: queryCursor(c.query),
        p_limit: queryLimit(c.query),
      });
    }),

    route("GET", "/founder-applications/:id", (c) => {
      onlyQuery(c.query, []);
      return call("admin_founder_application", { ...actorArgs(c), p_application_id: c.params.id });
    }),

    route("POST", "/founder-applications/:id/decide", async (c) => {
      const body = await v.readBody(c.request, ["decision", "reason", "idempotencyKey"]);
      const decision = body.decision;
      if (decision !== "approve" && decision !== "reject") {
        throw new ApiError("validation_error", { field: "decision" });
      }
      const args = {
        ...commandArgs(c),
        p_application_id: c.params.id,
        p_decision: decision,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      };
      // Approval sends a founder invitation: a fresh link per attempt (a
      // replay keeps the first one).
      const link = decision === "approve" ? await deps.issueToken() : null;
      return call("admin_decide_founder_application", {
        ...args,
        p_token_id: link?.tokenId ?? null,
        p_token_digest: link?.digest ?? null,
      });
    }),

    route("POST", "/founder-applications/:id/resend", async (c) => {
      const body = await v.readBody(c.request, ["reason", "idempotencyKey"]);
      const args = {
        ...commandArgs(c),
        p_application_id: c.params.id,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      };
      const link = await deps.issueToken();
      return call("admin_resend_founder_invitation", {
        ...args,
        p_token_id: link.tokenId,
        p_token_digest: link.digest,
      });
    }),
  ];

  async function adminChange(fn: string, c: Context): Promise<unknown> {
    const body = await v.readBody(c.request, [
      "targetUid",
      "reason",
      "idempotencyKey",
    ]);
    return call(fn, {
      ...commandArgs(c),
      p_target_uid: v.uid(body, "targetUid"),
      p_reason: v.reason(body),
      p_idempotency_key: v.idempotencyKey(body),
    });
  }

  return async (request: Request): Promise<Response> => {
    const started = Date.now();
    const requestId = crypto.randomUUID();
    const cors = corsHeaders(
      request.headers.get("origin"),
      deps.allowedOrigins,
    );
    const url = new URL(request.url);
    const path = url.pathname.replace(/^.*?\/admin(?=\/|$)/, "") || "/";

    let found: { route: Route; params: Record<string, string> } | null = null;
    for (const candidate of routes) {
      if (candidate.method !== request.method) continue;
      const params = match(candidate.pattern, path);
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
    if (!found) {
      return finish(failure("not_found", requestId, {}, cors), "not_found");
    }

    try {
      const token = request.headers.get("authorization")?.match(/^Bearer (.+)$/)
        ?.[1];
      const actor = token ? await deps.verifyToken(token) : null;
      if (!actor) throw new ApiError("authentication_required");
      const given = request.headers.get("x-app-server-secret");
      if (
        !deps.appServerSecret || !given ||
        !(await sameSecret(given, deps.appServerSecret))
      ) {
        throw new ApiError("authorization_denied", {
          reason: "app_server_only",
        });
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
        return finish(
          failure(error.code, requestId, error.details, cors),
          error.code,
        );
      }
      return finish(
        failure("internal_error", requestId, {}, cors),
        "internal_error",
      );
    }
  };
}
