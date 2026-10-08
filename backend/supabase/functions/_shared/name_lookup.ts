// Bank account name lookup (Blueprint 05 — B4, P-04). One provider interface,
// the Paystack adapter and a fake for tests. The secret key travels only in the
// Authorization header; keys, numbers and response bodies never reach errors
// or logs.

export interface Bank {
  readonly code: string;
  readonly name: string;
  readonly slug: string | null;
}

export type LookupOutcome =
  | { readonly kind: "resolved"; readonly accountName: string }
  | { readonly kind: "not_found" }
  | { readonly kind: "unavailable"; readonly retryAfterSeconds?: number };

export type BankListOutcome =
  | { readonly kind: "ok"; readonly banks: readonly Bank[] }
  | { readonly kind: "unavailable" };

export interface NameLookupProvider {
  readonly id: "paystack" | "fake";
  listBanks(signal?: AbortSignal): Promise<BankListOutcome>;
  resolve(bankCode: string, accountNumber: string, signal?: AbortSignal): Promise<LookupOutcome>;
}

export const bankCodePattern = /^[0-9A-Z]{3,10}$/;
const accountNumberPattern = /^[0-9]{10}$/;
const origin = "https://api.paystack.co";
const maxBodyBytes = 256 * 1024;
const maxPages = 10;

export interface PaystackOptions {
  readonly fetcher?: typeof fetch;
  readonly timeoutMs?: number;
  /** Local test doubles only; see localTestOrigin(). */
  readonly origin?: string;
}

/**
 * Accepts an origin override only for local hosts (end-to-end tests against
 * a fake provider), so a misconfigured deployment can never send lookups or
 * the secret key anywhere but the real provider.
 */
export function localTestOrigin(value: string | undefined): string | undefined {
  if (!value) return undefined;
  try {
    const url = new URL(value);
    return ["127.0.0.1", "localhost", "host.docker.internal"].includes(url.hostname)
      ? url.origin
      : undefined;
  } catch {
    return undefined;
  }
}

type Json = Record<string, unknown>;

function object(value: unknown): Json | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Json
    : null;
}

/** Provider names: 1–160 characters after trimming, no control characters. */
export function safeName(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const name = value.trim().replace(/\s+/g, " ");
  if (name.length < 1 || name.length > 160) return null;
  for (const character of name) {
    const code = character.codePointAt(0) ?? 0;
    if (code < 32 || (code >= 127 && code < 160)) return null;
  }
  return name;
}

class Unavailable extends Error {
  constructor(readonly retryAfterSeconds?: number) {
    super("provider unavailable");
  }
}

