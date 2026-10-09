// Blueprint 15: the exports-worker routes, the statement/report routes on the
// ledger function and M15.
import { assert, assertEquals, assertThrows } from "@std/assert";
import {
  createHandler as createWorker,
  type RpcResult,
} from "../supabase/functions/exports-worker/handler.ts";
import { type Actor, createHandler as createLedger } from "../supabase/functions/ledger/handler.ts";
import { renderEmail, TemplateError } from "../supabase/functions/_shared/email/templates.ts";

const exportId = "00000000-0000-0000-0000-0000000000f1";
const membershipId = "00000000-0000-0000-0000-0000000000b1";
const tenantId = "00000000-0000-0000-0000-0000000000e1";
const actor: Actor = {
  userId: "00000000-0000-0000-0000-0000000000a1",
  sessionId: "00000000-0000-0000-0000-00000000a0a1",
};

function worker(results: Record<string, RpcResult> = {}) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const handler = createWorker({
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve(results[fn] ?? { data: { ok: true }, error: null });
    },
    workerSecret: "s3cret-worker",
    log: () => {},
  });
  return { handler, calls };
}

function workerRequest(method: string, path: string, body?: unknown, secret = "s3cret-worker") {
  return new Request(`http://localhost/functions/v1/exports-worker${path}`, {
    method,
    headers: { authorization: `Bearer ${secret}`, "content-type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

Deno.test("exports-worker refuses a wrong or missing secret", async () => {
  const { handler, calls } = worker();
  const response = await handler(workerRequest("POST", "/claim", { worker: "w1" }, "nope"));
  assertEquals(response.status, 403);
  assertEquals(calls.length, 0);
});

Deno.test("exports-worker maps each step to its api function", async () => {
  const { handler, calls } = worker();
  await handler(workerRequest("POST", "/claim", { worker: "cf:abc" }));
  await handler(workerRequest("POST", `/${exportId}/prepare`, { worker: "cf:abc" }));
  await handler(workerRequest("GET", `/${exportId}/rows?worker=cf:abc&after=0&limit=1000`));
  await handler(workerRequest("POST", `/${exportId}/finalize`, {
    worker: "cf:abc",
    rowCount: 12,
    pageCount: 2,
    byteSize: 40960,
    sha256: "a".repeat(64),
    hasPreview: true,
  }));
  await handler(
    workerRequest("POST", `/${exportId}/fail`, { worker: "cf:abc", reason: "render_failed" }),
  );
  assertEquals(calls.map((c) => c.fn), [
    "export_claim",
    "export_prepare",
    "export_rows",
    "export_finalize",
    "export_fail",
  ]);
  assertEquals(calls[2]?.args, {
    p_export_id: exportId,
    p_worker: "cf:abc",
    p_after: 0,
    p_limit: 1000,
  });
  assertEquals(calls[3]?.args.p_row_count, 12);
});

Deno.test("exports-worker validates every input", async () => {
  const { handler, calls } = worker();
  const bad = [
    workerRequest("POST", "/claim", { worker: "has space" }),
    workerRequest("POST", "/claim", { worker: "w", extra: 1 }),
    workerRequest("GET", `/${exportId}/rows?worker=w&after=0&limit=1001`),
    workerRequest("GET", `/${exportId}/rows?worker=w&after=-1&limit=10`),
    workerRequest("POST", `/${exportId}/finalize`, {
      worker: "w",
      rowCount: 1,
      byteSize: 10,
      sha256: "nope",
    }),
    workerRequest("POST", `/${exportId}/finalize`, {
      worker: "w",
      rowCount: 1.5,
      byteSize: 10,
      sha256: "a".repeat(64),
    }),
    workerRequest("POST", `/${exportId}/fail`, { worker: "w", reason: "because" }),
  ];
  for (const request of bad) assertEquals((await handler(request)).status, 400);
  assertEquals((await handler(workerRequest("POST", "/not-a-step", {}))).status, 404);
  assertEquals(calls.length, 0);
});

Deno.test("exports-worker passes database errors through the envelope", async () => {
  const { handler } = worker({
    export_finalize: {
      data: null,
      error: { message: "conflict", details: JSON.stringify({ reason: "lease_lost" }) },
    },
  });
  const response = await handler(workerRequest("POST", `/${exportId}/finalize`, {
    worker: "w",
    rowCount: 1,
    byteSize: 10,
    sha256: "a".repeat(64),
  }));
  assertEquals(response.status, 409);
  assertEquals((await response.json()).error.details.reason, "lease_lost");
});

function ledger(results: Record<string, RpcResult> = {}) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const handler = createLedger({
    verifyToken: (token) => Promise.resolve(token === "good" ? actor : null),
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve(results[fn] ?? { data: { ok: true }, error: null });
    },
    signUpload: () => Promise.resolve(null),
    download: () => Promise.resolve(null),
    signDownload: () => Promise.resolve(null),
    openAccount: () => Promise.resolve(""),
    log: () => {},
    allowedOrigins: [],
    appServerSecret: "app-server-secret",
  });
  return { handler, calls };
}

function ledgerRequest(
  method: string,
  path: string,
  body?: unknown,
  headers: Record<string, string> = {},
) {
  return new Request(`http://localhost/functions/v1/ledger${path}`, {
    method,
    headers: {
      authorization: "Bearer good",
      "content-type": "application/json",
      "x-membership": membershipId,
      ...headers,
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

const period = { periodKind: "month", from: "2026-09-01", to: "2026-09-30" };

Deno.test("statements: create passes the period, format and network", async () => {
  const { handler, calls } = ledger();
  const response = await handler(ledgerRequest("POST", "/statements", {
    tenantId,
    currency: "NGN",
    ...period,
    format: "pdf",
    idempotencyKey: "key-0000000000000001",
  }));
  assertEquals(response.status, 200);
  assertEquals(calls[0]?.fn, "create_statement");
  assertEquals(calls[0]?.args.p_period_kind, "month");
  assertEquals(calls[0]?.args.p_tenant_id, tenantId);
  assertEquals(calls[0]?.args.p_format, "pdf");
});

Deno.test("statements and reports reject bad input before the database", async () => {
  const { handler, calls } = ledger();
  const bad = [
    ledgerRequest("POST", "/statements", {
      currency: "NGN",
      ...period,
      format: "xls",
      idempotencyKey: "key-0000000000000001",
    }),
    ledgerRequest("POST", "/statements", {
      currency: "NGN",
      ...period,
      periodKind: "week",
      format: "pdf",
      idempotencyKey: "key-0000000000000001",
    }),
    ledgerRequest("POST", "/statements", {
      currency: "NGN",
      ...period,
      from: "1 Sep",
      format: "pdf",
      idempotencyKey: "key-0000000000000001",
    }),
    ledgerRequest("POST", "/reports", {
      kind: "everything",
      currency: "NGN",
      ...period,
      idempotencyKey: "key-0000000000000001",
    }),
    ledgerRequest(
      "GET",
      "/reports/overview?currency=ngn&periodKind=month&from=2026-09-01&to=2026-09-30",
    ),
  ];
  for (const request of bad) assertEquals((await handler(request)).status, 400);
  assertEquals(calls.length, 0);
});

Deno.test("reports: overview and create run in the selected workspace", async () => {
  const { handler, calls } = ledger();
  await handler(
    ledgerRequest(
      "GET",
      "/reports/overview?currency=NGN&periodKind=month&from=2026-09-01&to=2026-09-30",
    ),
  );
  await handler(ledgerRequest("POST", "/reports", {
    kind: "member_balances_csv",
    currency: "USD",
    ...period,
    idempotencyKey: "key-0000000000000002",
  }));
  assertEquals(calls.map((c) => c.fn), ["report_overview", "create_report"]);
  assertEquals(calls[0]?.args.p_membership_id, membershipId);
  assertEquals(calls[1]?.args.p_kind, "member_balances_csv");
  assertEquals(calls[1]?.args.p_member_wallet_id, null);
});

Deno.test("download authorization is for the app server only and checks the key", async () => {
  const key = `exports/${tenantId}/${exportId}/1.pdf`;
  const { handler, calls } = ledger({
    authorize_export_download: {
      data: { objectKey: key, fileName: "f.pdf", contentType: "application/pdf" },
      error: null,
    },
  });
  const browser = await handler(ledgerRequest("POST", `/exports/${exportId}/download`, {}));
  assertEquals(browser.status, 403);
  assertEquals(calls.length, 0);
  const server = await handler(
    ledgerRequest("POST", `/exports/${exportId}/download`, { part: "file" }, {
      "x-app-server-secret": "app-server-secret",
    }),
  );
  assertEquals(server.status, 200);
  assertEquals((await server.json()).data.objectKey, key);

  const drift = ledger({
    authorize_export_download: { data: { objectKey: "../../etc/passwd" }, error: null },
  });
  const response = await drift.handler(
    ledgerRequest("POST", `/exports/${exportId}/download`, {}, {
      "x-app-server-secret": "app-server-secret",
    }),
  );
  assertEquals(response.status, 500);
});

Deno.test("M15 renders the statement and report variants without amounts or file links", () => {
  const base = {
    network: "Cedar Network",
    title: "Q3 2026",
    currency: "USD",
    format: "Office report PDF",
    chip: "Report",
    path: "/app/reports",
  };
  const email = renderEmail("money.statement_ready", 1, base, {
    appUrl: "https://app.elivatewallet.com",
  });
  assertEquals(email.subject, "Your report is ready");
  assert(email.html.includes("Q3 2026"));
  assert(email.html.includes("USD · Office report PDF"));
  assert(email.html.includes("Get report"));
  assert(!/₦|\$[0-9]/.test(email.html));
  for (
    const title of [
      "September 2026",
      "2026",
      "2026 so far",
      "1 Sep – 15 Oct 2026",
      "28 Dec 2025 – 3 Jan 2026",
    ]
  ) {
    renderEmail("money.statement_ready", 1, { ...base, title }, {
      appUrl: "https://app.elivatewallet.com",
    });
  }
  for (
    const bad of [{ title: "<b>x</b>" }, { format: "Zip" }, { chip: "Invoice" }, {
      path: "https://evil.test",
    }]
  ) {
    assertThrows(
      () =>
        renderEmail("money.statement_ready", 1, { ...base, ...bad }, {
          appUrl: "https://app.elivatewallet.com",
        }),
      TemplateError,
    );
  }
});
