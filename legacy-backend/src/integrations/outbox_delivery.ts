export interface OutboxDeliveryClaim {
  readonly outboxEventId: string;
  readonly tenantId: string | null;
  readonly aggregateType: string;
  readonly aggregateId: string;
  readonly eventType: string;
  readonly payload: Readonly<Record<string, unknown>>;
  readonly occurredAt: string;
  readonly deliveryCycle: number;
  readonly attemptNumber: number;
  readonly leaseToken: string;
  readonly leaseExpiresAt: string;
  readonly idempotencyKey: string;
}

export interface DeliveryEnvelope {
  readonly eventId: string;
  readonly tenantId: string | null;
  readonly aggregateType: string;
  readonly aggregateId: string;
  readonly eventType: string;
  readonly payload: Readonly<Record<string, unknown>>;
  readonly occurredAt: string;
  readonly idempotencyKey: string;
}

export interface DeliveryReceipt {
  readonly providerReference?: string;
  readonly providerStatusCode?: number;
}

export interface IntegrationAdapter {
  readonly provider: string;
  deliver(envelope: DeliveryEnvelope): Promise<DeliveryReceipt>;
}

export type DeliveryState = "retry_scheduled" | "dead_lettered";

export interface DeliveryStateStore {
  complete(input: {
    readonly outboxEventId: string;
    readonly leaseToken: string;
    readonly provider: string;
    readonly providerReference?: string;
    readonly providerStatusCode?: number;
    readonly latencyMs: number;
  }): Promise<void>;

  fail(input: {
    readonly outboxEventId: string;
    readonly leaseToken: string;
    readonly provider: string;
    readonly errorCode: string;
    readonly retryable: boolean;
    readonly providerReference?: string;
    readonly providerStatusCode?: number;
    readonly latencyMs: number;
  }): Promise<DeliveryState>;
}

export interface OutboxDeliveryStore extends DeliveryStateStore {
  claim(input: {
    readonly workerId: string;
    readonly batchSize: number;
    readonly leaseSeconds: number;
    readonly now?: string;
  }): Promise<readonly OutboxDeliveryClaim[]>;
}

export class IntegrationDeliveryError extends Error {
  readonly code: string;
  readonly retryable: boolean;
  readonly providerReference: string | undefined;
  readonly providerStatusCode: number | undefined;

  constructor(
    code: string,
    options: {
      readonly retryable: boolean;
      readonly providerReference?: string;
      readonly providerStatusCode?: number;
      readonly cause?: unknown;
    },
  ) {
    super("Integration delivery failed", { cause: options.cause });

    if (!/^[a-z][a-z0-9_.-]{0,127}$/.test(code)) {
      throw new TypeError("Integration delivery error code is invalid");
    }

    this.name = "IntegrationDeliveryError";
    this.code = code;
    this.retryable = options.retryable;
    this.providerReference = options.providerReference;
    this.providerStatusCode = options.providerStatusCode;
  }
}

export type DeliveryRunResult =
  | {
    readonly status: "delivered";
    readonly provider: string;
    readonly latencyMs: number;
  }
  | {
    readonly status: DeliveryState;
    readonly provider: string;
    readonly errorCode: string;
    readonly latencyMs: number;
  };

export interface OutboxBatchResult {
  readonly claimed: number;
  readonly delivered: number;
  readonly retryScheduled: number;
  readonly deadLettered: number;
  readonly results: readonly DeliveryRunResult[];
}

const providerPattern = /^[a-z][a-z0-9_]{0,63}$/;

export function outboxIdempotencyKey(outboxEventId: string): string {
  return `outbox:${outboxEventId}`;
}

export function toDeliveryEnvelope(
  claim: OutboxDeliveryClaim,
): DeliveryEnvelope {
  const expectedIdempotencyKey = outboxIdempotencyKey(claim.outboxEventId);

  if (claim.idempotencyKey !== expectedIdempotencyKey) {
    throw new TypeError("Outbox delivery claim has an invalid idempotency key");
  }

  return {
    eventId: claim.outboxEventId,
    tenantId: claim.tenantId,
    aggregateType: claim.aggregateType,
    aggregateId: claim.aggregateId,
    eventType: claim.eventType,
    payload: claim.payload,
    occurredAt: claim.occurredAt,
    idempotencyKey: expectedIdempotencyKey,
  };
}

