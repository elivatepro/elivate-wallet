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
import { evidenceMimeTypes, sha256Hex, sniffMime } from "../_shared/evidence.ts";
import { sameSecret } from "../_shared/secret.ts";

export { sniffMime };

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
  /** Signed short-lived read of one evidence object (payout receipts). */
  signDownload(path: string, seconds: number): Promise<string | null>;
  /** Decrypts a snapshotted bank account number; never logged. */
  openAccount(
    ownerUserId: string,
    ciphertext: string,
    keyVersion: number,
  ): Promise<string>;
  log(entry: LogEntry): void;
  readonly allowedOrigins: readonly string[];
  /** APP_SERVER_SECRET: only the app server may learn a file's storage key. */
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
const objectPathPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/(income|payout|conversion|adjustment|returned_funds)\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const mimeTypes = evidenceMimeTypes;

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

function queryStatus(
  query: URLSearchParams,
  field: string,
  values: readonly string[],
): string | null {
  const value = query.get(field);
  if (value === null) return null;
  if (!values.includes(value)) {
    throw new ApiError("validation_error", { field });
  }
  return value;
}

function optionalText(body: v.Body, field: string, max: number): string | null {
  return body[field] === undefined || body[field] === null ? null : v.text(body, field, max);
}

const activityQuery = [
  "currency",
  "pocketId",
  "direction",
  "type",
  "status",
  "q",
  "tz",
  "from",
  "to",
  "cursor",
  "limit",
];

/** IANA zone names ("Africa/Lagos", "UTC"); the database checks they exist. */
const timeZonePattern = /^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+){0,2}$/;

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
    p_query: queryText(query, "q", 100),
    p_status: queryPattern(query, "status", /^[a-z_]{1,30}$/),
    p_tz: queryPattern(query, "tz", timeZonePattern),
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

function uploadFacts(body: v.Body) {
  const mimeType = v.text(body, "mimeType", 40);
  if (!(mimeTypes as readonly string[]).includes(mimeType)) {
    throw new ApiError("validation_error", { field: "mimeType" });
  }
  const sha256 = v.text(body, "sha256", 64);
  if (!/^[0-9a-f]{64}$/i.test(sha256)) {
    throw new ApiError("validation_error", { field: "sha256" });
  }
  return {
    fileName: v.text(body, "fileName", 200),
    mimeType,
    size: v.integer(body, "size", 1, 10485760),
    sha256: sha256.toLowerCase(),
  };
}

const payoutFields = [
  "amount",
  "fee",
  "paidOn",
  "bankReference",
  "notes",
  "evidenceId",
  "idempotencyKey",
];

/**
 * Record or correct a payout: amounts in NGN; the database checks the cap.
 * The one fix may leave out evidenceId to keep the first receipt (Paper U03).
 */
function payoutArgs(
  body: v.Body,
  keepReceipt = false,
): Record<string, unknown> {
  return {
    p_amount: v.decimal(body, "amount"),
    p_fee_amount: body.fee === undefined || body.fee === null ? null : v.decimal(body, "fee"),
    p_paid_on: v.date(body, "paidOn"),
    p_bank_reference: optionalText(body, "bankReference", 100),
    p_notes: optionalText(body, "notes", 1000),
    p_evidence_id: keepReceipt && (body.evidenceId === undefined || body.evidenceId === null)
      ? null
      : v.uuid(body, "evidenceId"),
    p_idempotency_key: v.idempotencyKey(body),
  };
}

/** An observed moment: ISO 8601 with an offset; the database checks the range. */
function moment(body: v.Body, field: string): string {
  const value = v.text(body, field, 40);
  if (
    !/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]{1,6})?)?(Z|[+-][0-9]{2}:[0-9]{2})$/
      .test(value) || Number.isNaN(Date.parse(value))
  ) {
    throw new ApiError("validation_error", { field });
  }
  return value;
}

/** Evidence ids of an entry: an empty list is "evidence required". */
function entryEvidence(body: v.Body): string[] {
  if (Array.isArray(body.evidenceIds) && body.evidenceIds.length === 0) {
    throw new ApiError("evidence_required");
  }
  return v.uuidList(body, "evidenceIds", 1, 5);
}

const entryKinds = ["conversion", "adjustment", "returned_funds"] as const;
const reversalCategories = [
  "recorded_twice",
  "wrong_member",
  "wrong_amount",
  "wrong_pocket",
  "other",
];

