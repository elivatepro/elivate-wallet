import { assert, assertEquals } from "@std/assert";
import {
  type Actor,
  createHandler,
  type Deps,
  type LogEntry,
  type RpcResult,
} from "../supabase/functions/billing/handler.ts";
import {
  environmentOf,
  type PaystackBilling,
  paystackBilling,
  validSignature,
  type VerifyOutcome,
} from "../supabase/functions/_shared/paystack_billing.ts";

const actor: Actor = {
  userId: "00000000-0000-0000-0000-0000000000a1",
  sessionId: "00000000-0000-0000-0000-00000000a0a1",
};
const membershipId = "00000000-0000-0000-0000-0000000000b1";
const paymentId = "00000000-0000-0000-0000-0000000000c1";
const secret = "sk_test_billingtest00000000";
const workerSecret = "w".repeat(64);
const key = "key-0000000000000001";
const reference = "ewp_0123456789abcdef";

type Responder = (fn: string, args: Record<string, unknown>) => RpcResult;
const ok = (data: unknown): RpcResult => ({ data, error: null });
const fail = (message: string, details: unknown = {}): RpcResult => ({
  data: null,
  error: { message, details: JSON.stringify(details) },
});

function charge(extra: Partial<Record<string, unknown>> = {}): VerifyOutcome {
  return {
    kind: "ok",
    status: "success",
    reference,
    amountKobo: 70000000,
    currency: "NGN",
    environment: "test",
    paidAt: "2026-10-09T10:00:00.000Z",
    transactionId: 4099260516,
    customerCode: "CUS_abc123",
    reusable: true,
    planCode: null,
    ...extra,
  } as VerifyOutcome;
}

interface FakePaystack extends PaystackBilling {
  readonly calls: string[];
}

function fakePaystack(verify: (ref: string) => VerifyOutcome = () => charge()): FakePaystack {
  const calls: string[] = [];
  return {
    calls,
    environment: "test",
    initialize(input) {
      calls.push(`initialize:${input.amountKobo}:${input.reference}:${input.callbackUrl}`);
      return Promise.resolve({
        kind: "ok",
        authorizationUrl: "https://checkout.paystack.com/abc123",
      });
    },
    verify(ref) {
      calls.push(`verify:${ref}`);
      return Promise.resolve(verify(ref));
    },
    createPlan(name, amount) {
      calls.push(`plan:${name}:${amount}`);
      return Promise.resolve("PLN_new0001");
    },
    createSubscription(input) {
      calls.push(`subscribe:${input.customerCode}:${input.planCode}:${input.startDate}`);
      return Promise.resolve({ kind: "ok", subscriptionCode: "SUB_new0001", emailToken: "tok123" });
    },
    disableSubscription(code, token) {
      calls.push(`disable:${code}:${token}`);
      return Promise.resolve(true);
    },
    findSubscription(input) {
      calls.push(`find:${input.customerCode}:${input.amountKobo}`);
      return Promise.resolve(
        input.customerCode === "CUS_adopt0001"
          ? {
            kind: "found",
            candidates: [
              { subscriptionCode: "SUB_othernet1", emailToken: "tokB" },
              { subscriptionCode: "SUB_adopted01", emailToken: "tokA" },
            ],
          }
          : { kind: "none" },
      );
    },
  };
}

function setup(db: Responder = () => ok({}), paystack: FakePaystack | null = fakePaystack()) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const logs: LogEntry[] = [];
  const deps: Deps = {
    verifyToken: (token) => Promise.resolve(token === "good" ? actor : null),
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve(db(fn, args));
    },
    log: (entry) => logs.push(entry),
    allowedOrigins: ["https://app.elivatewallet.com"],
    paystack,
    webhookSecret: secret,
    workerSecret,
    appOrigin: "https://app.elivatewallet.com",
    now: () => new Date("2026-10-09T10:00:00Z"),
  };
  return { handler: createHandler(deps), calls, logs };
}

async function hmac(body: string, keyText = secret): Promise<string> {
  const k = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(keyText),
    { name: "HMAC", hash: "SHA-512" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(body));
  return Array.from(new Uint8Array(sig), (b) => b.toString(16).padStart(2, "0")).join("");
}

