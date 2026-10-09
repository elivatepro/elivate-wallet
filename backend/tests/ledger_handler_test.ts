import { assertEquals } from "@std/assert";
import {
  type Actor,
  createHandler,
  type Deps,
  type LogEntry,
  type RpcResult,
  sniffMime,
  type StoredObject,
} from "../supabase/functions/ledger/handler.ts";

const actor: Actor = {
  userId: "00000000-0000-0000-0000-0000000000a1",
  sessionId: "00000000-0000-0000-0000-00000000a0a1",
};
const membershipId = "00000000-0000-0000-0000-0000000000b1";
const targetId = "00000000-0000-0000-0000-0000000000c1";
const evidenceId = "00000000-0000-0000-0000-0000000000d1";
const tenantId = "00000000-0000-0000-0000-0000000000e1";
const objectPath = `${tenantId}/income/${evidenceId}`;
const key = "key-0000000000000001";
const pdf = new TextEncoder().encode("%PDF-1.7 receipt");

async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(bytes)));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}

function setup(
  results: Record<string, RpcResult> = {},
  stored: StoredObject | null = { size: pdf.length, bytes: pdf },
) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const logs: LogEntry[] = [];
  const signed: string[] = [];
  const deps: Deps = {
    verifyToken: (token) => Promise.resolve(token === "good" ? actor : null),
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve(
        results[fn] ?? { data: { ok: true }, error: null },
      );
    },
    signUpload: (path) => {
      signed.push(path);
      return Promise.resolve({
        url: "https://storage.test/upload",
        token: "upload-token",
      });
    },
    download: () => Promise.resolve(stored),
    signDownload: (path) => Promise.resolve(`https://storage.test/read/${path}`),
    openAccount: () => Promise.resolve("0123456789"),
    log: (entry) => logs.push(entry),
    allowedOrigins: [],
  };
  return { handler: createHandler(deps), calls, logs, signed };
}

