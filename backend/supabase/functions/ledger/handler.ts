// Routes for the `ledger` Edge Function (Blueprint 04 — B4). Dependencies are
// injected so tests can exercise routing, validation, receipt verification and
// error mapping. Amounts are decimal strings in both directions.

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

/** A stored object: its real size, and its bytes when within the limit. */
export interface StoredObject {
  readonly size: number;
  readonly bytes: Uint8Array | null;
}

export interface Deps {
  /** Verifies the bearer token; returns null when it is not a valid session token. */
  verifyToken(token: string): Promise<Actor | null>;
  rpc(fn: string, args: Record<string, unknown>): Promise<RpcResult>;
  /** Signed single-object upload for a server-built path in the evidence bucket. */
  signUpload(
    path: string,
  ): Promise<{ readonly url: string; readonly token: string } | null>;
  /** Reads a private evidence object; bytes are null when larger than maxBytes. */
  download(path: string, maxBytes: number): Promise<StoredObject | null>;
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
const objectPathPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/income\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const mimeTypes = ["application/pdf", "image/jpeg", "image/png"] as const;

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

/** Matches `/wallets/:walletId/activity` against a path; path ids must be UUIDs. */
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

function queryPattern(
  query: URLSearchParams,
  field: string,
  pattern: RegExp,
): string | null {
  const value = query.get(field);
  if (value === null) return null;
  if (!pattern.test(value)) throw new ApiError("validation_error", { field });
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

function optionalText(body: v.Body, field: string, max: number): string | null {
  return body[field] === undefined || body[field] === null ? null : v.text(body, field, max);
}

const activityQuery = [
  "currency",
  "pocketId",
  "direction",
  "type",
  "from",
  "to",
  "cursor",
  "limit",
];

function activityArgs(query: URLSearchParams): Record<string, unknown> {
  onlyQuery(query, activityQuery);
  return {
    p_currency: queryPattern(query, "currency", /^[A-Z]{3}$/),
    p_pocket_id: queryUuid(query, "pocketId"),
    p_direction: queryPattern(query, "direction", /^(in|out)$/),
    p_type: queryPattern(query, "type", /^[a-z_]{1,30}$/),
    p_from: queryPattern(query, "from", /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/),
    p_to: queryPattern(query, "to", /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/),
    p_cursor: queryText(query, "cursor", 500),
    p_limit: queryLimit(query),
  };
}

/** The pockets list for a split change; the database checks meaning. */
function pockets(body: v.Body): unknown[] {
  const value = body.pockets;
  if (!Array.isArray(value) || value.length < 1 || value.length > 12) {
    throw new ApiError("validation_error", { field: "pockets" });
  }
  return value.map((item: unknown) => {
    if (typeof item !== "object" || item === null || Array.isArray(item)) {
      throw new ApiError("validation_error", { field: "pockets" });
    }
    const p = item as v.Body;
    for (const key of Object.keys(p)) {
      if (!["pocketId", "name", "basisPoints"].includes(key)) {
        throw new ApiError("validation_error", {
          field: `pockets.${key}`,
          reason: "unknown_field",
        });
      }
    }
    const pocketId = p.pocketId === undefined || p.pocketId === null ? null : v.uuid(p, "pocketId");
    return {
      pocketId,
      name: v.text(p, "name", 40),
      basisPoints: v.integer(p, "basisPoints", 0, 10000),
    };
  });
}

/** Detects PDF, JPEG or PNG from the first bytes; null for anything else. */
export function sniffMime(
  bytes: Uint8Array,
): (typeof mimeTypes)[number] | null {
  const starts = (sig: number[]) => sig.every((b, i) => bytes[i] === b);
  if (starts([0x25, 0x50, 0x44, 0x46, 0x2d])) return "application/pdf";
  if (starts([0xff, 0xd8, 0xff])) return "image/jpeg";
  if (starts([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    return "image/png";
  }
  return null;
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}

function record(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("unexpected result");
  }
  return value as Record<string, unknown>;
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
  const inWorkspace = (c: Context) => ({
    ...actorArgs(c),
    p_membership_id: workspace(c.request),
  });
  const commandInWorkspace = (c: Context) => ({
    ...inWorkspace(c),
    p_request_id: c.requestId,
  });

  const route = (method: string, pattern: string, handler: Handler): Route => ({
    method,
    pattern,
    handler,
  });

  const routes: Route[] = [
    // ── Own wallet (account-level; no workspace) ──
    route("GET", "/me/wallet", (c) => {
      onlyQuery(c.query, []);
      return call("my_wallet", actorArgs(c));
    }),

    route("GET", "/me/activity", (c) => {
      const args = activityArgs(
        new URLSearchParams([...c.query].filter(([k]) => k !== "tenantId")),
      );
      return call("my_activity", {
        ...actorArgs(c),
        ...args,
        p_tenant_id: queryUuid(c.query, "tenantId"),
      });
    }),

    route("GET", "/me/transactions/:id", (c) => {
      onlyQuery(c.query, []);
      return call("my_transaction", {
        ...actorArgs(c),
        p_transaction_id: c.params.id,
      });
    }),

    route("GET", "/currencies", (c) => {
      onlyQuery(c.query, []);
      return call("ledger_currencies", actorArgs(c));
    }),

    // ── Pockets and split ──
    route("GET", "/allocation", (c) => {
      onlyQuery(c.query, []);
      return call("allocation_policy", inWorkspace(c));
    }),

    route("GET", "/allocation/versions", (c) => {
      onlyQuery(c.query, []);
      return call("allocation_versions", inWorkspace(c));
    }),

    route("PUT", "/allocation", async (c) => {
      const body = await v.readBody(c.request, [
        "expectedVersion",
        "pockets",
        "reason",
        "idempotencyKey",
      ]);
      return call("set_allocation", {
        ...commandInWorkspace(c),
        p_expected_version: v.integer(body, "expectedVersion", 1, 2147483647),
        p_pockets: pockets(body),
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("GET", "/admin/tenants/:id/allocation-versions", (c) => {
      onlyQuery(c.query, []);
      return call("admin_allocation_versions", {
        ...actorArgs(c),
        p_tenant_id: c.params.id,
      });
    }),

    // ── Managed wallets and totals ──
    route("GET", "/wallets", (c) => {
      onlyQuery(c.query, ["officeId", "q", "cursor", "limit"]);
      return call("list_managed_wallets", {
        ...inWorkspace(c),
        p_office_id: queryUuid(c.query, "officeId"),
        p_query: queryText(c.query, "q", 100),
        p_cursor: queryText(c.query, "cursor", 500),
        p_limit: queryLimit(c.query),
      });
    }),

    route("GET", "/wallets/:walletId", (c) => {
      onlyQuery(c.query, []);
      return call("managed_wallet", {
        ...inWorkspace(c),
        p_wallet_id: c.params.walletId,
      });
    }),

    route("GET", "/wallets/:walletId/activity", (c) => {
      return call("managed_wallet_activity", {
        ...inWorkspace(c),
        ...activityArgs(c.query),
        p_wallet_id: c.params.walletId,
      });
    }),

    route("GET", "/wallets/:walletId/transactions/:id", (c) => {
      onlyQuery(c.query, []);
      return call("managed_transaction", {
        ...inWorkspace(c),
        p_wallet_id: c.params.walletId,
        p_transaction_id: c.params.id,
      });
    }),

    route("GET", "/offices/:id/totals", (c) => {
      onlyQuery(c.query, []);
      return call("office_totals", {
        ...inWorkspace(c),
        p_office_id: c.params.id,
      });
    }),

    // ── Income ──
    route("GET", "/income/targets", (c) => {
      onlyQuery(c.query, ["officeId", "cursor", "limit"]);
      return call("income_targets", {
        ...inWorkspace(c),
        p_office_id: queryUuid(c.query, "officeId"),
        p_cursor: queryText(c.query, "cursor", 500),
        p_limit: queryLimit(c.query),
      });
    }),

    route("POST", "/evidence/uploads", async (c) => {
      const body = await v.readBody(c.request, [
        "targetMembershipId",
        "idempotencyKey",
        "fileName",
        "mimeType",
        "size",
        "sha256",
      ]);
      const mimeType = v.text(body, "mimeType", 40);
      if (!(mimeTypes as readonly string[]).includes(mimeType)) {
        throw new ApiError("validation_error", { field: "mimeType" });
      }
      const sha256 = v.text(body, "sha256", 64);
      if (!/^[0-9a-f]{64}$/i.test(sha256)) {
        throw new ApiError("validation_error", { field: "sha256" });
      }
      const created = record(
        await call("create_evidence_upload", {
          ...commandInWorkspace(c),
          p_target_membership_id: v.uuid(body, "targetMembershipId"),
          p_command_key: v.idempotencyKey(body),
          p_file_name: v.text(body, "fileName", 200),
          p_mime_type: mimeType,
          p_size: v.integer(body, "size", 1, 10485760),
          p_sha256: sha256.toLowerCase(),
        }),
      );
      const path = created.objectPath;
      if (typeof path !== "string" || !objectPathPattern.test(path)) {
        throw new Error("create_evidence_upload returned an unexpected path");
      }
      const signed = await deps.signUpload(path);
      if (!signed) throw new Error("signing the upload failed");
      return {
        evidenceId: created.evidenceId,
        uploadUrl: signed.url,
        token: signed.token,
        expiresAt: created.expiresAt,
      };
    }),

    route("POST", "/evidence/uploads/:id/finalize", async (c) => {
      await v.readBody(c.request, []);
      const target = record(
        await call("evidence_upload_target", {
          ...inWorkspace(c),
          p_evidence_id: c.params.id,
        }),
      );
      const path = target.objectPath;
      const maxSize = target.maxSize;
      if (
        typeof path !== "string" || !objectPathPattern.test(path) ||
        typeof maxSize !== "number"
      ) {
        throw new Error("evidence_upload_target returned an unexpected result");
      }
      const stored = await deps.download(path, maxSize);
      if (!stored) {
        throw new ApiError("evidence_invalid", { reason: "not_uploaded" });
      }
      const facts = stored.bytes
        ? {
          size: stored.bytes.length,
          sha256: await sha256Hex(stored.bytes),
          mime: sniffMime(stored.bytes),
        }
        : { size: stored.size, sha256: "0".repeat(64), mime: null };
      const result = record(
        await call("finalize_evidence_upload", {
          ...commandInWorkspace(c),
          p_evidence_id: c.params.id,
          p_size: facts.size,
          p_sha256: facts.sha256,
          p_mime: facts.mime,
        }),
      );
      if (result.status !== "finalized") {
        throw new ApiError("evidence_invalid", { reason: "content_mismatch" });
      }
      return result;
    }),

    route("POST", "/income", async (c) => {
      const body = await v.readBody(c.request, [
        "targetMembershipId",
        "currency",
        "amount",
        "source",
        "receivedOn",
        "providerReference",
        "notes",
        "fee",
        "evidenceIds",
        "idempotencyKey",
      ]);
      let fee: { amount: string; currency: string } | null = null;
      if (body.fee !== undefined && body.fee !== null) {
        if (typeof body.fee !== "object" || Array.isArray(body.fee)) {
          throw new ApiError("validation_error", { field: "fee" });
        }
        const f = body.fee as v.Body;
        for (const key of Object.keys(f)) {
          if (key !== "amount" && key !== "currency") {
            throw new ApiError("validation_error", {
              field: `fee.${key}`,
              reason: "unknown_field",
            });
          }
        }
        fee = {
          amount: v.decimal(f, "amount"),
          currency: v.currency(f, "currency"),
        };
      }
      if (Array.isArray(body.evidenceIds) && body.evidenceIds.length === 0) {
        throw new ApiError("evidence_required");
      }
      return call("record_income", {
        ...commandInWorkspace(c),
        p_target_membership_id: v.uuid(body, "targetMembershipId"),
        p_currency: v.currency(body, "currency"),
        p_amount: v.decimal(body, "amount"),
        p_source: v.text(body, "source", 100),
        p_received_on: v.date(body, "receivedOn"),
        p_provider_reference: optionalText(body, "providerReference", 100),
        p_notes: optionalText(body, "notes", 1000),
        p_fee_amount: fee?.amount ?? null,
        p_fee_currency: fee?.currency ?? null,
        p_evidence_ids: v.uuidList(body, "evidenceIds", 1, 5),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/income/cancel", async (c) => {
      const body = await v.readBody(c.request, [
        "targetMembershipId",
        "reason",
        "idempotencyKey",
      ]);
      return call("cancel_income_attempt", {
        ...commandInWorkspace(c),
        p_target_membership_id: v.uuid(body, "targetMembershipId"),
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),
  ];

  return async (request: Request): Promise<Response> => {
    const started = Date.now();
    const requestId = crypto.randomUUID();
    const cors = corsHeaders(
      request.headers.get("origin"),
      deps.allowedOrigins,
    );
    const url = new URL(request.url);
    const path = url.pathname.replace(/^.*?\/ledger(?=\/|$)/, "") || "/";

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
