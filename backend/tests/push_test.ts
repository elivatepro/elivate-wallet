// Blueprint 42 — B6: Web Push encryption (RFC 8291 vector and a round trip),
// VAPID (RFC 8292), the push wording for every Q1 kind, the endpoint
// allow-list, the transport's outcomes, the worker's push pass and the
// identity routes for this device's switch.

import { assert, assertEquals, assertRejects } from "@std/assert";
import {
  createPushTransport,
  encrypt,
  endpointAllowed,
  fromBase64Url,
  importLocalKeys,
  toBase64Url,
  vapidAuthorization,
} from "../supabase/functions/_shared/push/webpush.ts";
import {
  MAX_PAYLOAD_BYTES,
  pushPayload,
  pushText,
  safePath,
  topicFor,
  urgencyFor,
} from "../supabase/functions/_shared/push/text.ts";
import {
  createHandler,
  type RpcResult,
  type WorkerLogEntry,
} from "../supabase/functions/outbox-worker/handler.ts";
import { createHandler as createIdentityHandler } from "../supabase/functions/identity/handler.ts";
import type {
  PushDevice,
  PushMessage,
  PushOutcome,
} from "../supabase/functions/_shared/push/webpush.ts";

const join = (...parts: string[]) => parts.join("");

// ── RFC 8291 Appendix A ──
Deno.test("encryption matches the RFC 8291 test vector", async () => {
  const keys = await importLocalKeys(
    join(
      "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIg",
      "Dll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
    ),
    "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw",
  );
  const body = await encrypt(
    new TextEncoder().encode("When I grow up, I want to be a watermelon"),
    {
      p256dh: join(
        "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcx",
        "aOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
      ),
      auth: "BTBZMqHH6r4Tts7J_aSIgg",
    },
    { salt: fromBase64Url("DGv6ra1nlYgDCS1FRnbzlw"), keys },
  );
  assertEquals(
    toBase64Url(body),
    join(
      "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml",
      "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT",
      "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
    ),
  );
});

/** The browser's side (RFC 8291 §3.4), to check a fresh message decrypts. */
async function decrypt(
  body: Uint8Array<ArrayBuffer>,
  ua: CryptoKeyPair,
  auth: Uint8Array<ArrayBuffer>,
) {
  const salt = body.slice(0, 16);
  const idlen = body[20] ?? 0;
  const asPublic = body.slice(21, 21 + idlen);
  const ciphertext = body.slice(21 + idlen);
  const uaPublic = new Uint8Array(await crypto.subtle.exportKey("raw", ua.publicKey));
  const asKey = await crypto.subtle.importKey(
    "raw",
    asPublic,
    { name: "ECDH", namedCurve: "P-256" },
    false,
    [],
  );
  const secret = new Uint8Array(
    await crypto.subtle.deriveBits({ name: "ECDH", public: asKey }, ua.privateKey, 256),
  );
  const hmac = async (key: Uint8Array<ArrayBuffer>, data: Uint8Array<ArrayBuffer>) =>
    new Uint8Array(
      await crypto.subtle.sign(
        "HMAC",
        await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, [
          "sign",
        ]),
        data,
      ),
    );
  const enc = new TextEncoder();
  const info = new Uint8Array([...enc.encode("WebPush: info\0"), ...uaPublic, ...asPublic, 1]);
  const ikm = await hmac(await hmac(auth, secret), info);
  const prk = await hmac(salt, ikm);
  const cek = (await hmac(prk, enc.encode("Content-Encoding: aes128gcm\0\x01"))).slice(0, 16);
  const nonce = (await hmac(prk, enc.encode("Content-Encoding: nonce\0\x01"))).slice(0, 12);
  const plain = new Uint8Array(
    await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: nonce },
      await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["decrypt"]),
      ciphertext,
    ),
  );
  assertEquals(plain[plain.length - 1], 2, "last-record delimiter");
  return new TextDecoder().decode(plain.slice(0, -1));
}

async function browserKeys() {
  const ua = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, [
    "deriveBits",
  ]) as CryptoKeyPair;
  const auth = crypto.getRandomValues(new Uint8Array(16));
  const p256dh = toBase64Url(new Uint8Array(await crypto.subtle.exportKey("raw", ua.publicKey)));
  return { ua, auth, p256dh, authText: toBase64Url(auth) };
}