function request(
  method: string,
  path: string,
  body?: unknown,
  headers: Record<string, string> = { "x-membership": membershipId },
): Request {
  return new Request(`http://localhost/functions/v1/ledger${path}`, {
    method,
    headers: {
      authorization: "Bearer good",
      "content-type": "application/json",
      ...headers,
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

const income = {
  targetMembershipId: targetId,
  currency: "NGN",
  amount: "125000.50",
  source: "Fiverr",
  receivedOn: "2026-10-08",
  evidenceIds: [evidenceId],
  idempotencyKey: key,
};

async function code(response: Response): Promise<string> {
  return (await response.json()).error.code;
}

Deno.test("income amounts must be decimal strings; JSON numbers are refused", async () => {
  const { handler, calls } = setup();
  for (const amount of [125000.5, "1e5", "-1", "12,000", ""]) {
    const response = await handler(
      request("POST", "/income", { ...income, amount }),
    );
    assertEquals(response.status, 400);
    assertEquals(await code(response), "validation_error");
  }
  assertEquals(calls.length, 0);
});

Deno.test("income passes exact strings and the actor from the token", async () => {
  const { handler, calls } = setup();
  const response = await handler(
    request("POST", "/income", {
      ...income,
      fee: { amount: "500.00", currency: "NGN" },
    }),
  );
  assertEquals(response.status, 200);
  assertEquals(calls[0]?.fn, "record_income");
  assertEquals(calls[0]?.args.p_amount, "125000.50");
  assertEquals(calls[0]?.args.p_fee_amount, "500.00");
  assertEquals(calls[0]?.args.p_user_id, actor.userId);
  assertEquals(calls[0]?.args.p_membership_id, membershipId);
  assertEquals(calls[0]?.args.p_evidence_ids, [evidenceId]);
});

Deno.test("income field formats are checked", async () => {
  const { handler, calls } = setup();
  const bad: Record<string, unknown>[] = [
    { currency: "ngn" },
    { receivedOn: "2026-02-30" },
    { receivedOn: "08/10/2026" },
    { evidenceIds: [evidenceId, evidenceId] },
    { evidenceIds: ["nope"] },
    { evidenceIds: Array(6).fill(evidenceId) },
    { fee: { amount: "1.00" } },
    { extra: true },
  ];
  for (const change of bad) {
    const response = await handler(
      request("POST", "/income", { ...income, ...change }),
    );
    assertEquals(response.status, 400, JSON.stringify(change));
  }
  const empty = await handler(
    request("POST", "/income", { ...income, evidenceIds: [] }),
  );
  assertEquals(await code(empty), "evidence_required");
  assertEquals(calls.length, 0);
});

Deno.test("leadership routes need the workspace header; own-wallet routes don't use it", async () => {
  const { handler, calls } = setup();
  const missing = await handler(request("GET", "/wallets", undefined, {}));
  assertEquals(await code(missing), "workspace_invalid");
  const own = await handler(request("GET", "/me/wallet", undefined, {}));
  assertEquals(own.status, 200);
  assertEquals(calls[0]?.fn, "my_wallet");
  assertEquals(calls[0]?.args, {
    p_user_id: actor.userId,
    p_session_id: actor.sessionId,
  });
});

Deno.test("activity filters are validated", async () => {
  const { handler, calls } = setup();
  for (
    const query of [
      "direction=sideways",
      "currency=naira",
      "from=yesterday",
      "bogus=1",
    ]
  ) {
    const response = await handler(
      request("GET", `/me/activity?${query}`, undefined, {}),
    );
    assertEquals(response.status, 400, query);
  }
  const ok = await handler(
    request(
      "GET",
      `/me/activity?currency=USD&direction=in&tenantId=${tenantId}`,
      undefined,
      {},
    ),
  );
  assertEquals(ok.status, 200);
  assertEquals(calls[0]?.args.p_currency, "USD");
  assertEquals(calls[0]?.args.p_tenant_id, tenantId);
});

Deno.test("split changes take integer basis points", async () => {
  const { handler, calls } = setup();
  const body = {
    expectedVersion: 1,
    pockets: [{ name: "Savings", basisPoints: 10000 }],
    reason: "Pilot review",
    idempotencyKey: key,
  };
  for (
    const pockets of [[{ name: "Savings", basisPoints: 50.5 }], [], [{
      name: "",
      basisPoints: 1,
    }]]
  ) {
    const response = await handler(
      request("PUT", "/allocation", { ...body, pockets }),
    );
    assertEquals(response.status, 400);
  }
  const ok = await handler(request("PUT", "/allocation", body));
  assertEquals(ok.status, 200);
  assertEquals(calls[0]?.args.p_pockets, [{
    pocketId: null,
    name: "Savings",
    basisPoints: 10000,
  }]);
});

Deno.test("uploads are signed for the server-built path only", async () => {
  const { handler, signed } = setup({
    create_evidence_upload: {
      data: { evidenceId, objectPath, expiresAt: "2026-10-08T10:00:00Z" },
      error: null,
    },
  });
  const response = await handler(request("POST", "/evidence/uploads", {
    targetMembershipId: targetId,
    idempotencyKey: key,
    fileName: "receipt.pdf",
    mimeType: "application/pdf",
    size: pdf.length,
    sha256: await sha256(pdf),
  }));
  assertEquals(response.status, 200);
  const data = (await response.json()).data;
  assertEquals(data.uploadUrl, "https://storage.test/upload");
  assertEquals(data.objectPath, undefined);
  assertEquals(signed, [objectPath]);

  const unknownField = await handler(request("POST", "/evidence/uploads", {
    targetMembershipId: targetId,
    idempotencyKey: key,
    fileName: "receipt.pdf",
    mimeType: "application/pdf",
    size: pdf.length,
    sha256: await sha256(pdf),
    objectPath: "elsewhere/x",
  }));
  assertEquals(unknownField.status, 400);
});

function finalizeSetup(stored: StoredObject | null) {
  return setup({
    evidence_upload_target: {
      data: { evidenceId, objectPath, status: "pending", maxSize: 10485760 },
      error: null,
    },
    finalize_evidence_upload: {
      data: { evidenceId, status: "finalized" },
      error: null,
    },
  }, stored);
}

Deno.test("finalize passes the computed facts of the stored bytes", async () => {
  const { handler, calls } = finalizeSetup({ size: pdf.length, bytes: pdf });
  const response = await handler(
    request("POST", `/evidence/uploads/${evidenceId}/finalize`),
  );
  assertEquals(response.status, 200);
  const args = calls.find((c) => c.fn === "finalize_evidence_upload")?.args;
  assertEquals(args?.p_size, pdf.length);
  assertEquals(args?.p_sha256, await sha256(pdf));
  assertEquals(args?.p_mime, "application/pdf");
});

Deno.test("finalize: oversize, wrong type and missing objects", async () => {
  const big = finalizeSetup({ size: 10485761, bytes: null });
  await big.handler(
    request("POST", `/evidence/uploads/${evidenceId}/finalize`),
  );
  const bigArgs = big.calls.find((c) => c.fn === "finalize_evidence_upload")
    ?.args;
  assertEquals(bigArgs?.p_size, 10485761);
  assertEquals(bigArgs?.p_mime, null);

  const fake = new TextEncoder().encode("GIF89a not allowed");
  const wrong = finalizeSetup({ size: fake.length, bytes: fake });
  await wrong.handler(
    request("POST", `/evidence/uploads/${evidenceId}/finalize`),
  );
  assertEquals(
    wrong.calls.find((c) => c.fn === "finalize_evidence_upload")?.args.p_mime,
    null,
  );

  const missing = finalizeSetup(null);
  const response = await missing.handler(
    request("POST", `/evidence/uploads/${evidenceId}/finalize`),
  );
  assertEquals(await code(response), "evidence_invalid");
  assertEquals(
    missing.calls.some((c) => c.fn === "finalize_evidence_upload"),
    false,
  );

  const mismatch = setup({
    evidence_upload_target: {
      data: { evidenceId, objectPath, status: "pending", maxSize: 10485760 },
      error: null,
    },
    finalize_evidence_upload: {
      data: { evidenceId, status: "cancelled" },
      error: null,
    },
  });
  const cancelled = await mismatch.handler(
    request("POST", `/evidence/uploads/${evidenceId}/finalize`),
  );
  assertEquals(await code(cancelled), "evidence_invalid");
});

Deno.test("magic bytes decide the type", () => {
  assertEquals(sniffMime(pdf), "application/pdf");
  assertEquals(
    sniffMime(new Uint8Array([0xff, 0xd8, 0xff, 0xe0])),
    "image/jpeg",
  );
  assertEquals(
    sniffMime(
      new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0]),
    ),
    "image/png",
  );
  assertEquals(sniffMime(new Uint8Array([0x3c, 0x73, 0x76, 0x67])), null);
});

Deno.test("database errors map to contract codes", async () => {
  const { handler } = setup({
    record_income: {
      data: null,
      error: {
        message: "insufficient_funds",
        details: '{"available":"10.00"}',
      },
    },
  });
  const response = await handler(request("POST", "/income", income));
  assertEquals(response.status, 409);
  const body = await response.json();
  assertEquals(body.error.code, "insufficient_funds");
  assertEquals(body.error.details.available, "10.00");
});

Deno.test("logs carry no amounts, ids, file names or hashes", async () => {
  const { handler, logs } = setup();
  await handler(request("POST", "/income", income));
  await handler(request("GET", `/wallets/${evidenceId}/activity`));
  const text = JSON.stringify(logs);
  for (
    const secret of [
      "125000.50",
      evidenceId,
      targetId,
      membershipId,
      "receipt",
      key,
    ]
  ) {
    assertEquals(text.includes(secret), false, secret);
  }
  assertEquals(logs[1]?.route, "GET /wallets/:walletId/activity");
});

// ── Blueprint 08 ──

Deno.test("activity search, status and time zone pass through validated", async () => {
  const { handler, calls } = setup();
  for (
    const query of [
      "status=Posted!",
      "tz=../../etc",
      "q=",
      `q=${"x".repeat(101)}`,
    ]
  ) {
    const response = await handler(
      request("GET", `/me/activity?${query}`, undefined, {}),
    );
    assertEquals(response.status, 400, query);
  }
  assertEquals(calls.length, 0);
  const ok = await handler(
    request(
      "GET",
      `/me/activity?q=${encodeURIComponent("₦180,000")}&status=posted&tz=Africa/Lagos`,
      undefined,
      {},
    ),
  );
  assertEquals(ok.status, 200);
  assertEquals(calls[0]?.fn, "my_activity");
  assertEquals(calls[0]?.args.p_query, "₦180,000");
  assertEquals(calls[0]?.args.p_status, "posted");
  assertEquals(calls[0]?.args.p_tz, "Africa/Lagos");
  const managed = await handler(
    request("GET", `/wallets/${evidenceId}/activity?q=INC-7F2K&tz=UTC`),
  );
  assertEquals(managed.status, 200);
  assertEquals(calls[1]?.fn, "managed_wallet_activity");
  assertEquals(calls[1]?.args.p_query, "INC-7F2K");
});

Deno.test("command outcome: own key, no workspace, validated", async () => {
  const { handler, calls } = setup({
    command_outcome: {
      data: { status: "committed", command: "record_income", reference: "INC-7F2K-0931" },
      error: null,
    },
  });
  for (
    const query of [
      "",
      "idempotencyKey=short",
      `idempotencyKey=${key}&command=Record-Income`,
      `idempotencyKey=${key}&extra=1`,
    ]
  ) {
    const response = await handler(
      request("GET", `/me/command-outcome?${query}`, undefined, {}),
    );
    assertEquals(response.status, 400, query);
  }
  assertEquals(calls.length, 0);
  const ok = await handler(
    request(
      "GET",
      `/me/command-outcome?idempotencyKey=${key}&command=record_income`,
      undefined,
      {},
    ),
  );
  assertEquals(ok.status, 200);
  assertEquals((await ok.json()).data.status, "committed");
  assertEquals(calls[0]?.fn, "command_outcome");
  assertEquals(calls[0]?.args, {
    p_user_id: actor.userId,
    p_session_id: actor.sessionId,
    p_idempotency_key: key,
    p_command: "record_income",
  });
});

Deno.test("command outcome: the key never reaches the logs", async () => {
  const { handler, logs } = setup();
  await handler(request("GET", `/me/command-outcome?idempotencyKey=${key}`, undefined, {}));
  assertEquals(JSON.stringify(logs).includes(key), false);
  assertEquals(logs[0]?.route, "GET /me/command-outcome");
});

Deno.test("overview needs the workspace and takes an optional zone", async () => {
  const { handler, calls } = setup();
  const missing = await handler(request("GET", "/overview", undefined, {}));
  assertEquals(await code(missing), "workspace_invalid");
  const bad = await handler(request("GET", "/overview?tz=%20"));
  assertEquals(bad.status, 400);
  const ok = await handler(request("GET", "/overview?tz=Africa/Lagos"));
  assertEquals(ok.status, 200);
  assertEquals(calls[0]?.fn, "leadership_overview");
  assertEquals(calls[0]?.args, {
    p_user_id: actor.userId,
    p_session_id: actor.sessionId,
    p_membership_id: membershipId,
    p_tz: "Africa/Lagos",
  });
});
