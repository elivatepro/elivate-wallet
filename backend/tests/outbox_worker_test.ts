import { assert, assertEquals } from "@std/assert";
import {
  createHandler,
  type Deps,
  type EmailSetup,
  type RpcResult,
  type WorkerLogEntry,
} from "../supabase/functions/outbox-worker/handler.ts";
import type { OutgoingEmail, SendOutcome } from "../supabase/functions/_shared/email/cloudflare.ts";

const secret = "s".repeat(64);
const tokenFor = (id: string) => `T${id.replace(/-/g, "").slice(0, 32)}${"x".repeat(10)}`;

function item(n: number, overrides: Record<string, unknown> = {}) {
  return {
    eventId: `00000000-0000-0000-0000-00000000000${n}`,
    leaseToken: `10000000-0000-0000-0000-00000000000${n}`,
    cycle: 1,
    attempt: 1,
    template: "invitation.issued",
    version: 1,
    params: {
      network: "Lagos Network",
      office: "Team A",
      role: "Member",
      reference: "INV-7K3M-9QP2",
      expiresAt: "2026-10-15T09:00:00Z",
    },
    to: `person${n}@example.test`,
    tokenId: `20000000-0000-0000-0000-00000000000${n}`,
    ...overrides,
  };
}

function setup(
  options: {
    claims?: unknown[][];
    email?: "none" | ((email: OutgoingEmail) => SendOutcome);
    secret?: string | null;
  } = {},
) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const sent: OutgoingEmail[] = [];
  const logs: WorkerLogEntry[] = [];
  const claims = [...(options.claims ?? [])];
  const rpc = (fn: string, args: Record<string, unknown>): Promise<RpcResult> => {
    calls.push({ fn, args });
    if (fn === "outbox_run_maintenance") {
      return Promise.resolve({ data: { expiredInvitations: 0 }, error: null });
    }
    if (fn === "outbox_claim") return Promise.resolve({ data: claims.shift() ?? [], error: null });
    if (fn === "outbox_complete") {
      return Promise.resolve({ data: { applied: true, status: "sent" }, error: null });
    }
    return Promise.resolve({ data: { applied: true, status: "retry_scheduled" }, error: null });
  };
  const send = options.email === "none" ? null : options.email ??
    ((): SendOutcome => ({ outcome: "sent", providerStatus: 200, messageId: "<m@cf>" }));
  const email: EmailSetup | null = send === null ? null : {
    transport: {
      send: (message) => {
        sent.push(message);
        return Promise.resolve(send(message));
      },
    },
    token: (id) => Promise.resolve(tokenFor(id)),
    appOrigin: "https://app.elivatewallet.com",
  };
  const deps: Deps = {
    rpc,
    workerSecret: options.secret === undefined ? secret : options.secret,
    email,
    workerId: "test-worker",
    log: (entry) => logs.push(entry),
    batchSize: 2,
  };
  return { handler: createHandler(deps), calls, sent, logs };
}

const run = (auth: string | null = `Bearer ${secret}`) =>
  new Request("http://localhost/functions/v1/outbox-worker", {
    method: "POST",
    headers: auth ? { authorization: auth } : {},
  });

Deno.test("missing or wrong worker secret is refused before any database call", async () => {
  for (const auth of [null, "Bearer wrong", "Basic abc", `Bearer ${secret}x`]) {
    const { handler, calls } = setup();
    const response = await handler(run(auth));
    assertEquals(response.status, 401);
    assertEquals((await response.json()).error.code, "authentication_required");
    assertEquals(calls.length, 0);
  }
  const unset = setup({ secret: null });
  assertEquals((await unset.handler(run())).status, 401);
});

Deno.test("without email provider config nothing is claimed and the run says so", async () => {
  const { handler, calls, logs } = setup({ email: "none", claims: [[item(1)]] });
  const response = await handler(run());
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.data.configured, false);
  assertEquals(body.data.message, "email provider not configured");
  assertEquals(calls.map((c) => c.fn), ["outbox_run_maintenance"]);
  assert(logs.some((l) => l.message === "email provider not configured"));
});

