import { recordVerifiedIncome } from "../supabase/functions/_shared/record-income.ts";
import { sha256Hex } from "../supabase/functions/_shared/financial.ts";
import {
  parseIncomeSubmit,
  parseIncomeUpload,
  validIncomeFile,
} from "../supabase/functions/_shared/income.ts";
function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
const valid = {
  idempotencyKey: "91000000-0000-4000-8000-000000000001",
  targetMembershipId: "31000000-0000-4000-8000-000000000001",
  currencyCode: "NGN",
  grossAmount: "9007199254740993.01",
  originalFilename: "receipt.pdf",
  mimeType: "application/pdf",
  fileSizeBytes: 5,
  sha256Hex: "a".repeat(64),
  observedAt: "2026-10-01T00:00:00.000Z",
  providerReference: "REF",
};
Deno.test("income transport preserves exact decimal and permits only intent selectors", () => {
  assert(parseIncomeUpload(valid).p_gross_amount === valid.grossAmount);
  assert(
    parseIncomeSubmit({ uploadIntentId: valid.idempotencyKey }) ===
      valid.idempotencyKey,
  );
});
Deno.test("income rejects client security context and unverified storage fields", () => {
  for (
    const extra of [
      "actorUserId",
      "sessionId",
      "tenantId",
      "officeId",
      "role",
      "storagePath",
      "evidenceItems",
    ]
  ) {
    let denied = false;
    try {
      parseIncomeUpload({ ...valid, [extra]: "malicious" });
    } catch {
      denied = true;
    }
    assert(denied, extra);
  }
  let denied = false;
  try {
    parseIncomeSubmit({
      uploadIntentId: valid.idempotencyKey,
      verifiedSha256Hex: valid.sha256Hex,
    });
  } catch {
    denied = true;
  }
  assert(denied);
});
Deno.test("income boundary rejects unsafe amount, date and receipt sizes", () => {
  for (
    const bad of [
      { grossAmount: 100 },
      { grossAmount: "0" },
      { grossAmount: "1e5" },
      { grossAmount: "0.0000000000000000001" },
      { grossAmount: "100000000000000000000" },
      { fileSizeBytes: 10485761 },
      { fileSizeBytes: 0 },
      { observedAt: "2026-02-30T00:00:00.000Z" },
      { mimeType: "text/html" },
    ]
  ) {
    let denied = false;
    try {
      parseIncomeUpload({ ...valid, ...bad });
    } catch {
      denied = true;
    }
    assert(denied, JSON.stringify(bad));
  }
});
Deno.test("receipt type is checked against downloaded bytes", () => {
  const pdf = new TextEncoder().encode("%PDF-1.7").buffer;
  assert(validIncomeFile(pdf, "application/pdf"));
  assert(!validIncomeFile(pdf, "image/png"));
  assert(
    validIncomeFile(
      new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]).buffer,
      "image/png",
    ),
  );
  assert(validIncomeFile(new Uint8Array([255, 216, 255]).buffer, "image/jpeg"));
  assert(
    !validIncomeFile(
      new TextEncoder().encode("<html>").buffer,
      "application/pdf",
    ),
  );
});

Deno.test("denied income intent never accesses privileged Storage", async () => {
  let downloads = 0;
  let denied = false;
  try {
    await recordVerifiedIncome(
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
      valid.idempotencyKey,
      "actor",
      null,
    );
  } catch {
    denied = true;
  }
  assert(denied);
  assert(downloads === 0);
});
Deno.test("posted income retry recovers receipt without downloading or posting again", async () => {
  let calls = 0;
  const result = await recordVerifiedIncome(
    {
      schema: () => ({
        rpc: () => {
          calls++;
          return Promise.resolve({
            data: {
              posted: true,
              operation_id: valid.idempotencyKey,
              operation_reference: "INC-A1",
            },
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
    valid.idempotencyKey,
    "actor",
    null,
  );
  assert(calls === 1);
  assert((result as { reused: boolean }).reused);
});
Deno.test("income hashes only authorized downloaded bytes before posting", async () => {
  const file = new Blob(["%PDF-1.7"]);
  const calls: Record<string, unknown>[] = [];
  const result = await recordVerifiedIncome(
    {
      schema: () => ({
        rpc: (name, args) => {
          calls.push({ ...args, name });
          return Promise.resolve(
            name === "income_upload_object"
              ? {
                data: {
                  posted: false,
                  bucket: "financial-evidence",
                  path: "server/path",
                  file_size_bytes: file.size,
                  mime_type: "application/pdf",
                },
                error: null,
              }
              : { data: { operation_reference: "INC-A1" }, error: null },
          );
        },
      }),
    },
    {
      from: (bucket) => ({
        download: (path) => {
          assert(bucket === "financial-evidence" && path === "server/path");
          return Promise.resolve({ data: file, error: null });
        },
      }),
    },
    valid.idempotencyKey,
    "verified-actor",
    null,
  );
  assert(calls.length === 2);
  assert(
    calls[1]?.p_verified_sha256_hex ===
      await sha256Hex(await file.arrayBuffer()),
  );
  assert(calls[1]?.p_actor_user_id === "verified-actor");
  assert(
    (result as { operation_reference: string }).operation_reference ===
      "INC-A1",
  );
});
Deno.test("mismatched receipt bytes never invoke financial posting", async () => {
  let calls = 0;
  let denied = false;
  try {
    await recordVerifiedIncome(
      {
        schema: () => ({
          rpc: () => {
            calls++;
            return Promise.resolve({
              data: {
                posted: false,
                bucket: "financial-evidence",
                path: "server/path",
                file_size_bytes: 6,
                mime_type: "application/pdf",
              },
              error: null,
            });
          },
        }),
      },
      {
        from: () => ({
          download: () =>
            Promise.resolve({ data: new Blob(["<html>"]), error: null }),
        }),
      },
      valid.idempotencyKey,
      "actor",
      null,
    );
  } catch {
    denied = true;
  }
  assert(denied && calls === 1);
});
