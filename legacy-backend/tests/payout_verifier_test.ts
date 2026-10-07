import {
  handlePayoutVerifier,
  type PayoutVerifierDependencies,
} from "../supabase/functions/_shared/payout-verifier.ts";
import type { ReceiptExtraction } from "../supabase/functions/_shared/openai-receipts.ts";
function assert(value: unknown): asserts value {
  if (!value) throw new Error("Assertion failed");
}
const secret = "ab".repeat(32);
const id = (n: number) =>
  `99000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const bytes = new TextEncoder().encode("%PDF-fixture-only");
const facts: ReceiptExtraction = {
  amount: "95",
  currency: "NGN",
  recipientAccount: "0123456789",
  recipientName: "Fixture Member",
  institutionName: "Fixture Bank",
  transactionDateTime: "2026-10-03T12:00:00Z",
  transactionReference: "FIXTURE",
  paymentStatus: "successful",
  confidence: "high",
  notes: null,
  walletDebitAmount: "100",
  providerFeeAmount: "5",
};
function request(body = "{}", token: string | null = secret, method = "POST") {
  return new Request("https://worker.test", {
    method,
    ...(method === "POST" ? { body } : {}),
    headers: {
      ...(token ? { "x-payout-verifier-secret": token } : {}),
      authorization: "Bearer ordinary-user-jwt",
      apikey: "public-key",
    },
  });
}
async function fixture() {
  const sha = Array.from(
    new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)),
  ).map((v) => v.toString(16).padStart(2, "0")).join("");
  const job = {
    jobId: id(1),
    leaseToken: id(2),
    revisionId: id(3),
    verificationRequestId: id(1),
    leaseExpiresAt: new Date(Date.now() + 120000).toISOString(),
    facts: {
      beneficiaryPayoutAmount: "95.000000000000000000",
      payoutCurrency: "NGN",
      paidAt: "2026-10-03T11:00:00Z",
    },
    destination: {
      accountReference: "0123456789",
      accountHolderName: "Fixture Member",
    },
    files: [{
      evidenceId: id(4),
      bucket: "financial-evidence",
      path: `${id(5)}/payout/${id(6)}/${id(7)}`,
      mimeType: "application/pdf",
      fileSizeBytes: bytes.length,
      sha256Hex: sha,
    }],
  };
  const calls: { name: string; args: Readonly<Record<string, unknown>> }[] = [];
  let factories = 0, downloads = 0, extractions = 0;
  const dependencies: PayoutVerifierDependencies = {
    secret,
    createRuntime: () => {
      factories++;
      return {
        supabaseUrl: "https://fixture.supabase.co",
        storageKey: "server-secret",
        openai: {
          OPENAI_API_KEY: "synthetic-provider-key",
          OPENAI_RECEIPT_MODEL: "fixture-model",
        },
        client: {
          schema: (schema) => {
            assert(schema === "command_api");
            return {
              rpc(name, args) {
                // PostgREST methods require the schema client's receiver.
                assert(typeof this.rpc === "function");
                calls.push({ name, args });
                return Promise.resolve({
                  data: name === "claim_payout_verification"
                    ? job
                    : { jobId: job.jobId, status: "completed" },
                  error: null,
                });
              },
            };
          },
        },
      };
    },
    fetch: (input, options) => {
      downloads++;
      assert(
        String(input) ===
          `https://fixture.supabase.co/storage/v1/object/financial-evidence/${
            job.files[0]!.path
          }`,
      );
      assert(options?.redirect === "error" && options.method === "GET");
      const headers = new Headers(options.headers);
      assert(headers.get("Authorization") === "Bearer server-secret");
      return Promise.resolve(
        new Response(bytes, {
          headers: {
            "Content-Type": "application/pdf",
            "Content-Length": String(bytes.length),
          },
        }),
      );
    },
    extract: (file, config, timeout) => {
      extractions++;
      assert(
        file.bytes.length === bytes.length &&
          config.OPENAI_RECEIPT_MODEL === "fixture-model" && timeout <= 30000,
      );
      return Promise.resolve({ ok: true, facts });
    },
  };
  return {
    job,
    calls,
    dependencies,
    counters: () => ({ factories, downloads, extractions }),
  };
}
Deno.test("payout worker authenticates dedicated 32-byte secret before factory, RPC, storage or provider", async () => {
  const f = await fixture();
  for (const token of [null, "short", "cd".repeat(32), "ab".repeat(31)]) {
    assert(
      (await handlePayoutVerifier(request("{}", token), f.dependencies))
        .status === 401,
    );
  }
  assert(
    (await handlePayoutVerifier(request(), {
      ...f.dependencies,
      secret: undefined,
    })).status === 401,
  );
  assert(f.counters().factories === 0 && f.calls.length === 0);
});
Deno.test("payout worker accepts only POST empty object and rejects caller-selected financial or security fields", async () => {
  const f = await fixture();
  for (
    const body of [
      "[]",
      "null",
      "",
      "{",
      JSON.stringify({ jobId: id(1) }),
      JSON.stringify({ actorUserId: id(2) }),
      JSON.stringify({ path: "foreign" }),
      " ".repeat(65) + "{}",
    ]
  ) {
    assert(
      (await handlePayoutVerifier(request(body), f.dependencies)).status ===
        400,
    );
  }
  assert(
    (await handlePayoutVerifier(request("", secret, "GET"), f.dependencies))
      .status === 405,
  );
  assert(f.counters().factories === 0);
});
Deno.test("payout worker verifies bytes and submits exact claimed revision with strict facts, exposes no evidence", async () => {
  const f = await fixture();
  const response = await handlePayoutVerifier(request(), f.dependencies);
  assert(
    response.status === 200 &&
      response.headers.get("cache-control") === "no-store",
  );
  assert(await response.text() === '{"state":"processed"}');
  assert(
    f.calls.length === 2 && f.calls[1]!.name === "finish_payout_verification",
  );
  const first = f.calls[0]!.args, finish = f.calls[1]!.args;
  assert(
    finish.p_job_id === f.job.jobId &&
      finish.p_revision_id === f.job.revisionId &&
      finish.p_lease_token === f.job.leaseToken &&
      finish.p_worker_id === first.p_worker_id,
  );
  assert(JSON.stringify(finish.p_mismatch_reasons) === "[]");
  assert(f.counters().downloads === 1 && f.counters().extractions === 1);
});
Deno.test("payout worker rejects forged paths and verification request identities before download", async () => {
  for (const change of ["path", "request"]) {
    const f = await fixture();
    if (change === "path") {
      f.job.files[0]!.path = "https://attacker.test/private";
    } else f.job.verificationRequestId = id(99);
    assert(
      (await handlePayoutVerifier(request(), f.dependencies)).status === 503,
    );
    assert(
      f.counters().downloads === 0 && f.counters().extractions === 0 &&
        f.calls.length === 1,
    );
  }
});
Deno.test("payout worker tampered MIME, size, hash and streaming overflow retry without extraction or completion", async () => {
  for (const defect of ["mime", "size", "hash", "overflow", "magic"]) {
    const f = await fixture();
    if (defect === "hash") f.job.files[0]!.sha256Hex = "00".repeat(32);
    else {f.dependencies.fetch = () =>
        Promise.resolve(
          new Response(
            defect === "magic"
              ? new Uint8Array(bytes.length)
              : defect === "overflow"
              ? new Uint8Array(bytes.length + 1)
              : bytes,
            {
              headers: {
                "content-type": defect === "mime"
                  ? "image/png"
                  : "application/pdf",
                ...(defect === "size" ? { "content-length": "100" } : {}),
              },
            },
          ),
        );}
    assert(
      (await handlePayoutVerifier(request(), f.dependencies)).status === 202,
    );
    assert(
      f.calls[1]!.name === "fail_payout_verification" &&
        f.calls[1]!.args.p_error_code === "evidence_invalid",
    );
    assert(
      f.counters().extractions === 0 &&
        !f.calls.some((c) => c.name === "finish_payout_verification"),
    );
  }
});
Deno.test("payout worker technical provider failures retry rather than record financial mismatches", async () => {
  const f = await fixture();
  f.dependencies.extract = () =>
    Promise.resolve({ ok: false, code: "rate_limited" });
  assert(
    (await handlePayoutVerifier(request(), f.dependencies)).status === 202,
  );
  assert(
    f.calls[1]!.name === "fail_payout_verification" &&
      f.calls[1]!.args.p_error_code === "rate_limited",
  );
});
Deno.test("payout worker single-receipt mismatch reaches canonical finish and never retry-fails", async () => {
  const f = await fixture();
  f.dependencies.extract = () =>
    Promise.resolve({ ok: true, facts: { ...facts, amount: "94" } });
  assert(
    (await handlePayoutVerifier(request(), f.dependencies)).status === 200,
  );
  assert(
    JSON.stringify(f.calls[1]!.args.p_mismatch_reasons) ===
      '["amount_mismatch"]',
  );
  assert(f.calls.every((c) => c.name !== "fail_payout_verification"));
});
Deno.test("payout worker multiple verified receipts conservatively records ambiguity without extracting any", async () => {
  const f = await fixture();
  f.job.files.push({
    ...f.job.files[0]!,
    evidenceId: id(8),
    path: `${id(5)}/payout/${id(6)}/${id(9)}`,
  });
  f.dependencies.fetch = () =>
    Promise.resolve(
      new Response(bytes, { headers: { "content-type": "application/pdf" } }),
    );
  assert(
    (await handlePayoutVerifier(request(), f.dependencies)).status === 200,
  );
  const finish = f.calls[1]!.args;
  assert(
    JSON.stringify(finish.p_mismatch_reasons) === '["ambiguous_evidence"]',
  );
  const payload = finish.p_extracted_facts as Record<string, unknown>;
  assert(
    payload.evidenceCount === 2 &&
      payload.extractionSkipped === "multiple_receipts" &&
      JSON.stringify(payload.receiptFacts) === "[]",
  );
  assert(f.counters().extractions === 0);
});
Deno.test("payout worker uncertain finish retries identical payload then never marks consumed claim failed", async () => {
  for (const recovered of [true, false]) {
    const f = await fixture();
    const original = f.dependencies.createRuntime;
    f.dependencies.createRuntime = () => {
      const runtime = original();
      const commands = runtime.client.schema("command_api");
      let attempts = 0;
      return {
        ...runtime,
        client: {
          schema: () => ({
            rpc: async (name, args) => {
              const result = await commands.rpc(name, args);
              if (
                name === "finish_payout_verification" &&
                (++attempts === 1 || !recovered)
              ) throw new Error("lost response with sensitive details");
              return result;
            },
          }),
        },
      };
    };
    const response = await handlePayoutVerifier(request(), f.dependencies);
    assert(response.status === (recovered ? 200 : 202));
    assert(
      f.calls.length === 3 &&
        JSON.stringify(f.calls[1]!.args) === JSON.stringify(f.calls[2]!.args),
    );
    assert(!f.calls.some((c) => c.name === "fail_payout_verification"));
    assert(!(await response.text()).includes("sensitive"));
  }
});
Deno.test("payout worker expired work budget never downloads or finishes", async () => {
  const f = await fixture();
  f.job.leaseExpiresAt = new Date(Date.now() - 1000).toISOString();
  assert(
    (await handlePayoutVerifier(request(), f.dependencies)).status === 202,
  );
  assert(
    f.calls[1]!.args.p_error_code === "timeout" && f.counters().downloads === 0,
  );
});
Deno.test("payout worker corrupt frozen expected facts retry technically and cannot consume a correction", async () => {
  for (const defect of ["amount", "currency", "paidAt", "account", "name"]) {
    const f = await fixture();
    if (defect === "amount") f.job.facts.beneficiaryPayoutAmount = "1e2";
    if (defect === "currency") f.job.facts.payoutCurrency = "bad";
    if (defect === "paidAt") f.job.facts.paidAt = "2026-02-30T12:00:00Z";
    if (defect === "account") f.job.destination.accountReference = "****6789";
    if (defect === "name") f.job.destination.accountHolderName = "  ";
    assert(
      (await handlePayoutVerifier(request(), f.dependencies)).status === 202,
    );
    assert(
      f.calls[1]!.name === "fail_payout_verification" &&
        f.calls[1]!.args.p_error_code === "internal_error",
    );
    assert(f.counters().downloads === 0 && f.counters().extractions === 0);
  }
});
