import { DomainError } from "../src/shared/domain_error.ts";
import {
  finalizeVerifiedPayout,
  parsePayoutDownload,
  parsePayoutFinalize,
  parsePayoutUpload,
  payoutStage,
} from "../supabase/functions/_shared/payout-evidence.ts";
import { sha256Hex } from "../supabase/functions/_shared/financial.ts";
import type { CommandClient } from "../supabase/functions/_shared/command-client.ts";
function assert(value: unknown): asserts value {
  if (!value) throw new Error("Assertion failed");
}
function denies(action: () => unknown) {
  let rejected = false;
  try {
    action();
  } catch {
    rejected = true;
  }
  assert(rejected);
}
const id = "96000000-0000-4000-8000-000000000001";
const fileId = "96000000-0000-4000-8000-000000000002";
const valid = {
  idempotencyKey: id,
  withdrawalId: "92000000-0000-4000-8000-000000000007",
  operation: "submit",
  facts: {
    walletDebitAmount: "9007199254740993.01",
    beneficiaryPayoutAmount: "9007199254740992.01",
    payoutCurrency: "NGN",
    provider: "manual",
    paidAt: "2026-10-03T00:00:00.000Z",
    providerFeeAmount: "1",
  },
  files: [{
    originalFilename: "receipt.pdf",
    mimeType: "application/pdf",
    fileSizeBytes: 8,
    sha256Hex: "a".repeat(64),
  }],
};
Deno.test("payout upload preserves exact decimals and validates correction selector", () => {
  assert(
    parsePayoutUpload(valid).p_facts.walletDebitAmount ===
      valid.facts.walletDebitAmount,
  );
  denies(() => parsePayoutUpload({ ...valid, operation: "correct" }));
  assert(
    parsePayoutUpload({
      ...valid,
      operation: "correct",
      payoutAssertionId: fileId,
    }).p_payout_assertion_id === fileId,
  );
  denies(() => parsePayoutUpload({ ...valid, payoutAssertionId: fileId }));
});
Deno.test("payout transport rejects client authority, remote paths and raw evidence metadata", () => {
  for (
    const field of [
      "tenantId",
      "actorUserId",
      "sessionId",
      "role",
      "storagePath",
      "evidenceItems",
    ]
  ) denies(() => parsePayoutUpload({ ...valid, [field]: "forged" }));
  for (const field of ["bucket", "path", "url", "verifiedSha256Hex"]) {
    denies(() =>
      parsePayoutUpload({
        ...valid,
        files: [{ ...valid.files[0], [field]: "forged" }],
      })
    );
  }
  denies(() => parsePayoutFinalize({ ...valid, stageId: id }));
  denies(() => parsePayoutFinalize({ stageId: id, idempotencyKey: fileId }));
  assert(parsePayoutFinalize({ stageId: id, idempotencyKey: id }) === id);
  denies(() =>
    parsePayoutDownload({
      membershipId: id,
      evidenceId: fileId,
      path: "forged",
    })
  );
});
Deno.test("payout receipt count, money scale, dates, mime and file size remain bounded", () => {
  for (
    const files of [[], Array(21).fill(valid.files[0]), [{
      ...valid.files[0],
      fileSizeBytes: 10485761,
    }], [{ ...valid.files[0], mimeType: "text/html" }]]
  ) denies(() => parsePayoutUpload({ ...valid, files }));
  for (
    const facts of [
      { ...valid.facts, walletDebitAmount: 2 },
      { ...valid.facts, providerFeeAmount: "-1" },
      { ...valid.facts, paidAt: "2026-02-30T00:00:00.000Z" },
      { ...valid.facts, walletDebitAmount: "1.0000000000000000001" },
    ]
  ) denies(() => parsePayoutUpload({ ...valid, facts }));
});
const path = `10000000-0000-4000-8000-000000000001/payout/${id}/${fileId}`;
function fixture(hash: string, finalized = false) {
  return {
    stageId: id,
    expiresAt: "2026-10-03T02:00:00.000Z",
    operation: "submit",
    finalized,
    expired: false,
    files: [{
      fileId,
      bucket: "financial-evidence",
      path,
      originalFilename: "receipt.pdf",
      mimeType: "application/pdf",
      fileSizeBytes: 8,
      sha256Hex: hash,
    }],
  };
}
Deno.test("denied stage never reaches privileged Storage", async () => {
  let downloads = 0;
  let rejected = false;
  try {
    await finalizeVerifiedPayout(
      {
        schema: () => ({
          rpc: () => Promise.resolve({ data: null, error: { code: "42501" } }),
        }),
      },
      {
        from: () => ({
          download: () => {
            downloads++;
            return Promise.resolve({ data: null, error: null });
          },
        }),
      },
      id,
      "actor",
      null,
    );
  } catch {
    rejected = true;
  }
  assert(rejected && downloads === 0);
});
Deno.test("finalized retry skips Storage but invokes current canonical authorization", async () => {
  const calls: string[] = [];
  const client: CommandClient = {
    schema: () => ({
      rpc: (name) => {
        calls.push(name);
        return Promise.resolve({
          data: name === "payout_upload_objects"
            ? fixture("a".repeat(64), true)
            : { reused: true },
          error: null,
        });
      },
    }),
  };
  const result = await finalizeVerifiedPayout(
    client,
    {
      from: () => ({
        download: () => {
          throw new Error("No download expected");
        },
      }),
    },
    id,
    "actor",
    null,
  );
  assert(calls.join(",") === "payout_upload_objects,finalize_payout_evidence");
  assert((result as { reused: boolean }).reused);
});
Deno.test("actual receipt bytes and server-selected objects are verified before submission", async () => {
  const file = new Blob(["%PDF-1.7"], { type: "application/pdf" });
  const hash = await sha256Hex(await file.arrayBuffer());
  const calls: Record<string, unknown>[] = [];
  const client: CommandClient = {
    schema: () => ({
      rpc: (name, args) => {
        calls.push({ name, ...args });
        return Promise.resolve({
          data: name === "payout_upload_objects"
            ? fixture(hash)
            : { reused: false },
          error: null,
        });
      },
    }),
  };
  await finalizeVerifiedPayout(
    client,
    {
      from: (bucket) => ({
        download: (actualPath) => {
          assert(bucket === "financial-evidence" && actualPath === path);
          return Promise.resolve({ data: file, error: null });
        },
      }),
    },
    id,
    "verified-actor",
    "verified-session",
  );
  const verified = calls[1]?.p_verified_files as Record<string, unknown>[];
  assert(verified[0]?.sha256Hex === hash);
  assert(calls[1]?.p_actor_user_id === "verified-actor");
  assert(calls[1]?.p_session_id === "verified-session");
});
Deno.test("missing file, wrong size, forged signature, MIME and changed hash never invoke financial command", async () => {
  for (
    const file of [
      null,
      new Blob(["%PDF-1.7extra"], { type: "application/pdf" }),
      new Blob(["<html>XX"], { type: "application/pdf" }),
      new Blob(["%PDF-1.7"], { type: "image/png" }),
      new Blob(["%PDF-1.7"], { type: "application/pdf" }),
    ]
  ) {
    let calls = 0;
    let rejected = false;
    try {
      await finalizeVerifiedPayout(
        {
          schema: () => ({
            rpc: () => {
              calls++;
              return Promise.resolve({
                data: fixture("a".repeat(64)),
                error: null,
              });
            },
          }),
        },
        {
          from: () => ({
            download: () => Promise.resolve({ data: file, error: null }),
          }),
        },
        id,
        "actor",
        null,
      );
    } catch {
      rejected = true;
    }
    assert(rejected && calls === 1);
  }
});
Deno.test("legacy submit and correct endpoints cannot use each other's staged operation", async () => {
  let calls = 0;
  let rejected = false;
  try {
    await finalizeVerifiedPayout(
      {
        schema: () => ({
          rpc: () => {
            calls++;
            return Promise.resolve({
              data: fixture("a".repeat(64), true),
              error: null,
            });
          },
        }),
      },
      {
        from: () => ({
          download: () => {
            throw new Error("No download expected");
          },
        }),
      },
      id,
      "actor",
      null,
      "correct",
    );
  } catch {
    rejected = true;
  }
  assert(rejected && calls === 1);
});

