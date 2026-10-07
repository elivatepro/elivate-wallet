import {
  deliverOutboxClaim,
  type DeliveryStateStore,
  type IntegrationAdapter,
  IntegrationDeliveryError,
  type OutboxDeliveryClaim,
  type OutboxDeliveryStore,
  outboxIdempotencyKey,
  runOutboxDeliveryBatch,
  toDeliveryEnvelope,
} from "../src/integrations/outbox_delivery.ts";

const assertEquals = (actual: unknown, expected: unknown): void => {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
};

const assertRejects = async (
  action: () => Promise<unknown>,
  expectedMessage: string,
): Promise<void> => {
  try {
    await action();
  } catch (error: unknown) {
    if (error instanceof Error && error.message === expectedMessage) return;
    throw error;
  }

  throw new Error("Expected action to reject");
};

const claim: OutboxDeliveryClaim = {
  outboxEventId: "11111111-1111-4111-8111-111111111111",
  tenantId: "22222222-2222-4222-8222-222222222222",
  aggregateType: "withdrawal",
  aggregateId: "33333333-3333-4333-8333-333333333333",
  eventType: "withdrawal_completed",
  payload: { withdrawal_id: "33333333-3333-4333-8333-333333333333" },
  occurredAt: "2026-09-20T00:00:00.000Z",
  deliveryCycle: 1,
  attemptNumber: 1,
  leaseToken: "44444444-4444-4444-8444-444444444444",
  leaseExpiresAt: "2026-09-20T00:01:00.000Z",
  idempotencyKey: "outbox:11111111-1111-4111-8111-111111111111",
};

const createStore = () => {
  const completed: unknown[] = [];
  const failed: unknown[] = [];

  const store: DeliveryStateStore = {
    complete(input) {
      completed.push(input);
      return Promise.resolve();
    },
    fail(input) {
      failed.push(input);
      return Promise.resolve(
        input.retryable ? "retry_scheduled" : "dead_lettered",
      );
    },
  };

  return { completed, failed, store };
};

Deno.test("outbox idempotency is stable across retries and delivery cycles", () => {
  assertEquals(
    outboxIdempotencyKey(claim.outboxEventId),
    "outbox:11111111-1111-4111-8111-111111111111",
  );
  assertEquals(
    toDeliveryEnvelope({ ...claim, deliveryCycle: 9, attemptNumber: 7 })
      .idempotencyKey,
    claim.idempotencyKey,
  );
});

Deno.test("successful adapter delivery records only safe receipt metadata", async () => {
  const { completed, failed, store } = createStore();
  const adapter: IntegrationAdapter = {
    provider: "resend",
    deliver(envelope) {
      assertEquals(envelope.idempotencyKey, claim.idempotencyKey);
      return Promise.resolve({
        providerReference: "provider-message-1",
        providerStatusCode: 202,
      });
    },
  };
  let tick = 100;

  const result = await deliverOutboxClaim(
    claim,
    adapter,
    store,
    () => (tick += 25),
  );

  assertEquals(result, {
    status: "delivered",
    provider: "resend",
    latencyMs: 25,
  });
  assertEquals(failed, []);
  assertEquals(completed, [{
    outboxEventId: claim.outboxEventId,
    leaseToken: claim.leaseToken,
    provider: "resend",
    providerReference: "provider-message-1",
    providerStatusCode: 202,
    latencyMs: 25,
  }]);
});

Deno.test("known retryable failure records a stable code without raw details", async () => {
  const { completed, failed, store } = createStore();
  const adapter: IntegrationAdapter = {
    provider: "posthog",
    deliver() {
      return Promise.reject(
        new IntegrationDeliveryError("provider_rate_limited", {
          retryable: true,
          providerStatusCode: 429,
          cause: new Error("secret response body"),
        }),
      );
    },
  };
  let tick = 0;

  const result = await deliverOutboxClaim(
    claim,
    adapter,
    store,
    () => (tick += 10),
  );

  assertEquals(completed, []);
  assertEquals(result, {
    status: "retry_scheduled",
    provider: "posthog",
    errorCode: "provider_rate_limited",
    latencyMs: 10,
  });
  assertEquals(failed, [{
    outboxEventId: claim.outboxEventId,
    leaseToken: claim.leaseToken,
    provider: "posthog",
    errorCode: "provider_rate_limited",
    retryable: true,
    providerStatusCode: 429,
    latencyMs: 10,
  }]);
  assertEquals(JSON.stringify(failed).includes("secret response body"), false);
});