function retryAfter(headers: Headers): number | undefined {
  for (const name of ["retry-after", "x-ratelimit-reset"]) {
    const value = headers.get(name);
    if (value && /^[0-9]{1,6}$/.test(value)) {
      return Math.min(3600, Math.max(1, Number(value)));
    }
  }
  return undefined;
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

export function paystackProvider(
  secretKey: string,
  options: PaystackOptions = {},
): NameLookupProvider {
  if (!/^sk_(test|live)_[A-Za-z0-9]{10,200}$/.test(secretKey)) {
    throw new Error("PAYSTACK_SECRET_KEY has an unexpected format");
  }
  const fetcher = options.fetcher ?? fetch;
  const timeoutMs = options.timeoutMs ?? 10_000;
  const base = options.origin ?? origin;

  /** GET with a fixed origin, timeout, no redirects and a size cap. */
  async function get(
    path: string,
    params: Record<string, string>,
    signal?: AbortSignal,
  ): Promise<{ status: number; body: unknown; headers: Headers }> {
    const url = new URL(path, base);
    for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), timeoutMs);
    const onAbort = () => abort.abort();
    signal?.addEventListener("abort", onAbort);
    try {
      const response = await fetcher(url, {
        method: "GET",
        redirect: "error",
        signal: abort.signal,
        headers: { accept: "application/json", authorization: `Bearer ${secretKey}` },
      });
      if (response.status === 429 || response.status >= 500) {
        await response.body?.cancel();
        throw new Unavailable(response.status === 429 ? retryAfter(response.headers) : undefined);
      }
      return {
        status: response.status,
        body: await readBounded(response),
        headers: response.headers,
      };
    } catch (error) {
      if (error instanceof Unavailable) throw error;
      throw new Unavailable();
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
    }
  }

  return {
    id: "paystack",

    async listBanks(signal) {
      const banks = new Map<string, Bank>();
      let cursor: string | null = null;
      try {
        for (let page = 0; page < maxPages; page++) {
          const params: Record<string, string> = {
            country: "nigeria",
            currency: "NGN",
            type: "nuban",
            perPage: "100",
            use_cursor: "true",
          };
          if (cursor) params.next = cursor;
          const { status, body } = await get("/bank", params, signal);
          const envelope = object(body);
          if (status !== 200 || envelope?.status !== true || !Array.isArray(envelope.data)) {
            return { kind: "unavailable" };
          }
          for (const item of envelope.data) {
            const row = object(item);
            if (!row || row.active !== true || row.is_deleted === true) continue;
            if (row.type !== undefined && row.type !== "nuban") continue;
            const code = typeof row.code === "string" ? row.code.trim().toUpperCase() : "";
            const name = safeName(row.name);
            if (!bankCodePattern.test(code) || !name || name.length > 100 || banks.has(code)) {
              continue;
            }
            const slug = typeof row.slug === "string" && row.slug.length <= 100 ? row.slug : null;
            banks.set(code, { code, name, slug });
          }
          const next = object(envelope.meta)?.next;
          if (typeof next !== "string" || next === "" || next.length > 200) break;
          cursor = next;
        }
      } catch {
        return { kind: "unavailable" };
      }
      return banks.size > 0 ? { kind: "ok", banks: [...banks.values()] } : { kind: "unavailable" };
    },

    async resolve(bankCode, accountNumber, signal) {
      if (!bankCodePattern.test(bankCode) || !accountNumberPattern.test(accountNumber)) {
        return { kind: "not_found" };
      }
      try {
        const { status, body } = await get(
          "/bank/resolve",
          { account_number: accountNumber, bank_code: bankCode },
          signal,
        );
        const envelope = object(body);
        if ((status === 400 || status === 422) && envelope?.status === false) {
          return { kind: "not_found" };
        }
        const data = object(envelope?.data);
        const accountName = safeName(data?.account_name);
        // The answer must be about the account we asked for (legacy rule).
        if (
          status !== 200 || envelope?.status !== true || data?.account_number !== accountNumber ||
          !accountName
        ) {
          return { kind: "unavailable" };
        }
        return { kind: "resolved", accountName };
      } catch (error) {
        return error instanceof Unavailable && error.retryAfterSeconds !== undefined
          ? { kind: "unavailable", retryAfterSeconds: error.retryAfterSeconds }
          : { kind: "unavailable" };
      }
    },
  };
}

export type FakeAnswer = string | "not_found" | "unavailable";

export interface FakeFixtures {
  /** `bankCode:accountNumber` → account name, `not_found` or `unavailable`. */
  readonly accounts: Readonly<Record<string, FakeAnswer>>;
  readonly banks?: readonly Bank[] | "unavailable";
}

/** Test double. index.ts never builds it; there is no switch to enable it. */
export function fakeProvider(fixtures: FakeFixtures): NameLookupProvider & {
  readonly calls: string[];
} {
  const calls: string[] = [];
  return {
    id: "fake",
    calls,
    listBanks() {
      calls.push("listBanks");
      const banks = fixtures.banks ?? [];
      return Promise.resolve(
        banks === "unavailable" ? { kind: "unavailable" } : { kind: "ok", banks },
      );
    },
    resolve(bankCode, accountNumber) {
      calls.push(`resolve:${bankCode}`);
      const answer = fixtures.accounts[`${bankCode}:${accountNumber}`] ?? "not_found";
      if (answer === "not_found") return Promise.resolve({ kind: "not_found" });
      if (answer === "unavailable") {
        return Promise.resolve({ kind: "unavailable", retryAfterSeconds: 30 });
      }
      return Promise.resolve({ kind: "resolved", accountName: answer });
    },
  };
}
