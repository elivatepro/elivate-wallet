// Deterministic receipt comparison (Blueprint 11 — B3, `strict-single-receipt-v1`).
// The model only reads; this decides. A match needs every fact to agree
// exactly; anything missing, unreadable or different is a stated reason.

export const policyVersion = "strict-single-receipt-v1";

export type PaymentStatus = "successful" | "failed" | "pending" | "unknown";
export type Confidence = "high" | "medium" | "low";

/** Facts read from one receipt; every string is nullable (absent or illegible). */
export interface ReceiptFacts {
  readonly amount: string | null;
  readonly currency: string | null;
  readonly recipientAccount: string | null;
  readonly recipientName: string | null;
  readonly institutionName: string | null;
  readonly transactionDate: string | null;
  readonly transactionTime: string | null;
  readonly transactionTimezone: string | null;
  readonly transactionReference: string | null;
  readonly paymentStatus: PaymentStatus;
  readonly confidence: Confidence;
  readonly notes: string | null;
}

export interface Expected {
  /** Sent amount as a decimal string. */
  readonly amount: string;
  readonly currency: string;
  /** YYYY-MM-DD as recorded. */
  readonly paidOn: string;
  readonly recipientName: string;
  /** Full decrypted account number of the destination snapshot. */
  readonly accountNumber: string;
}

export interface Comparison {
  readonly outcome: "match" | "mismatch";
  readonly reasons: readonly string[];
  /** The payment date used for the comparison, or null when unknown. */
  readonly paymentDate: string | null;
}

const decimalPattern = /^[0-9]{1,20}(\.[0-9]{1,18})?$/;

/** "002450.500" → "2450.5": compares decimals exactly, never via floats. */
export function canonicalDecimal(value: string): string {
  const [whole = "", fraction = ""] = value.split(".");
  const w = whole.replace(/^0+(?=[0-9])/, "");
  const f = fraction.replace(/0+$/, "");
  return f ? `${w}.${f}` : w;
}

export function normalizeName(value: string): string {
  return value.trim().replace(/\s+/g, " ").toLowerCase();
}

function validDate(value: string): boolean {
  if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

/** "+01:00", "-0500", "+1", "Z", "UTC", "GMT", "UTC+1", "GMT+01:00" → minutes east of UTC. */
export function offsetMinutes(zone: string): number | null {
  const z = zone.trim().toUpperCase();
  if (z === "Z" || z === "UTC" || z === "GMT") return 0;
  if (z === "WAT") return 60;
  const m = z.match(/^(?:UTC|GMT)?\s*([+-])([0-9]{1,2})(?::?([0-9]{2}))?$/);
  if (!m) return null;
  const hours = Number(m[2]);
  const minutes = Number(m[3] ?? "0");
  if (hours > 14 || minutes > 59) return null;
  return (m[1] === "-" ? -1 : 1) * (hours * 60 + minutes);
}

/**
 * The payment's calendar date: as printed, or its UTC date when a time zone
 * is printed with a time (owner decision 2026-10-09).
 */
export function paymentDate(
  facts: Pick<ReceiptFacts, "transactionDate" | "transactionTime" | "transactionTimezone">,
): { date: string | null; reason: "missing" | "invalid" | null } {
  const printed = facts.transactionDate?.trim();
  if (!printed) return { date: null, reason: "missing" };
  if (!validDate(printed)) return { date: null, reason: "invalid" };
  const zone = facts.transactionTimezone?.trim();
  const time = facts.transactionTime?.trim();
  if (!zone || !time) return { date: printed, reason: null };
  const offset = offsetMinutes(zone);
  const t = time.match(/^([01][0-9]|2[0-3]):([0-5][0-9])(?::([0-5][0-9]))?$/);
  if (offset === null || !t) return { date: null, reason: "invalid" };
  const local = Date.parse(`${printed}T${t[1]}:${t[2]}:${t[3] ?? "00"}Z`);
  return { date: new Date(local - offset * 60_000).toISOString().slice(0, 10), reason: null };
}

export function compareReceipt(facts: ReceiptFacts, expected: Expected): Comparison {
  const reasons: string[] = [];

  const amount = facts.amount?.trim();
  if (!amount) reasons.push("amount_missing");
  else if (!decimalPattern.test(amount)) reasons.push("amount_invalid");
  else if (canonicalDecimal(amount) !== canonicalDecimal(expected.amount)) {
    reasons.push("amount_mismatch");
  }

  const currency = facts.currency?.trim().toUpperCase();
  if (!currency) reasons.push("currency_missing");
  else if (!/^[A-Z]{3}$/.test(currency)) reasons.push("currency_invalid");
  else if (currency !== expected.currency) reasons.push("currency_mismatch");

  // Leading zeros are kept; a masked number can never prove the destination.
  const account = facts.recipientAccount?.replace(/[\s-]/g, "");
  if (!account) reasons.push("recipientAccount_missing");
  else if (/^[0-9]+$/.test(account)) {
    if (account !== expected.accountNumber) reasons.push("recipientAccount_mismatch");
  } else if (/^[0-9*xX•.]+$/.test(account)) reasons.push("recipientAccount_mismatch");
  else reasons.push("recipientAccount_invalid");

  const name = facts.recipientName === null ? "" : normalizeName(facts.recipientName);
  if (!name) reasons.push("recipientName_missing");
  else if (name !== normalizeName(expected.recipientName)) reasons.push("recipientName_mismatch");

  const date = paymentDate(facts);
  if (date.reason) reasons.push(`paymentDate_${date.reason}`);
  else if (date.date !== expected.paidOn) reasons.push("paymentDate_mismatch");

  if (facts.paymentStatus !== "successful") reasons.push("payment_not_successful");
  if (facts.confidence !== "high") reasons.push("reading_confidence");

  return { outcome: reasons.length === 0 ? "match" : "mismatch", reasons, paymentDate: date.date };
}