async function webhook(
  handler: (r: Request) => Promise<Response>,
  payload: unknown,
  signature?: string | null,
) {
  const body = JSON.stringify(payload);
  const sig = signature === undefined ? await hmac(body) : signature;
  return handler(
    new Request("https://x.supabase.co/functions/v1/billing/paystack/webhook", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(sig ? { "x-paystack-signature": sig } : {}),
      },
      body,
    }),
  );
}

function user(path: string, init: RequestInit = {}): Request {
  return new Request(`https://x.supabase.co/functions/v1/billing${path}`, {
    ...init,
    headers: {
      authorization: "Bearer good",
      "x-membership": membershipId,
      "content-type": "application/json",
      ...(init.headers ?? {}),
    },
  });
}

const eventDb: Responder = (fn) => {
  switch (fn) {
    case "billing_record_event":
      return ok({ eventId: 7, duplicate: false });
    case "billing_apply_verified":
      return ok({ outcome: "applied", paymentId, tenantId: "t1" });
    default:
      return ok({});
  }
};

// ── Signature ──────────────────────────────────────────────────────────────

Deno.test("the webhook signature is HMAC SHA-512 of the raw body", async () => {
  const raw = new Uint8Array(new TextEncoder().encode('{"event":"charge.success"}'));
  assert(await validSignature(raw, await hmac('{"event":"charge.success"}'), secret));
  assert(
    !(await validSignature(raw, await hmac('{"event":"charge.success"} '), secret)),
    "tampered body",
  );
  assert(
    !(await validSignature(
      raw,
      await hmac('{"event":"charge.success"}', "sk_test_other0000000000"),
      secret,
    )),
  );
  assert(!(await validSignature(raw, null, secret)), "missing header");
  assert(!(await validSignature(raw, "abc", secret)), "malformed header");
});

Deno.test("an unsigned or forged webhook is refused before anything is read", async () => {
  const { handler, calls } = setup(eventDb);
  const payload = { event: "charge.success", data: { id: 1, reference } };
  assertEquals((await webhook(handler, payload, null)).status, 401);
  assertEquals((await webhook(handler, payload, "f".repeat(128))).status, 401);
  assertEquals(
    (await webhook(handler, payload, await hmac("{}", "sk_test_wrongkey00000000"))).status,
    401,
  );
  assertEquals(calls.length, 0, "no database call for an unauthenticated webhook");
});

// ── Charges ────────────────────────────────────────────────────────────────

Deno.test("a signed charge.success is verified with Paystack and then applied", async () => {
  const paystack = fakePaystack();
  const { handler, calls } = setup(eventDb, paystack);
  const res = await webhook(handler, {
    event: "charge.success",
    data: { id: 42, reference, amount: 1 },
  });
  assertEquals(res.status, 200);
  assertEquals(paystack.calls, [`verify:${reference}`]);
  const apply = calls.find((c) => c.fn === "billing_apply_verified");
  // The verified amount is used, never the (forgeable) webhook body's.
  assertEquals(apply?.args.p_amount_kobo, 70000000);
  assertEquals(apply?.args.p_environment, "test");
  assertEquals(
    calls.find((c) => c.fn === "billing_record_event")?.args.p_dedupe_key,
    "charge.success:42",
  );
  assertEquals(calls.at(-1)?.fn, "billing_event_done");
  assertEquals(calls.at(-1)?.args.p_outcome, "applied");
});

Deno.test("a duplicate event is acknowledged and not processed again", async () => {
  const paystack = fakePaystack();
  const { handler, calls } = setup(
    (fn) => fn === "billing_record_event" ? ok({ eventId: 7, duplicate: true }) : ok({}),
    paystack,
  );
  const res = await webhook(handler, { event: "charge.success", data: { id: 42, reference } });
  assertEquals(res.status, 200);
  assertEquals(paystack.calls.length, 0);
  assertEquals(calls.map((c) => c.fn), ["billing_record_event"]);
});

Deno.test("a charge Paystack doesn't confirm as successful applies nothing", async () => {
  for (
    const verified of [
      charge({ status: "failed" }),
      { kind: "not_found" } as VerifyOutcome,
      charge({ reference: "ewp_somethingelse0" }),
    ]
  ) {
    const { handler, calls } = setup(eventDb, fakePaystack(() => verified));
    assertEquals(
      (await webhook(handler, { event: "charge.success", data: { id: 1, reference } })).status,
      200,
    );
    assert(!calls.some((c) => c.fn === "billing_apply_verified"));
  }
});

