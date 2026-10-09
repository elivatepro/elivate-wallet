// Routes for the `org` Edge Function (Blueprint 02 — B4). Dependencies are
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
  log(entry: LogEntry): void;
  readonly allowedOrigins: readonly string[];
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

/** Matches `/offices/:id/place` against a path; path ids must be UUIDs. */
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

function optionalUuid(body: v.Body, field: string): string | null {
  return body[field] === null || body[field] === undefined ? null : v.uuid(body, field);
}

function uidList(body: v.Body, field: string): string[] {
  const value = body[field];
  if (!Array.isArray(value) || value.length < 1 || value.length > 20) {
    throw new ApiError("validation_error", { field });
  }
  return value.map((_, i) => v.uid(value as unknown as v.Body, String(i)));
}

const ruleFields = [
  "permission",
  "effect",
  "scopeType",
  "scopeOfficeId",
  "scopeUid",
  "startsAt",
  "expiresAt",
];

/** Shape-checks access rules; the database checks meaning and authority. */
function rules(body: v.Body): unknown[] {
  const value = body.rules;
  if (!Array.isArray(value) || value.length < 1 || value.length > 50) {
    throw new ApiError("validation_error", { field: "rules" });
  }
  return value.map((rule: unknown) => {
    if (typeof rule !== "object" || rule === null || Array.isArray(rule)) {
      throw new ApiError("validation_error", { field: "rules" });
    }
    const r = rule as v.Body;
    for (const key of Object.keys(r)) {
      if (!ruleFields.includes(key)) {
        throw new ApiError("validation_error", { field: `rules.${key}`, reason: "unknown_field" });
      }
    }
    v.text(r, "permission", 60);
    const effect = v.text(r, "effect", 10);
    if (effect !== "allow" && effect !== "deny") {
      throw new ApiError("validation_error", { field: "rules.effect" });
    }
    const scopeType = v.text(r, "scopeType", 20);
    if (scopeType === "office_subtree") v.uuid(r, "scopeOfficeId");
    else if (scopeType === "member") v.uid(r, "scopeUid");
    else if (scopeType !== "tenant") {
      throw new ApiError("validation_error", { field: "rules.scopeType" });
    }
    for (const field of ["startsAt", "expiresAt"]) {
      const at = r[field];
      if (at !== undefined && (typeof at !== "string" || Number.isNaN(Date.parse(at)))) {
        throw new ApiError("validation_error", { field: `rules.${field}` });
      }
    }
    return { ...r, ...(scopeType === "member" ? { scopeUid: v.uid(r, "scopeUid") } : {}) };
  });
}

function oneOf<T extends string>(value: string, field: string, allowed: readonly T[]): T {
  if (!(allowed as readonly string[]).includes(value)) {
    throw new ApiError("validation_error", { field });
  }
  return value as T;
}

const roles = [
  "member",
  "team_leader",
  "director",
  "world_team_member",
  "president_team_member",
] as const;

