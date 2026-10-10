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
  log(entry: LogEntry): void;
  readonly allowedOrigins: readonly string[];
  /** APP_SERVER_SECRET: storage keys (logos, backups) go to the app server only. */
  readonly appServerSecret?: string | null;
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
    return typeof parsed === "object" && parsed !== null &&
        !Array.isArray(parsed)
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
  if (!value || !uuidPattern.test(value)) {
    throw new ApiError("workspace_invalid");
  }
  return value.toLowerCase();
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
  if (value.trim() === "" || value.length > max) {
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
        throw new ApiError("validation_error", {
          field: `rules.${key}`,
          reason: "unknown_field",
        });
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
      if (
        at !== undefined &&
        (typeof at !== "string" || Number.isNaN(Date.parse(at)))
      ) {
        throw new ApiError("validation_error", { field: `rules.${field}` });
      }
    }
    return {
      ...r,
      ...(scopeType === "member" ? { scopeUid: v.uid(r, "scopeUid") } : {}),
    };
  });
}

function oneOf<T extends string>(
  value: string,
  field: string,
  allowed: readonly T[],
): T {
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

// Blueprint 17: the settings a save may carry (D-11). Postgres validates every
// value again; this layer refuses unknown fields and oversized text.
const settingsFields: Readonly<Record<string, number>> = {
  name: 100,
  shortName: 30,
  theme: 20,
  slogan: 60,
  supportName: 80,
  supportEmail: 254,
  supportPhone: 24,
  helpUrl: 300,
  locale: 10,
  timeZone: 64,
  logoKey: 120,
  iconKey: 120,
  logoLightKey: 120,
};

function settingsPatch(body: v.Body): Record<string, string | null> {
  const value = body.fields;
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new ApiError("validation_error", { field: "fields" });
  }
  const entries = Object.entries(value as Record<string, unknown>);
  if (entries.length < 1) {
    throw new ApiError("validation_error", { field: "fields" });
  }
  const patch: Record<string, string | null> = {};
  for (const [key, field] of entries) {
    const max = settingsFields[key];
    if (max === undefined) {
      throw new ApiError("validation_error", {
        field: key,
        reason: "unknown_field",
      });
    }
    if (field === null) {
      patch[key] = null;
    } else if (typeof field === "string" && [...field].length <= max) {
      patch[key] = field;
    } else {
      throw new ApiError("validation_error", { field: key });
    }
  }
  return patch;
}

function positiveInt(body: v.Body, field: string): number {
  const value = body[field];
  if (
    typeof value !== "number" || !Number.isInteger(value) || value < 1 ||
    value > 1_000_000
  ) {
    throw new ApiError("validation_error", { field });
  }
  return value;
}

/** W-24 steps only Elivate takes. */
const restoreSteps = [
  "validating",
  "in_review",
  "restoring",
  "completed",
  "rejected",
  "failed",
];

