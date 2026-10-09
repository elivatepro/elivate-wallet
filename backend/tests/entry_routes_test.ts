import { assertEquals } from "@std/assert";
import {
  type Actor,
  createHandler,
  type Deps,
  type RpcResult,
} from "../supabase/functions/ledger/handler.ts";

const actor: Actor = {
  userId: "00000000-0000-0000-0000-0000000000a1",
  sessionId: "00000000-0000-0000-0000-00000000a0a1",
};
const membershipId = "00000000-0000-0000-0000-0000000000b1";
const accountId = "00000000-0000-0000-0000-0000000000c1";
const evidenceId = "00000000-0000-0000-0000-0000000000d1";
const entryId = "00000000-0000-0000-0000-0000000000e1";
const tenantId = "00000000-0000-0000-0000-0000000000f1";
const key = "key-0000000000000001";

function setup(results: Record<string, RpcResult> = {}) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
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
    openAccount: () => Promise.resolve("0123456789"),
    log: () => {},
    allowedOrigins: [],
  };
  return { handler: createHandler(deps), calls, reads };
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

const conversion = {
  sourceAccountId: accountId,
  amount: "420.00",
  destinationCurrency: "NGN",
  destinationAmount: "638400.00",
  quotedRate: "1525",
  provider: "Grey",
  convertedAt: "2026-10-02T16:40:00+01:00",
  evidenceIds: [evidenceId],
  idempotencyKey: key,
};

Deno.test("conversion passes exact strings and the moment as sent", async () => {
  const { handler, calls } = setup();
  const response = await handler(request("POST", "/conversions", conversion));
  assertEquals(response.status, 200);
  assertEquals(calls[0]?.fn, "submit_conversion");
  assertEquals(calls[0]?.args.p_amount, "420.00");
  assertEquals(calls[0]?.args.p_destination_amount, "638400.00");
  assertEquals(calls[0]?.args.p_quoted_rate, "1525");
  assertEquals(calls[0]?.args.p_converted_at, "2026-10-02T16:40:00+01:00");
  assertEquals(calls[0]?.args.p_external_reference, null);
  assertEquals(typeof calls[0]?.args.p_request_id, "string");
});

Deno.test("conversion refuses bad rates, moments and missing evidence", async () => {
  const { handler, calls } = setup();
  for (
    const change of [
      { quotedRate: "1,525" },
      { quotedRate: 1525 },
      { convertedAt: "2026-10-02 16:40" },
      { convertedAt: "2026-13-02T16:40:00Z" },
      { amount: 420 },
      { destinationCurrency: "naira" },
    ]
  ) {
    const response = await handler(request("POST", "/conversions", { ...conversion, ...change }));
    assertEquals(response.status, 400, JSON.stringify(change));
  }
  const empty = await handler(request("POST", "/conversions", { ...conversion, evidenceIds: [] }));
  assertEquals(await code(empty), "evidence_required");
  assertEquals(calls.length, 0);
});

Deno.test("adjustment needs a direction, a reason and evidence", async () => {
  const { handler, calls } = setup();
  const body = {
    targetMembershipId: entryId,
    direction: "credit",
    currency: "NGN",
    amount: "12000.00",
    reason: "Goodwill credit from the network",
    evidenceIds: [evidenceId],
    idempotencyKey: key,
  };
  assertEquals((await handler(request("POST", "/adjustments", body))).status, 200);
  assertEquals(calls[0]?.fn, "submit_adjustment");
  assertEquals(calls[0]?.args.p_direction, "credit");
  for (const change of [{ direction: "up" }, { reason: "" }, { reason: undefined }]) {
    const response = await handler(request("POST", "/adjustments", { ...body, ...change }));
    assertEquals(response.status, 400, JSON.stringify(change));
  }
  assertEquals(calls.length, 1);
});

Deno.test("returned funds go to the withdrawal's route", async () => {
  const { handler, calls } = setup();
  const response = await handler(request("POST", `/withdrawals/${entryId}/returns`, {
    amount: "25000.00",
    seenAt: "2026-10-07T14:20:00Z",
    returnedBy: "Access Bank",
    bankReference: "RTN-26P8-XQ19",
    evidenceIds: [evidenceId],
    idempotencyKey: key,
  }));
  assertEquals(response.status, 200);
  assertEquals(calls[0]?.fn, "submit_returned_funds");
  assertEquals(calls[0]?.args.p_withdrawal_id, entryId);
  assertEquals(calls[0]?.args.p_bank_reference, "RTN-26P8-XQ19");
  await handler(request("GET", `/withdrawals/${entryId}/returnable`));
  assertEquals(calls[1]?.fn, "returnable_withdrawal");
});

