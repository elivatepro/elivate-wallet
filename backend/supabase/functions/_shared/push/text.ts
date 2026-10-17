// What a push says (Blueprint 42 — Part A wording; owner Q2: title and
// amount). The bell's titles; its lines without member names, bank digits or
// references. Amounts come from the ledger's exact decimal string, never a
// float, and are hidden on a device with Hide amounts on.

export interface PushText {
  readonly title: string;
  readonly body: string;
}

export interface PushPayload extends PushText {
  readonly v: 1;
  readonly id: string;
  readonly path: string;
}

const SYMBOL: Record<string, string> = { NGN: "₦", USD: "$" };

/** "250000.00" → "₦250,000.00"; hidden → "₦••••••" (as the app shows it). */
export function money(params: Readonly<Record<string, unknown>>, hide: boolean): string {
  const currency = typeof params.currency === "string" ? params.currency : "";
  const amount = typeof params.amount === "string" ? params.amount : "";
  const symbol = SYMBOL[currency];
  if (!symbol || !/^\d{1,15}\.\d{2}$/.test(amount)) return "";
  if (hide) return `${symbol}••••••`;
  const [whole = "0", fraction = "00"] = amount.split(".");
  return `${symbol}${whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",")}.${fraction}`;
}

const KIND_NOUN: Record<string, string> = {
  conversion: "Conversion",
  adjustment: "Adjustment",
  returned_funds: "Returned funds",
};

const FALLBACK = "Open Elivate Wallet to see it.";

/** Title and line for a pushed kind; null for a kind that never pushes. */
export function pushText(
  kind: string,
  params: Readonly<Record<string, unknown>>,
  hide: boolean,
): PushText | null {
  const m = money(params, hide);
  const line = (text: (amount: string) => string) => (m ? text(m) : FALLBACK);
  const waiting = line((a) => `${a} is waiting for you`);
  switch (kind) {
    case "money.income_posted":
      return { title: "Income posted", body: line((a) => `${a}, split across your pockets`) };
    // Blueprint 44 (D2): the owner's own request, on hold until approved.
    case "money.withdrawal_submitted":
      return {
        title: "Withdrawal requested",
        body: line((a) => `${a} is on hold until it’s approved.`),
      };
    case "money.withdrawal_approved":
      return { title: "Withdrawal approved", body: line((a) => `${a}. Payout is next.`) };
    case "money.withdrawal_completed":
      return { title: "Withdrawal completed", body: line((a) => `Payout of ${a} confirmed.`) };
    case "money.withdrawal_not_approved":
      return {
        title: "Withdrawal not approved",
        body: line((a) => `${a} is back in your pocket.`),
      };
    case "task.withdrawal_approve":
      return { title: "Withdrawal to approve", body: waiting };
    case "task.payout_record":
      return { title: "Payout to record", body: line((a) => `${a} to pay out`) };
    case "task.payout_fix":
      return { title: "Payout record to fix", body: line((a) => `${a} needs a fix`) };
    case "task.payout_review":
      return { title: "Payout to review", body: waiting };
    case "task.entry_review": {
      const subject = typeof params.subject === "string" ? params.subject : "";
      return { title: `${KIND_NOUN[subject] ?? "Evidence"} to review`, body: waiting };
    }
    case "task.transfer_approve":
      return { title: "Pocket move to approve", body: waiting };
    case "task.nin_review":
      return { title: "Identity to review", body: "Someone in your network is waiting for you" };
    default:
      return null;
  }
}

/** The bell's link allow-list: identical to frontend #lib/app-path and the email one. */
const PATH =
  /^\/app(\/[a-z][a-z-]*)*(\?withdrawal=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$|^\/app\/billing\/payments\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$|^\/app\/withdrawals\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function safePath(path: unknown): string {
  return typeof path === "string" && PATH.test(path) ? path : "/app";
}

export const MAX_PAYLOAD_BYTES = 1024;

/** The JSON the service worker shows; null when the kind never pushes. */
export function pushPayload(
  itemId: string,
  kind: string,
  params: Readonly<Record<string, unknown>>,
  hide: boolean,
): Uint8Array<ArrayBuffer> | null {
  const text = pushText(kind, params, hide);
  if (!text) return null;
  const payload: PushPayload = { v: 1, id: itemId, ...text, path: safePath(params.path) };
  const bytes = new TextEncoder().encode(JSON.stringify(payload));
  if (bytes.length > MAX_PAYLOAD_BYTES) throw new Error("push payload too large");
  return bytes;
}

/** Tasks reach an approver now; money news can wait for the phone's next wake. */
export const urgencyFor = (kind: string): "high" | "normal" =>
  kind.startsWith("task.") ? "high" : "normal";

/** The item id without dashes: a retry replaces rather than repeats. */
export const topicFor = (itemId: string): string => itemId.replace(/-/g, "");
