// The `payout-checker` Edge Function (Blueprint 11 — B3). Called every minute
// by pg_cron through pg_net with `Authorization: Bearer <PAYOUT_CHECKER_SECRET>`;
// never with a user JWT. Each run claims up to 3 receipt checks, re-verifies
// the stored bytes, has the model read the receipt, compares deterministically
// and reports. Technical failures go back with backoff and never consume the
// one correction. No account number, name or receipt content is logged.

import { ApiError, failure, isErrorCode, success } from "../_shared/http.ts";
import { type EvidenceMime, evidenceMimeTypes, sha256Hex, sniffMime } from "../_shared/evidence.ts";
import { compareReceipt, policyVersion } from "./compare.ts";
import { ExtractionError, type Extractor } from "./extract.ts";

export type RpcResult =
  | { readonly data: unknown; readonly error: null }
  | {
    readonly data: null;
    readonly error: { readonly message: string; readonly details?: string | null };
  };

export interface CheckerLogEntry {
  readonly requestId: string;
  readonly route: string;
  readonly status?: number;
  readonly code?: string;
  readonly ms?: number;
  readonly message?: string;
  readonly checkId?: string;
  readonly outcome?: string;
}

export interface Deps {
  rpc(fn: string, args: Record<string, unknown>): Promise<RpcResult>;
  /** PAYOUT_CHECKER_SECRET; null when unset (then every call is refused). */
  readonly workerSecret: string | null;
  /** Null when OpenAI isn't configured: then nothing is claimed. */
  readonly extractor: Extractor | null;
  /** Reads one evidence object; null when missing or larger than maxBytes. */
  download(path: string, maxBytes: number): Promise<Uint8Array | null>;
  openAccount(ownerUserId: string, ciphertext: string, keyVersion: number): Promise<string>;
  readonly workerId: string;
  log(entry: CheckerLogEntry): void;
  readonly batchSize?: number;
}

interface Claimed {
  readonly checkId: string;
  readonly leaseToken: string;
  readonly expected: {
    readonly amount: string;
    readonly currency: string;
    readonly paidOn: string;
    readonly recipientName: string;
    readonly ownerUserId: string;
    readonly accountCiphertext: string;
    readonly keyVersion: number;
  };
  readonly receipt: {
    readonly objectPath: string;
    readonly size: number;
    readonly sha256: string;
    readonly mimeType: EvidenceMime;
  };
}

const encoder = new TextEncoder();

async function sameSecret(given: string, expected: string): Promise<boolean> {
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(given)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const x = new Uint8Array(a);
  const y = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

const isText = (v: unknown): v is string => typeof v === "string" && v.length > 0;
const isObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);

export function parseClaimed(data: unknown): Claimed[] {
  if (!Array.isArray(data)) throw new Error("claim_payout_checks returned an unexpected result");
  return data.map((item: unknown) => {
    const r = isObject(item) ? item : {};
    const e = isObject(r.expected) ? r.expected : {};
    const f = isObject(r.receipt) ? r.receipt : {};
    if (
      !isText(r.checkId) || !isText(r.leaseToken) || !isText(e.amount) || !isText(e.currency) ||
      !isText(e.paidOn) || !isText(e.recipientName) || !isText(e.ownerUserId) ||
      !isText(e.accountCiphertext) || typeof e.keyVersion !== "number" ||
      !isText(f.objectPath) || typeof f.size !== "number" || !isText(f.sha256) ||
      !(evidenceMimeTypes as readonly unknown[]).includes(f.mimeType)
    ) {
      throw new Error("claim_payout_checks returned an unexpected item");
    }
    return {
      checkId: r.checkId,
      leaseToken: r.leaseToken,
      expected: {
        amount: e.amount,
        currency: e.currency,
        paidOn: e.paidOn,
        recipientName: e.recipientName,
        ownerUserId: e.ownerUserId,
        accountCiphertext: e.accountCiphertext,
        keyVersion: e.keyVersion,
      },
      receipt: {
        objectPath: f.objectPath,
        size: f.size,
        sha256: f.sha256,
        mimeType: f.mimeType as EvidenceMime,
      },
    };
  });
}

