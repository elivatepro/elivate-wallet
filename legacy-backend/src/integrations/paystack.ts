export type PaystackEnvironment = "test" | "live";

export type ExpectedPaystackPayment = Readonly<{
  reference: string;
  amountMinor: number;
  email: string;
}>;

export type PaystackFailureCode =
  | "invalid_configuration"
  | "invalid_request"
  | "provider_unavailable"
  | "provider_rejected"
  | "invalid_response"
  | "payment_not_confirmed"
  | "payment_mismatch";

export class PaystackError extends Error {
  constructor(
    readonly code: PaystackFailureCode,
    readonly retryable = false,
  ) {
    super("Payment provider request failed");
    this.name = "PaystackError";
  }
}

type ProviderFetch = (
  input: string,
  init: RequestInit,
) => Promise<Response>;

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function validateExpectedPayment(input: ExpectedPaystackPayment): void {
  if (
    typeof input.reference !== "string" ||
    !/^[A-Za-z0-9.=-]{1,128}$/.test(input.reference) ||
    input.reference === "." || input.reference === ".." ||
    !Number.isSafeInteger(input.amountMinor) || input.amountMinor <= 0 ||
    typeof input.email !== "string" ||
    !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(input.email)
  ) throw new PaystackError("invalid_request");
}

/** Provider transport only. Callers derive purchase identity and price server-side. */
export class PaystackClient {
  readonly #secretKey: string;
  readonly #environment: PaystackEnvironment;
  readonly #callbackOrigin: string;
  readonly #fetch: ProviderFetch;

  constructor(
    options: Readonly<{
      secretKey: string;
      environment: PaystackEnvironment;
      callbackOrigin: string;
      fetch?: ProviderFetch;
    }>,
  ) {
    if (
      !["test", "live"].includes(options.environment) ||
      !new RegExp(`^sk_${options.environment}_[A-Za-z0-9]+$`).test(
        options.secretKey,
      )
    ) throw new PaystackError("invalid_configuration");
    let origin: URL;
    try {
      origin = new URL(options.callbackOrigin);
    } catch {
      throw new PaystackError("invalid_configuration");
    }
    if (
      origin.protocol !== "https:" || origin.username || origin.password ||
      origin.pathname !== "/" || origin.search || origin.hash
    ) throw new PaystackError("invalid_configuration");
    this.#secretKey = options.secretKey;
    this.#environment = options.environment;
    this.#callbackOrigin = origin.origin;
    this.#fetch = options.fetch ?? fetch;
  }

  async #request(path: string, body?: Record<string, unknown>): Promise<
    Record<string, unknown>
  > {
    let response: Response;
    try {
      response = await this.#fetch(`https://api.paystack.co${path}`, {
        method: body ? "POST" : "GET",
        headers: {
          Authorization: `Bearer ${this.#secretKey}`,
          "Content-Type": "application/json",
          Accept: "application/json",
          "User-Agent": "ElivateWallet/2.0",
        },
        redirect: "error",
        signal: AbortSignal.timeout(10_000),
        ...(body ? { body: JSON.stringify(body) } : {}),
      });
    } catch {
      // Provider errors may contain credentials, URLs or buyer data.
      throw new PaystackError("provider_unavailable", true);
    }
    if (!response.ok) {
      throw new PaystackError(
        response.status === 429 || response.status >= 500
          ? "provider_unavailable"
          : "provider_rejected",
        response.status === 429 || response.status >= 500,
      );
    }
    let parsed: unknown;
    try {
      parsed = await response.json();
    } catch (error) {
      if (error instanceof SyntaxError) {
        throw new PaystackError("invalid_response");
      }
      throw new PaystackError("provider_unavailable", true);
    }
    if (!record(parsed) || parsed.status !== true || !record(parsed.data)) {
      throw new PaystackError("invalid_response");
    }
    return parsed.data;
  }

  async initialize(
    input: ExpectedPaystackPayment & Readonly<{ callbackUrl: string }>,
  ): Promise<Readonly<{ checkoutUrl: string; reference: string }>> {
    validateExpectedPayment(input);
    let callback: URL;
    try {
      callback = new URL(input.callbackUrl);
    } catch {
      throw new PaystackError("invalid_request");
    }
    if (
      callback.origin !== this.#callbackOrigin || callback.username ||
      callback.password
    ) throw new PaystackError("invalid_request");
    const data = await this.#request("/transaction/initialize", {
      reference: input.reference,
      amount: String(input.amountMinor),
      email: input.email,
      currency: "NGN",
      callback_url: callback.href,
    });
    if (
      data.reference !== input.reference ||
      typeof data.authorization_url !== "string"
    ) throw new PaystackError("invalid_response");
    let checkout: URL;
    try {
      checkout = new URL(data.authorization_url);
    } catch {
      throw new PaystackError("invalid_response");
    }
    if (
      checkout.protocol !== "https:" ||
      checkout.hostname !== "checkout.paystack.com" || checkout.port ||
      checkout.username || checkout.password
    ) throw new PaystackError("invalid_response");
    return { checkoutUrl: checkout.href, reference: input.reference };
  }

  async verify(input: ExpectedPaystackPayment): Promise<
    Readonly<{
      reference: string;
      amountMinor: number;
      currency: "NGN";
      paidAt: string;
    }>
  > {
    validateExpectedPayment(input);
    const data = await this.#request(
      `/transaction/verify/${encodeURIComponent(input.reference)}`,
    );
    if (data.status !== "success") {
      throw new PaystackError(
        "payment_not_confirmed",
        data.status === "pending" || data.status === "ongoing" ||
          data.status === "processing",
      );
    }
    if (
      data.reference !== input.reference || data.amount !== input.amountMinor ||
      data.currency !== "NGN" || data.domain !== this.#environment ||
      !record(data.customer) ||
      typeof data.customer.email !== "string" ||
      data.customer.email.toLowerCase() !== input.email.toLowerCase()
    ) throw new PaystackError("payment_mismatch");
    if (
      typeof data.paid_at !== "string" ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/.test(data.paid_at) ||
      !Number.isFinite(Date.parse(data.paid_at)) ||
      new Date(data.paid_at).toISOString().slice(0, 19) !==
        data.paid_at.slice(0, 19)
    ) throw new PaystackError("invalid_response");
    return {
      reference: input.reference,
      amountMinor: input.amountMinor,
      currency: "NGN",
      paidAt: data.paid_at,
    };
  }

  /** Authenticate exact raw bytes before parsing or accepting a webhook event. */
  async verifyWebhook(
    rawBody: ArrayBuffer,
    signature: string | null,
  ): Promise<boolean> {
    if (
      !signature || !/^[a-f0-9]{128}$/i.test(signature) ||
      rawBody.byteLength === 0 || rawBody.byteLength > 1_048_576
    ) return false;
    const bytes = Uint8Array.from(
      signature.match(/.{2}/g) ?? [],
      (part) => Number.parseInt(part, 16),
    );
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(this.#secretKey),
      { name: "HMAC", hash: "SHA-512" },
      false,
      ["verify"],
    );
    return crypto.subtle.verify("HMAC", key, bytes, rawBody);
  }
}