Deno.test("verification outages make Paystack retry (500, event left open)", async () => {
  const { handler, calls } = setup(eventDb, fakePaystack(() => ({ kind: "unavailable" })));
  assertEquals(
    (await webhook(handler, { event: "charge.success", data: { id: 1, reference } })).status,
    500,
  );
  assert(!calls.some((c) => c.fn === "billing_event_done"));
});

Deno.test("a live-mode charge is passed as live so a test checkout refuses it", async () => {
  const { handler, calls } = setup(eventDb, fakePaystack(() => charge({ environment: "live" })));
  await webhook(handler, { event: "charge.success", data: { id: 1, reference } });
  assertEquals(calls.find((c) => c.fn === "billing_apply_verified")?.args.p_environment, "live");
});

Deno.test("a subscription renewal (invoice.update) is matched by its subscription code", async () => {
  const { handler, calls } = setup((fn) => {
    if (fn === "billing_record_event") return ok({ eventId: 9, duplicate: false });
    if (fn === "billing_record_renewal") {
      return ok({ outcome: "applied", tenantId: "t1", paymentId });
    }
    return ok({});
  }, fakePaystack(() => charge({ reference: "T_renewal_00001", planCode: "PLN_band400" })));
  await webhook(handler, {
    event: "invoice.update",
    data: {
      id: 77,
      paid: true,
      subscription: { subscription_code: "SUB_abc123" },
      transaction: { reference: "T_renewal_00001", status: "success" },
    },
  });
  const renewal = calls.find((c) => c.fn === "billing_record_renewal");
  assertEquals(renewal?.args.p_subscription_code, "SUB_abc123");
  assertEquals(renewal?.args.p_plan_code, "PLN_band400");
});

Deno.test("unknown events are acknowledged and logged", async () => {
  const { handler, calls } = setup(eventDb);
  assertEquals(
    (await webhook(handler, { event: "transfer.success", data: { id: 3 } })).status,
    200,
  );
  assertEquals(calls.at(-1)?.args.p_outcome, "ignored");
});

// ── User routes ────────────────────────────────────────────────────────────

Deno.test("checkout opens Paystack with the server's amount and never leaks server fields", async () => {
  const paystack = fakePaystack();
  const { handler, calls } = setup((fn) => {
    if (fn === "billing_checkout") {
      return ok({
        paymentId,
        applied: false,
        reference: "PAY-7Q4K-2603",
        amount: "700000.00",
        currency: "NGN",
        amountKobo: 70000000,
        providerReference: reference,
        email: "founder@example.test",
        status: "open",
        authorizationUrl: null,
      });
    }
    return ok({ paymentId });
  }, paystack);
  const res = await handler(user("/checkout", {
    method: "POST",
    body: JSON.stringify({
      planKey: "band_400",
      kind: "year",
      returnTo: "setup",
      idempotencyKey: key,
    }),
  }));
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.data.authorizationUrl, "https://checkout.paystack.com/abc123");
  assertEquals(body.data.reference, "PAY-7Q4K-2603");
  assert(!JSON.stringify(body).includes(reference), "the Paystack reference stays server-side");
  assert(!JSON.stringify(body).includes("founder@example.test"));
  assertEquals(
    paystack.calls[0],
    `initialize:70000000:${reference}:https://app.elivatewallet.com/setup/payment/${paymentId}`,
  );
  assertEquals(calls.find((c) => c.fn === "billing_checkout")?.args.p_environment, "test");
});

Deno.test("checkout validates its input", async () => {
  const { handler } = setup();
  for (
    const body of [
      { planKey: "band_9", kind: "year", idempotencyKey: key },
      { planKey: "band_400", kind: "free", idempotencyKey: key },
      { planKey: "band_400", kind: "year", returnTo: "https://evil.example", idempotencyKey: key },
      { planKey: "band_400", kind: "year", amount: "1.00", idempotencyKey: key },
    ]
  ) {
    const res = await handler(user("/checkout", { method: "POST", body: JSON.stringify(body) }));
    assertEquals(res.status, 400, JSON.stringify(body));
  }
});

