import type { ReceiptExtraction } from "./openai-receipts.ts";

export const RECEIPT_COMPARISON_POLICY_VERSION = "strict-single-receipt-v1";
export type ExpectedPayoutReceipt = {
  amount: string;
  currency: string;
  recipientAccount: string;
  recipientName: string;
  paidAt: string;
};
export type ReceiptCheck =
  | "amount"
  | "currency"
  | "recipientAccount"
  | "recipientName"
  | "paymentStatus"
  | "paymentDate"
  | "confidence";
export type ReceiptComparisonReason =
  | "missing_evidence"
  | "ambiguous_evidence"
  | "invalid_expected"
  | "reading_confidence"
  | "payment_not_successful"
  | `${
    | "amount"
    | "currency"
    | "recipientAccount"
    | "recipientName"
    | "paymentDate"}_${"missing" | "invalid" | "mismatch"}`;
export type ReceiptComparison = {
  policyVersion: typeof RECEIPT_COMPARISON_POLICY_VERSION;
  matched: boolean;
  reasons: ReceiptComparisonReason[];
  checks: Record<ReceiptCheck, boolean>;
  facts: readonly ReceiptExtraction[];
};
// PostgreSQL numeric(38,18), compared as scaled integers without rounding.
function decimal(value: unknown): bigint | null {
  if (
    typeof value !== "string" || !/^[0-9]{1,20}(?:\.[0-9]{1,18})?$/.test(value)
  ) return null;
  const [whole, fraction = ""] = value.split(".");
  if (whole === undefined) return null;
  return BigInt(whole) * 10n ** 18n + BigInt(fraction.padEnd(18, "0"));
}
function account(value: unknown): string | null {
  if (typeof value !== "string" || value.length > 64) return null;
  const normalized = value.replace(/[ -]/g, "");
  return /^[0-9]+$/.test(normalized) ? normalized : null;
}
function name(value: unknown): string | null {
  if (typeof value !== "string" || value.length > 255) return null;
  const normalized = value.trim().replace(/\s+/gu, " ").toLowerCase();
  return normalized || null;
}
function currency(value: unknown): string | null {
  return typeof value === "string" && /^[A-Z]{3}$/.test(value) ? value : null;
}
function calendar(value: string): boolean {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match || match[1] === "0000") return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(parsed.getTime()) &&
    parsed.toISOString().slice(0, 10) === value;
}
/** Only printed ISO calendar dates or times with explicit zones are unambiguous. */
function utcDate(value: unknown, requireTimestamp = false): string | null {
  if (typeof value !== "string") return null;
  if (!requireTimestamp && calendar(value)) return value;
  const match =
    /^(\d{4}-\d{2}-\d{2})T([01]\d|2[0-3]):([0-5]\d)(?::([0-5]\d)(?:\.\d{1,9})?)?(Z|[+-](?:0\d|1[0-4]):[0-5]\d)$/
      .exec(value);
  if (
    !match || !match[1] || !match[5] || !calendar(match[1]) ||
    /[+-]14:(?!00)/.test(match[5])
  ) {
    return null;
  }
  const parsed = new Date(value);
  if (!Number.isFinite(parsed.getTime())) return null;
  return parsed.toISOString().slice(0, 10);
}
/** Compares untrusted extracted facts only. A match grants no authority and proves no settlement. */
export function comparePayoutReceipts(
  expected: ExpectedPayoutReceipt,
  receipts: readonly ReceiptExtraction[],
): ReceiptComparison {
  const checks: Record<ReceiptCheck, boolean> = {
    amount: false,
    currency: false,
    recipientAccount: false,
    recipientName: false,
    paymentStatus: false,
    paymentDate: false,
    confidence: false,
  };
  const reasons: ReceiptComparisonReason[] = [];
  const result = (): ReceiptComparison => ({
    policyVersion: RECEIPT_COMPARISON_POLICY_VERSION,
    matched: reasons.length === 0 && Object.values(checks).every(Boolean),
    reasons,
    checks,
    facts: receipts,
  });
  const canonical = {
    amount: decimal(expected.amount),
    currency: currency(expected.currency),
    recipientAccount: account(expected.recipientAccount),
    recipientName: name(expected.recipientName),
    paymentDate: utcDate(expected.paidAt, true),
  };
  if (Object.values(canonical).some((value) => value === null)) {
    reasons.push("invalid_expected");
  }
  if (receipts.length !== 1) {
    reasons.push(
      receipts.length === 0 ? "missing_evidence" : "ambiguous_evidence",
    );
    return result();
  }
  if (reasons.length) return result();
  const facts = receipts[0];
  if (!facts) {
    reasons.push("missing_evidence");
    return result();
  }
  const observed = {
    amount: decimal(facts.amount),
    currency: currency(facts.currency),
    recipientAccount: account(facts.recipientAccount),
    recipientName: name(facts.recipientName),
    paymentDate: utcDate(facts.transactionDateTime),
  };
  const raw = {
    amount: facts.amount,
    currency: facts.currency,
    recipientAccount: facts.recipientAccount,
    recipientName: facts.recipientName,
    paymentDate: facts.transactionDateTime,
  };
  for (
    const key of [
      "amount",
      "currency",
      "recipientAccount",
      "recipientName",
      "paymentDate",
    ] as const
  ) {
    checks[key] = observed[key] !== null && observed[key] === canonical[key];
    if (!checks[key]) {
      reasons.push(
        `${key}_${
          raw[key] === null
            ? "missing"
            : observed[key] === null
            ? "invalid"
            : "mismatch"
        }`,
      );
    }
  }
  checks.paymentStatus = facts.paymentStatus === "successful";
  if (!checks.paymentStatus) reasons.push("payment_not_successful");
  checks.confidence = facts.confidence === "high";
  if (!checks.confidence) reasons.push("reading_confidence");
  return result();
}
