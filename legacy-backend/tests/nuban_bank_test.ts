import { DomainError } from "../src/shared/domain_error.ts";
import {
  parseNubanResolution,
  resolveNubanAccount,
} from "../src/integrations/nuban.ts";
import {
  parseBankConfirmation,
  parseBankResolution,
  resolveAuthorizedBank,
} from "../supabase/functions/_shared/bank-resolution.ts";
import type { CommandClient } from "../supabase/functions/_shared/command-client.ts";
function assert(condition: unknown): asserts condition {
  if (!condition) throw new Error("Assertion failed");
}
const row = {
  bank_code: "044",
  account_number: "0123456789",
  account_name: "RESOLVED PERSON",
  bank_name: "Test Bank",
};
const id = "10000000-0000-4000-8000-000000000001";
const membership = "20000000-0000-4000-8000-000000000001";
const input = {
  idempotencyKey: id,
  membershipId: membership,
  countryCode: "NG",
  payoutCurrency: "NGN",
  payoutRail: "bank_transfer",
  bankCode: "044",
  accountNumber: "0123456789",
};
Deno.test("NUBAN requires unique exact bank and account binding for every supported envelope", () => {
  for (const value of [[row], { data: [row] }, { results: [row] }]) {
    assert(
      parseNubanResolution(value, "044", "0123456789").accountHolderName ===
        "RESOLVED PERSON",
    );
  }
  for (
    const value of [
      [{ ...row, bank_code: "033" }],
      [{ ...row, account_number: "9999999999" }],
      [row, row],
      [],
      { verified: false, data: [row] },
      [{ ...row, account_name: "" }],
      [{ ...row, verified: false }],
    ]
  ) {
    try {
      parseNubanResolution(value, "044", "0123456789");
      throw new Error("accepted unsafe record");
    } catch (error) {
      assert(error instanceof DomainError);
    }
  }
});
Deno.test("NUBAN provider transport binds identifiers and redacts key, raw bodies and failures", async () => {
  let calls = 0;
  const fetcher: typeof fetch = (url, init) => {
    calls++;
    const request = new URL(String(url));
    assert(request.origin === "https://app.nuban.com.ng");
    assert(
      request.searchParams.get("bank_code") === "044" &&
        request.searchParams.get("acc_no") === "0123456789",
    );
    assert(init?.redirect === "error");
    return Promise.resolve(Response.json({ data: [row] }));
  };
  assert(
    (await resolveNubanAccount("fake-test-key", "044", "0123456789", fetcher))
      .institutionName === "Test Bank",
  );
  assert(calls === 1);
  for (
    const failure of [
      () => Promise.reject(new Error("fake-test-key private")),
      () =>
        Promise.resolve(new Response("secret-provider-body", { status: 500 })),
      () => Promise.resolve(new Response("x".repeat(262145))),
      () => Promise.resolve(new Response("not-json")),
    ]
  ) {
    try {
      await resolveNubanAccount("fake-test-key", "044", "0123456789", failure);
      throw new Error("accepted failure");
    } catch (error) {
      assert(error instanceof DomainError);
      assert(
        !JSON.stringify(error.toJSON()).includes("fake-test-key") &&
          !JSON.stringify(error.toJSON()).includes("secret-provider-body"),
      );
    }
  }
});
Deno.test("bank inputs reject forged verification, holdername, identity, unsupported rails and mixed selectors", () => {
  assert(parseBankResolution(input).p_bank_code === "044");
  assert(
    parseBankConfirmation({
      resolutionId: id,
      membershipId: membership,
      idempotencyKey: id,
      confirmed: true,
    }).p_confirmed,
  );
  for (
    const body of [
      { ...input, verified: true },
      { ...input, accountHolderName: "forged" },
      { ...input, actorUserId: id },
      { ...input, countryCode: "US" },
      { ...input, payoutRail: "bank" },
      { ...input, payoutAccountId: id },
      { ...input, accountNumber: "1234" },
    ]
  ) {
    try {
      parseBankResolution(body);
      throw new Error("accepted forged input");
    } catch (error) {
      assert(error instanceof DomainError);
    }
  }
});
Deno.test("denied bank intent never accesses provider and resolved replay never needs a secret", async () => {
  let providerCalls = 0;
  const denied: CommandClient = {
    schema: () => ({
      rpc: () => Promise.resolve({ data: null, error: { code: "42501" } }),
    }),
  };
  try {
    await resolveAuthorizedBank(
      denied,
      parseBankResolution(input),
      id,
      id,
      () => {
        providerCalls++;
        return "fake-test-key";
      },
    );
    throw new Error("accepted denied");
  } catch (error) {
    assert(error instanceof DomainError);
    assert(providerCalls === 0);
  }
  const stored = {
    resolutionId: id,
    bankCode: "044",
    accountNumber: "0123456789",
    accountReferenceMasked: "••••6789",
    expiresAt: "2026-10-03T00:00:00Z",
    resolved: true,
    confirmed: false,
    expired: false,
    payoutAccountId: null,
    accountHolderName: "RESOLVED PERSON",
    institutionName: "Test Bank",
  };
  const replay: CommandClient = {
    schema: () => ({
      rpc: () => Promise.resolve({ data: stored, error: null }),
    }),
  };
  const result = await resolveAuthorizedBank(
    replay,
    parseBankResolution(input),
    id,
    id,
    () => {
      providerCalls++;
      return "fake-test-key";
    },
  );
  assert(providerCalls === 0 && !JSON.stringify(result).includes("0123456789"));
});