Deno.test("checking a payment verifies with Paystack server-side, then re-reads", async () => {
  let reads = 0;
  const paystack = fakePaystack();
  const { handler, calls } = setup((fn) => {
    if (fn === "billing_payment") {
      reads++;
      return ok({
        payment: { id: paymentId, status: reads === 1 ? "open" : "paid" },
        tenantStatus: "active",
        verify: reads === 1 ? { providerReference: reference, environment: "test" } : null,
      });
    }
    return ok({ outcome: "applied" });
  }, paystack);
  const res = await handler(user(`/payments/${paymentId}`));
  const body = await res.json();
  assertEquals(body.data.payment.status, "paid");
  assertEquals(body.data.verify, undefined, "verification details never reach the client");
  assert(calls.some((c) => c.fn === "billing_apply_verified"));
});

Deno.test("an abandoned checkout is marked only after returning from Paystack", async () => {
  const paystack = fakePaystack(() => charge({ status: "abandoned" }));
  const db: Responder = (fn) =>
    fn === "billing_payment"
      ? ok({ payment: { id: paymentId, status: "open" }, verify: { providerReference: reference } })
      : ok({});
  const first = setup(db, paystack);
  await first.handler(user(`/payments/${paymentId}`));
  assert(!first.calls.some((c) => c.fn === "billing_mark_unpaid"), "still open while polling");
  const second = setup(db, paystack);
  await second.handler(user(`/payments/${paymentId}?returned=1`));
  assertEquals(
    second.calls.find((c) => c.fn === "billing_mark_unpaid")?.args.p_status,
    "abandoned",
  );
});

Deno.test("user routes need a session and map database errors", async () => {
  const { handler } = setup(() => fail("conflict", { reason: "seat_limit_reached" }));
  const anon = await handler(new Request("https://x.supabase.co/functions/v1/billing/overview"));
  assertEquals(anon.status, 401);
  const res = await handler(user("/overview"));
  assertEquals(res.status, 409);
  assertEquals((await res.json()).error.details.reason, "seat_limit_reached");
});

// ── Sync worker ────────────────────────────────────────────────────────────

Deno.test("the sync worker needs its secret and moves the subscription", async () => {
  const paystack = fakePaystack();
  const { handler, calls } = setup((fn) => {
    if (fn === "billing_plan_codes") {
      return ok([{
        planId: "p1",
        key: "band_400",
        name: "Up to 400 users",
        amountKobo: 70000000,
        planCode: null,
      }]);
    }
    if (fn === "billing_set_plan_code") return ok({ planCode: "PLN_new0001" });
    if (fn === "billing_sync_claim") {
      return ok([{
        tenantId: "t1",
        version: 7,
        renew: true,
        amountKobo: 70000000,
        planId: "p1",
        startDate: "2027-10-14T09:00:00Z",
        customerCode: "CUS_abc123",
        subscriptionCode: "SUB_old0001",
        emailToken: "oldtoken",
      }]);
    }
    return ok({});
  }, paystack);
  const denied = await handler(
    new Request("https://x.supabase.co/functions/v1/billing/worker/sync", {
      method: "POST",
      headers: { authorization: "Bearer nope" },
    }),
  );
  assertEquals(denied.status, 401);
  const res = await handler(
    new Request("https://x.supabase.co/functions/v1/billing/worker/sync", {
      method: "POST",
      headers: { authorization: `Bearer ${workerSecret}` },
    }),
  );
  assertEquals(res.status, 200);
  assertEquals(paystack.calls, [
    "plan:Elivate Wallet — Up to 400 users (yearly):70000000",
    "disable:SUB_old0001:oldtoken",
    "find:CUS_abc123:70000000",
    "subscribe:CUS_abc123:PLN_new0001:2027-10-14T09:00:00.000Z",
  ]);
  const done = calls.find((c) => c.fn === "billing_sync_done");
  assertEquals(done?.args.p_subscription_code, "SUB_new0001");
  assertEquals(done?.args.p_version, 7, "the claimed version goes back with the result");
});

