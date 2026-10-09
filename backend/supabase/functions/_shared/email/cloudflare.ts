// Cloudflare Email Sending REST adapter (Blueprint 03 — B4, owner decision 6).
// POST /accounts/{account_id}/email/sending/send with an Email-Sending-only API
// token. Returns a classified outcome; never logs or returns addresses,
// bodies, tokens or raw provider responses.

export interface CloudflareConfig {
  readonly accountId: string;
  readonly apiToken: string;
  readonly fromAddress: string;
  readonly fromName: string;
}

export interface OutgoingEmail {
  readonly to: string;
  readonly subject: string;
  readonly html: string;
  readonly text: string;
  /** Correlation id, sent as `X-Elivate-Outbox` (`outbox:<event>:<cycle>`). */
  readonly correlationId: string;
}

export type SendOutcome =
  | {
    readonly outcome: "sent";
    readonly providerStatus: number;
    readonly messageId: string | null;
  }
  | {
    readonly outcome: "retryable_failure" | "permanent_failure" | "outcome_unknown";
    readonly providerStatus: number | null;
    readonly errorCode: string;
  };

export type FetchLike = (input: string, init: RequestInit) => Promise<Response>;

export interface EmailTransport {
  send(email: OutgoingEmail): Promise<SendOutcome>;
}

const apiBase = "https://api.cloudflare.com/client/v4";

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function includesAddress(value: unknown, address: string): boolean {
  return Array.isArray(value) &&
    value.some((entry) => typeof entry === "string" && entry.toLowerCase() === address);
}

/** First numeric Cloudflare error code, for a safe error code suffix. */
function providerCode(body: Record<string, unknown> | null): string {
  const errors = body?.errors;
  if (Array.isArray(errors)) {
    const code = asRecord(errors[0])?.code;
    if (typeof code === "number" && Number.isInteger(code) && code >= 0) return `.${code}`;
  }
  return "";
}

export function createCloudflareTransport(
  config: CloudflareConfig,
  options: {
    readonly fetch?: FetchLike;
    readonly timeoutMs?: number;
    /** Local end-to-end only: a fake Cloudflare on a loopback origin. */
    readonly apiBase?: string;
  } = {},
): EmailTransport {
  const doFetch: FetchLike = options.fetch ?? ((input, init) => fetch(input, init));
  const timeoutMs = options.timeoutMs ?? 15_000;
  const base = options.apiBase ?? apiBase;
  const url = `${base}/accounts/${encodeURIComponent(config.accountId)}/email/sending/send`;

  return {
    async send(email: OutgoingEmail): Promise<SendOutcome> {
      const body = JSON.stringify({
        from: { address: config.fromAddress, name: config.fromName },
        to: [email.to],
        subject: email.subject,
        html: email.html,
        text: email.text,
        headers: { "X-Elivate-Outbox": email.correlationId },
      });

      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      let response: Response;
      try {
        response = await doFetch(url, {
          method: "POST",
          headers: {
            authorization: `Bearer ${config.apiToken}`,
            "content-type": "application/json",
          },
          body,
          signal: controller.signal,
        });
      } catch (error) {
        clearTimeout(timer);
        // A timeout may fire after Cloudflare received the request: unknown.
        // Other fetch errors (DNS, refused connection) happen before sending.
        if (
          controller.signal.aborted ||
          (error instanceof DOMException && error.name === "AbortError")
        ) {
          return {
            outcome: "outcome_unknown",
            providerStatus: null,
            errorCode: "provider.timeout",
          };
        }
        return {
          outcome: "retryable_failure",
          providerStatus: null,
          errorCode: "provider.network",
        };
      }

      let parsed: Record<string, unknown> | null = null;
      try {
        parsed = asRecord(await response.json());
      } catch {
        parsed = null;
      } finally {
        clearTimeout(timer);
      }

      const status = response.status;
      if (status === 429) {
        return {
          outcome: "retryable_failure",
          providerStatus: status,
          errorCode: "provider.rate_limited",
        };
      }
      if (status >= 500) {
        return {
          outcome: "retryable_failure",
          providerStatus: status,
          errorCode: "provider.unavailable",
        };
      }
      if (status < 200 || status >= 300) {
        return {
          outcome: "permanent_failure",
          providerStatus: status,
          errorCode: `provider.rejected${providerCode(parsed)}`,
        };
      }

      const result = asRecord(parsed?.result);
      if (parsed?.success !== true || !result) {
        return {
          outcome: "outcome_unknown",
          providerStatus: status,
          errorCode: "provider.unexpected_response",
        };
      }
      const to = email.to.toLowerCase();
      if (includesAddress(result.permanent_bounces, to)) {
        return {
          outcome: "permanent_failure",
          providerStatus: status,
          errorCode: "provider.bounced",
        };
      }
      if (includesAddress(result.suppressed_recipients, to)) {
        return {
          outcome: "permanent_failure",
          providerStatus: status,
          errorCode: "provider.suppressed",
        };
      }
      const messageId = typeof result.message_id === "string"
        ? result.message_id.slice(0, 300)
        : null;
      return { outcome: "sent", providerStatus: status, messageId };
    },
  };
}