Deno.test("expired stage is terminal without uploads; finalized replay is never expired", () => {
  const expired = { ...fixture("a".repeat(64)), expired: true, files: [] };
  assert(payoutStage(expired).expired);
  denies(() => payoutStage({ ...expired, finalized: true }));
  denies(() =>
    payoutStage({ ...expired, files: fixture("a".repeat(64)).files })
  );
  denies(() => payoutStage({ ...expired, expired: false }));
  assert(!payoutStage(fixture("a".repeat(64), true)).expired);
});

Deno.test("terminal expired stage is never finalized even if returned by lookup", async () => {
  let calls = 0;
  let rejected = false;
  try {
    await finalizeVerifiedPayout(
      {
        schema: () => ({
          rpc: () => {
            calls++;
            return Promise.resolve({
              data: { ...fixture("a".repeat(64)), expired: true, files: [] },
              error: null,
            });
          },
        }),
      },
      {
        from: () => ({
          download: () => {
            throw new Error("No storage access");
          },
        }),
      },
      id,
      "actor",
      null,
    );
  } catch {
    rejected = true;
  }
  assert(rejected && calls === 1);
});

Deno.test("receipt step-up challenge remains actionable before Storage or finalization", async () => {
  const calls: string[] = [];
  let storageCalls = 0;
  let caught: unknown;
  try {
    await finalizeVerifiedPayout(
      {
        schema: () => ({
          rpc: (name) => {
            calls.push(name);
            return Promise.resolve({ data: null, error: { code: "P0401" } });
          },
        }),
      },
      {
        from: () => {
          storageCalls++;
          return {
            download: () => Promise.resolve({ data: null, error: null }),
          };
        },
      },
      id,
      "verified-actor",
      null,
    );
  } catch (error) {
    caught = error;
  }
  assert(caught instanceof DomainError && caught.code === "step_up_required");
  assert(storageCalls === 0);
  assert(calls.length === 1 && calls[0] === "payout_upload_objects");
});
