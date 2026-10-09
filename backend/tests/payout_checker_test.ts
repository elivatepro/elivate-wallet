import { assertEquals, assertRejects, assertThrows } from "@std/assert";
import {
  canonicalDecimal,
  compareReceipt,
  type Expected,
  offsetMinutes,
  paymentDate,
  type ReceiptFacts,
} from "../supabase/functions/payout-checker/compare.ts";
import {
  createOpenAiExtractor,
  ExtractionError,
  outputText,
  parseFacts,
  receiptSchema,
} from "../supabase/functions/payout-checker/extract.ts";
import {
  type CheckerLogEntry,
  createHandler,
  type Deps,
  type RpcResult,
} from "../supabase/functions/payout-checker/handler.ts";
import { sha256Hex } from "../supabase/functions/_shared/evidence.ts";

const facts: ReceiptFacts = {
  amount: "2450.00",
  currency: "NGN",
  recipientAccount: "0123456789",
  recipientName: "Ada  Obi ",
  institutionName: "GTBank",
  transactionDate: "2026-10-09",
  transactionTime: null,
  transactionTimezone: null,
  transactionReference: "TRX1",
  paymentStatus: "successful",
  confidence: "high",
  notes: null,
};
const expected: Expected = {
  amount: "2450.00",
  currency: "NGN",
  paidOn: "2026-10-09",
  recipientName: "ADA OBI",
  accountNumber: "0123456789",
};

Deno.test("an exact receipt matches", () => {
  assertEquals(compareReceipt(facts, expected), {
    outcome: "match",
    reasons: [],
    paymentDate: "2026-10-09",
  });
});

Deno.test("amounts compare exactly as decimals", () => {
  assertEquals(canonicalDecimal("002450.500"), "2450.5");
  assertEquals(canonicalDecimal("0.10"), "0.1");
  assertEquals(compareReceipt({ ...facts, amount: "2450" }, expected).outcome, "match");
  assertEquals(compareReceipt({ ...facts, amount: "2450.01" }, expected).reasons, [
    "amount_mismatch",
  ]);
  assertEquals(compareReceipt({ ...facts, amount: "2,450.00" }, expected).reasons, [
    "amount_invalid",
  ]);
  assertEquals(compareReceipt({ ...facts, amount: null }, expected).reasons, ["amount_missing"]);
});

Deno.test("account keeps leading zeros; masks never match", () => {
  assertEquals(
    compareReceipt({ ...facts, recipientAccount: "012 345-6789" }, expected).outcome,
    "match",
  );
  assertEquals(compareReceipt({ ...facts, recipientAccount: "123456789" }, expected).reasons, [
    "recipientAccount_mismatch",
  ]);
  assertEquals(compareReceipt({ ...facts, recipientAccount: "******6789" }, expected).reasons, [
    "recipientAccount_mismatch",
  ]);
  assertEquals(compareReceipt({ ...facts, recipientAccount: "acct 6789" }, expected).reasons, [
    "recipientAccount_invalid",
  ]);
});

Deno.test("name, currency, status and confidence give their reasons", () => {
  const r = compareReceipt(
    {
      ...facts,
      recipientName: "Ada Obiora",
      currency: "usd",
      paymentStatus: "pending",
      confidence: "medium",
    },
    expected,
  );
  assertEquals(r.reasons, [
    "currency_mismatch",
    "recipientName_mismatch",
    "payment_not_successful",
    "reading_confidence",
  ]);
  assertEquals(compareReceipt({ ...facts, currency: "₦" }, expected).reasons, ["currency_invalid"]);
  assertEquals(compareReceipt({ ...facts, recipientName: "  " }, expected).reasons, [
    "recipientName_missing",
  ]);
});

Deno.test("payment date: printed date, or its UTC date when a zone is printed", () => {
  assertEquals(paymentDate(facts), { date: "2026-10-09", reason: null });
  // Printed time zone without a time: the printed date stands.
  assertEquals(paymentDate({ ...facts, transactionTimezone: "WAT" }).date, "2026-10-09");
  // 00:30 WAT is 23:30 UTC the day before.
  assertEquals(
    paymentDate({ ...facts, transactionTime: "00:30", transactionTimezone: "WAT" }).date,
    "2026-10-08",
  );
  assertEquals(
    paymentDate({ ...facts, transactionTime: "23:30:00", transactionTimezone: "-02:00" }).date,
    "2026-10-10",
  );
  assertEquals(
    paymentDate({ ...facts, transactionTime: "12:00", transactionTimezone: "Mars" }).reason,
    "invalid",
  );
  assertEquals(paymentDate({ ...facts, transactionDate: "2026-02-30" }).reason, "invalid");
  assertEquals(paymentDate({ ...facts, transactionDate: null }).reason, "missing");
  assertEquals(offsetMinutes("GMT+01:00"), 60);
  assertEquals(offsetMinutes("+0530"), 330);
  assertEquals(offsetMinutes("+15"), null);
  assertEquals(compareReceipt({ ...facts, transactionDate: "2026-10-08" }, expected).reasons, [
    "paymentDate_mismatch",
  ]);
});

Deno.test("model output must match the strict schema", () => {
  const raw = { ...facts };
  assertEquals(parseFacts(raw), facts);
  assertThrows(() => parseFacts({ ...raw, extra: "x" }), ExtractionError);
  assertThrows(() => parseFacts({ ...raw, paymentStatus: "verified" }), ExtractionError);
  assertThrows(() => parseFacts({ ...raw, amount: 2450 }), ExtractionError);
  const { notes: _notes, ...missing } = raw;
  assertThrows(() => parseFacts(missing), ExtractionError);
  assertEquals(receiptSchema.required.length, 12);
});

