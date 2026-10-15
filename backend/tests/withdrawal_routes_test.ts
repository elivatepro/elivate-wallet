import { assertEquals } from "@std/assert";
import {
  type Actor,
  createHandler,
  type Deps,
  type LogEntry,
  type RpcResult,
} from "../supabase/functions/ledger/handler.ts";

const actor: Actor = {
  userId: "00000000-0000-0000-0000-0000000000a1",
  sessionId: "00000000-0000-0000-0000-00000000a0a1",
};
const membershipId = "00000000-0000-0000-0000-0000000000b1";
const withdrawalId = "00000000-0000-0000-0000-0000000000c1";
const evidenceId = "00000000-0000-0000-0000-0000000000d1";
const tenantId = "00000000-0000-0000-0000-0000000000e1";
const ownerId = "00000000-0000-0000-0000-0000000000f1";
const key = "key-0000000000000001";

function setup(results: Record<string, RpcResult> = {}) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const logs: LogEntry[] = [];
  const opened: unknown[][] = [];
  const reads: { path: string; seconds: number }[] = [];
  const deps: Deps = {
    verifyToken: (token) => Promise.resolve(token === "good" ? actor : null),
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve(results[fn] ?? { data: { ok: true }, error: null });
    },
    signUpload: () => Promise.resolve({ url: "https://storage.test/upload", token: "t" }),
    download: () => Promise.resolve(null),
    signDownload: (path, seconds) => {
      reads.push({ path, seconds });
      return Promise.resolve("https://storage.test/read");
    },
    openAccount: (...args) => {
      opened.push(args);
      return Promise.resolve("0123456789");
    },
    log: (entry) => logs.push(entry),
    allowedOrigins: [],
  };
  return { handler: createHandler(deps), calls, logs, opened, reads };
}

