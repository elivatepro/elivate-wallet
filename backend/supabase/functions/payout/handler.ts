// Routes for the `payout` Edge Function (Blueprint 05 — B4). Dependencies are
// injected so tests can exercise routing, validation, the provider flow and
// error mapping. Full account numbers exist only in memory here: they are
// sealed before reaching the database and returned only by the owner reveal.

import type { AccountCrypto } from "../_shared/account_crypto.ts";
import {
  ApiError,
  corsHeaders,
  type Details,
  failure,
  isErrorCode,
  success,
} from "../_shared/http.ts";
import { bankCodePattern, type NameLookupProvider } from "../_shared/name_lookup.ts";
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
  /** Null when PAYSTACK_SECRET_KEY is not configured: lookups answer provider_unavailable. */
  readonly provider: NameLookupProvider | null;
  readonly accountCrypto: AccountCrypto;
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

type Json = Readonly<Record<string, unknown>>;

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const lookupFields = [
  "lookupId",
  "status",
  "bankCode",
  "bankName",
  "accountLast4",
  "accountName",
  "nameMatch",
  "replacesPayoutAccountId",
  "expiresAt",
  "confirmedPayoutAccountId",
] as const;

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

/** Matches `/accounts/:id/primary` against a path; path ids must be UUIDs. */
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

function bankCode(body: v.Body): string {
  const value = body.bankCode;
  const code = typeof value === "string" ? value.trim().toUpperCase() : "";
  if (!bankCodePattern.test(code)) throw new ApiError("validation_error", { field: "bankCode" });
  return code;
}

/** A string of exactly 10 digits; numbers are refused (leading zeros). */
function accountNumber(body: v.Body): string {
  const value = body.accountNumber;
  if (typeof value !== "string" || !/^[0-9]{10}$/.test(value)) {
    throw new ApiError("validation_error", { field: "accountNumber" });
  }
  return value;
}

function optionalUuid(body: v.Body, field: string): string | null {
  return body[field] === null || body[field] === undefined ? null : v.uuid(body, field);
}

function optionalReason(body: v.Body): string | null {
  return body.reason === null || body.reason === undefined ? null : v.text(body, "reason", 500);
}

function asObject(value: unknown): Json {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("unexpected result shape");
  }
  return value as Json;
}

/** The public view of a lookup proof. */
function publicLookup(lookup: Json): Json {
  const out: Record<string, unknown> = {};
  for (const field of lookupFields) out[field] = lookup[field] ?? null;
  return out;
}