Deno.test("a fresh message decrypts on the browser's side, with new keys each time", async () => {
  const b = await browserKeys();
  const one = await encrypt(new TextEncoder().encode("hello"), {
    p256dh: b.p256dh,
    auth: b.authText,
  });
  const two = await encrypt(new TextEncoder().encode("hello"), {
    p256dh: b.p256dh,
    auth: b.authText,
  });
  assertEquals(await decrypt(one, b.ua, b.auth), "hello");
  assert(toBase64Url(one.slice(0, 16)) !== toBase64Url(two.slice(0, 16)), "fresh salt");
  await assertRejects(() =>
    encrypt(new Uint8Array(1), { p256dh: b.p256dh, auth: toBase64Url(new Uint8Array(8)) })
  );
});

async function vapidKeys() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ]) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
  return {
    pair,
    vapid: {
      publicKey: toBase64Url(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey))),
      privateKey: jwk.d!,
      subject: "mailto:support@elivatewallet.com",
    },
  };
}

Deno.test("the VAPID header is an ES256 JWT for the push service that verifies", async () => {
  const { pair, vapid } = await vapidKeys();
  const now = new Date("2026-10-16T10:00:00Z");
  const header = await vapidAuthorization("https://fcm.googleapis.com/fcm/send/abc", vapid, now);
  const match = header.match(/^vapid t=([^.]+)\.([^.]+)\.([^,]+), k=(.+)$/);
  assert(match, header);
  const [, h, c, s, k] = match;
  assertEquals(k, vapid.publicKey);
  assertEquals(JSON.parse(new TextDecoder().decode(fromBase64Url(h!))), {
    typ: "JWT",
    alg: "ES256",
  });
  assertEquals(JSON.parse(new TextDecoder().decode(fromBase64Url(c!))), {
    aud: "https://fcm.googleapis.com",
    exp: Math.floor(now.getTime() / 1000) + 12 * 3600,
    sub: "mailto:support@elivatewallet.com",
  });
  assert(
    await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      pair.publicKey,
      fromBase64Url(s!),
      new TextEncoder().encode(`${h}.${c}`),
    ),
  );
});

Deno.test("only the browsers' push services are allowed", () => {
  for (
    const ok of [
      "https://fcm.googleapis.com/fcm/send/abc",
      "https://updates.push.services.mozilla.com/wpush/v2/abc",
      "https://web.push.apple.com/QK",
      "https://api.push.apple.com/x",
      "https://wns2-par02p.notify.windows.com/w/?token=abc",
    ]
  ) assert(endpointAllowed(ok), ok);
  for (
    const bad of [
      "http://fcm.googleapis.com/fcm/send/abc",
      "https://fcm.googleapis.com.evil.example/x",
      "https://evil.example/fcm.googleapis.com/",
      "https://user@fcm.googleapis.com/x",
      "https://fcm.googleapis.com:8443/x",
      "https://push.apple.com/x",
      "https://fcm.googleapis.com/a b",
      `https://fcm.googleapis.com/${"x".repeat(1000)}`,
    ]
  ) assert(!endpointAllowed(bad), bad);
});

// ── Wording (Part A) ──
const amount = { amount: "250000.00", currency: "NGN", path: "/app/activity" };

Deno.test("every Q1 kind has its title and line, with and without hidden amounts", () => {
  const cases: [string, string, string][] = [
    ["money.income_posted", "Income posted", "₦250,000.00, split across your pockets"],
    ["money.withdrawal_approved", "Withdrawal approved", "₦250,000.00. Payout is next."],
    ["money.withdrawal_completed", "Withdrawal completed", "Payout of ₦250,000.00 confirmed."],
    [
      "money.withdrawal_not_approved",
      "Withdrawal not approved",
      "₦250,000.00 is back in your pocket.",
    ],
    ["task.withdrawal_approve", "Withdrawal to approve", "₦250,000.00 is waiting for you"],
    ["task.payout_record", "Payout to record", "₦250,000.00 to pay out"],
    ["task.payout_fix", "Payout record to fix", "₦250,000.00 needs a fix"],
    ["task.payout_review", "Payout to review", "₦250,000.00 is waiting for you"],
    ["task.entry_review", "Evidence to review", "₦250,000.00 is waiting for you"],
    ["task.transfer_approve", "Pocket move to approve", "₦250,000.00 is waiting for you"],
    ["task.nin_review", "Identity to review", "Someone in your network is waiting for you"],
  ];
  for (const [kind, title, body] of cases) {
    assertEquals(pushText(kind, amount, false), { title, body }, kind);
    const hidden = pushText(kind, amount, true)!;
    assertEquals(hidden.title, title);
    assert(!hidden.body.includes("250"), `${kind} hides the amount`);
    if (kind !== "task.nin_review") assert(hidden.body.includes("₦••••••"), kind);
  }
  assertEquals(
    pushText("task.entry_review", { ...amount, subject: "returned_funds" }, false)?.title,
    "Returned funds to review",
  );
  assertEquals(pushText("money.withdrawal_submitted", amount, false), null);
  assertEquals(pushText("security.new_sign_in", amount, false), null);
});

