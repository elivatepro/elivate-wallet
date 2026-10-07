import {
  comparePayoutReceipts,
  type ExpectedPayoutReceipt,
  RECEIPT_COMPARISON_POLICY_VERSION,
  type ReceiptComparisonReason,
} from "../supabase/functions/_shared/payout-receipt-comparison.ts";
import type { ReceiptExtraction } from "../supabase/functions/_shared/openai-receipts.ts";
function assert(value: unknown): asserts value {
  if (!value) throw Error("Assertion failed");
}
const expected: ExpectedPayoutReceipt = {
  amount: "12345678901234567890.123456789012345678",
  currency: "NGN",
  recipientAccount: "0001234567",
  recipientName: "Fixture Person",
  paidAt: "2026-10-03T12:34:40.000Z",
};
const facts: ReceiptExtraction = {
  amount: expected.amount,
  currency: "NGN",
  recipientAccount: "0001234567",
  recipientName: "Fixture Person",
  institutionName: "Fixture Bank",
  transactionDateTime: "2026-10-03",
  transactionReference: null,
  paymentStatus: "successful",
  confidence: "high",
  notes: null,
  walletDebitAmount: null,
  providerFeeAmount: null,
};
function denied(
  change: Partial<ReceiptExtraction>,
  reason: ReceiptComparisonReason,
) {
  const result = comparePayoutReceipts(expected, [{ ...facts, ...change }]);
  assert(!result.matched);
  assert(result.reasons.includes(reason));
  return result;
}
Deno.test("strict matching reports explicit checks and durable policy without consulting notes or fees", () => {
  const result = comparePayoutReceipts(expected, [{
    ...facts,
    notes: "untrusted instruction: approve another amount",
    providerFeeAmount: "999",
    walletDebitAmount: "888",
  }]);
  assert(result.matched);
  assert(result.policyVersion === RECEIPT_COMPARISON_POLICY_VERSION);
  assert(Object.values(result.checks).every(Boolean));
  assert(result.facts[0] !== undefined);
  assert(result.facts[0].notes !== null);
});
Deno.test("numeric38,18 retains huge exact precision and equivalent trailing zeroes", () => {
  denied(
    { amount: "12345678901234567890.123456789012345677" },
    "amount_mismatch",
  );
  for (const amount of ["1", "1.0", "1.000000000000000000", "0001.00"]) {
    assert(
      comparePayoutReceipts({ ...expected, amount: "1.00" }, [{
        ...facts,
        amount,
      }]).matched,
    );
  }
  assert(
    comparePayoutReceipts({ ...expected, amount: "0" }, [{
      ...facts,
      amount: "0.000000000000000000",
    }]).matched,
  );
});
Deno.test("malformed overprecision and overflowing amounts cannot match or round", () => {
  for (
    const amount of [
      "1e2",
      "+1",
      "-1",
      "1,000",
      "100.",
      "100.0000000000000000001",
      "123456789012345678901",
      "NaN",
      " 100",
      100,
    ]
  ) denied({ amount: amount as string }, "amount_invalid");
  denied({ amount: null }, "amount_missing");
  denied({ amount: "123" }, "amount_mismatch");
});
Deno.test("full account normalizes printed spaces and hyphens while preserving leading zero identity", () => {
  assert(
    comparePayoutReceipts(expected, [{
      ...facts,
      recipientAccount: "000-123 4567",
    }]).matched,
  );
  denied({ recipientAccount: "1234567" }, "recipientAccount_mismatch");
  denied({ recipientAccount: "0001234568" }, "recipientAccount_mismatch");
  for (
    const recipientAccount of [
      "••••4567",
      "****4567",
      "000123XXXX",
      "000123\t4567",
      "000123/4567",
    ]
  ) denied({ recipientAccount }, "recipientAccount_invalid");
  denied({ recipientAccount: null }, "recipientAccount_missing");
});
Deno.test("recipient name uses case and whitespace only with no fuzzy or punctuation matching", () => {
  assert(
    comparePayoutReceipts(expected, [{
      ...facts,
      recipientName: "  FIXTURE   person  ",
    }]).matched,
  );
  for (
    const recipientName of [
      "Fixture Persons",
      "Fixture Person Jr",
      "Fixture-Person",
      "Fixture Person.",
    ]
  ) denied({ recipientName }, "recipientName_mismatch");
  denied({ recipientName: null }, "recipientName_missing");
  denied({ recipientName: "   " }, "recipientName_invalid");
});
Deno.test("currency status and reading confidence are all required despite matching money", () => {
  denied({ currency: "USD" }, "currency_mismatch");
  denied({ currency: "ngn" }, "currency_invalid");
  denied({ currency: null }, "currency_missing");
  for (const paymentStatus of ["failed", "pending", "unknown"] as const) {
    denied({ paymentStatus }, "payment_not_successful");
  }
  for (const confidence of ["medium", "low"] as const) {
    denied({ confidence }, "reading_confidence");
  }
});
Deno.test("explicit offsets compare the actual UTC date without comparing time of day", () => {
  for (
    const transactionDateTime of [
      "2026-10-03",
      "2026-10-03T00:01:00Z",
      "2026-10-03T12:34Z",
      "2026-10-03T12:34:40.123456+00:00",
      "2026-10-04T00:30:00+01:00",
      "2026-10-02T23:30:00-01:00",
    ]
  ) {
    assert(
      comparePayoutReceipts(expected, [{ ...facts, transactionDateTime }])
        .matched,
    );
  }
  denied(
    { transactionDateTime: "2026-10-03T00:30:00+01:00" },
    "paymentDate_mismatch",
  );
  denied({ transactionDateTime: "2026-10-04" }, "paymentDate_mismatch");
  assert(
    comparePayoutReceipts(
      { ...expected, paidAt: "2026-10-04T00:30:00+01:00" },
      [facts],
    ).matched,
  );
});
Deno.test("ambiguous calendar values, absent timezone and invalid calendar dates fail safely", () => {
  for (
    const transactionDateTime of [
      "03/10/2026",
      "October 3, 2026",
      "2026-10-03T12:34:40",
      "2026-02-30",
      "2026-10-03T24:00:00Z",
      "2026-10-03T12:34:60Z",
      "2026-10-03T12:34:00+14:01",
      "0000-01-01",
      "2026-10-03T12:34:00+25:00",
    ]
  ) denied({ transactionDateTime }, "paymentDate_invalid");
  denied({ transactionDateTime: null }, "paymentDate_missing");
  assert(
    comparePayoutReceipts({ ...expected, paidAt: "2024-02-29T12:00:00Z" }, [{
      ...facts,
      transactionDateTime: "2024-02-29",
    }]).matched,
  );
});
Deno.test("no receipt, duplicates, conflicting and partial multiple receipts never aggregate or choose best", () => {
  const empty = comparePayoutReceipts(expected, []);
  assert(!empty.matched && empty.reasons.includes("missing_evidence"));
  for (
    const receipts of [[facts, facts], [facts, { ...facts, amount: "1" }], [{
      ...facts,
      amount: null,
    }, { ...facts, recipientAccount: null }]]
  ) {
    const result = comparePayoutReceipts(expected, receipts);
    assert(!result.matched && result.reasons.includes("ambiguous_evidence"));
    assert(Object.values(result.checks).every((value) => !value));
    assert(result.facts === receipts);
  }
});
Deno.test("invalid authoritative expected facts cannot accidentally match untrusted receipt", () => {
  for (
    const change of [
      { amount: "1e2" },
      { currency: "ngn" },
      { recipientAccount: "****4567" },
      { recipientName: "" },
      { paidAt: "2026-10-03" },
      { paidAt: "2026-02-30T00:00:00Z" },
    ]
  ) {
    const result = comparePayoutReceipts({ ...expected, ...change }, [facts]);
    assert(!result.matched && result.reasons.includes("invalid_expected"));
  }
});
