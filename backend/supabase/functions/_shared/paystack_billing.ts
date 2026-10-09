// Paystack for plan purchases (Blueprint 16, W-19). Checkout initialization,
// server-side transaction verification, plans, subscriptions and the webhook
// signature. The secret key travels only in the Authorization header (and is
// the HMAC key); keys, card details and response bodies never reach errors or
// logs. Payout automation stays deferred (W-26).

export type Environment = "test" | "live";

export interface VerifiedCharge {
  readonly kind: "ok";
  /** Paystack's status: success, failed, abandoned, ongoing, pending, reversed, ... */
  readonly status: string;
  readonly reference: string;
  readonly amountKobo: number;
  readonly currency: string;
  readonly environment: Environment | null;
  readonly paidAt: string | null;
  readonly transactionId: number | null;
  readonly customerCode: string | null;
  readonly reusable: boolean;
  readonly planCode: string | null;
}

export type VerifyOutcome =
  | VerifiedCharge
  | { readonly kind: "not_found" }
  | { readonly kind: "unavailable" };

export type SubscriptionOutcome =
  | { readonly kind: "ok"; readonly subscriptionCode: string; readonly emailToken: string | null }
  | { readonly kind: "no_card" }
  | { readonly kind: "unavailable" };

export interface PaystackBilling {
  readonly environment: Environment;
  initialize(input: {
    readonly email: string;
    readonly amountKobo: number;
    readonly reference: string;
    readonly callbackUrl: string;
    readonly paymentId: string;
  }): Promise<
    { readonly kind: "ok"; readonly authorizationUrl: string } | { readonly kind: "unavailable" }
  >;
  verify(reference: string): Promise<VerifyOutcome>;
  createPlan(name: string, amountKobo: number): Promise<string | null>;
  createSubscription(input: {
    readonly customerCode: string;
    readonly planCode: string;
    readonly startDate: string;
  }): Promise<SubscriptionOutcome>;
  disableSubscription(code: string, emailToken: string): Promise<boolean>;
}

const origin = "https://api.paystack.co";
const checkoutHosts = ["checkout.paystack.com"];
const localHosts = ["127.0.0.1", "localhost", "host.docker.internal"];
const maxBodyBytes = 256 * 1024;

export const referencePattern = /^[A-Za-z0-9._=-]{6,100}$/;
const codePattern = (prefix: string) => new RegExp(`^${prefix}_[A-Za-z0-9]{1,60}$`);

type Json = Record<string, unknown>;

function object(value: unknown): Json | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Json
    : null;
}

function str(value: unknown, pattern?: RegExp): string | null {
  return typeof value === "string" && (!pattern || pattern.test(value)) ? value : null;
}

export function environmentOf(secretKey: string): Environment {
  if (secretKey.startsWith("sk_live_")) return "live";
  if (secretKey.startsWith("sk_test_")) return "test";
  throw new Error("PAYSTACK_SECRET_KEY has an unexpected format");
}

const encoder = new TextEncoder();

function hex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256Hex(raw: Uint8Array<ArrayBuffer>): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", raw));
}

/**
 * Paystack signs the raw request bytes: hex HMAC SHA-512 keyed with the
 * secret key, in `x-paystack-signature`. Compared in constant time.
 */
export async function validSignature(
  raw: Uint8Array<ArrayBuffer>,
  signature: string | null,
  secretKey: string,
): Promise<boolean> {
  if (!signature || !/^[0-9a-f]{128}$/i.test(signature)) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secretKey),
    { name: "HMAC", hash: "SHA-512" },
    false,
    ["sign"],
  );
  const expected = hex(await crypto.subtle.sign("HMAC", key, raw));
  const given = signature.toLowerCase();
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ given.charCodeAt(i);
  return diff === 0;
}

class Unavailable extends Error {
  constructor() {
    super("provider unavailable");
  }
}

async function readBounded(response: Response): Promise<unknown> {
  if (!response.body) throw new Unavailable();
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const result = await reader.read();
      if (result.done) break;
      size += result.value.byteLength;
      if (size > maxBodyBytes) {
        await reader.cancel();
        throw new Unavailable();
      }
      chunks.push(result.value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new Unavailable();
  }
}

export interface PaystackBillingOptions {
  readonly fetcher?: typeof fetch;
  readonly timeoutMs?: number;
  /** Local test doubles only (see name_lookup.ts localTestOrigin). */
  readonly origin?: string;
}