/** Roles a membership in an office can hold (never President Team). */
const officeRoles = [
  "member",
  "team_leader",
  "director",
  "world_team_member",
] as const;

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
  const inWorkspace = (c: Context) => ({
    ...actorArgs(c),
    p_membership_id: workspace(c.request),
  });
  const commandInWorkspace = (c: Context) => ({
    ...inWorkspace(c),
    p_request_id: c.requestId,
  });

  async function appServerOnly(c: Context): Promise<void> {
    const given = c.request.headers.get("x-app-server-secret");
    if (
      !deps.appServerSecret || !given ||
      !(await sameSecret(given, deps.appServerSecret))
    ) {
      throw new ApiError("authorization_denied", { reason: "app_server_only" });
    }
  }

  function brandKey(data: unknown): unknown {
    const key = (data as Record<string, unknown>).objectKey;
    if (
      typeof key !== "string" ||
      !/^brand\/[0-9a-f-]{36}\/[0-9a-f-]{36}\.(jpg|png|webp)$/.test(key)
    ) {
      throw new Error("brand key has an unexpected shape");
    }
    return data;
  }

  const route = (method: string, pattern: string, handler: Handler): Route => ({
    method,
    pattern,
    handler,
  });

  const routes: Route[] = [
    route("POST", "/networks", async (c) => {
      const body = await v.readBody(c.request, [
        "name",
        "shortName",
        "planKey",
        "trial",
        "idempotencyKey",
      ]);
      // Blueprint 16: the plan and whether to use the founder's one trial.
      const planKey = body.planKey ?? "band_400";
      if (
        typeof planKey !== "string" || !/^band_[0-9a-z_]{1,20}$/.test(planKey)
      ) {
        throw new ApiError("validation_error", { field: "planKey" });
      }
      const trial = body.trial ?? false;
      if (typeof trial !== "boolean") {
        throw new ApiError("validation_error", { field: "trial" });
      }
      return call("start_network", {
        ...commandArgs(c),
        p_name: v.name(body),
        p_short_name: v.text(body, "shortName", 30),
        p_idempotency_key: v.idempotencyKey(body),
        p_plan_key: planKey,
        p_trial: trial,
      });
    }),

    route("POST", "/admin/tenants/:id/activate", async (c) => {
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
        // Blueprint 16: a complimentary period until this WAT day; none = the
        // development exception.
        p_until: body.until === undefined || body.until === null ? null : v.date(body, "until"),
      });
    }),

    // Blueprint 18: operations Elivate has stopped for this workspace's network.
    route("GET", "/operations", (c) => {
      onlyQuery(c.query, []);
      return call("stopped_operations", inWorkspace(c));
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
        p_type: oneOf(v.text(body, "type", 20), "type", [
          "world_team",
          "director",
          "team_leader",
        ]),
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
      const body = await v.readBody(c.request, [
        "parentOfficeId",
        "reason",
        "idempotencyKey",
      ]);
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
      return call("office_detail", {
        ...inWorkspace(c),
        p_office_id: c.params.id,
      });
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
      const body = await v.readBody(c.request, [
        "leaderUid",
        "reason",
        "idempotencyKey",
      ]);
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
      onlyQuery(c.query, [
        "officeId",
        "role",
        "status",
        "q",
        "cursor",
        "limit",
      ]);
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
      const body = await v.readBody(c.request, [
        "officeId",
        "memberUid",
        "idempotencyKey",
      ]);
      return call("add_membership", {
        ...commandInWorkspace(c),
        p_office_id: v.uuid(body, "officeId"),
        p_member_uid: v.uid(body, "memberUid"),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("GET", "/memberships/:id", (c) => {
      onlyQuery(c.query, []);
      return call("member_detail", {
        ...inWorkspace(c),
        p_target_membership_id: c.params.id,
      });
    }),

    // Blueprint 07: a role change ends the membership and creates the new one.
    route("POST", "/memberships/:id/role", async (c) => {
      const body = await v.readBody(c.request, [
        "role",
        "reason",
        "idempotencyKey",
      ]);
      return call("change_membership_role", {
        ...commandInWorkspace(c),
        p_target_membership_id: c.params.id,
        p_role: oneOf(v.text(body, "role", 30), "role", officeRoles),
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/memberships/:id/move", async (c) => {
      const body = await v.readBody(c.request, [
        "toOfficeId",
        "reason",
        "idempotencyKey",
      ]);
      return call("move_membership", {
        ...commandInWorkspace(c),
        p_target_membership_id: c.params.id,
        p_to_office_id: v.uuid(body, "toOfficeId"),
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route(
      "POST",
      "/memberships/:id/suspend",
      (c) => membershipStatus(c, "suspended"),
    ),
    route(
      "POST",
      "/memberships/:id/reactivate",
      (c) => membershipStatus(c, "active"),
    ),

    route("POST", "/memberships/:id/end", async (c) => {
      const body = await v.readBody(c.request, ["reason", "idempotencyKey"]);
      return call("end_membership", {
        ...commandInWorkspace(c),
        p_target_membership_id: c.params.id,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    // Blueprint 22: "funds not managed" for a director. President Team,
    // reason + step-up; refused while the wallet holds money.
    route("POST", "/memberships/:id/funds", async (c) => {
      const body = await v.readBody(c.request, [
        "notManaged",
        "reason",
        "idempotencyKey",
      ]);
      if (typeof body.notManaged !== "boolean") {
        throw new ApiError("validation_error", { field: "notManaged" });
      }
      return call("set_funds_managed", {
        ...commandInWorkspace(c),
        p_target_membership_id: c.params.id,
        p_not_managed: body.notManaged,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/presidents", async (c) => {
      const body = await v.readBody(c.request, [
        "memberUid",
        "reason",
        "idempotencyKey",
      ]);
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
      const body = await v.readBody(c.request, [
        "subjectUid",
        "rules",
        "reason",
        "idempotencyKey",
      ]);
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
      const body = await v.readBody(c.request, [
        "membershipId",
        "reason",
        "idempotencyKey",
      ]);
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

    // ── Blueprint 17: team settings, brand, quick search, backups ──

    route("GET", "/settings", (c) => {
      onlyQuery(c.query, []);
      return call("team_settings", inWorkspace(c));
    }),

    route("PATCH", "/settings", async (c) => {
      const body = await v.readBody(c.request, [
        "expectedRevision",
        "fields",
        "idempotencyKey",
      ]);
      return call("update_team_settings", {
        ...commandInWorkspace(c),
        p_expected_revision: positiveInt(body, "expectedRevision"),
        p_fields: settingsPatch(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/settings/restore", async (c) => {
      const body = await v.readBody(c.request, [
        "expectedRevision",
        "revision",
        "idempotencyKey",
      ]);
      return call("restore_team_settings_revision", {
        ...commandInWorkspace(c),
        p_expected_revision: positiveInt(body, "expectedRevision"),
        p_revision: positiveInt(body, "revision"),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("GET", "/brand", (c) => {
      onlyQuery(c.query, []);
      return call("workspace_brand", inWorkspace(c));
    }),

    // Storage keys for a logo the app server streams or is about to store.
    route("POST", "/brand/asset-key", async (c) => {
      await appServerOnly(c);
      const body = await v.readBody(c.request, ["kind"]);
      const kind = body.kind;
      if (kind !== "logo" && kind !== "icon" && kind !== "logo-light") {
        throw new ApiError("validation_error", { field: "kind" });
      }
      return brandKey(
        await call("brand_asset_key", { ...inWorkspace(c), p_kind: kind }),
      );
    }),

    route("POST", "/brand/upload-key", async (c) => {
      await appServerOnly(c);
      const body = await v.readBody(c.request, ["ext"]);
      const ext = body.ext;
      if (ext !== "jpg" && ext !== "png" && ext !== "webp") {
        throw new ApiError("validation_error", { field: "ext" });
      }
      return brandKey(
        await call("brand_upload_key", { ...inWorkspace(c), p_ext: ext }),
      );
    }),

    route("GET", "/search", (c) => {
      onlyQuery(c.query, ["q", "limit"]);
      const q = c.query.get("q");
      if (q === null || [...q.trim()].length < 2 || [...q.trim()].length > 80) {
        throw new ApiError("validation_error", { field: "q" });
      }
      const limit = queryLimit(c.query);
      if (limit !== null && (limit < 1 || limit > 10)) {
        throw new ApiError("validation_error", { field: "limit" });
      }
      return call("quick_search", {
        ...inWorkspace(c),
        p_query: q,
        p_limit: limit,
      });
    }),

    route("GET", "/backups", (c) => {
      onlyQuery(c.query, []);
      return call("backup_vault", inWorkspace(c));
    }),

    route("POST", "/backups", async (c) => {
      const body = await v.readBody(c.request, ["idempotencyKey"]);
      return call("start_backup", {
        ...commandInWorkspace(c),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/backups/:id/download", async (c) => {
      await appServerOnly(c);
      await v.readBody(c.request, []);
      const target = await call("authorize_backup_download", {
        ...commandInWorkspace(c),
        p_backup_id: c.params.id,
      }) as Record<string, unknown>;
      if (
        typeof target.objectKey !== "string" ||
        !/^backups\/[0-9a-f-]{36}\/[0-9a-f-]{36}\/[0-9]{1,3}\.zip$/.test(
          target.objectKey,
        )
      ) {
        throw new Error("authorize_backup_download returned an unexpected key");
      }
      return target;
    }),

    route("POST", "/restores", async (c) => {
      const body = await v.readBody(c.request, [
        "backupId",
        "reason",
        "idempotencyKey",
      ]);
      return call("request_restore", {
        ...commandInWorkspace(c),
        p_backup_id: v.uuid(body, "backupId"),
        p_reason: v.text(body, "reason", 500, 10),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/restores/:id/cancel", async (c) => {
      const body = await v.readBody(c.request, ["idempotencyKey"]);
      return call("cancel_restore_request", {
        ...commandInWorkspace(c),
        p_restore_id: c.params.id,
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    // Elivate operators only (W-24), until the Admin app has screens.
    route("POST", "/platform/restores/:id/advance", async (c) => {
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
    const cors = corsHeaders(
      request.headers.get("origin"),
      deps.allowedOrigins,
    );
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
    if (!found) {
      return finish(failure("not_found", requestId, {}, cors), "not_found");
    }

    try {
      const token = request.headers.get("authorization")?.match(/^Bearer (.+)$/)
        ?.[1];
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