Deno.test("entry reads take a closed kind", async () => {
  const { handler, calls } = setup();
  for (
    const path of [
      "/entries/targets",
      "/entries/targets?kind=returned_funds",
      "/entries/segments?kind=conversion",
      `/entries/segments?membershipId=${entryId}`,
    ]
  ) {
    assertEquals((await handler(request("GET", path))).status, 400, path);
  }
  assertEquals(calls.length, 0);
  await handler(request("GET", `/entries/segments?kind=adjustment&membershipId=${entryId}`));
  assertEquals(calls[0]?.fn, "entry_segments");
  assertEquals(calls[0]?.args.p_target_membership_id, entryId);
});

Deno.test("entry evidence upload signs only a database-built path of its kind", async () => {
  const good = `${tenantId}/conversion/${evidenceId}`;
  const { handler } = setup({
    create_entry_evidence_upload: {
      data: { evidenceId, objectPath: good, expiresAt: "2026-10-09T12:00:00Z" },
      error: null,
    },
  });
  const body = {
    kind: "conversion",
    targetMembershipId: entryId,
    idempotencyKey: key,
    fileName: "grey.png",
    mimeType: "image/png",
    size: 1000,
    sha256: "a".repeat(64),
  };
  const response = await handler(request("POST", "/entry-evidence/uploads", body));
  assertEquals(response.status, 200);
  assertEquals((await response.json()).data.uploadUrl, "https://storage.test/upload");
  assertEquals(
    (await handler(request("POST", "/entry-evidence/uploads", { ...body, kind: "income" }))).status,
    400,
  );

  const { handler: bad } = setup({
    create_entry_evidence_upload: {
      data: { evidenceId, objectPath: `${tenantId}/other/${evidenceId}`, expiresAt: "x" },
      error: null,
    },
  });
  assertEquals((await bad(request("POST", "/entry-evidence/uploads", body))).status, 500);
});

Deno.test("review decision routes payouts and entries by kind", async () => {
  const { handler, calls } = setup();
  const body = { decision: "clear", reason: "Statement matches", idempotencyKey: key };
  await handler(request("POST", `/reviews/${entryId}/decision`, body));
  await handler(request("POST", `/reviews/${entryId}/decision`, { ...body, kind: "adjustment" }));
  assertEquals(calls.map((c) => c.fn), ["review_payout", "review_entry"]);
  assertEquals(calls[1]?.args.p_entry_id, entryId);
  const bad = await handler(
    request("POST", `/reviews/${entryId}/decision`, { ...body, kind: "x" }),
  );
  assertEquals(bad.status, 400);
});

Deno.test("entry evidence download is signed for 60 seconds", async () => {
  const { handler, reads } = setup({
    entry_evidence: {
      data: { objectPath: `${tenantId}/adjustment/${evidenceId}`, name: "letter.pdf" },
      error: null,
    },
  });
  const response = await handler(request("GET", `/reviews/${entryId}/evidence/${evidenceId}`));
  assertEquals(response.status, 200);
  const data = (await response.json()).data;
  assertEquals(data.url, "https://storage.test/read");
  assertEquals(data.objectPath, undefined);
  assertEquals(reads[0]?.seconds, 60);
});

Deno.test("reversal needs a closed category and the typed reference", async () => {
  const { handler, calls } = setup();
  const body = {
    transactionId: entryId,
    category: "recorded_twice",
    note: "Same Fiverr order recorded twice",
    confirmReference: "INC-7F2K-0931",
    idempotencyKey: key,
  };
  assertEquals((await handler(request("POST", "/reversals", body))).status, 200);
  assertEquals(calls[0]?.fn, "reverse_transaction");
  assertEquals(calls[0]?.args.p_confirm_reference, "INC-7F2K-0931");
  for (const change of [{ category: "mistake" }, { confirmReference: undefined }]) {
    assertEquals(
      (await handler(request("POST", "/reversals", { ...body, ...change }))).status,
      400,
    );
  }
  assertEquals(
    (await handler(request("GET", "/reversals/preview?reference=inc7f2k0931"))).status,
    200,
  );
  assertEquals(calls[1]?.args.p_reference, "inc7f2k0931");
  assertEquals((await handler(request("GET", "/reversals/preview?reference=x'"))).status, 400);
});

Deno.test("the payout fix may keep its receipt", async () => {
  const { handler, calls } = setup();
  const body = { amount: "60000.00", paidOn: "2026-09-29", idempotencyKey: key };
  assertEquals((await handler(request("POST", `/payouts/${entryId}/correct`, body))).status, 200);
  assertEquals(calls[0]?.args.p_evidence_id, null);
  const recorded = await handler(request("POST", `/withdrawals/${entryId}/payouts`, body));
  assertEquals(recorded.status, 400);
});