export function paystackBilling(
  secretKey: string,
  options: PaystackBillingOptions = {},
): PaystackBilling {
  if (!/^sk_(test|live)_[A-Za-z0-9]{10,200}$/.test(secretKey)) {
    throw new Error("PAYSTACK_SECRET_KEY has an unexpected format");
  }
  const environment = environmentOf(secretKey);
  const fetcher = options.fetcher ?? fetch;
  const timeoutMs = options.timeoutMs ?? 10_000;
  const base = options.origin ?? origin;
  const testing = options.origin !== undefined;

  async function send(
    method: "GET" | "POST",
    path: string,
    body?: Json,
  ): Promise<{ status: number; body: Json | null }> {
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), timeoutMs);
    try {
      const response = await fetcher(new URL(path, base), {
        method,
        redirect: "error",
        signal: abort.signal,
        headers: {
          accept: "application/json",
          authorization: `Bearer ${secretKey}`,
          ...(body ? { "content-type": "application/json" } : {}),
        },
        ...(body ? { body: JSON.stringify(body) } : {}),
      });
      if (response.status === 429 || response.status >= 500) {
        await response.body?.cancel();
        throw new Unavailable();
      }
      return { status: response.status, body: object(await readBounded(response)) };
    } catch (error) {
      if (error instanceof Unavailable) throw error;
      throw new Unavailable();
    } finally {
      clearTimeout(timer);
    }
  }

  function checkoutUrl(value: unknown): string | null {
    const raw = str(value);
    if (!raw) return null;
    try {
      const url = new URL(raw);
      if (url.protocol === "https:" && checkoutHosts.includes(url.hostname)) return url.href;
      if (testing && localHosts.includes(url.hostname)) return url.href;
    } catch {
      return null;
    }
    return null;
  }

  return {
    environment,

    async initialize(input) {
      try {
        const { status, body } = await send("POST", "/transaction/initialize", {
          email: input.email,
          amount: input.amountKobo,
          currency: "NGN",
          reference: input.reference,
          callback_url: input.callbackUrl,
          metadata: { paymentId: input.paymentId },
        });
        const data = object(body?.data);
        const url = checkoutUrl(data?.authorization_url);
        if (status !== 200 || body?.status !== true || !url) return { kind: "unavailable" };
        return { kind: "ok", authorizationUrl: url };
      } catch {
        return { kind: "unavailable" };
      }
    },

    async verify(reference) {
      if (!referencePattern.test(reference)) return { kind: "not_found" };
      try {
        const { status, body } = await send(
          "GET",
          `/transaction/verify/${encodeURIComponent(reference)}`,
        );
        if (status === 404 || (status === 400 && body?.status === false)) {
          return { kind: "not_found" };
        }
        const data = object(body?.data);
        if (status !== 200 || body?.status !== true || !data) return { kind: "unavailable" };
        const amount = data.amount;
        const ref = str(data.reference, referencePattern);
        const txStatus = str(data.status, /^[a-z_]{1,30}$/);
        if (
          typeof amount !== "number" || !Number.isSafeInteger(amount) || amount < 0 || !ref ||
          !txStatus
        ) {
          return { kind: "unavailable" };
        }
        const domain = data.domain === "test" || data.domain === "live" ? data.domain : null;
        const customer = object(data.customer);
        const authorization = object(data.authorization);
        const plan = object(data.plan);
        const paidAt = str(data.paid_at) ?? str(data.paidAt);
        return {
          kind: "ok",
          status: txStatus,
          reference: ref,
          amountKobo: amount,
          currency: (str(data.currency, /^[A-Za-z]{3}$/) ?? "").toUpperCase(),
          environment: domain,
          paidAt: paidAt && !Number.isNaN(Date.parse(paidAt))
            ? new Date(paidAt).toISOString()
            : null,
          transactionId: typeof data.id === "number" && Number.isSafeInteger(data.id)
            ? data.id
            : null,
          customerCode: str(customer?.customer_code, codePattern("CUS")),
          reusable: authorization?.reusable === true && authorization?.channel === "card",
          planCode: str(plan?.plan_code, codePattern("PLN")) ?? str(data.plan, codePattern("PLN")),
        };
      } catch {
        return { kind: "unavailable" };
      }
    },

    async createPlan(name, amountKobo) {
      try {
        const { status, body } = await send("POST", "/plan", {
          name,
          interval: "annually",
          amount: amountKobo,
          currency: "NGN",
          send_invoices: false,
          send_sms: false,
        });
        const data = object(body?.data);
        return status >= 200 && status < 300 && body?.status === true
          ? str(data?.plan_code, codePattern("PLN"))
          : null;
      } catch {
        return null;
      }
    },

    async createSubscription(input) {
      try {
        const { status, body } = await send("POST", "/subscription", {
          customer: input.customerCode,
          plan: input.planCode,
          start_date: input.startDate,
        });
        const data = object(body?.data);
        const code = str(data?.subscription_code, codePattern("SUB"));
        if (status >= 200 && status < 300 && body?.status === true && code) {
          return {
            kind: "ok",
            subscriptionCode: code,
            emailToken: str(data?.email_token, /^[A-Za-z0-9_-]{1,100}$/),
          };
        }
        // Paystack refuses when the customer has no reusable card authorization.
        const message = str(body?.message) ?? "";
        if (status === 400 && /authori[sz]ation/i.test(message)) return { kind: "no_card" };
        return { kind: "unavailable" };
      } catch {
        return { kind: "unavailable" };
      }
    },

    async disableSubscription(code, emailToken) {
      try {
        const { status, body } = await send("POST", "/subscription/disable", {
          code,
          token: emailToken,
        });
        // Already disabled or gone counts as done.
        return (status >= 200 && status < 300 && body?.status === true) || status === 404 ||
          status === 400;
      } catch {
        return false;
      }
    },
  };
}