Deno.test("a subscription created by an uncertain earlier attempt is adopted, not duplicated", async () => {
  const paystack = fakePaystack();
  const { handler, calls } = setup((fn) => {
    if (fn === "billing_plan_codes") {
      return ok([{
        planId: "p1",
        name: "Up to 400 users",
        amountKobo: 70000000,
        planCode: "PLN_x1",
      }]);
    }
    if (fn === "billing_sync_claim") {
      return ok([{
        tenantId: "t1",
        version: 3,
        renew: true,
        planId: "p1",
        amountKobo: 70000000,
        startDate: "2027-10-14T09:00:00Z",
        customerCode: "CUS_adopt0001",
        subscriptionCode: null,
        emailToken: null,
      }]);
    }
    // SUB_othernet1 already belongs to another network of the same payer.
    if (fn === "billing_unclaimed_subscriptions") return ok(["SUB_adopted01"]);
    return ok({});
  }, paystack);
  await handler(
    new Request("https://x.supabase.co/functions/v1/billing/worker/sync", {
      method: "POST",
      headers: { authorization: `Bearer ${workerSecret}` },
    }),
  );
  assert(!paystack.calls.some((c) => c.startsWith("subscribe:")), "no second subscription");
  assertEquals(
    calls.find((c) => c.fn === "billing_sync_done")?.args.p_subscription_code,
    "SUB_adopted01",
  );
});

Deno.test("each invoice state is its own event, so a paid update is never deduplicated away", async () => {
  const { handler, calls } = setup((fn) =>
    fn === "billing_record_event" ? ok({ eventId: 1, duplicate: false }) : ok({ outcome: "x" })
  );
  await webhook(handler, {
    event: "invoice.update",
    data: { id: 77, paid: false, status: "pending" },
  });
  await webhook(handler, { event: "invoice.update", data: { id: 77, paid: true } });
  const keys = calls.filter((c) => c.fn === "billing_record_event").map((c) => c.args.p_dedupe_key);
  assertEquals(keys, ["invoice.update:77:pending", "invoice.update:77:paid"]);
});

// ── Paystack client ────────────────────────────────────────────────────────

Deno.test("the Paystack client reads the mode from the key and accepts only Paystack checkout URLs", async () => {
  assertEquals(environmentOf("sk_test_abc"), "test");
  assertEquals(environmentOf("sk_live_abc"), "live");
  const client = paystackBilling(secret, {
    fetcher: () =>
      Promise.resolve(
        new Response(
          JSON.stringify({ status: true, data: { authorization_url: "https://evil.example/pay" } }),
        ),
      ),
  });
  const opened = await client.initialize({
    email: "a@example.test",
    amountKobo: 1,
    reference,
    callbackUrl: "https://app.elivatewallet.com/x",
    paymentId,
  });
  assertEquals(opened.kind, "unavailable");
  const verifying = paystackBilling(secret, {
    fetcher: () =>
      Promise.resolve(
        new Response(JSON.stringify({
          status: true,
          data: {
            id: 5,
            status: "success",
            reference,
            amount: 70000000,
            currency: "NGN",
            domain: "test",
            paid_at: "2026-10-09T10:00:00.000Z",
            customer: { customer_code: "CUS_abc123", email: "a@example.test" },
            authorization: { reusable: true, channel: "card", last4: "4081" },
          },
        })),
      ),
  });
  const verified = await verifying.verify(reference);
  assertEquals(verified.kind, "ok");
  if (verified.kind === "ok") {
    assertEquals(verified.amountKobo, 70000000);
    assertEquals(verified.reusable, true);
    assert(!JSON.stringify(verified).includes("4081"), "card details are never kept");
  }
});

Deno.test("a disable counts only when Paystack confirms it or says it is already gone", async () => {
  const answer = (status: number, message: string) =>
    paystackBilling(secret, {
      fetcher: () =>
        Promise.resolve(
          new Response(JSON.stringify({ status: status === 200, message }), { status }),
        ),
    });
  assert(
    await answer(200, "Subscription disabled successfully").disableSubscription("SUB_a1", "t"),
  );
  assert(
    await answer(400, "Subscription with code not found or already inactive").disableSubscription(
      "SUB_a1",
      "t",
    ),
  );
  assert(!(await answer(400, "Invalid email token").disableSubscription("SUB_a1", "t")));
});
