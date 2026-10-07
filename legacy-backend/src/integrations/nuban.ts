import { DomainError } from "../shared/domain_error.ts";

export type ResolvedBankAccount = Readonly<{
  bankCode: string;
  accountNumber: string;
  accountHolderName: string;
  institutionName: string;
}>;
const invalid = () =>
  new DomainError("validation_error", "Bank account could not be confirmed");
const unavailable = () =>
  new DomainError(
    "internal_error",
    "Bank verification is unavailable. Try again",
    { retryable: true },
  );
function object(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}
function safeName(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0 &&
    value.length <= 160 &&
    !Array.from(value).some((character) =>
      character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127
    );
}
/** Provider output is bound to both requested identifiers; an unrelated first result is never accepted. */
export function parseNubanResolution(
  value: unknown,
  bankCode: string,
  accountNumber: string,
): ResolvedBankAccount {
  const envelope = object(value);
  if (
    envelope?.verified === false || envelope?.success === false ||
    envelope?.status === false
  ) throw invalid();
  const rows: unknown = Array.isArray(value)
    ? value
    : envelope?.data ?? envelope?.results;
  if (!Array.isArray(rows) || rows.length > 700) throw invalid();
  const matches = rows.map(object).filter((row) =>
    row?.bank_code === bankCode && row.account_number === accountNumber
  );
  if (matches.length !== 1) throw invalid();
  const match = matches[0];
  if (
    !match || match.verified === false || match.success === false ||
    !safeName(match.account_name) || !safeName(match.bank_name)
  ) {
    throw invalid();
  }
  return {
    bankCode,
    accountNumber,
    accountHolderName: match.account_name.trim(),
    institutionName: match.bank_name.trim(),
  };
}
/** Fixed-origin, bounded server-only lookup. The provider key and raw response never enter errors or logs. */
export async function resolveNubanAccount(
  apiKey: string,
  bankCode: string,
  accountNumber: string,
  fetcher: typeof fetch = fetch,
  timeoutMs = 10000,
): Promise<ResolvedBankAccount> {
  if (!/^[0-9]{3,6}$/.test(bankCode) || !/^[0-9]{10}$/.test(accountNumber)) {
    throw invalid();
  }
  if (
    !apiKey || apiKey === "." || apiKey === ".." || apiKey.length > 512 ||
    Array.from(apiKey).some((character) =>
      character.charCodeAt(0) <= 32 || character.charCodeAt(0) === 127
    )
  ) {
    throw unavailable();
  }
  const url = new URL(
    "https://app.nuban.com.ng/api/" + encodeURIComponent(apiKey),
  );
  url.searchParams.set("bank_code", bankCode);
  url.searchParams.set("acc_no", accountNumber);
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), timeoutMs);
  try {
    const response = await fetcher(url, {
      method: "GET",
      redirect: "error",
      signal: abort.signal,
      headers: { accept: "application/json" },
    });
    if (!response.ok || !response.body) throw unavailable();
    const reader = response.body.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    try {
      while (true) {
        const result = await reader.read();
        if (result.done) break;
        size += result.value.byteLength;
        if (size > 262144) {
          await reader.cancel();
          throw unavailable();
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
    let parsed: unknown;
    try {
      parsed = JSON.parse(new TextDecoder().decode(bytes));
    } catch {
      throw unavailable();
    }
    return parseNubanResolution(parsed, bankCode, accountNumber);
  } catch (error) {
    if (error instanceof DomainError) throw error;
    throw unavailable();
  } finally {
    clearTimeout(timer);
  }
}