Deno.test("unknown adapter errors are retryable and redacted", async () => {
  const { failed, store } = createStore();
  const adapter: IntegrationAdapter = {
    provider: "resend",
    deliver() {
      return Promise.reject(new Error("token=do-not-record"));
    },
  };
  let tick = 10;

  const result = await deliverOutboxClaim(
    claim,
    adapter,
    store,
    () => (tick += 5),
  );

  assertEquals(result, {
    status: "retry_scheduled",
    provider: "resend",
    errorCode: "unexpected_delivery_error",
    latencyMs: 5,
  });
  assertEquals(JSON.stringify(failed).includes("do-not-record"), false);
});

Deno.test("invalid claim idempotency is rejected before provider delivery", async () => {
  let adapterCalled = false;
  const { store } = createStore();
  const adapter: IntegrationAdapter = {
    provider: "resend",
    deliver() {
      adapterCalled = true;
      return Promise.resolve({});
    },
  };

  await assertRejects(
    () =>
      deliverOutboxClaim(
        { ...claim, idempotencyKey: "wrong" },
        adapter,
        store,
      ),
    "Outbox delivery claim has an invalid idempotency key",
  );
  assertEquals(adapterCalled, false);
});

Deno.test("worker claims and routes a provider-neutral delivery batch", async () => {
  const { completed, failed, store: stateStore } = createStore();
  const unknownClaim: OutboxDeliveryClaim = {
    ...claim,
    outboxEventId: "55555555-5555-4555-8555-555555555555",
    aggregateId: "66666666-6666-4666-8666-666666666666",
    eventType: "unknown_event",
    idempotencyKey: "outbox:55555555-5555-4555-8555-555555555555",
  };
  const claims = [claim, unknownClaim];
  const claimed: unknown[] = [];
  const store: OutboxDeliveryStore = {
    ...stateStore,
    claim(input) {
      claimed.push(input);
      return Promise.resolve(claims);
    },
  };

  const result = await runOutboxDeliveryBatch(
    store,
    new Map<string, IntegrationAdapter>([
      ["withdrawal_completed", {
        provider: "resend",
        deliver: () => Promise.resolve({ providerStatusCode: 202 }),
      }],
    ]),
    { workerId: "worker-1", batchSize: 10, leaseSeconds: 60 },
  );

  assertEquals(claimed, [{
    workerId: "worker-1",
    batchSize: 10,
    leaseSeconds: 60,
  }]);
  assertEquals(result.claimed, 2);
  assertEquals(result.delivered, 1);
  assertEquals(result.retryScheduled, 0);
  assertEquals(result.deadLettered, 1);
  assertEquals(completed.length, 1);
  assertEquals(failed, [{
    outboxEventId: unknownClaim.outboxEventId,
    leaseToken: unknownClaim.leaseToken,
    provider: "unrouted",
    errorCode: "unsupported_event_type",
    retryable: false,
    latencyMs: 0,
  }]);
});

Deno.test("worker validates its lease and batch bounds", async () => {
  const { store: stateStore } = createStore();
  const store: OutboxDeliveryStore = {
    ...stateStore,
    claim: () => Promise.resolve([]),
  };
  const adapters = new Map<string, IntegrationAdapter>();

  await assertRejects(
    () => runOutboxDeliveryBatch(store, adapters, { workerId: "" }),
    "Outbox worker ID is invalid",
  );
  await assertRejects(
    () =>
      runOutboxDeliveryBatch(store, adapters, {
        workerId: "worker-1",
        batchSize: 0,
      }),
    "Outbox batch size is invalid",
  );
  await assertRejects(
    () =>
      runOutboxDeliveryBatch(store, adapters, {
        workerId: "worker-1",
        leaseSeconds: 3601,
      }),
    "Outbox lease duration is invalid",
  );
});
