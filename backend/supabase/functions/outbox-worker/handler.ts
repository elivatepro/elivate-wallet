// The `outbox-worker` Edge Function (Blueprint 03 — B4). Called every minute
// by pg_cron through pg_net with `Authorization: Bearer <OUTBOX_WORKER_SECRET>`;
// never with a user JWT. Each run records invitation expiry, claims leased
// batches, renders and sends each email, and reports the outcome per event.
// When the email provider isn't configured it claims nothing, so deliveries
// stay pending without burning attempts.
// Blueprint 42: first a push pass (the bell's push jobs, kicked right after
// the bell item commits), the same way: without VAPID keys it claims nothing.

import { ApiError, failure, isErrorCode, success } from "../_shared/http.ts";
import { renderEmail, TemplateError } from "../_shared/email/templates.ts";
import type { EmailTransport, SendOutcome } from "../_shared/email/cloudflare.ts";
import { joinLink } from "../_shared/invite_token.ts";
import { sameSecret } from "../_shared/secret.ts";
import { pushPayload, topicFor, urgencyFor } from "../_shared/push/text.ts";
import type { PushDevice, PushOutcome, PushTransport } from "../_shared/push/webpush.ts";

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
  readonly itemId?: string;
  readonly kind?: string;
  readonly devices?: number;
}

export interface EmailSetup {
  readonly transport: EmailTransport;
  /** Rebuilds an invitation link token from its token id. */
  token(tokenId: string): Promise<string>;
  readonly appOrigin: string;
}

export interface PushSetup {
  readonly transport: PushTransport;
}

export interface Deps {
  rpc(fn: string, args: Record<string, unknown>): Promise<RpcResult>;
  /** OUTBOX_WORKER_SECRET; null when unset (then every call is refused). */
  readonly workerSecret: string | null;
  /** Null when the email provider isn't configured. */
  readonly email: EmailSetup | null;
  /** Null (or absent) when the VAPID keys aren't configured. */
  readonly push?: PushSetup | null;
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

/** Blueprint 42: a push goes to each device at once, each bounded by 10 s. */
const pushBatchSize = 5;
const pushTtlSeconds = 12 * 60 * 60;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

interface PushClaimed {
  readonly itemId: string;
  readonly leaseToken: string;
  readonly kind: string;
  readonly params: Record<string, unknown>;
  readonly devices:
    readonly (PushDevice & { readonly id: string; readonly hideAmounts: boolean })[];
}

function parsePushClaimed(data: unknown): PushClaimed[] {
  if (!Array.isArray(data)) throw new Error("push_claim returned an unexpected result");
  return data.map((item: unknown) => {
    const r = item as Record<string, unknown>;
    if (
      typeof r !== "object" || r === null || typeof r.itemId !== "string" ||
      !uuidPattern.test(r.itemId) || typeof r.leaseToken !== "string" ||
      typeof r.kind !== "string" || typeof r.params !== "object" || r.params === null ||
      Array.isArray(r.params) || !Array.isArray(r.devices) || r.devices.length > 10
    ) {
      throw new Error("push_claim returned an unexpected item");
    }
    const devices = r.devices.map((d: unknown) => {
      const x = d as Record<string, unknown>;
      if (
        typeof x !== "object" || x === null || typeof x.id !== "string" ||
        typeof x.endpoint !== "string" || typeof x.p256dh !== "string" ||
        typeof x.auth !== "string" || typeof x.hideAmounts !== "boolean"
      ) {
        throw new Error("push_claim returned an unexpected device");
      }
      return {
        id: x.id,
        endpoint: x.endpoint,
        p256dh: x.p256dh,
        auth: x.auth,
        hideAmounts: x.hideAmounts,
      };
    });
    return {
      itemId: r.itemId,
      leaseToken: r.leaseToken,
      kind: r.kind,
      params: r.params as Record<string, unknown>,
      devices,
    };
  });
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
      const joinUrl = item.tokenId === null ? undefined : joinLink(
        email.appOrigin,
        await email.token(item.tokenId),
        item.template.startsWith("founder.") ? "founder" : "join",
      );
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

  async function pushOne(item: PushClaimed, push: PushSetup, requestId: string): Promise<string> {
    const started = Date.now();
    const results = await Promise.all(item.devices.map(async (device) => {
      const sentAt = Date.now();
      let outcome: PushOutcome;
      try {
        const payload = pushPayload(item.itemId, item.kind, item.params, device.hideAmounts);
        outcome = payload === null
          ? { outcome: "permanent_failure", providerStatus: null, errorCode: "push.unknown_kind" }
          : await push.transport.send(device, {
            payload,
            ttl: pushTtlSeconds,
            urgency: urgencyFor(item.kind),
            topic: topicFor(item.itemId),
          });
      } catch {
        outcome = { outcome: "permanent_failure", providerStatus: null, errorCode: "push.failed" };
      }
      return {
        subscriptionId: device.id,
        outcome: outcome.outcome,
        providerStatus: outcome.providerStatus,
        ...(outcome.outcome === "sent" ? {} : { errorCode: outcome.errorCode }),
        latencyMs: Date.now() - sentAt,
      };
    }));
    const report = await call("push_report", {
      p_item_id: item.itemId,
      p_lease_token: item.leaseToken,
      p_results: results,
    });
    const status = (report as { status?: unknown } | null)?.status;
    deps.log({
      requestId,
      route: "push",
      itemId: item.itemId,
      kind: item.kind,
      devices: item.devices.length,
      outcome: typeof status === "string" ? status : "unknown",
      ms: Date.now() - started,
    });
    return typeof status === "string" ? status : "unknown";
  }

  async function pushPass(push: PushSetup, requestId: string, started: number) {
    const counts: Record<string, number> = {};
    let claimed = 0;
    for (let batch = 0; batch < maxBatches && Date.now() - started < timeBudgetMs; batch++) {
      const items = parsePushClaimed(
        await call("push_claim", {
          p_worker_id: deps.workerId,
          p_batch_size: pushBatchSize,
          p_lease_seconds: leaseSeconds,
        }),
      );
      claimed += items.length;
      for (const item of items) {
        const status = await pushOne(item, push, requestId);
        counts[status] = (counts[status] ?? 0) + 1;
      }
      if (items.length < pushBatchSize) break;
    }
    return { configured: true, claimed, results: counts };
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
      const push = deps.push
        ? await pushPass(deps.push, requestId, started)
        : { configured: false, claimed: 0 };
      if (!deps.email) {
        const message = "email provider not configured";
        return finish(
          success({ configured: false, message, maintenance, claimed: 0, push }, requestId),
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
        success({ configured: true, maintenance, claimed, results: counts, push }, requestId),
      );
    } catch (error) {
      if (error instanceof ApiError) {
        return finish(failure(error.code, requestId), error.code);
      }
      return finish(failure("internal_error", requestId), "internal_error");
    }
  };
}