/** Roles a membership in an office can hold (never President Team). */
const officeRoles = ["member", "team_leader", "director", "world_team_member"] as const;

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

  const actorArgs = ({ actor }: Context) => ({
    p_user_id: actor.userId,
    p_session_id: actor.sessionId,
  });
  const commandArgs = (c: Context) => ({ ...actorArgs(c), p_request_id: c.requestId });
  const inWorkspace = (c: Context) => ({ ...actorArgs(c), p_membership_id: workspace(c.request) });
  const commandInWorkspace = (c: Context) => ({ ...inWorkspace(c), p_request_id: c.requestId });

  const route = (method: string, pattern: string, handler: Handler): Route => ({
    method,
    pattern,
    handler,
  });

  const routes: Route[] = [
    route("POST", "/networks", async (c) => {
      const body = await v.readBody(c.request, ["name", "shortName", "idempotencyKey"]);
      return call("start_network", {
        ...commandArgs(c),
        p_name: v.name(body),
        p_short_name: v.text(body, "shortName", 30),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/admin/tenants/:id/activate", async (c) => {
      const body = await v.readBody(c.request, ["reason", "idempotencyKey"]);
      return call("activate_tenant", {
        ...commandArgs(c),
        p_tenant_id: c.params.id,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("GET", "/workspaces", (c) => {
      onlyQuery(c.query, []);
      return call("my_workspaces", actorArgs(c));
    }),

    route("GET", "/capabilities", (c) => {
      onlyQuery(c.query, []);
      return call("my_capabilities", inWorkspace(c));
    }),

    route("GET", "/offices", (c) => {
      onlyQuery(c.query, ["type", "q", "status", "cursor", "limit"]);
      return call("list_offices", {
        ...inWorkspace(c),
        p_type: queryText(c.query, "type", 20),
        p_query: queryText(c.query, "q", 100),
        p_status: queryText(c.query, "status", 20),
        p_cursor: queryText(c.query, "cursor", 500),
        p_limit: queryLimit(c.query),
      });
    }),

    route("POST", "/offices", async (c) => {
      const body = await v.readBody(c.request, [
        "type",
        "name",
        "parentOfficeId",
        "leaderUids",
        "idempotencyKey",
      ]);
      return call("create_office", {
        ...commandInWorkspace(c),
        p_type: oneOf(v.text(body, "type", 20), "type", ["world_team", "director", "team_leader"]),
        p_name: v.name(body),
        p_parent_office_id: optionalUuid(body, "parentOfficeId"),
        p_leader_uids: uidList(body, "leaderUids"),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("PATCH", "/offices/:id", async (c) => {
      const body = await v.readBody(c.request, ["name", "idempotencyKey"]);
      return call("rename_office", {
        ...commandInWorkspace(c),
        p_office_id: c.params.id,
        p_name: v.name(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/offices/:id/place", async (c) => {
      const body = await v.readBody(c.request, ["parentOfficeId", "reason", "idempotencyKey"]);
      if (!("parentOfficeId" in body)) {
        throw new ApiError("validation_error", { field: "parentOfficeId" });
      }
      return call("place_office", {
        ...commandInWorkspace(c),
        p_office_id: c.params.id,
        p_parent_office_id: optionalUuid(body, "parentOfficeId"),
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("GET", "/offices/:id", (c) => {
      onlyQuery(c.query, []);
      return call("office_detail", { ...inWorkspace(c), p_office_id: c.params.id });
    }),

    // Blueprint 07: President Team, reason + step-up; only an empty office closes.
    route("POST", "/offices/:id/close", async (c) => {
      const body = await v.readBody(c.request, ["reason", "idempotencyKey"]);
      return call("close_office", {
        ...commandInWorkspace(c),
        p_office_id: c.params.id,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/offices/:id/leaders", async (c) => {
      const body = await v.readBody(c.request, ["leaderUid", "reason", "idempotencyKey"]);
      return call("add_office_leader", {
        ...commandInWorkspace(c),
        p_office_id: c.params.id,
        p_leader_uid: v.uid(body, "leaderUid"),
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/offices/:id/leaders/replace", async (c) => {
      const body = await v.readBody(c.request, [
        "outgoingMembershipId",
        "incomingUid",
        "reason",
        "idempotencyKey",
      ]);
      return call("replace_office_leader", {
        ...commandInWorkspace(c),
        p_office_id: c.params.id,
        p_outgoing_membership_id: v.uuid(body, "outgoingMembershipId"),
        p_incoming_uid: v.uid(body, "incomingUid"),
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("GET", "/members", (c) => {
      onlyQuery(c.query, ["officeId", "role", "status", "q", "cursor", "limit"]);
      return call("list_members", {
        ...inWorkspace(c),
        p_query: queryText(c.query, "q", 100),
        p_office_id: queryUuid(c.query, "officeId"),
        p_role: queryText(c.query, "role", 30),
        p_status: queryText(c.query, "status", 20),
        p_cursor: queryText(c.query, "cursor", 500),
        p_limit: queryLimit(c.query),
      });
    }),

    route("POST", "/memberships", async (c) => {
      const body = await v.readBody(c.request, ["officeId", "memberUid", "idempotencyKey"]);
      return call("add_membership", {
        ...commandInWorkspace(c),
        p_office_id: v.uuid(body, "officeId"),
        p_member_uid: v.uid(body, "memberUid"),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("GET", "/memberships/:id", (c) => {
      onlyQuery(c.query, []);
      return call("member_detail", { ...inWorkspace(c), p_target_membership_id: c.params.id });
    }),

    // Blueprint 07: a role change ends the membership and creates the new one.
    route("POST", "/memberships/:id/role", async (c) => {
      const body = await v.readBody(c.request, ["role", "reason", "idempotencyKey"]);
      return call("change_membership_role", {
        ...commandInWorkspace(c),
        p_target_membership_id: c.params.id,
        p_role: oneOf(v.text(body, "role", 30), "role", officeRoles),
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/memberships/:id/move", async (c) => {
      const body = await v.readBody(c.request, ["toOfficeId", "reason", "idempotencyKey"]);
      return call("move_membership", {
        ...commandInWorkspace(c),
        p_target_membership_id: c.params.id,
        p_to_office_id: v.uuid(body, "toOfficeId"),
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/memberships/:id/suspend", (c) => membershipStatus(c, "suspended")),
    route("POST", "/memberships/:id/reactivate", (c) => membershipStatus(c, "active")),

    route("POST", "/memberships/:id/end", async (c) => {
      const body = await v.readBody(c.request, ["reason", "idempotencyKey"]);
      return call("end_membership", {
        ...commandInWorkspace(c),
        p_target_membership_id: c.params.id,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/presidents", async (c) => {
      const body = await v.readBody(c.request, ["memberUid", "reason", "idempotencyKey"]);
      return call("add_president", {
        ...commandInWorkspace(c),
        p_member_uid: v.uid(body, "memberUid"),
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("DELETE", "/presidents/:id", async (c) => {
      const body = await v.readBody(c.request, ["reason", "idempotencyKey"]);
      return call("remove_president", {
        ...commandInWorkspace(c),
        p_target_membership_id: c.params.id,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("GET", "/role-permissions", (c) => {
      onlyQuery(c.query, []);
      return call("list_role_permissions", inWorkspace(c));
    }),

    route("PUT", "/role-permissions", async (c) => {
      const body = await v.readBody(c.request, [
        "role",
        "permission",
        "allowed",
        "reason",
        "idempotencyKey",
      ]);
      if (typeof body.allowed !== "boolean") {
        throw new ApiError("validation_error", { field: "allowed" });
      }
      return call("set_role_permission", {
        ...commandInWorkspace(c),
        p_role: oneOf(v.text(body, "role", 30), "role", roles),
        p_permission_key: v.text(body, "permission", 60),
        p_allowed: body.allowed,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("GET", "/access", (c) => {
      onlyQuery(c.query, ["cursor", "limit"]);
      return call("list_access_assignments", {
        ...inWorkspace(c),
        p_cursor: queryText(c.query, "cursor", 500),
        p_limit: queryLimit(c.query),
      });
    }),

    route("POST", "/access", async (c) => {
      const body = await v.readBody(c.request, ["subjectUid", "rules", "reason", "idempotencyKey"]);
      return call("create_access_assignment", {
        ...commandInWorkspace(c),
        p_subject_uid: v.uid(body, "subjectUid"),
        p_rules: rules(body),
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/access/:id/revoke", async (c) => {
      const body = await v.readBody(c.request, ["reason", "idempotencyKey"]);
      return call("revoke_access_assignment", {
        ...commandInWorkspace(c),
        p_assignment_id: c.params.id,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("GET", "/reviewers", (c) => {
      onlyQuery(c.query, []);
      return call("list_reviewers", inWorkspace(c));
    }),

    route("POST", "/reviewers", async (c) => {
      const body = await v.readBody(c.request, ["membershipId", "reason", "idempotencyKey"]);
      return call("assign_reviewer", {
        ...commandInWorkspace(c),
        p_target_membership_id: v.uuid(body, "membershipId"),
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("DELETE", "/reviewers/:id", async (c) => {
      const body = await v.readBody(c.request, ["reason", "idempotencyKey"]);
      return call("end_reviewer", {
        ...commandInWorkspace(c),
        p_assignment_id: c.params.id,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("GET", "/audit", (c) => {
      onlyQuery(c.query, ["cursor", "limit"]);
      return call("tenant_audit_log", {
        ...inWorkspace(c),
        p_cursor: queryText(c.query, "cursor", 500),
        p_limit: queryLimit(c.query),
      });
    }),
  ];

  async function membershipStatus(c: Context, status: "active" | "suspended") {
    const body = await v.readBody(c.request, ["reason", "idempotencyKey"]);
    return call("set_membership_status", {
      ...commandInWorkspace(c),
      p_target_membership_id: c.params.id,
      p_status: status,
      p_reason: v.reason(body),
      p_idempotency_key: v.idempotencyKey(body),
    });
  }

  return async (request: Request): Promise<Response> => {
    const started = Date.now();
    const requestId = crypto.randomUUID();
    const cors = corsHeaders(request.headers.get("origin"), deps.allowedOrigins);
    const url = new URL(request.url);
    const path = url.pathname.replace(/^.*?\/org(?=\/|$)/, "") || "/";

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
    if (!found) return finish(failure("not_found", requestId, {}, cors), "not_found");

    try {
      const token = request.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1];
      const actor = token ? await deps.verifyToken(token) : null;
      if (!actor) throw new ApiError("authentication_required");
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