Deno.test("odd params never leak or break the line", () => {
  assertEquals(
    pushText("money.income_posted", { amount: "1e9", currency: "NGN" }, false)?.body,
    "Open Elivate Wallet to see it.",
  );
  assertEquals(
    pushText("money.income_posted", { amount: "10.00", currency: "EUR" }, false)?.body,
    "Open Elivate Wallet to see it.",
  );
  assertEquals(
    pushText("money.income_posted", { amount: "1500.50", currency: "USD" }, false)?.body,
    "$1,500.50, split across your pockets",
  );
  assertEquals(safePath("https://evil.example/app"), "/app");
  assertEquals(
    safePath("/app/queue?withdrawal=00000000-0000-0000-0000-000000000001"),
    "/app/queue?withdrawal=00000000-0000-0000-0000-000000000001",
  );
});

Deno.test("the payload is small JSON with a safe link, urgency and topic", () => {
  const id = "11111111-2222-3333-4444-555555555555";
  const bytes = pushPayload(
    id,
    "task.withdrawal_approve",
    { ...amount, path: "//evil.example" },
    false,
  )!;
  assert(bytes.length <= MAX_PAYLOAD_BYTES);
  assertEquals(JSON.parse(new TextDecoder().decode(bytes)), {
    v: 1,
    id,
    title: "Withdrawal to approve",
    body: "₦250,000.00 is waiting for you",
    path: "/app",
  });
  assertEquals(pushPayload(id, "money.withdrawal_cancelled", amount, false), null);
  assertEquals(urgencyFor("task.payout_fix"), "high");
  assertEquals(urgencyFor("money.income_posted"), "normal");
  assertEquals(topicFor(id), "11111111222233334444555555555555");
});

// ── Transport ──
const device = (endpoint = "https://fcm.googleapis.com/fcm/send/abc") =>
  browserKeys().then((b) => ({ endpoint, p256dh: b.p256dh, auth: b.authText, b }));
const message = (): PushMessage => ({
  payload: new TextEncoder().encode('{"v":1}'),
  ttl: 43200,
  urgency: "high",
  topic: "abc",
});

Deno.test("the transport posts an encrypted body with VAPID and maps outcomes", async () => {
  const { vapid } = await vapidKeys();
  const d = await device();
  const seen: { url: string; init: RequestInit }[] = [];
  let status = 201;
  const transport = createPushTransport({
    vapid,
    fetch: (url, init) => {
      seen.push({ url: String(url), init: init! });
      return Promise.resolve(new Response(null, { status }));
    },
  });
  assertEquals(await transport.send(d, message()), { outcome: "sent", providerStatus: 201 });
  const headers = seen[0]!.init.headers as Record<string, string>;
  assertEquals(seen[0]!.url, d.endpoint);
  assertEquals(headers["content-encoding"], "aes128gcm");
  assertEquals(headers.ttl, "43200");
  assertEquals(headers.urgency, "high");
  assertEquals(headers.topic, "abc");
  assert(headers.authorization!.startsWith("vapid t="));
  assertEquals(
    await decrypt(seen[0]!.init.body as Uint8Array<ArrayBuffer>, d.b.ua, d.b.auth),
    '{"v":1}',
  );

  const outcome = async (s: number) => {
    status = s;
    return (await transport.send(d, message())).outcome;
  };
  assertEquals(await outcome(410), "gone");
  assertEquals(await outcome(404), "gone");
  assertEquals(await outcome(429), "retryable_failure");
  assertEquals(await outcome(503), "retryable_failure");
  assertEquals(await outcome(403), "permanent_failure");

  const before = seen.length;
  assertEquals(
    (await transport.send({ ...d, endpoint: "https://evil.example/x" }, message())).outcome,
    "permanent_failure",
  );
  assertEquals(seen.length, before, "a host off the list is never contacted");
});