class TechnicalFailure extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

export function createHandler(deps: Deps): (request: Request) => Promise<Response> {
  const batchSize = deps.batchSize ?? 3;

  async function call(fn: string, args: Record<string, unknown>): Promise<unknown> {
    const { data, error } = await deps.rpc(fn, args);
    if (error) {
      if (isErrorCode(error.message)) throw new ApiError(error.message);
      throw new Error(`rpc ${fn} failed`);
    }
    return data;
  }

  async function check(item: Claimed, extractor: Extractor): Promise<string> {
    try {
      const bytes = await deps.download(item.receipt.objectPath, item.receipt.size);
      if (!bytes) throw new TechnicalFailure("receipt_unavailable");
      if (
        bytes.length !== item.receipt.size ||
        (await sha256Hex(bytes)) !== item.receipt.sha256 ||
        sniffMime(bytes) !== item.receipt.mimeType
      ) {
        throw new TechnicalFailure("receipt_changed");
      }
      let facts;
      try {
        facts = await extractor.read(bytes, item.receipt.mimeType);
      } catch (error) {
        throw new TechnicalFailure(
          error instanceof ExtractionError ? error.code : "extraction_failed",
        );
      }
      let accountNumber: string;
      try {
        accountNumber = await deps.openAccount(
          item.expected.ownerUserId,
          item.expected.accountCiphertext,
          item.expected.keyVersion,
        );
      } catch {
        throw new TechnicalFailure("destination_unreadable");
      }
      const result = compareReceipt(facts, { ...item.expected, accountNumber });
      const done = await call("finish_payout_check", {
        p_check_id: item.checkId,
        p_lease_token: item.leaseToken,
        p_outcome: result.outcome,
        p_facts: { paymentDate: result.paymentDate, receipt: facts },
        p_reasons: result.reasons,
        p_model: extractor.model,
        p_policy_version: policyVersion,
      });
      return isObject(done) && typeof done.status === "string" ? done.status : "done";
    } catch (error) {
      if (error instanceof ApiError) return `finish_${error.code}`;
      const code = error instanceof TechnicalFailure ? error.code : "worker_error";
      try {
        await call("fail_payout_check", {
          p_check_id: item.checkId,
          p_lease_token: item.leaseToken,
          p_error: code,
        });
      } catch {
        // The lease runs out and the check is claimed again.
      }
      return code;
    }
  }

  return async (request: Request): Promise<Response> => {
    const started = Date.now();
    const requestId = crypto.randomUUID();
    const finish = (response: Response, code?: string, message?: string): Response => {
      deps.log({
        requestId,
        route: "POST /run",
        status: response.status,
        ...(code ? { code } : {}),
        ...(message ? { message } : {}),
        ms: Date.now() - started,
      });
      return response;
    };

    const path = new URL(request.url).pathname.replace(/^.*?\/payout-checker(?=\/|$)/, "");
    if (request.method !== "POST" || !["", "/", "/run"].includes(path)) {
      return finish(failure("not_found", requestId), "not_found");
    }

    try {
      const given = request.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1];
      if (!deps.workerSecret || !given || !(await sameSecret(given, deps.workerSecret))) {
        throw new ApiError("authentication_required");
      }
      const extractor = deps.extractor;
      if (!extractor) {
        const message = "receipt reader not configured";
        return finish(
          success({ configured: false, message, claimed: 0 }, requestId),
          undefined,
          message,
        );
      }
      const items = parseClaimed(
        await call("claim_payout_checks", { p_worker: deps.workerId, p_limit: batchSize }),
      );
      const outcomes = await Promise.all(items.map((item) => check(item, extractor)));
      const results: Record<string, number> = {};
      items.forEach((item, i) => {
        const outcome = outcomes[i] ?? "unknown";
        results[outcome] = (results[outcome] ?? 0) + 1;
        deps.log({ requestId, route: "check", checkId: item.checkId, outcome });
      });
      return finish(success({ configured: true, claimed: items.length, results }, requestId));
    } catch (error) {
      if (error instanceof ApiError) return finish(failure(error.code, requestId), error.code);
      return finish(failure("internal_error", requestId), "internal_error");
    }
  };
}