export function createHandler(deps: Deps): (request: Request) => Promise<Response> {
  async function call(fn: string, args: Record<string, unknown>): Promise<Json> {
    const { data, error } = await deps.rpc(fn, args);
    if (error) {
      if (isErrorCode(error.message)) {
        throw new ApiError(error.message, parseDetails(error.details));
      }
      throw new Error(`rpc ${fn} failed`);
    }
    return asObject(data);
  }

  const actorArgs = ({ actor }: Context) => ({
    p_user_id: actor.userId,
    p_session_id: actor.sessionId,
  });
  const inWorkspace = (c: Context) => ({ ...actorArgs(c), p_membership_id: workspace(c.request) });
  const commandInWorkspace = (c: Context) => ({ ...inWorkspace(c), p_request_id: c.requestId });

  const route = (method: string, pattern: string, handler: Handler): Route => ({
    method,
    pattern,
    handler,
  });

  async function listBanks(c: Context): Promise<Json> {
    const cached = await call("list_banks", actorArgs(c));
    if (cached.stale !== true) return cached;
    const empty = !Array.isArray(cached.banks) || cached.banks.length === 0;
    const fresh = deps.provider
      ? await deps.provider.listBanks()
      : { kind: "unavailable" as const };
    if (fresh.kind === "ok") {
      await call("refresh_banks", {
        ...actorArgs(c),
        p_provider: "paystack",
        p_banks: fresh.banks,
      });
      return call("list_banks", actorArgs(c));
    }
    if (empty) throw new ApiError("provider_unavailable");
    return cached;
  }

  const routes: Route[] = [
    route("GET", "/banks", (c) => {
      onlyQuery(c.query, []);
      return listBanks(c);
    }),

    route("POST", "/lookups", async (c) => {
      const body = await v.readBody(c.request, [
        "bankCode",
        "accountNumber",
        "replacesPayoutAccountId",
        "idempotencyKey",
      ]);
      const code = bankCode(body);
      const number = accountNumber(body);
      const replaces = optionalUuid(body, "replacesPayoutAccountId");
      const key = v.idempotencyKey(body);
      const sealed = await deps.accountCrypto.seal(c.actor.userId, code, number);

      let lookup = await call("prepare_account_lookup", {
        ...inWorkspace(c),
        p_bank_code: code,
        p_account_ciphertext: sealed.ciphertext,
        p_key_version: sealed.keyVersion,
        p_account_fingerprint: sealed.fingerprint,
        p_account_last4: sealed.last4,
        p_replaces_payout_account_id: replaces,
        p_idempotency_key: key,
      });

      if (lookup.status === "pending") {
        if (!deps.provider) throw new ApiError("provider_unavailable");
        const outcome = await deps.provider.resolve(code, number);
        if (outcome.kind === "unavailable") {
          throw new ApiError(
            "provider_unavailable",
            outcome.retryAfterSeconds === undefined
              ? {}
              : { retryAfterSeconds: outcome.retryAfterSeconds },
          );
        }
        lookup = await call("record_account_lookup", {
          ...commandInWorkspace(c),
          p_lookup_id: lookup.lookupId,
          p_outcome: outcome.kind,
          p_account_name: outcome.kind === "resolved" ? outcome.accountName : null,
        });
      }
      if (lookup.status === "not_found") throw new ApiError("account_not_found");
      if (lookup.status !== "resolved") throw new Error("unexpected lookup status");
      return publicLookup(lookup);
    }),

    route("POST", "/accounts", async (c) => {
      const body = await v.readBody(c.request, [
        "lookupId",
        "confirmed",
        "reason",
        "idempotencyKey",
      ]);
      if (body.confirmed !== true) throw new ApiError("validation_error", { field: "confirmed" });
      return call("confirm_payout_account", {
        ...commandInWorkspace(c),
        p_lookup_id: v.uuid(body, "lookupId"),
        p_reason: optionalReason(body),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("GET", "/accounts", (c) => {
      onlyQuery(c.query, []);
      return call("list_payout_accounts", inWorkspace(c));
    }),

    route("POST", "/accounts/:id/primary", async (c) => {
      const body = await v.readBody(c.request, ["idempotencyKey"]);
      return call("set_primary_payout_account", {
        ...commandInWorkspace(c),
        p_payout_account_id: c.params.id,
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/accounts/:id/deactivate", async (c) => {
      const body = await v.readBody(c.request, ["reason", "idempotencyKey"]);
      return call("deactivate_payout_account", {
        ...commandInWorkspace(c),
        p_payout_account_id: c.params.id,
        p_reason: v.text(body, "reason", 500),
        p_idempotency_key: v.idempotencyKey(body),
      });
    }),

    route("POST", "/accounts/:id/reveal", async (c) => {
      await v.readBody(c.request, []);
      const sealed = await call("reveal_payout_account", {
        ...commandInWorkspace(c),
        p_payout_account_id: c.params.id,
      });
      if (typeof sealed.ciphertext !== "string" || typeof sealed.keyVersion !== "number") {
        throw new Error("unexpected reveal result");
      }
      return {
        payoutAccountId: sealed.payoutAccountId,
        accountNumber: await deps.accountCrypto.open(
          c.actor.userId,
          sealed.ciphertext,
          sealed.keyVersion,
        ),
      };
    }),
  ];

  return async (request: Request): Promise<Response> => {
    const started = Date.now();
    const requestId = crypto.randomUUID();
    const cors = corsHeaders(request.headers.get("origin"), deps.allowedOrigins);
    const url = new URL(request.url);
    const path = url.pathname.replace(/^.*?\/payout(?=\/|$)/, "") || "/";

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
