// The `outbox-worker` Edge Function (Blueprint 03 — B4). Called every minute
// by pg_cron through pg_net with `Authorization: Bearer <OUTBOX_WORKER_SECRET>`;
// never with a user JWT. Each run records invitation expiry, claims leased
// batches, renders and sends each email, and reports the outcome per event.
// When the email provider isn't configured it claims nothing, so deliveries
// stay pending without burning attempts.

import { ApiError, failure, isErrorCode, success } from "../_shared/http.ts";
import { renderEmail, TemplateError } from "../_shared/email/templates.ts";
import type { EmailTransport, SendOutcome } from "../_shared/email/cloudflare.ts";
import { joinLink } from "../_shared/invite_token.ts";

export type RpcResult =
  | { readonly data: unknown; readonly error: null }
  | {
    readonly data: null;
    readonly error: { readonly message: string; readonly details?: string | null };
  };

export interface WorkerLogEntry {
  readonly requestId: string;
  readonly route: string;
  readonly status?: number;
  readonly code?: string;
  readonly ms?: number;
  readonly message?: string;
  readonly eventId?: string;
  readonly template?: string;
  readonly outcome?: string;
  readonly providerStatus?: number | null;
}

export interface EmailSetup {
  readonly transport: EmailTransport;
  /** Rebuilds an invitation link token from its token id. */
  token(tokenId: string): Promise<string>;
  readonly appOrigin: string;
}

export interface Deps {
  rpc(fn: string, args: Record<string, unknown>): Promise<RpcResult>;
  /** OUTBOX_WORKER_SECRET; null when unset (then every call is refused). */
  readonly workerSecret: string | null;
  /** Null when the email provider isn't configured. */
  readonly email: EmailSetup | null;
  readonly workerId: string;
  log(entry: WorkerLogEntry): void;
  readonly batchSize?: number;
  readonly maxBatches?: number;
  /** Stop claiming new batches after this long (ms). */
  readonly timeBudgetMs?: number;
}

/**
 * Lease sizing: emails in a batch are sent one after another, each bounded by
 * the transport timeout (15 s). 5 × 15 s = 75 s stays inside the 120 s lease,
 * so a later run never re-claims an email this run is still about to send.
 */
const defaultBatchSize = 5;
const leaseSeconds = 120;

interface Claimed {
  readonly eventId: string;
  readonly leaseToken: string;
  readonly cycle: number;
  readonly template: string;
  readonly version: number;
  readonly params: Record<string, unknown>;
  readonly to: string;
  readonly tokenId: string | null;
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

function parseClaimed(data: unknown): Claimed[] {
  if (!Array.isArray(data)) throw new Error("outbox_claim returned an unexpected result");
  return data.map((item: unknown) => {
    const r = item as Record<string, unknown>;
    if (
      typeof r !== "object" || r === null || typeof r.eventId !== "string" ||
      typeof r.leaseToken !== "string" || typeof r.cycle !== "number" ||
      typeof r.template !== "string" || typeof r.version !== "number" ||
      typeof r.params !== "object" || r.params === null || Array.isArray(r.params) ||
      typeof r.to !== "string" || !(r.tokenId === null || typeof r.tokenId === "string")
    ) {
      throw new Error("outbox_claim returned an unexpected item");
    }
    return {
      eventId: r.eventId,
      leaseToken: r.leaseToken,
      cycle: r.cycle,
      template: r.template,
      version: r.version,
      params: r.params as Record<string, unknown>,
      to: r.to,
      tokenId: r.tokenId as string | null,
    };
  });
}

export function createHandler(deps: Deps): (request: Request) => Promise<Response> {
  const batchSize = deps.batchSize ?? defaultBatchSize;
  const maxBatches = deps.maxBatches ?? 8;
  const timeBudgetMs = deps.timeBudgetMs ?? 40_000;

  async function call(fn: string, args: Record<string, unknown>): Promise<unknown> {
    const { data, error } = await deps.rpc(fn, args);
    if (error) {
      if (isErrorCode(error.message)) throw new ApiError(error.message);
      throw new Error(`rpc ${fn} failed`);
    }
    return data;
  }

  async function deliver(item: Claimed, email: EmailSetup, requestId: string): Promise<string> {
    const started = Date.now();
    let outcome: SendOutcome;
    try {
      const joinUrl = item.tokenId === null
        ? undefined
        : joinLink(email.appOrigin, await email.token(item.tokenId));
      const rendered = renderEmail(item.template, item.version, item.params, {
        appUrl: email.appOrigin,
        ...(joinUrl ? { joinUrl } : {}),
      });
      outcome = await email.transport.send({
        to: item.to,
        ...rendered,
        correlationId: `outbox:${item.eventId}:${item.cycle}`,
      });
    } catch (error) {
      // A render error is permanent; it never stops the batch.
      outcome = {
        outcome: "permanent_failure",
        providerStatus: null,
        errorCode: error instanceof TemplateError ? error.code : "worker.render_failed",
      };
    }
    const latency = Date.now() - started;

    const report = outcome.outcome === "sent"
      ? await call("outbox_complete", {
        p_event_id: item.eventId,
        p_lease_token: item.leaseToken,
        p_provider_message_id: outcome.messageId,
        p_provider_status: outcome.providerStatus,
        p_latency_ms: latency,
      })
      : await call("outbox_fail", {
        p_event_id: item.eventId,
        p_lease_token: item.leaseToken,
        p_outcome: outcome.outcome,
        p_error_code: outcome.errorCode,
        p_provider_status: outcome.providerStatus,
        p_latency_ms: latency,
      });
    const status = (report as { status?: unknown } | null)?.status;
    deps.log({
      requestId,
      route: "delivery",
      eventId: item.eventId,
      template: item.template,
      outcome: outcome.outcome,
      providerStatus: outcome.providerStatus,
      ms: latency,
      ...(outcome.outcome === "sent" ? {} : { code: outcome.errorCode }),
    });
    return typeof status === "string" ? status : "unknown";
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

    const path = new URL(request.url).pathname.replace(/^.*?\/outbox-worker(?=\/|$)/, "");
    if (request.method !== "POST" || !["", "/", "/run"].includes(path)) {
      return finish(failure("not_found", requestId), "not_found");
    }

    try {
      const given = request.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1];
      if (!deps.workerSecret || !given || !(await sameSecret(given, deps.workerSecret))) {
        throw new ApiError("authentication_required");
      }

      const maintenance = await call("outbox_run_maintenance", {});
      if (!deps.email) {
        const message = "email provider not configured";
        return finish(
          success({ configured: false, message, maintenance, claimed: 0 }, requestId),
          undefined,
          message,
        );
      }

      const counts: Record<string, number> = {};
      let claimed = 0;
      for (let batch = 0; batch < maxBatches && Date.now() - started < timeBudgetMs; batch++) {
        const items = parseClaimed(
          await call("outbox_claim", {
            p_worker_id: deps.workerId,
            p_batch_size: batchSize,
            p_lease_seconds: leaseSeconds,
          }),
        );
        claimed += items.length;
        for (const item of items) {
          const status = await deliver(item, deps.email, requestId);
          counts[status] = (counts[status] ?? 0) + 1;
        }
        if (items.length < batchSize) break;
      }
      return finish(
        success({ configured: true, maintenance, claimed, results: counts }, requestId),
      );
    } catch (error) {
      if (error instanceof ApiError) {
        return finish(failure(error.code, requestId), error.code);
      }
      return finish(failure("internal_error", requestId), "internal_error");
    }
  };
}
