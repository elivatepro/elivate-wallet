// The `exports-worker` Edge Function (Blueprint 15 — B3). Called only by the
// app Worker's export runner with `Authorization: Bearer <EXPORTS_WORKER_SECRET>`,
// never with a user JWT. It exposes the job steps: claim a job, prepare its
// rows (one database transaction), page through them, then finalize or fail.
// Postgres re-authorizes and checks completeness; this layer validates input.

import { ApiError, type Details, failure, isErrorCode, success } from "../_shared/http.ts";
import { sameSecret } from "../_shared/secret.ts";

export type RpcResult =
  | { readonly data: unknown; readonly error: null }
  | {
    readonly data: null;
    readonly error: { readonly message: string; readonly details?: string | null };
  };

export interface WorkerLogEntry {
  readonly requestId: string;
  readonly route: string;
  readonly status: number;
  readonly code?: string;
  readonly ms: number;
}

export interface Deps {
  rpc(fn: string, args: Record<string, unknown>): Promise<RpcResult>;
  /** EXPORTS_WORKER_SECRET; null when unset (then every call is refused). */
  readonly workerSecret: string | null;
  log(entry: WorkerLogEntry): void;
}

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const workerPattern = /^[A-Za-z0-9:_-]{1,100}$/;
const failReasons = ["read_failed", "render_failed", "storage_failed", "incomplete", "timeout"];

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

async function readJson(
  request: Request,
  allowed: readonly string[],
): Promise<Record<string, unknown>> {
  const text = await request.text();
  if (text.length > 4096) throw new ApiError("validation_error", { reason: "body_too_large" });
  let body: unknown;
  try {
    body = text === "" ? {} : JSON.parse(text);
  } catch {
    throw new ApiError("validation_error", { reason: "invalid_json" });
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    throw new ApiError("validation_error", { reason: "invalid_json" });
  }
  for (const key of Object.keys(body)) {
    if (!allowed.includes(key)) {
      throw new ApiError("validation_error", { field: key, reason: "unknown_field" });
    }
  }
  return body as Record<string, unknown>;
}

function worker(body: Record<string, unknown>): string {
  const value = body.worker;
  if (typeof value !== "string" || !workerPattern.test(value)) {
    throw new ApiError("validation_error", { field: "worker" });
  }
  return value;
}

function int(value: unknown, field: string, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) {
    throw new ApiError("validation_error", { field });
  }
  return value;
}

function queryInt(query: URLSearchParams, field: string, min: number, max: number): number {
  const raw = query.get(field);
  if (raw === null || !/^[0-9]{1,9}$/.test(raw)) throw new ApiError("validation_error", { field });
  return int(Number(raw), field, min, max);
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

  async function route(request: Request, path: string): Promise<unknown> {
    const url = new URL(request.url);
    if (request.method === "POST" && path === "/claim") {
      const body = await readJson(request, ["worker"]);
      return call("export_claim", { p_worker: worker(body) });
    }
    const match = /^\/([0-9a-f-]{36})\/(prepare|rows|finalize|fail)$/.exec(path);
    if (!match || !uuidPattern.test(match[1] ?? "")) throw new ApiError("not_found");
    const id = match[1];
    const step = match[2];
    if (request.method === "GET" && step === "rows") {
      for (const key of url.searchParams.keys()) {
        if (!["worker", "after", "limit"].includes(key)) {
          throw new ApiError("validation_error", { field: key, reason: "unknown_field" });
        }
      }
      const name = url.searchParams.get("worker");
      if (!name || !workerPattern.test(name)) {
        throw new ApiError("validation_error", { field: "worker" });
      }
      return call("export_rows", {
        p_export_id: id,
        p_worker: name,
        p_after: queryInt(url.searchParams, "after", 0, 1_000_000),
        p_limit: queryInt(url.searchParams, "limit", 1, 1000),
      });
    }
    if (request.method !== "POST") throw new ApiError("not_found");
    if (step === "prepare") {
      const body = await readJson(request, ["worker"]);
      return call("export_prepare", { p_export_id: id, p_worker: worker(body) });
    }
    if (step === "finalize") {
      const body = await readJson(request, [
        "worker",
        "rowCount",
        "pageCount",
        "byteSize",
        "sha256",
        "hasPreview",
      ]);
      if (typeof body.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(body.sha256)) {
        throw new ApiError("validation_error", { field: "sha256" });
      }
      if (body.hasPreview !== undefined && typeof body.hasPreview !== "boolean") {
        throw new ApiError("validation_error", { field: "hasPreview" });
      }
      return call("export_finalize", {
        p_export_id: id,
        p_worker: worker(body),
        p_row_count: int(body.rowCount, "rowCount", 0, 1_000_000),
        p_page_count: body.pageCount === undefined || body.pageCount === null
          ? null
          : int(body.pageCount, "pageCount", 1, 100_000),
        p_byte_size: int(body.byteSize, "byteSize", 1, 2 ** 40),
        p_sha256: body.sha256,
        p_has_preview: body.hasPreview ?? false,
      });
    }
    if (step === "fail") {
      const body = await readJson(request, ["worker", "reason"]);
      if (typeof body.reason !== "string" || !failReasons.includes(body.reason)) {
        throw new ApiError("validation_error", { field: "reason" });
      }
      return call("export_fail", {
        p_export_id: id,
        p_worker: worker(body),
        p_reason: body.reason,
      });
    }
    throw new ApiError("not_found");
  }

  return async (request: Request): Promise<Response> => {
    const started = Date.now();
    const requestId = crypto.randomUUID();
    const path = new URL(request.url).pathname.replace(/^.*\/exports-worker/, "") || "/";
    const finish = (response: Response, code?: string) => {
      deps.log({
        requestId,
        route: `${request.method} ${path.replace(/[0-9a-f-]{36}/, ":id")}`,
        status: response.status,
        ...(code ? { code } : {}),
        ms: Date.now() - started,
      });
      return response;
    };
    try {
      const given = request.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1];
      if (!deps.workerSecret || !given || !(await sameSecret(given, deps.workerSecret))) {
        return finish(failure("authorization_denied", requestId), "authorization_denied");
      }
      return finish(success(await route(request, path), requestId));
    } catch (error) {
      if (error instanceof ApiError) {
        return finish(failure(error.code, requestId, error.details), error.code);
      }
      return finish(failure("internal_error", requestId), "internal_error");
    }
  };
}
