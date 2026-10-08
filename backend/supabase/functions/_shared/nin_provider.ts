// NIN verification (Blueprint 06 — B3). Provider: NUBAN KYC data API
// (owner decision Q1), `GET {base}/api/nin-data?nin_no=<11 digits>` with a
// Bearer key. The response shape is not documented publicly, so parsing is
// defensive but strict: only a record carrying a first name and a surname
// counts as found. A 2xx without names is treated as an outage (never burns a
// check). Nothing but the legal name and, when present, the phone leaves this
// module: no photo, address, date of birth or raw body.

export interface NinRecord {
  readonly givenName: string;
  readonly middleNames: readonly string[];
  readonly surname: string;
  readonly phone: string | null;
}

export type NinOutcome =
  | { readonly kind: "found"; readonly record: NinRecord }
  | { readonly kind: "not_found" }
  | { readonly kind: "unavailable"; readonly shape?: readonly string[] };

export interface NinProvider {
  verify(nin: string): Promise<NinOutcome>;
}

export const ninPattern = /^[0-9]{11}$/;

const encoder = new TextEncoder();

/** Hex HMAC-SHA256(key, "nin:v1:" + nin): what the database stores. */
export async function ninFingerprint(keyHex: string, nin: string): Promise<string> {
  if (!/^[0-9a-f]{64}$/i.test(keyHex)) throw new Error("NIN_FINGERPRINT_KEY must be 64 hex chars");
  const bytes = new Uint8Array(keyHex.length / 2);
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(keyHex.slice(i * 2, i * 2 + 2), 16);
  const key = await crypto.subtle.importKey(
    "raw",
    bytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    [
      "sign",
    ],
  );
  const mac = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, encoder.encode(`nin:v1:${nin}`)),
  );
  return Array.from(mac, (b) => b.toString(16).padStart(2, "0")).join("");
}

const normalizeKey = (key: string) => key.toLowerCase().replace(/[^a-z0-9]/g, "");

const FIRST = ["firstname", "givenname"];
const MIDDLE = ["middlename", "othernames", "othername"];
const SURNAME = ["surname", "lastname", "familyname"];
const PHONE = ["telephoneno", "phone", "phonenumber", "mobile", "telephone"];

type Json = Record<string, unknown>;

function field(record: Json, names: readonly string[]): string | null {
  for (const [key, value] of Object.entries(record)) {
    if (names.includes(normalizeKey(key)) && typeof value === "string" && value.trim() !== "") {
      return value.trim();
    }
  }
  return null;
}

/** The nearest object (breadth-first, depth ≤ 4) holding both a first name and a surname. */
function findPerson(payload: unknown): Json | null {
  let level: unknown[] = [payload];
  for (let depth = 0; depth <= 4 && level.length > 0; depth++) {
    const next: unknown[] = [];
    for (const node of level) {
      if (Array.isArray(node)) {
        next.push(...node);
        continue;
      }
      if (typeof node !== "object" || node === null) continue;
      const record = node as Json;
      if (field(record, FIRST) && field(record, SURNAME)) return record;
      next.push(...Object.values(record));
    }
    level = next;
  }
  return null;
}

/** Letters (any script), spaces, hyphens, apostrophes and dots; 1–80 characters. */
export function cleanName(value: string | null): string | null {
  if (value === null) return null;
  const cleaned = value.replace(/\s+/g, " ").trim();
  if (cleaned.length < 1 || cleaned.length > 80) return null;
  if (!/^[\p{L}\p{M}' .-]+$/u.test(cleaned)) return null;
  // Records often arrive upper-case; keep the provider's letters, title-case words.
  return cleaned.toLowerCase().replace(
    /(^|[\s'-])(\p{L})/gu,
    (_, sep, ch) => sep + ch.toUpperCase(),
  );
}

/** Nigerian numbers as 0XXXXXXXXXX or +234XXXXXXXXXX; anything else is dropped. */
export function cleanPhone(value: string | null): string | null {
  if (value === null) return null;
  const digits = value.replace(/[\s-]/g, "");
  return /^\+?[0-9]{7,15}$/.test(digits) ? digits : null;
}

/** Top-level key names only, for diagnosing a shape change without logging data. */
function shapeOf(payload: unknown): string[] {
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) return [];
  return Object.keys(payload).slice(0, 20).map(normalizeKey);
}

/** A 2xx that plainly says no record: `status`/`success` false or a "not found" message. */
function saysNotFound(payload: unknown): boolean {
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) return false;
  const record = payload as Json;
  const flag = record.status ?? record.success;
  const message = typeof record.message === "string" ? record.message.toLowerCase() : "";
  return flag === false || /not found|no record|invalid nin|does not exist/.test(message);
}

export function parseNinResponse(payload: unknown): NinOutcome {
  const person = findPerson(payload);
  if (!person) {
    return saysNotFound(payload)
      ? { kind: "not_found" }
      : { kind: "unavailable", shape: shapeOf(payload) };
  }
  const givenName = cleanName(field(person, FIRST));
  const surname = cleanName(field(person, SURNAME));
  if (!givenName || !surname) return { kind: "unavailable", shape: shapeOf(payload) };
  const middle = cleanName(field(person, MIDDLE));
  return {
    kind: "found",
    record: {
      givenName,
      middleNames: middle ? middle.split(" ").slice(0, 4) : [],
      surname,
      phone: cleanPhone(field(person, PHONE)),
    },
  };
}

export interface NubanKycOptions {
  readonly baseUrl?: string;
  readonly timeoutMs?: number;
  readonly fetch?: typeof fetch;
}

export function nubanKycProvider(apiKey: string, options: NubanKycOptions = {}): NinProvider {
  if (!apiKey.trim()) throw new Error("NUBAN_KYC_API_KEY is empty");
  const base = (options.baseUrl ?? "https://api-kycdata.nuban.com.ng").replace(/\/+$/, "");
  const doFetch = options.fetch ?? fetch;
  const timeoutMs = options.timeoutMs ?? 10_000;
  return {
    async verify(nin) {
      if (!ninPattern.test(nin)) return { kind: "not_found" };
      const url = new URL("/api/nin-data", base);
      url.searchParams.set("nin_no", nin);
      let response: Response;
      try {
        response = await doFetch(url.toString(), {
          headers: { accept: "application/json", authorization: `Bearer ${apiKey}` },
          signal: AbortSignal.timeout(timeoutMs),
          redirect: "error",
        });
      } catch {
        return { kind: "unavailable" };
      }
      if ([400, 404, 422].includes(response.status)) {
        await response.body?.cancel();
        return { kind: "not_found" };
      }
      if (!response.ok) {
        await response.body?.cancel();
        return { kind: "unavailable" };
      }
      const payload = await response.json().catch(() => null);
      return parseNinResponse(payload);
    },
  };
}

/** Test double: NINs mapped to records, "not_found" or "unavailable". */
export function fakeNinProvider(
  fixtures: Readonly<Record<string, NinRecord | "not_found" | "unavailable">>,
): NinProvider & { readonly calls: string[] } {
  const calls: string[] = [];
  return {
    calls,
    verify(nin) {
      calls.push(nin);
      const answer = fixtures[nin] ?? "not_found";
      if (answer === "not_found") return Promise.resolve({ kind: "not_found" });
      if (answer === "unavailable") return Promise.resolve({ kind: "unavailable" });
      return Promise.resolve({ kind: "found", record: answer });
    },
  };
}