Deno.test("processes claimed batches and reports each event", async () => {
  const { handler, calls, sent } = setup({ claims: [[item(1), item(2)], [item(3)]] });
  const response = await handler(run());
  const body = await response.json();
  assertEquals(body.data.claimed, 3);
  assertEquals(body.data.results, { sent: 3 });
  assertEquals(sent.length, 3);
  assertEquals(sent[0]?.to, "person1@example.test");
  assertEquals(sent[0]?.correlationId, "outbox:00000000-0000-0000-0000-000000000001:1");
  assert(
    sent[0]?.text.includes(
      `https://app.elivatewallet.com/join#t=${tokenFor("20000000-0000-0000-0000-000000000001")}`,
    ),
  );
  const claim = calls.find((c) => c.fn === "outbox_claim");
  assertEquals(claim?.args.p_batch_size, 2);
  assertEquals(claim?.args.p_lease_seconds, 120, "lease covers a whole batch of sequential sends");
  const completes = calls.filter((c) => c.fn === "outbox_complete");
  assertEquals(completes.length, 3);
  assertEquals(completes[0]?.args.p_lease_token, "10000000-0000-0000-0000-000000000001");
  assertEquals(completes[0]?.args.p_provider_message_id, "<m@cf>");
});

Deno.test("a render error becomes a permanent failure without stopping the batch", async () => {
  const { handler, calls, sent } = setup({
    claims: [[item(1, { params: { network: "" } }), item(2)]],
  });
  const body = await (await handler(run())).json();
  assertEquals(body.data.claimed, 2);
  const fail = calls.find((c) => c.fn === "outbox_fail");
  assertEquals(fail?.args.p_outcome, "permanent_failure");
  assertEquals(fail?.args.p_error_code, "template.param_invalid");
  assertEquals(sent.length, 1);
  assertEquals(calls.filter((c) => c.fn === "outbox_complete").length, 1);
});

Deno.test("provider failures are reported with their classification", async () => {
  const { handler, calls } = setup({
    claims: [[item(1)]],
    email: () => ({
      outcome: "retryable_failure",
      providerStatus: 503,
      errorCode: "provider.unavailable",
    }),
  });
  await handler(run());
  const fail = calls.find((c) => c.fn === "outbox_fail");
  assertEquals(fail?.args.p_outcome, "retryable_failure");
  assertEquals(fail?.args.p_error_code, "provider.unavailable");
  assertEquals(fail?.args.p_provider_status, 503);
});

Deno.test("logs never carry addresses, links or tokens", async () => {
  const { handler, logs } = setup({ claims: [[item(1)]] });
  await handler(run());
  const text = JSON.stringify(logs);
  assert(!text.includes("person1@example.test"));
  assert(!text.includes("#t="));
  assert(!text.includes(tokenFor("20000000-0000-0000-0000-000000000001")));
  assert(!text.includes(secret));
  assert(logs.some((l) => l.route === "delivery" && l.outcome === "sent"));
});

Deno.test("only POST to the worker path is served", async () => {
  const { handler } = setup();
  const get = await handler(
    new Request("http://localhost/functions/v1/outbox-worker", {
      method: "GET",
      headers: { authorization: `Bearer ${secret}` },
    }),
  );
  assertEquals(get.status, 404);
});

Deno.test("no new batch is claimed once the time budget is spent", async () => {
  const { handler, calls } = setup({ claims: [[item(1)]] });
  const budgeted = createHandler({
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve({ data: { expiredInvitations: 0 }, error: null });
    },
    workerSecret: secret,
    email: {
      transport: { send: () => Promise.reject(new Error("must not send")) },
      token: () => Promise.resolve("x"),
      appOrigin: "https://app.elivatewallet.com",
    },
    workerId: "test-worker",
    log: () => {},
    timeBudgetMs: 0,
  });
  assert(handler);
  const body = await (await budgeted(run())).json();
  assertEquals(body.data.claimed, 0);
  assertEquals(calls.map((c) => c.fn), ["outbox_run_maintenance"]);
});

Deno.test("a founder approval links to /founder (Blueprint 19)", async () => {
  const { handler, sent } = setup({
    claims: [[
      item(1, {
        template: "founder.application_approved",
        params: { team: "Harmony Builders", expiresAt: "2026-10-24T09:00:00Z" },
      }),
    ]],
  });
  const body = await (await handler(run())).json();
  assertEquals(body.data.results, { sent: 1 });
  assert(
    sent[0]?.text.includes(
      `https://app.elivatewallet.com/founder#t=${tokenFor("20000000-0000-0000-0000-000000000001")}`,
    ),
  );
});
