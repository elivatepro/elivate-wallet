import {
  assertEquals,
  assertRejects,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  PaystackClient,
  PaystackError,
  type PaystackFailureCode,
} from "../src/integrations/paystack.ts";

const secretKey = "sk_test_fixture";
const expected = {
  reference: "purchase-00000000-0000-4000-8000-000000000001",
  amountMinor: 70_000_000,
  email: "buyer@example.test",
};
const callbackUrl = "https://app.example.test/setup/payment";
const payment = {
  reference: expected.reference,
  amount: expected.amountMinor,
  currency: "NGN",
  domain: "test",
  status: "success",
  paid_at: "2026-10-01T10:00:00.000Z",
  customer: { email: expected.email },
};
function client(fetch: (url: string, init: RequestInit) => Promise<Response>) {
  return new PaystackClient({
    secretKey,
    environment: "test",
    callbackOrigin: "https://app.example.test",
    fetch,
  });
}
function response(data: unknown): Promise<Response> {
  return Promise.resolve(Response.json({ status: true, data }));
}
async function failure(
  operation: () => Promise<unknown>,
  code: PaystackFailureCode,
  retryable = false,
) {
  const error = await assertRejects(operation, PaystackError);
  assertEquals(error.code, code);
  assertEquals(error.retryable, retryable);
  assertEquals(error.message, "Payment provider request failed");
  assertEquals(error.cause, undefined);
}

Deno.test("Paystack initializes only the server-bound NGN purchase", async () => {
  const adapter = client((url, init) => {
    assertEquals(url, "https://api.paystack.co/transaction/initialize");
    assertEquals(init.method, "POST");
    assertEquals(init.redirect, "error");
    assertEquals(
      new Headers(init.headers).get("authorization"),
      `Bearer ${secretKey}`,
    );
    assertEquals(
      new Headers(init.headers).get("user-agent"),
      "ElivateWallet/2.0",
    );
    assertEquals(init.signal instanceof AbortSignal, true);
    assertEquals(JSON.parse(String(init.body)), {
      reference: expected.reference,
      amount: "70000000",
      email: expected.email,
      currency: "NGN",
      callback_url: callbackUrl,
    });
    return response({
      reference: expected.reference,
      authorization_url: "https://checkout.paystack.com/fixture",
      access_code: "not-exposed",
    });
  });
  assertEquals(await adapter.initialize({ ...expected, callbackUrl }), {
    reference: expected.reference,
    checkoutUrl: "https://checkout.paystack.com/fixture",
  });
  assertEquals(JSON.stringify(adapter), "{}");
});

Deno.test("Paystack rejects mismatched environment credentials and unsafe origins", () => {
  for (
    const options of [
      {
        secretKey: "sk_live_fixture",
        callbackOrigin: "https://app.example.test",
      },
      { secretKey, callbackOrigin: "http://app.example.test" },
      { secretKey, callbackOrigin: "https://account:secret@app.example.test" },
      { secretKey, callbackOrigin: "https://app.example.test/untrusted-path" },
    ]
  ) {
    assertThrows(
      () => new PaystackClient({ ...options, environment: "test" }),
      PaystackError,
    );
  }
});

Deno.test("Paystack rejects invalid purchase data before a provider call", async () => {
  let calls = 0;
  const adapter = client(() => {
    calls++;
    return response({});
  });
  for (
    const input of [
      { ...expected, amountMinor: 0 },
      { ...expected, amountMinor: 0.1 },
      { ...expected, amountMinor: Number.MAX_SAFE_INTEGER + 1 },
      { ...expected, reference: "../../another-payment" },
      { ...expected, reference: "." },
      { ...expected, reference: ".." },
      { ...expected, email: "invalid" },
      { ...expected, callbackUrl: "https://other.example.test" },
      { ...expected, callbackUrl: "https://account:secret@app.example.test" },
    ]
  ) {
    await failure(
      () => adapter.initialize({ callbackUrl, ...input }),
      "invalid_request",
    );
  }
  assertEquals(calls, 0);
});

Deno.test("Paystack rejects altered references and untrusted checkout URLs", async () => {
  for (
    const data of [
      {
        reference: "another",
        authorization_url: "https://checkout.paystack.com/x",
      },
      {
        reference: expected.reference,
        authorization_url: "https://other.example/x",
      },
      {
        reference: expected.reference,
        authorization_url: "http://checkout.paystack.com/x",
      },
      {
        reference: expected.reference,
        authorization_url: "https://account:secret@checkout.paystack.com/x",
      },
      { reference: expected.reference, authorization_url: "not a URL" },
    ]
  ) {
    await failure(
      () =>
        client(() => response(data)).initialize({ ...expected, callbackUrl }),
      "invalid_response",
    );
  }
});

