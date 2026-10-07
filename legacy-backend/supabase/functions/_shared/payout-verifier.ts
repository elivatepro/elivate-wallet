import type { CommandClient } from "./command-client.ts";
import { validIncomeFile } from "./income.ts";
import {
  extractReceiptWithOpenAI,
  type OpenAIReceiptConfig,
  type ReceiptExtractionOutcome,
  type ReceiptMime,
} from "./openai-receipts.ts";
import {
  comparePayoutReceipts,
  RECEIPT_COMPARISON_POLICY_VERSION,
} from "./payout-receipt-comparison.ts";

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const fileLimit = 10 * 1024 * 1024;
type File = {
  evidenceId: string;
  bucket: "financial-evidence";
  path: string;
  mimeType: ReceiptMime;
  fileSizeBytes: number;
  sha256Hex: string;
};
type Claim = {
  jobId: string;
  leaseToken: string;
  leaseExpiresAt: string;
  revisionId: string;
  verificationRequestId: string;
  facts: {
    beneficiaryPayoutAmount: string;
    payoutCurrency: string;
    paidAt: string;
  };
  destination: { accountReference: string; accountHolderName: string };
  files: File[];
};
export type PayoutVerifierRuntime = {
  client: CommandClient;
  supabaseUrl: string;
  storageKey: string;
  openai: OpenAIReceiptConfig;
};
export type PayoutVerifierDependencies = {
  secret: string | undefined;
  createRuntime: () => PayoutVerifierRuntime;
  fetch?: typeof fetch;
  extract?: (
    file: { bytes: Uint8Array; mimeType: ReceiptMime },
    config: OpenAIReceiptConfig,
    timeoutMs: number,
  ) => Promise<ReceiptExtractionOutcome>;
};
function object(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}
function claim(value: unknown): Claim {
  const result = object(value);
  const facts = object(result?.facts);
  const destination = object(result?.destination);
  if (
    !result || !facts || !destination ||
    ![result.jobId, result.leaseToken, result.revisionId].every((v) =>
      typeof v === "string" && uuid.test(v)
    ) || result.verificationRequestId !== result.jobId ||
    typeof result.leaseExpiresAt !== "string" ||
    !Number.isFinite(Date.parse(result.leaseExpiresAt)) ||
    typeof facts.beneficiaryPayoutAmount !== "string" ||
    typeof facts.payoutCurrency !== "string" ||
    typeof facts.paidAt !== "string" ||
    typeof destination.accountReference !== "string" ||
    typeof destination.accountHolderName !== "string" ||
    !Array.isArray(result.files) || result.files.length < 1 ||
    result.files.length > 20
  ) throw new Error("Invalid claim");
  const files = result.files.map((value): File => {
    const f = object(value);
    if (
      !f || typeof f.evidenceId !== "string" || !uuid.test(f.evidenceId) ||
      f.bucket !== "financial-evidence" || typeof f.path !== "string" ||
      !new RegExp(
        `^${uuid.source.slice(1, -1)}/payout/${uuid.source.slice(1, -1)}/${
          uuid.source.slice(1, -1)
        }$`,
      ).test(f.path) ||
      !["application/pdf", "image/png", "image/jpeg"].includes(
        String(f.mimeType),
      ) ||
      typeof f.fileSizeBytes !== "number" ||
      !Number.isInteger(f.fileSizeBytes) ||
      f.fileSizeBytes < 1 || f.fileSizeBytes > fileLimit ||
      typeof f.sha256Hex !== "string" || !/^[0-9a-f]{64}$/.test(f.sha256Hex)
    ) throw new Error("Invalid claim evidence");
    return f as File;
  });
  if (
    new Set(files.map((f) => f.evidenceId)).size !== files.length ||
    new Set(files.map((f) => f.path)).size !== files.length
  ) throw new Error("Duplicate evidence");
  return { ...result, facts, destination, files } as Claim;
}
function response(status: number, state: string): Response {
  return Response.json({ state }, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
}
// Fixed 32-byte comparison. Neither a user JWT nor an API key authenticates this worker.
function authenticated(
  expected: string | undefined,
  actual: string | null,
): boolean {
  if (
    !expected || !/^[0-9a-f]{64}$/.test(expected) || !actual ||
    !/^[0-9a-f]{64}$/.test(actual)
  ) return false;
  let difference = 0;
  for (let i = 0; i < 64; i += 2) {
    difference |= parseInt(expected.slice(i, i + 2), 16) ^
      parseInt(actual.slice(i, i + 2), 16);
  }
  return difference === 0;
}
async function emptyBody(request: Request): Promise<boolean> {
  if (!request.body) return false;
  const reader = request.body.getReader();
  let text = "";
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      if (value.length + text.length > 64) {
        await reader.cancel();
        return false;
      }
      text += new TextDecoder().decode(value);
    }
    const value = object(JSON.parse(text));
    return value !== null && Object.keys(value).length === 0;
  } catch {
    return false;
  } finally {
    reader.releaseLock();
  }
}
class EvidenceError extends Error {}
async function bounded<T>(
  promise: Promise<T>,
  milliseconds = 10_000,
): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_, reject) => {
        timer = setTimeout(
          () => reject(new Error("Transport timeout")),
          milliseconds,
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
async function download(
  file: File,
  runtime: PayoutVerifierRuntime,
  fetcher: typeof fetch,
  signal: AbortSignal,
): Promise<Uint8Array> {
  const origin = new URL(runtime.supabaseUrl);
  if (
    origin.protocol !== "https:" || origin.username || origin.password ||
    origin.search || origin.hash || !/^\/[\/]?$/.test(origin.pathname)
  ) throw new Error("Invalid storage configuration");
  const url = new URL(
    `/storage/v1/object/financial-evidence/${file.path}`,
    origin,
  );
  const result = await fetcher(url, {
    method: "GET",
    redirect: "error",
    signal,
    headers: {
      apikey: runtime.storageKey,
      Authorization: `Bearer ${runtime.storageKey}`,
    },
  });
  if (!result.ok) {
    await result.body?.cancel();
    throw new Error("Storage unavailable");
  }
  const mime = result.headers.get("content-type")?.split(";", 1)[0]?.trim();
  const length = result.headers.get("content-length");
  if (
    mime !== file.mimeType ||
    (length !== null &&
      (!/^\d+$/.test(length) || Number(length) !== file.fileSizeBytes)) ||
    !result.body
  ) {
    await result.body?.cancel();
    throw new EvidenceError("Invalid evidence");
  }
  const bytes = new Uint8Array(file.fileSizeBytes);
  const reader = result.body.getReader();
  let offset = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      if (offset + value.length > bytes.length || signal.aborted) {
        await reader.cancel();
        throw new EvidenceError("Invalid evidence");
      }
      bytes.set(value, offset);
      offset += value.length;
    }
  } finally {
    reader.releaseLock();
  }
  if (
    offset !== bytes.length || !validIncomeFile(bytes.buffer, file.mimeType)
  ) throw new EvidenceError("Invalid evidence");
  const digest = Array.from(
    new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)),
  ).map((v) => v.toString(16).padStart(2, "0")).join("");
  if (digest !== file.sha256Hex) throw new EvidenceError("Invalid evidence");
  return bytes;
}
/** One exact claim per invocation; no user commands, logging or financial data in responses. */
export async function handlePayoutVerifier(
  request: Request,
  dependencies: PayoutVerifierDependencies,
): Promise<Response> {
  if (
    !authenticated(
      dependencies.secret,
      request.headers.get("x-payout-verifier-secret"),
    )
  ) return response(401, "unauthorized");
  if (request.method !== "POST") return response(405, "method_not_allowed");
  if (!await emptyBody(request)) return response(400, "invalid_request");
  let runtime: PayoutVerifierRuntime;
  try {
    runtime = dependencies.createRuntime();
  } catch {
    return response(503, "unavailable");
  }
  const startedAt = Date.now();
  const workerId = crypto.randomUUID();
  const commands = runtime.client.schema("command_api");
  const rpc = (name: string, args: Readonly<Record<string, unknown>>) =>
    bounded(commands.rpc(name, args));
  let job: Claim;
  try {
    const result = await rpc("claim_payout_verification", {
      p_worker_id: workerId,
    });
    if (result.error) return response(503, "unavailable");
    if (result.data === null) return response(200, "idle");
    job = claim(result.data);
  } catch {
    return response(503, "unavailable");
  }
  const selectors = {
    p_job_id: job.jobId,
    p_worker_id: workerId,
    p_lease_token: job.leaseToken,
    p_revision_id: job.revisionId,
  };
  const controller = new AbortController();
  const deadline = Math.min(
    startedAt + 80_000,
    Date.parse(job.leaseExpiresAt) - 10_000,
  );
  const remaining = () => deadline - Date.now();
  const timer = setTimeout(() => controller.abort(), Math.max(0, remaining()));
  const cancelled = new Promise<never>((_, reject) =>
    controller.signal.addEventListener(
      "abort",
      () => reject(new Error("Work deadline")),
      { once: true },
    )
  );
  // Pre-work validation may return before the cancellation promise joins a race.
  void cancelled.catch(() => undefined);
  const fail = async (code: string): Promise<Response> => {
    try {
      await rpc("fail_payout_verification", {
        ...selectors,
        p_error_code: code,
      });
    } catch { /* The durable lease recovers an unknown failure response. */ }
    return response(202, "retry_pending");
  };
  let finishStarted = false;
  try {
    if (remaining() <= 0) return await fail("timeout");
    const expected = {
      amount: job.facts.beneficiaryPayoutAmount,
      currency: job.facts.payoutCurrency,
      recipientAccount: job.destination.accountReference,
      recipientName: job.destination.accountHolderName,
      paidAt: job.facts.paidAt,
    };
    if (
      comparePayoutReceipts(expected, []).reasons.includes("invalid_expected")
    ) return await fail("internal_error");
    const work = async () => {
      let single: Uint8Array | null = null;
      for (const file of job.files) {
        const bytes = await download(
          file,
          runtime,
          dependencies.fetch ?? fetch,
          controller.signal,
        );
        if (job.files.length === 1) single = bytes;
      }
      if (remaining() <= 0) throw new Error("Deadline");
      if (job.files.length > 1) {
        const comparison = comparePayoutReceipts(expected, []);
        return {
          ...comparison,
          reasons: ["ambiguous_evidence"],
          facts: [],
          extractionSkipped: "multiple_receipts",
        };
      }
      if (!single) throw new EvidenceError("No receipt");
      const timeout = Math.max(1, Math.min(30_000, remaining()));
      const file = { bytes: single, mimeType: job.files[0]!.mimeType };
      const extracted = dependencies.extract
        ? await dependencies.extract(file, runtime.openai, timeout)
        : await extractReceiptWithOpenAI(file, runtime.openai, {
          timeoutMs: timeout,
        });
      if (!extracted.ok) return { failure: extracted.code };
      return {
        ...comparePayoutReceipts(expected, [extracted.facts]),
        extractionSkipped: null,
      };
    };
    const comparison = await Promise.race([work(), cancelled]);
    if ("failure" in comparison) return await fail(comparison.failure);
    if (remaining() <= 0) return await fail("timeout");
    const args = {
      ...selectors,
      p_extracted_facts: {
        policyVersion: RECEIPT_COMPARISON_POLICY_VERSION,
        checks: comparison.checks,
        receiptFacts: comparison.facts,
        evidenceCount: job.files.length,
        extractionSkipped: comparison.extractionSkipped,
      },
      p_mismatch_reasons: comparison.reasons,
      p_verifier_name: "openai",
      p_verifier_version: runtime.openai.OPENAI_RECEIPT_MODEL,
    };
    // Once finish may have committed, never schedule a failure. Retry only the exact payload.
    finishStarted = true;
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const result = await Promise.race([
          rpc("finish_payout_verification", args),
          cancelled,
        ]);
        const value = object(result.data);
        if (
          !result.error && value?.jobId === job.jobId &&
          ["completed", "obsolete"].includes(String(value.status))
        ) return response(200, "processed");
      } catch { /* Replay the immutable finish once if time remains. */ }
      if (remaining() <= 0) break;
    }
    return response(202, "finish_unconfirmed");
  } catch (error) {
    if (finishStarted) return response(202, "finish_unconfirmed");
    return await fail(
      controller.signal.aborted
        ? "timeout"
        : error instanceof EvidenceError
        ? "evidence_invalid"
        : "network",
    );
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
}