Deno.test("a network error is retryable; a local fake receives the same path", async () => {
  const { vapid } = await vapidKeys();
  const d = await device();
  const failing = createPushTransport({
    vapid,
    fetch: () => Promise.reject(new TypeError("down")),
  });
  assertEquals((await failing.send(d, message())) as PushOutcome, {
    outcome: "retryable_failure",
    providerStatus: null,
    errorCode: "push.network",
  });
  let url = "";
  const local = createPushTransport({
    vapid,
    testOrigin: "http://host.docker.internal:54399",
    fetch: (u) => {
      url = String(u);
      return Promise.resolve(new Response(null, { status: 201 }));
    },
  });
  await local.send(d, message());
  assertEquals(url, "http://host.docker.internal:54399/fcm/send/abc");
});

// ── Worker push pass ──
const secret = "s".repeat(64);

function claim(n: number, kind = "money.income_posted", devices = 1) {
  return {
    itemId: `00000000-0000-0000-0000-00000000000${n}`,
    leaseToken: `10000000-0000-0000-0000-00000000000${n}`,
    attempt: 1,
    kind,
    params: { amount: "85000.00", currency: "NGN", path: "/app/withdrawals" },
    devices: Array.from({ length: devices }, (_, i) => ({
      id: `20000000-0000-0000-0000-0000000000${n}${i}`,
      endpoint: `https://fcm.googleapis.com/fcm/send/${n}${i}`,
      p256dh: "B" + "A".repeat(86),
      auth: "Q".repeat(22),
      hideAmounts: i === 1,
    })),
  };
}

function worker(claims: unknown[][], send: (d: PushDevice, m: PushMessage) => PushOutcome) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const sent: { device: PushDevice; message: PushMessage }[] = [];
  const logs: WorkerLogEntry[] = [];
  const queue = [...claims];
  const handler = createHandler({
    rpc: (fn, args): Promise<RpcResult> => {
      calls.push({ fn, args });
      if (fn === "push_claim") return Promise.resolve({ data: queue.shift() ?? [], error: null });
      if (fn === "push_report") {
        const results = args.p_results as { outcome: string }[];
        return Promise.resolve({
          data: {
            applied: true,
            status: results.some((r) => r.outcome === "sent") ? "sent" : "retry_scheduled",
          },
          error: null,
        });
      }
      return Promise.resolve({ data: {}, error: null });
    },
    workerSecret: secret,
    email: null,
    push: {
      transport: {
        send: (d, m) => {
          sent.push({ device: d, message: m });
          return Promise.resolve(send(d, m));
        },
      },
    },
    workerId: "test-worker",
    log: (entry) => logs.push(entry),
  });
  const run = () =>
    handler(
      new Request("http://localhost/functions/v1/outbox-worker", {
        method: "POST",
        headers: { authorization: `Bearer ${secret}` },
      }),
    );
  return { run, calls, sent, logs };
}

Deno.test("the push pass sends to every device and reports per device", async () => {
  const w = worker(
    [[claim(1, "money.income_posted", 2), claim(2, "task.withdrawal_approve")]],
    (d) =>
      d.endpoint.endsWith("/11")
        ? { outcome: "gone", providerStatus: 410, errorCode: "push.gone" }
        : { outcome: "sent", providerStatus: 201 },
  );
  const body = await (await w.run()).json();
  assertEquals(body.data.push, { configured: true, claimed: 2, results: { sent: 2 } });
  assertEquals(body.data.configured, false, "email stays unconfigured");
  assertEquals(w.sent.length, 3);
  const texts = w.sent.map((s) => JSON.parse(new TextDecoder().decode(s.message.payload)).body);
  assertEquals(texts[0], "₦85,000.00, split across your pockets");
  assertEquals(texts[1], "₦••••••, split across your pockets", "Hide amounts on that device");
  assertEquals(w.sent[2]?.message.urgency, "high");
  assertEquals(w.sent[0]?.message.topic, "00000000000000000000000000000001");
  const report = w.calls.find((c) => c.fn === "push_report");
  assertEquals(report?.args.p_lease_token, "10000000-0000-0000-0000-000000000001");
  const results = report?.args.p_results as Record<string, unknown>[];
  assertEquals(results.map((r) => r.outcome), ["sent", "gone"]);
  assertEquals(results[1]?.errorCode, "push.gone");
  assert(!JSON.stringify(w.logs).includes("fcm.googleapis.com"), "endpoints never reach the logs");
  assert(!JSON.stringify(w.logs).includes("85"), "nor amounts");
});