function record(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("unexpected result");
  }
  return value as Record<string, unknown>;
}

// Statements and reports (Blueprint 15): one network and currency per file,
// WAT periods; the database checks meaning (whole months, started periods).
const periodKinds = ["month", "quarter", "year", "year_to_date", "custom"];
const datePattern = /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;

function periodArgs(source: { get(field: string): unknown }): Record<string, unknown> {
  const kind = source.get("periodKind");
  const from = source.get("from");
  const to = source.get("to");
  if (typeof kind !== "string" || !periodKinds.includes(kind)) {
    throw new ApiError("validation_error", { field: "periodKind" });
  }
  if (typeof from !== "string" || !datePattern.test(from)) {
    throw new ApiError("validation_error", { field: "from" });
  }
  if (typeof to !== "string" || !datePattern.test(to)) {
    throw new ApiError("validation_error", { field: "to" });
  }
  return { p_period_kind: kind, p_from: from, p_to: to };
}

function bodySource(body: v.Body) {
  return { get: (field: string) => body[field] };
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

  /** Signs the upload for a path the database built; never a client path. */
  async function signed(created: Record<string, unknown>, fn: string) {
    const path = created.objectPath;
    if (typeof path !== "string" || !objectPathPattern.test(path)) {
      throw new Error(`${fn} returned an unexpected path`);
    }
    const upload = await deps.signUpload(path);
    if (!upload) throw new Error("signing the upload failed");
    return {
      evidenceId: created.evidenceId,
      uploadUrl: upload.url,
      token: upload.token,
      expiresAt: created.expiresAt,
    };
  }

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

    // Unknown-outcome recovery (Blueprint 08, F-03): the fate of the actor's
    // own attempt by its idempotency key. Account-level; no workspace.
    route("GET", "/me/command-outcome", (c) => {
      onlyQuery(c.query, ["idempotencyKey", "command"]);
      const key = queryPattern(
        c.query,
        "idempotencyKey",
        /^[A-Za-z0-9_-]{16,100}$/,
      );
      if (key === null) {
        throw new ApiError("validation_error", { field: "idempotencyKey" });
      }
      return call("command_outcome", {
        ...actorArgs(c),
        p_idempotency_key: key,
        p_command: queryPattern(c.query, "command", /^[a-z][a-z_]{0,59}$/),
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

    // Leadership dashboard (Blueprint 08, W-07): the workspace's scope.
    route("GET", "/overview", (c) => {
      onlyQuery(c.query, ["tz"]);
      return call("leadership_overview", {
        ...inWorkspace(c),
        p_tz: queryPattern(c.query, "tz", timeZonePattern),
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
      onlyQuery(c.query, ["officeId", "cursor", "limit", "q"]);
      return call("income_targets", {
        ...inWorkspace(c),
        p_office_id: queryUuid(c.query, "officeId"),
        p_cursor: queryText(c.query, "cursor", 500),
        p_limit: queryLimit(c.query),
        p_query: queryText(c.query, "q", 100),
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
      const upload = uploadFacts(body);
      const created = record(
        await call("create_evidence_upload", {
          ...commandInWorkspace(c),
          p_target_membership_id: v.uuid(body, "targetMembershipId"),
          p_command_key: v.idempotencyKey(body),
          p_file_name: upload.fileName,
          p_mime_type: upload.mimeType,
          p_size: upload.size,
          p_sha256: upload.sha256,
        }),
      );
      return signed(created, "create_evidence_upload");
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

    // ── Withdrawals (Blueprint 11, W-09/W-10) ──
    route("GET", "/me/withdrawal-sources", (c) => {
      onlyQuery(c.query, []);
      return call("withdrawal_sources", inWorkspace(c));
    }),

    route("GET", "/me/withdrawals", (c) => {
      onlyQuery(c.query, ["status", "cursor", "limit"]);
      return call("my_withdrawals", {
        ...inWorkspace(c),
        p_status: queryStatus(c.query, "status", [
          "open",
          "completed",
          "closed",
        ]),
        p_cursor: queryText(c.query, "cursor", 500),
        p_limit: queryLimit(c.query),
      });
    }),

    route("POST", "/me/withdrawals", async (c) => {
      const body = await v.readBody(c.request, [
        "accountId",
        "amount",
        "payoutAccountId",
        "idempotencyKey",
      ]);
      return call("request_withdrawal", {
        ...commandInWorkspace(c),
        p_account_id: v.uuid(body, "accountId"),
        p_amount: v.decimal(body, "amount"),
        p_payout_account_id: v.uuid(body, "payoutAccountId"),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("GET", "/me/withdrawals/:id", (c) => {
      onlyQuery(c.query, []);
      return call("my_withdrawal", {
        ...inWorkspace(c),
        p_withdrawal_id: c.params.id,
      });
    }),

    route("POST", "/me/withdrawals/:id/cancel", async (c) => {
      const body = await v.readBody(c.request, ["reason", "idempotencyKey"]);
      return call("cancel_withdrawal", {
        ...commandInWorkspace(c),
        p_withdrawal_id: c.params.id,
        p_reason: optionalText(body, "reason", 500),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("GET", "/withdrawals", (c) => {
      onlyQuery(c.query, ["tab", "cursor", "limit"]);
      return call("withdrawal_queue", {
        ...inWorkspace(c),
        p_tab: queryStatus(c.query, "tab", [
          "action",
          "verifying",
          "completed",
          "closed",
        ]),
        p_cursor: queryText(c.query, "cursor", 500),
        p_limit: queryLimit(c.query),
      });
    }),

    route("GET", "/withdrawals/:id", (c) => {
      onlyQuery(c.query, []);
      return call("withdrawal_detail", {
        ...inWorkspace(c),
        p_withdrawal_id: c.params.id,
      });
    }),

    route("POST", "/withdrawals/:id/approve", async (c) => {
      const body = await v.readBody(c.request, ["idempotencyKey"]);
      return call("approve_withdrawal", {
        ...commandInWorkspace(c),
        p_withdrawal_id: c.params.id,
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/withdrawals/:id/reject", async (c) => {
      const body = await v.readBody(c.request, ["reason", "idempotencyKey"]);
      return call("reject_withdrawal", {
        ...commandInWorkspace(c),
        p_withdrawal_id: c.params.id,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/withdrawals/:id/cancel", async (c) => {
      const body = await v.readBody(c.request, ["reason", "idempotencyKey"]);
      return call("cancel_withdrawal", {
        ...commandInWorkspace(c),
        p_withdrawal_id: c.params.id,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    // The database audits the reveal and returns ciphertext; only the number
    // leaves here, never the ciphertext, and it is never logged.
    route("POST", "/withdrawals/:id/reveal", async (c) => {
      await v.readBody(c.request, []);
      const sealed = record(
        await call("reveal_withdrawal_destination", {
          ...commandInWorkspace(c),
          p_withdrawal_id: c.params.id,
        }),
      );
      const { ownerUserId, ciphertext, keyVersion, ...rest } = sealed;
      if (
        typeof ownerUserId !== "string" || typeof ciphertext !== "string" ||
        typeof keyVersion !== "number"
      ) {
        throw new Error(
          "reveal_withdrawal_destination returned an unexpected result",
        );
      }
      return {
        ...rest,
        accountNumber: await deps.openAccount(
          ownerUserId,
          ciphertext,
          keyVersion,
        ),
      };
    }),

    // ── Payouts (W-10 step 3, W-11) ──
    route("POST", "/payout-evidence/uploads", async (c) => {
      const body = await v.readBody(c.request, [
        "withdrawalId",
        "idempotencyKey",
        "fileName",
        "mimeType",
        "size",
        "sha256",
      ]);
      const upload = uploadFacts(body);
      const created = record(
        await call("create_payout_evidence_upload", {
          ...commandInWorkspace(c),
          p_withdrawal_id: v.uuid(body, "withdrawalId"),
          p_command_key: v.idempotencyKey(body),
          p_file_name: upload.fileName,
          p_mime_type: upload.mimeType,
          p_size: upload.size,
          p_sha256: upload.sha256,
        }),
      );
      return signed(created, "create_payout_evidence_upload");
    }),

    route("POST", "/withdrawals/:id/payouts", async (c) => {
      const body = await v.readBody(c.request, payoutFields);
      return call("record_payout", {
        ...commandInWorkspace(c),
        p_withdrawal_id: c.params.id,
        ...payoutArgs(body),
      });
    }),

    // The one fix (Paper U03): without evidenceId the first receipt is kept.
    route("POST", "/payouts/:id/correct", async (c) => {
      const body = await v.readBody(c.request, payoutFields);
      return call("correct_payout", {
        ...commandInWorkspace(c),
        p_payout_id: c.params.id,
        ...payoutArgs(body, true),
      });
    }),

    route("POST", "/payouts/:id/retry", async (c) => {
      const body = await v.readBody(c.request, ["idempotencyKey"]);
      return call("retry_payout_check", {
        ...commandInWorkspace(c),
        p_payout_id: c.params.id,
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("GET", "/payouts/:id/receipt", async (c) => {
      onlyQuery(c.query, ["revision"]);
      const revision = queryStatus(c.query, "revision", ["1", "2"]);
      if (revision === null) {
        throw new ApiError("validation_error", { field: "revision" });
      }
      const target = record(
        await call("payout_receipt", {
          ...inWorkspace(c),
          p_payout_id: c.params.id,
          p_revision: Number(revision),
        }),
      );
      const { objectPath, ...rest } = target;
      if (
        typeof objectPath !== "string" || !objectPathPattern.test(objectPath)
      ) {
        throw new Error("payout_receipt returned an unexpected path");
      }
      const url = await deps.signDownload(objectPath, 60);
      if (!url) throw new Error("signing the receipt failed");
      return { ...rest, url, expiresIn: 60 };
    }),

    // ── Statements and reports (Blueprint 15, W-18) ──
    route("GET", "/statements/options", (c) => {
      onlyQuery(c.query, []);
      return call("statement_options", actorArgs(c));
    }),

    route("GET", "/statements", (c) => {
      onlyQuery(c.query, ["cursor", "limit"]);
      return call("my_exports", {
        ...actorArgs(c),
        p_cursor: queryText(c.query, "cursor", 500),
        p_limit: queryLimit(c.query),
      });
    }),

    route("POST", "/statements", async (c) => {
      const body = await v.readBody(c.request, [
        "tenantId",
        "currency",
        "periodKind",
        "from",
        "to",
        "format",
        "idempotencyKey",
      ]);
      const format = v.text(body, "format", 3);
      if (format !== "pdf" && format !== "csv") {
        throw new ApiError("validation_error", { field: "format" });
      }
      return call("create_statement", {
        ...actorArgs(c),
        p_tenant_id: body.tenantId === undefined || body.tenantId === null
          ? null
          : v.uuid(body, "tenantId"),
        p_currency: v.currency(body, "currency"),
        ...periodArgs(bodySource(body)),
        p_format: format,
        p_idempotency_key: v.idempotencyKey(body),
        p_request_id: c.requestId,
      });
    }),

    route("GET", "/reports/overview", (c) => {
      onlyQuery(c.query, ["currency", "periodKind", "from", "to"]);
      const currency = queryPattern(c.query, "currency", /^[A-Z]{3}$/);
      if (currency === null) throw new ApiError("validation_error", { field: "currency" });
      return call("report_overview", {
        ...inWorkspace(c),
        p_currency: currency,
        ...periodArgs(c.query),
      });
    }),

    route("GET", "/reports/members", (c) => {
      onlyQuery(c.query, ["q"]);
      const q = queryText(c.query, "q", 100);
      if (q === null) throw new ApiError("validation_error", { field: "q" });
      return call("report_members", { ...inWorkspace(c), p_query: q });
    }),

    route("GET", "/reports", (c) => {
      onlyQuery(c.query, ["cursor", "limit"]);
      return call("workspace_exports", {
        ...inWorkspace(c),
        p_cursor: queryText(c.query, "cursor", 500),
        p_limit: queryLimit(c.query),
      });
    }),

    route("POST", "/reports", async (c) => {
      const body = await v.readBody(c.request, [
        "kind",
        "memberWalletId",
        "currency",
        "periodKind",
        "from",
        "to",
        "idempotencyKey",
      ]);
      const kind = v.text(body, "kind", 30);
      if (!["office_pdf", "transactions_csv", "member_balances_csv"].includes(kind)) {
        throw new ApiError("validation_error", { field: "kind" });
      }
      return call("create_report", {
        ...commandInWorkspace(c),
        p_kind: kind,
        p_member_wallet_id: body.memberWalletId === undefined || body.memberWalletId === null
          ? null
          : v.uuid(body, "memberWalletId"),
        p_currency: v.currency(body, "currency"),
        ...periodArgs(bodySource(body)),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("GET", "/exports/:id", (c) => {
      onlyQuery(c.query, []);
      return call("export_file", { ...actorArgs(c), p_export_id: c.params.id });
    }),

    route("POST", "/exports/:id/retry", async (c) => {
      await v.readBody(c.request, []);
      return call("retry_export", {
        ...actorArgs(c),
        p_export_id: c.params.id,
        p_request_id: c.requestId,
      });
    }),

    // The storage key goes to the app server only, which streams the file.
    route("POST", "/exports/:id/download", async (c) => {
      const given = c.request.headers.get("x-app-server-secret");
      if (!deps.appServerSecret || !given || !(await sameSecret(given, deps.appServerSecret))) {
        throw new ApiError("authorization_denied", { reason: "app_server_only" });
      }
      const body = await v.readBody(c.request, ["part"]);
      const part = body.part === undefined ? "file" : v.text(body, "part", 10);
      if (part !== "file" && part !== "preview") {
        throw new ApiError("validation_error", { field: "part" });
      }
      const target = record(
        await call("authorize_export_download", {
          ...actorArgs(c),
          p_export_id: c.params.id,
          p_part: part,
          p_request_id: c.requestId,
        }),
      );
      if (
        typeof target.objectKey !== "string" ||
        !/^exports\/[0-9a-f-]{36}\/[0-9a-f-]{36}\/[0-9]{1,3}\.(pdf|csv)(\.png)?$/.test(
          target.objectKey,
        )
      ) {
        throw new Error("authorize_export_download returned an unexpected key");
      }
      return target;
    }),

    // ── Evidence review (W-11) ──
    route("GET", "/reviews", (c) => {
      onlyQuery(c.query, ["tab", "cursor", "limit"]);
      return call("review_queue", {
        ...inWorkspace(c),
        p_tab: queryStatus(c.query, "tab", [
          "assigned",
          "cleared",
          "rejected",
          "all",
        ]),
        p_cursor: queryText(c.query, "cursor", 500),
        p_limit: queryLimit(c.query),
      });
    }),

    route("GET", "/reviews/:id", (c) => {
      onlyQuery(c.query, []);
      return call("review_case", {
        ...inWorkspace(c),
        p_payout_id: c.params.id,
      });
    }),

    // A payout case by default; `kind` names a conversion, adjustment or
    // returned-funds case (Blueprint 12).
    route("POST", "/reviews/:id/decision", async (c) => {
      const body = await v.readBody(c.request, [
        "kind",
        "decision",
        "reason",
        "idempotencyKey",
      ]);
      const decision = v.text(body, "decision", 10);
      if (decision !== "clear" && decision !== "reject") {
        throw new ApiError("validation_error", { field: "decision" });
      }
      const kind = body.kind === undefined || body.kind === null
        ? "payout"
        : v.text(body, "kind", 20);
      if (
        kind !== "payout" && !(entryKinds as readonly string[]).includes(kind)
      ) {
        throw new ApiError("validation_error", { field: "kind" });
      }
      const args = {
        ...commandInWorkspace(c),
        p_decision: decision,
        p_reason: v.reason(body),
        p_idempotency_key: v.idempotencyKey(body),
      };
      return kind === "payout"
        ? call("review_payout", { ...args, p_payout_id: c.params.id })
        : call("review_entry", { ...args, p_entry_id: c.params.id });
    }),

    route("GET", "/reviews/:id/evidence/:evidenceId", async (c) => {
      onlyQuery(c.query, []);
      const target = record(
        await call("entry_evidence", {
          ...inWorkspace(c),
          p_entry_id: c.params.id,
          p_evidence_id: c.params.evidenceId,
        }),
      );
      const { objectPath, ...rest } = target;
      if (
        typeof objectPath !== "string" || !objectPathPattern.test(objectPath)
      ) {
        throw new Error("entry_evidence returned an unexpected path");
      }
      const url = await deps.signDownload(objectPath, 60);
      if (!url) throw new Error("signing the evidence failed");
      return { ...rest, url, expiresIn: 60 };
    }),

    // ── Conversions, adjustments, returned funds (Blueprint 12) ──
    route("GET", "/entries/targets", (c) => {
      onlyQuery(c.query, ["kind", "cursor", "limit", "q"]);
      const kind = queryStatus(c.query, "kind", ["conversion", "adjustment"]);
      if (kind === null) {
        throw new ApiError("validation_error", { field: "kind" });
      }
      return call("entry_targets", {
        ...inWorkspace(c),
        p_kind: kind,
        p_cursor: queryText(c.query, "cursor", 500),
        p_limit: queryLimit(c.query),
        p_query: queryText(c.query, "q", 100),
      });
    }),

    route("GET", "/entries/segments", (c) => {
      onlyQuery(c.query, ["kind", "membershipId"]);
      const kind = queryStatus(c.query, "kind", ["conversion", "adjustment"]);
      const membershipId = queryUuid(c.query, "membershipId");
      if (kind === null) {
        throw new ApiError("validation_error", { field: "kind" });
      }
      if (membershipId === null) {
        throw new ApiError("validation_error", { field: "membershipId" });
      }
      return call("entry_segments", {
        ...inWorkspace(c),
        p_kind: kind,
        p_target_membership_id: membershipId,
      });
    }),

    route("POST", "/entry-evidence/uploads", async (c) => {
      const body = await v.readBody(c.request, [
        "kind",
        "targetMembershipId",
        "idempotencyKey",
        "fileName",
        "mimeType",
        "size",
        "sha256",
      ]);
      const kind = v.text(body, "kind", 20);
      if (!(entryKinds as readonly string[]).includes(kind)) {
        throw new ApiError("validation_error", { field: "kind" });
      }
      const upload = uploadFacts(body);
      const created = record(
        await call("create_entry_evidence_upload", {
          ...commandInWorkspace(c),
          p_kind: kind,
          p_target_membership_id: v.uuid(body, "targetMembershipId"),
          p_command_key: v.idempotencyKey(body),
          p_file_name: upload.fileName,
          p_mime_type: upload.mimeType,
          p_size: upload.size,
          p_sha256: upload.sha256,
        }),
      );
      return signed(created, "create_entry_evidence_upload");
    }),

    route("POST", "/conversions", async (c) => {
      const body = await v.readBody(c.request, [
        "sourceAccountId",
        "amount",
        "destinationCurrency",
        "destinationAmount",
        "quotedRate",
        "provider",
        "convertedAt",
        "externalReference",
        "notes",
        "evidenceIds",
        "idempotencyKey",
      ]);
      let quotedRate: string | null = null;
      if (body.quotedRate !== undefined && body.quotedRate !== null) {
        quotedRate = v.text(body, "quotedRate", 22);
        if (!/^[0-9]{1,12}(\.[0-9]{1,8})?$/.test(quotedRate)) {
          throw new ApiError("validation_error", { field: "quotedRate" });
        }
      }
      return call("submit_conversion", {
        ...commandInWorkspace(c),
        p_source_account_id: v.uuid(body, "sourceAccountId"),
        p_amount: v.decimal(body, "amount"),
        p_destination_currency: v.currency(body, "destinationCurrency"),
        p_destination_amount: v.decimal(body, "destinationAmount"),
        p_quoted_rate: quotedRate,
        p_provider: v.text(body, "provider", 100),
        p_converted_at: moment(body, "convertedAt"),
        p_external_reference: optionalText(body, "externalReference", 100),
        p_notes: optionalText(body, "notes", 1000),
        p_evidence_ids: entryEvidence(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/adjustments", async (c) => {
      const body = await v.readBody(c.request, [
        "targetMembershipId",
        "direction",
        "currency",
        "amount",
        "reason",
        "notes",
        "evidenceIds",
        "idempotencyKey",
      ]);
      const direction = v.text(body, "direction", 6);
      if (direction !== "credit" && direction !== "debit") {
        throw new ApiError("validation_error", { field: "direction" });
      }
      return call("submit_adjustment", {
        ...commandInWorkspace(c),
        p_target_membership_id: v.uuid(body, "targetMembershipId"),
        p_direction: direction,
        p_currency: v.currency(body, "currency"),
        p_amount: v.decimal(body, "amount"),
        p_reason: v.reason(body),
        p_notes: optionalText(body, "notes", 1000),
        p_evidence_ids: entryEvidence(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("GET", "/withdrawals/:id/returnable", (c) => {
      onlyQuery(c.query, []);
      return call("returnable_withdrawal", {
        ...inWorkspace(c),
        p_withdrawal_id: c.params.id,
      });
    }),

    route("POST", "/withdrawals/:id/returns", async (c) => {
      const body = await v.readBody(c.request, [
        "amount",
        "seenAt",
        "returnedBy",
        "bankReference",
        "notes",
        "evidenceIds",
        "idempotencyKey",
      ]);
      return call("submit_returned_funds", {
        ...commandInWorkspace(c),
        p_withdrawal_id: c.params.id,
        p_amount: v.decimal(body, "amount"),
        p_seen_at: moment(body, "seenAt"),
        p_returned_by: v.text(body, "returnedBy", 100),
        p_bank_reference: optionalText(body, "bankReference", 100),
        p_notes: optionalText(body, "notes", 1000),
        p_evidence_ids: entryEvidence(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    // ── Reversals (W-15) ──
    route("GET", "/reversals/preview", (c) => {
      onlyQuery(c.query, ["reference"]);
      const reference = queryPattern(
        c.query,
        "reference",
        /^[A-Za-z0-9-]{11,20}$/,
      );
      if (reference === null) {
        throw new ApiError("validation_error", { field: "reference" });
      }
      return call("reversal_preview", {
        ...inWorkspace(c),
        p_reference: reference,
      });
    }),

    route("POST", "/reversals", async (c) => {
      const body = await v.readBody(c.request, [
        "transactionId",
        "category",
        "note",
        "confirmReference",
        "idempotencyKey",
      ]);
      const category = v.text(body, "category", 20);
      if (!reversalCategories.includes(category)) {
        throw new ApiError("validation_error", { field: "category" });
      }
      return call("reverse_transaction", {
        ...commandInWorkspace(c),
        p_transaction_id: v.uuid(body, "transactionId"),
        p_category: category,
        p_note: optionalText(body, "note", 500),
        p_confirm_reference: v.text(body, "confirmReference", 20),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    // ── Pocket moves (W-13) ──
    route("GET", "/me/transfer-choices", (c) => {
      onlyQuery(c.query, []);
      return call("transfer_choices", inWorkspace(c));
    }),

    route("GET", "/me/pocket-transfers", (c) => {
      onlyQuery(c.query, ["status", "cursor", "limit"]);
      return call("my_pocket_transfers", {
        ...inWorkspace(c),
        p_status: queryStatus(c.query, "status", [
          "open",
          "completed",
          "closed",
        ]),
        p_cursor: queryText(c.query, "cursor", 500),
        p_limit: queryLimit(c.query),
      });
    }),

    route("POST", "/me/pocket-transfers", async (c) => {
      const body = await v.readBody(c.request, [
        "sourceAccountId",
        "destinationPocketId",
        "amount",
        "idempotencyKey",
      ]);
      return call("request_pocket_transfer", {
        ...commandInWorkspace(c),
        p_source_account_id: v.uuid(body, "sourceAccountId"),
        p_destination_pocket_id: v.uuid(body, "destinationPocketId"),
        p_amount: v.decimal(body, "amount"),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/me/pocket-transfers/:id/cancel", async (c) => {
      const body = await v.readBody(c.request, ["idempotencyKey"]);
      return call("cancel_pocket_transfer", {
        ...commandInWorkspace(c),
        p_transfer_id: c.params.id,
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("GET", "/pocket-transfers", (c) => {
      onlyQuery(c.query, ["tab", "cursor", "limit"]);
      return call("transfer_queue", {
        ...inWorkspace(c),
        p_tab: queryStatus(c.query, "tab", ["waiting", "history"]),
        p_cursor: queryText(c.query, "cursor", 500),
        p_limit: queryLimit(c.query),
      });
    }),

    route("POST", "/pocket-transfers/:id/approve", async (c) => {
      const body = await v.readBody(c.request, ["idempotencyKey"]);
      return call("approve_pocket_transfer", {
        ...commandInWorkspace(c),
        p_transfer_id: c.params.id,
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/pocket-transfers/:id/reject", async (c) => {
      const body = await v.readBody(c.request, ["reason", "idempotencyKey"]);
      return call("reject_pocket_transfer", {
        ...commandInWorkspace(c),
        p_transfer_id: c.params.id,
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