Deno.test("Paystack verification returns only a matched successful receipt", async () => {
  const result = await client((url, init) => {
    assertEquals(
      url,
      `https://api.paystack.co/transaction/verify/${expected.reference}`,
    );
    assertEquals(init.method, "GET");
    assertEquals(init.body, undefined);
    return response({
      ...payment,
      id: 9_007_199_254_740_992,
      ip_address: "private",
    });
  }).verify(expected);
  assertEquals(result, {
    reference: expected.reference,
    amountMinor: expected.amountMinor,
    currency: "NGN",
    paidAt: payment.paid_at,
  });
});

Deno.test("Paystack verification rejects amount, currency, buyer, reference and environment mismatches", async () => {
  for (
    const change of [
      { reference: "another" },
      { amount: expected.amountMinor - 1 },
      { currency: "USD" },
      { domain: "live" },
      { customer: { email: "another@example.test" } },
      { customer: null },
    ]
  ) {
    await failure(
      () => client(() => response({ ...payment, ...change })).verify(expected),
      "payment_mismatch",
    );
  }
});

Deno.test("Paystack pending or failed payments never become verified receipts", async () => {
  for (const status of ["failed", "abandoned", "pending", "ongoing"]) {
    await failure(
      () => client(() => response({ ...payment, status })).verify(expected),
      "payment_not_confirmed",
      status === "pending" || status === "ongoing",
    );
  }
  for (const paid_at of [null, "2026-02-31T10:00:00.000Z", "invalid-date"]) {
    await failure(
      () => client(() => response({ ...payment, paid_at })).verify(expected),
      "invalid_response",
    );
  }
});

Deno.test("Paystack HTTP and transport failures expose no provider body or credentials", async () => {
  for (const status of [401, 403, 429, 500]) {
    await failure(
      () =>
        client(() => Promise.resolve(new Response(secretKey, { status })))
          .verify(expected),
      status >= 500 || status === 429
        ? "provider_unavailable"
        : "provider_rejected",
      status >= 500 || status === 429,
    );
  }
  await failure(
    () => client(() => Promise.reject(new Error(secretKey))).verify(expected),
    "provider_unavailable",
    true,
  );
});

Deno.test("Paystack malformed provider contracts remain failures", async () => {
  for (
    const data of [null, [], { status: false, message: secretKey }, {
      status: true,
      data: null,
    }]
  ) {
    await failure(
      () => client(() => Promise.resolve(Response.json(data))).verify(expected),
      "invalid_response",
    );
  }
  await failure(
    () =>
      client(() => Promise.resolve(new Response("invalid-json"))).verify(
        expected,
      ),
    "invalid_response",
  );
});

Deno.test("Paystack body timeouts and stream failures remain retryable", async () => {
  for (
    const error of [
      new DOMException("private provider details", "TimeoutError"),
      new TypeError("private stream failure"),
    ]
  ) {
    const stream = new ReadableStream({
      start(controller) {
        controller.error(error);
      },
    });
    await failure(
      () =>
        client(() => Promise.resolve(new Response(stream))).verify(expected),
      "provider_unavailable",
      true,
    );
  }
});

Deno.test("Paystack webhook authentication binds the exact raw bytes", async () => {
  const raw = await new Blob(['{"event":"charge.success","data":{}}'])
    .arrayBuffer();
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secretKey),
    { name: "HMAC", hash: "SHA-512" },
    false,
    ["sign"],
  );
  const signed = new Uint8Array(await crypto.subtle.sign("HMAC", key, raw));
  const signature = Array.from(
    signed,
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
  const adapter = client(() => response({}));
  assertEquals(await adapter.verifyWebhook(raw, signature), true);
  assertEquals(
    await adapter.verifyWebhook(
      await new Blob(['{ "event":"charge.success","data":{}}']).arrayBuffer(),
      signature,
    ),
    false,
  );
  assertEquals(await adapter.verifyWebhook(raw, "0".repeat(128)), false);
  assertEquals(await adapter.verifyWebhook(raw, null), false);
  assertEquals(await adapter.verifyWebhook(raw, "invalid"), false);
  assertEquals(
    await adapter.verifyWebhook(new ArrayBuffer(0), signature),
    false,
  );
  assertEquals(
    await adapter.verifyWebhook(new ArrayBuffer(1_048_577), signature),
    false,
  );
});