export async function deliverOutboxClaim(
  claim: OutboxDeliveryClaim,
  adapter: IntegrationAdapter,
  store: DeliveryStateStore,
  now: () => number = Date.now,
): Promise<DeliveryRunResult> {
  if (!providerPattern.test(adapter.provider)) {
    throw new TypeError("Integration adapter provider is invalid");
  }

  const envelope = toDeliveryEnvelope(claim);
  const startedAt = now();

  try {
    const receipt = await adapter.deliver(envelope);
    const latencyMs = Math.max(0, now() - startedAt);

    await store.complete({
      outboxEventId: claim.outboxEventId,
      leaseToken: claim.leaseToken,
      provider: adapter.provider,
      ...(receipt.providerReference === undefined
        ? {}
        : { providerReference: receipt.providerReference }),
      ...(receipt.providerStatusCode === undefined
        ? {}
        : { providerStatusCode: receipt.providerStatusCode }),
      latencyMs,
    });

    return { status: "delivered", provider: adapter.provider, latencyMs };
  } catch (error: unknown) {
    const latencyMs = Math.max(0, now() - startedAt);
    const failure = error instanceof IntegrationDeliveryError
      ? error
      : new IntegrationDeliveryError("unexpected_delivery_error", {
        retryable: true,
        cause: error,
      });

    const status = await store.fail({
      outboxEventId: claim.outboxEventId,
      leaseToken: claim.leaseToken,
      provider: adapter.provider,
      errorCode: failure.code,
      retryable: failure.retryable,
      ...(failure.providerReference === undefined
        ? {}
        : { providerReference: failure.providerReference }),
      ...(failure.providerStatusCode === undefined
        ? {}
        : { providerStatusCode: failure.providerStatusCode }),
      latencyMs,
    });

    return {
      status,
      provider: adapter.provider,
      errorCode: failure.code,
      latencyMs,
    };
  }
}

export async function runOutboxDeliveryBatch(
  store: OutboxDeliveryStore,
  adapters: ReadonlyMap<string, IntegrationAdapter>,
  options: {
    readonly workerId: string;
    readonly batchSize?: number;
    readonly leaseSeconds?: number;
    readonly now?: string;
  },
): Promise<OutboxBatchResult> {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,127}$/.test(options.workerId)) {
    throw new TypeError("Outbox worker ID is invalid");
  }

  const batchSize = options.batchSize ?? 25;
  if (!Number.isInteger(batchSize) || batchSize < 1 || batchSize > 100) {
    throw new TypeError("Outbox batch size is invalid");
  }

  const leaseSeconds = options.leaseSeconds ?? 300;
  if (
    !Number.isInteger(leaseSeconds) ||
    leaseSeconds < 1 ||
    leaseSeconds > 3600
  ) {
    throw new TypeError("Outbox lease duration is invalid");
  }

  const claims = await store.claim({
    workerId: options.workerId,
    batchSize,
    leaseSeconds,
    ...(options.now === undefined ? {} : { now: options.now }),
  });
  const results: DeliveryRunResult[] = [];

  for (const claim of claims) {
    const adapter = adapters.get(claim.eventType);
    if (adapter === undefined) {
      const status = await store.fail({
        outboxEventId: claim.outboxEventId,
        leaseToken: claim.leaseToken,
        provider: "unrouted",
        errorCode: "unsupported_event_type",
        retryable: false,
        latencyMs: 0,
      });
      results.push({
        status,
        provider: "unrouted",
        errorCode: "unsupported_event_type",
        latencyMs: 0,
      });
      continue;
    }

    results.push(await deliverOutboxClaim(claim, adapter, store));
  }

  return {
    claimed: claims.length,
    delivered: results.filter((result) => result.status === "delivered")
      .length,
    retryScheduled:
      results.filter((result) => result.status === "retry_scheduled").length,
    deadLettered:
      results.filter((result) => result.status === "dead_lettered").length,
    results,
  };
}