Deno.test("without VAPID keys nothing is claimed for push", async () => {
  const calls: string[] = [];
  const handler = createHandler({
    rpc: (fn) => {
      calls.push(fn);
      return Promise.resolve({ data: [], error: null });
    },
    workerSecret: secret,
    email: null,
    push: null,
    workerId: "test-worker",
    log: () => {},
  });
  const body = await (await handler(
    new Request("http://localhost/outbox-worker", {
      method: "POST",
      headers: { authorization: `Bearer ${secret}` },
    }),
  )).json();
  assertEquals(body.data.push, { configured: false, claimed: 0 });
  assert(!calls.includes("push_claim"));
});

Deno.test("an unexpected claim shape fails the run without sending", async () => {
  const w = worker(
    [[{ ...claim(1), devices: "nope" }]],
    () => ({ outcome: "sent", providerStatus: 201 }),
  );
  const response = await w.run();
  assertEquals(response.status, 500);
  assertEquals(w.sent.length, 0);
});

// ── Identity routes ──
const actor = {
  userId: "00000000-0000-0000-0000-0000000000a1",
  sessionId: "00000000-0000-0000-0000-00000000a0a1",
};

function identity() {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const handler = createIdentityHandler({
    verifyToken: (token) => Promise.resolve(token === "good" ? actor : null),
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve({
        data: { on: fn !== "push_unsubscribe", hideAmounts: false },
        error: null,
      });
    },
    log: () => {},
    allowedOrigins: [],
    provider: null,
    fingerprint: (nin) => Promise.resolve(nin),
  });
  const call = async (method: string, path: string, body?: unknown) => {
    const response = await handler(
      new Request(`http://localhost/functions/v1/identity${path}`, {
        method,
        headers: { authorization: "Bearer good", "content-type": "application/json" },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      }),
    );
    return { status: response.status, body: await response.json() };
  };
  return { call, calls };
}

const subscription = {
  endpoint: "https://fcm.googleapis.com/fcm/send/abc",
  keys: { p256dh: "B" + "A".repeat(86), auth: "Q".repeat(22) + "==" },
  hideAmounts: true,
};

Deno.test("PUT /push/subscription binds this device to the caller's session", async () => {
  const { call, calls } = identity();
  const response = await call("PUT", "/push/subscription", subscription);
  assertEquals(response.status, 200);
  assertEquals(calls[0], {
    fn: "push_subscribe",
    args: {
      p_user_id: actor.userId,
      p_session_id: actor.sessionId,
      p_endpoint: subscription.endpoint,
      p_p256dh: "B" + "A".repeat(86),
      p_auth: "Q".repeat(22),
      p_hide_amounts: true,
    },
  });
});

Deno.test("the push routes refuse bad input before the database", async () => {
  const { call, calls } = identity();
  const cases: [unknown, number, string, string][] = [
    [
      { ...subscription, endpoint: "https://evil.example/x" },
      409,
      "conflict",
      "push_host_not_allowed",
    ],
    [
      { ...subscription, endpoint: "http://fcm.googleapis.com/x" },
      400,
      "validation_error",
      "endpoint",
    ],
    [
      { ...subscription, keys: { ...subscription.keys, p256dh: "Bshort" } },
      400,
      "validation_error",
      "p256dh",
    ],
    [
      { ...subscription, keys: { ...subscription.keys, extra: "x" } },
      400,
      "validation_error",
      "keys",
    ],
    [{ ...subscription, hideAmounts: "yes" }, 400, "validation_error", "hideAmounts"],
    [{ ...subscription, more: 1 }, 400, "validation_error", "more"],
  ];
  for (const [body, status, code, detail] of cases) {
    const response = await call("PUT", "/push/subscription", body);
    assertEquals(response.status, status, JSON.stringify(body));
    assertEquals(response.body.error.code, code);
    const details = response.body.error.details ?? {};
    assertEquals(details.field ?? details.reason, detail);
  }
  assertEquals(calls.length, 0);
  assertEquals((await call("GET", "/push/subscription?endpoint=x")).status, 400);
  assertEquals((await call("GET", "/push/subscription?endpoint=a&b=c")).status, 400);
});

Deno.test("GET and DELETE /push/subscription read and end this device's push", async () => {
  const { call, calls } = identity();
  const url = `/push/subscription?endpoint=${encodeURIComponent(subscription.endpoint)}`;
  assertEquals((await call("GET", url)).body.data, { on: true, hideAmounts: false });
  assertEquals(
    (await call("DELETE", "/push/subscription", { endpoint: subscription.endpoint })).body.data,
    {
      on: false,
      hideAmounts: false,
    },
  );
  assertEquals(calls.map((c) => c.fn), ["push_subscription_state", "push_unsubscribe"]);
  assertEquals(calls[1]?.args.p_endpoint, subscription.endpoint);
});