Deno.test("output text is found; refusals are invalid", () => {
  assertEquals(
    outputText({
      output: [{ type: "reasoning" }, { content: [{ type: "output_text", text: "{}" }] }],
    }),
    "{}",
  );
  assertThrows(
    () => outputText({ output: [{ content: [{ type: "refusal", refusal: "no" }] }] }),
    ExtractionError,
  );
  assertThrows(() => outputText({}), ExtractionError);
});

Deno.test("the OpenAI request stores nothing and carries no expected values", async () => {
  let sent: Record<string, unknown> = {};
  const extractor = createOpenAiExtractor("sk-test", "gpt-5-mini", (_url, init) => {
    sent = JSON.parse(String(init?.body));
    return Promise.resolve(
      new Response(
        JSON.stringify({
          output: [{ content: [{ type: "output_text", text: JSON.stringify(facts) }] }],
        }),
      ),
    );
  });
  const read = await extractor.read(new TextEncoder().encode("%PDF-1.7"), "application/pdf");
  assertEquals(read, facts);
  assertEquals(sent.store, false);
  assertEquals(sent.model, "gpt-5-mini");
  assertEquals(JSON.stringify(sent).includes("ADA OBI"), false);
  const failing = createOpenAiExtractor(
    "k",
    "m",
    () => Promise.resolve(new Response("{}", { status: 500 })),
  );
  await assertRejects(
    () => failing.read(new Uint8Array([0xff, 0xd8, 0xff]), "image/jpeg"),
    ExtractionError,
  );
});

// ── Worker ──
const pdf = new TextEncoder().encode("%PDF-1.7 receipt");
const secret = "worker-secret";

async function claim(): Promise<unknown[]> {
  return [{
    checkId: "c1",
    leaseToken: "l1",
    attempt: 1,
    payoutId: "p1",
    revision: 1,
    expected: {
      amount: "2450.00",
      currency: "NGN",
      paidOn: "2026-10-09",
      recipientName: "ADA OBI",
      accountLast4: "6789",
      ownerUserId: "u1",
      accountCiphertext: "sealed",
      keyVersion: 1,
    },
    receipt: {
      objectPath: "t/payout/e",
      size: pdf.length,
      sha256: await sha256Hex(pdf),
      mimeType: "application/pdf",
    },
  }];
}

async function worker(read: () => Promise<ReceiptFacts>, bytes: Uint8Array | null = pdf) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const logs: CheckerLogEntry[] = [];
  const claimed = await claim();
  const deps: Deps = {
    rpc: (fn, args): Promise<RpcResult> => {
      calls.push({ fn, args });
      if (fn === "claim_payout_checks") return Promise.resolve({ data: claimed, error: null });
      return Promise.resolve({ data: { status: "completed" }, error: null });
    },
    workerSecret: secret,
    extractor: { model: "gpt-5-mini", read },
    download: () => Promise.resolve(bytes),
    openAccount: () => Promise.resolve("0123456789"),
    workerId: "test",
    log: (entry) => logs.push(entry),
  };
  return { handler: createHandler(deps), calls, logs };
}

const run = (s = secret) =>
  new Request("http://localhost/functions/v1/payout-checker", {
    method: "POST",
    headers: { authorization: `Bearer ${s}` },
  });

Deno.test("worker refuses a wrong secret", async () => {
  const { handler, calls } = await worker(() => Promise.resolve(facts));
  assertEquals((await handler(run("nope"))).status, 401);
  assertEquals(calls.length, 0);
});

Deno.test("worker finishes a match with the facts and policy", async () => {
  const { handler, calls, logs } = await worker(() => Promise.resolve(facts));
  const response = await handler(run());
  assertEquals(response.status, 200);
  const finish = calls.find((c) => c.fn === "finish_payout_check");
  assertEquals(finish?.args.p_outcome, "match");
  assertEquals(finish?.args.p_policy_version, "strict-single-receipt-v1");
  assertEquals((finish?.args.p_facts as Record<string, unknown>).paymentDate, "2026-10-09");
  assertEquals(JSON.stringify(logs).includes("0123456789"), false);
  assertEquals(JSON.stringify(logs).includes("ADA"), false);
});

Deno.test("changed bytes and provider errors are technical failures", async () => {
  const changed = await worker(
    () => Promise.resolve(facts),
    new TextEncoder().encode("%PDF-1.7 other!!"),
  );
  await changed.handler(run());
  assertEquals(
    changed.calls.find((c) => c.fn === "fail_payout_check")?.args.p_error,
    "receipt_changed",
  );
  assertEquals(changed.calls.some((c) => c.fn === "finish_payout_check"), false);

  const down = await worker(() => Promise.reject(new ExtractionError("provider_unavailable")));
  await down.handler(run());
  assertEquals(
    down.calls.find((c) => c.fn === "fail_payout_check")?.args.p_error,
    "provider_unavailable",
  );
});

Deno.test("worker without a reader claims nothing", async () => {
  const calls: string[] = [];
  const handler = createHandler({
    rpc: (fn) => {
      calls.push(fn);
      return Promise.resolve({ data: [], error: null });
    },
    workerSecret: secret,
    extractor: null,
    download: () => Promise.resolve(null),
    openAccount: () => Promise.resolve(""),
    workerId: "t",
    log: () => {},
  });
  const body = await (await handler(run())).json();
  assertEquals(body.data.configured, false);
  assertEquals(calls, []);
});