function request(method: string, path: string, body?: unknown): Request {
  return new Request(`http://localhost/functions/v1/ledger${path}`, {
    method,
    headers: {
      authorization: "Bearer good",
      "content-type": "application/json",
      "x-membership": membershipId,
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

async function code(response: Response): Promise<string> {
  return (await response.json()).error.code;
}

Deno.test("request withdrawal passes exact strings in the workspace", async () => {
  const { handler, calls } = setup();
  const response = await handler(request("POST", "/me/withdrawals", {
    accountId: withdrawalId,
    amount: "2500.00",
    payoutAccountId: evidenceId,
    reason: "School fees for the term",
    idempotencyKey: key,
  }));
  assertEquals(response.status, 200);
  assertEquals(calls[0]?.fn, "request_withdrawal");
  assertEquals(calls[0]?.args.p_amount, "2500.00");
  assertEquals(calls[0]?.args.p_reason, "School fees for the term");
  assertEquals(calls[0]?.args.p_membership_id, membershipId);
  assertEquals(typeof calls[0]?.args.p_request_id, "string");
});

Deno.test("withdrawal amounts must be decimal strings", async () => {
  const { handler, calls } = setup();
  for (const amount of [2500, "1e3", "-5", ""]) {
    const response = await handler(request("POST", "/me/withdrawals", {
      accountId: withdrawalId,
      amount,
      payoutAccountId: evidenceId,
      reason: "School fees for the term",
      idempotencyKey: key,
    }));
    assertEquals(response.status, 400);
  }
  assertEquals(calls.length, 0);
});

Deno.test("a withdrawal needs a reason of 3–500 characters (Blueprint 40)", async () => {
  const { handler, calls } = setup();
  for (const reason of [undefined, null, 42, "", "  ab  ", "x".repeat(501)]) {
    const response = await handler(request("POST", "/me/withdrawals", {
      accountId: withdrawalId,
      amount: "2500.00",
      payoutAccountId: evidenceId,
      ...(reason === undefined ? {} : { reason }),
      idempotencyKey: key,
    }));
    assertEquals(response.status, 400);
    const body = await response.json();
    assertEquals(body.error.code, "validation_error");
    assertEquals(body.error.details.field, "reason");
  }
  assertEquals(calls.length, 0);
});

Deno.test("list filters are closed sets", async () => {
  const { handler, calls } = setup();
  for (
    const path of [
      "/me/withdrawals?status=pending",
      "/withdrawals?tab=all",
      "/reviews?tab=x",
      "/pocket-transfers",
    ]
  ) {
    const response = await handler(request("GET", path));
    if (path === "/pocket-transfers") continue;
    assertEquals(response.status, 400, path);
  }
  assertEquals(calls.map((c) => c.fn), ["transfer_queue"]);
  assertEquals((await handler(request("GET", "/withdrawals?tab=verifying"))).status, 200);
});

Deno.test("member cancel allows no reason; leader cancel and reject require one", async () => {
  const { handler, calls } = setup();
  assertEquals(
    (await handler(
      request("POST", `/me/withdrawals/${withdrawalId}/cancel`, { idempotencyKey: key }),
    )).status,
    200,
  );
  assertEquals(calls[0]?.args.p_reason, null);
  for (const action of ["cancel", "reject"]) {
    const response = await handler(
      request("POST", `/withdrawals/${withdrawalId}/${action}`, { idempotencyKey: key }),
    );
    assertEquals(response.status, 400);
  }
  assertEquals(calls.length, 1);
});

Deno.test("reveal decrypts with the owner and never returns ciphertext", async () => {
  const { handler, opened, logs } = setup({
    reveal_withdrawal_destination: {
      data: {
        withdrawalId,
        reference: "WDR-1",
        bankName: "GTBank",
        accountName: "ADA OBI",
        accountLast4: "6789",
        ownerUserId: ownerId,
        ciphertext: "sealed",
        keyVersion: 1,
      },
      error: null,
    },
  });
  const response = await handler(request("POST", `/withdrawals/${withdrawalId}/reveal`, {}));
  assertEquals(response.status, 200);
  assertEquals(response.headers.get("cache-control"), "no-store");
  const data = (await response.json()).data;
  assertEquals(data.accountNumber, "0123456789");
  assertEquals("ciphertext" in data || "ownerUserId" in data || "keyVersion" in data, false);
  assertEquals(opened, [[ownerId, "sealed", 1]]);
  assertEquals(JSON.stringify(logs).includes("0123456789"), false);
});

Deno.test("reveal fails closed on a malformed database result", async () => {
  const { handler, opened } = setup({
    reveal_withdrawal_destination: { data: { withdrawalId }, error: null },
  });
  const response = await handler(request("POST", `/withdrawals/${withdrawalId}/reveal`, {}));
  assertEquals(response.status, 500);
  assertEquals(opened.length, 0);
});

Deno.test("record payout validates money, date and the receipt id", async () => {
  const { handler, calls } = setup();
  const payout = {
    amount: "2450.00",
    fee: "50.00",
    paidOn: "2026-10-09",
    evidenceId,
    idempotencyKey: key,
  };
  assertEquals(
    (await handler(request("POST", `/withdrawals/${withdrawalId}/payouts`, payout))).status,
    200,
  );
  assertEquals(calls[0]?.fn, "record_payout");
  assertEquals(calls[0]?.args.p_fee_amount, "50.00");
  assertEquals(calls[0]?.args.p_bank_reference, null);
  for (
    const bad of [
      { amount: 2450 },
      { fee: "x" },
      { paidOn: "2026-02-30" },
      { evidenceId: "nope" },
      { extra: 1 },
    ]
  ) {
    const response = await handler(
      request("POST", `/withdrawals/${withdrawalId}/payouts`, { ...payout, ...bad }),
    );
    assertEquals(response.status, 400, JSON.stringify(bad));
  }
  assertEquals(calls.length, 1);
});

Deno.test("payout evidence upload signs only a database-built payout path", async () => {
  const upload = {
    withdrawalId,
    idempotencyKey: key,
    fileName: "r.pdf",
    mimeType: "application/pdf",
    size: 10,
    sha256: "a".repeat(64),
  };
  const good = setup({
    create_payout_evidence_upload: {
      data: { evidenceId, objectPath: `${tenantId}/payout/${evidenceId}`, expiresAt: "x" },
      error: null,
    },
  });
  assertEquals(
    (await good.handler(request("POST", "/payout-evidence/uploads", upload))).status,
    200,
  );
  const bad = setup({
    create_payout_evidence_upload: {
      data: { evidenceId, objectPath: `${tenantId}/other/${evidenceId}` },
      error: null,
    },
  });
  assertEquals(
    (await bad.handler(request("POST", "/payout-evidence/uploads", upload))).status,
    500,
  );
});

Deno.test("receipt link is signed for 60 seconds and needs a revision", async () => {
  const { handler, reads } = setup({
    payout_receipt: {
      data: {
        objectPath: `${tenantId}/payout/${evidenceId}`,
        name: "r.pdf",
        mimeType: "application/pdf",
      },
      error: null,
    },
  });
  assertEquals((await handler(request("GET", `/payouts/${withdrawalId}/receipt`))).status, 400);
  assertEquals(
    (await handler(request("GET", `/payouts/${withdrawalId}/receipt?revision=3`))).status,
    400,
  );
  const response = await handler(request("GET", `/payouts/${withdrawalId}/receipt?revision=1`));
  assertEquals(response.status, 200);
  const data = (await response.json()).data;
  assertEquals(data.url, "https://storage.test/read");
  assertEquals("objectPath" in data, false);
  assertEquals(reads, [{ path: `${tenantId}/payout/${evidenceId}`, seconds: 60 }]);
});

Deno.test("review decision is clear or reject with a reason", async () => {
  const { handler, calls } = setup();
  assertEquals(
    (await handler(
      request("POST", `/reviews/${withdrawalId}/decision`, {
        decision: "approve",
        reason: "fine",
        idempotencyKey: key,
      }),
    )).status,
    400,
  );
  assertEquals(
    (await handler(
      request("POST", `/reviews/${withdrawalId}/decision`, {
        decision: "clear",
        idempotencyKey: key,
      }),
    )).status,
    400,
  );
  assertEquals(
    (await handler(
      request("POST", `/reviews/${withdrawalId}/decision`, {
        decision: "clear",
        reason: "Receipt matches",
        idempotencyKey: key,
      }),
    )).status,
    200,
  );
  assertEquals(calls.map((c) => c.args.p_decision), ["clear"]);
});

Deno.test("database conflicts keep their reason", async () => {
  const { handler } = setup({
    request_pocket_transfer: {
      data: null,
      error: { message: "conflict", details: JSON.stringify({ reason: "debt_limit" }) },
    },
  });
  const response = await handler(request("POST", "/me/pocket-transfers", {
    sourceAccountId: withdrawalId,
    destinationPocketId: evidenceId,
    amount: "100.00",
    idempotencyKey: key,
  }));
  assertEquals(response.status, 409);
  const body = await response.json();
  assertEquals(body.error.code, "conflict");
  assertEquals(body.error.details.reason, "debt_limit");
});

Deno.test("workspace header is required", async () => {
  const { handler } = setup();
  const response = await handler(
    new Request("http://localhost/functions/v1/ledger/me/withdrawals", {
      headers: { authorization: "Bearer good" },
    }),
  );
  assertEquals(await code(response), "workspace_invalid");
});
