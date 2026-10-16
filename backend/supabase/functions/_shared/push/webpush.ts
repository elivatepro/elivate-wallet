// Web Push on WebCrypto, no dependency (Blueprint 42 — B3): RFC 8291 message
// encryption (aes128gcm, RFC 8188) and RFC 8292 VAPID. The push service sees
// only the encrypted body. Sends go only to the browsers' own push services
// (the same allow-list as the database); local tests may redirect them to a
// loopback fake.

export interface PushDevice {
  readonly endpoint: string;
  /** base64url, an uncompressed P-256 point (65 bytes). */
  readonly p256dh: string;
  /** base64url, 16 bytes. */
  readonly auth: string;
}

export interface Vapid {
  /** base64url, 65 bytes. */
  readonly publicKey: string;
  /** base64url, the 32-byte private scalar. */
  readonly privateKey: string;
  /** mailto: or https: contact for the push services. */
  readonly subject: string;
}

export type PushOutcome =
  | { readonly outcome: "sent"; readonly providerStatus: number }
  | {
    readonly outcome: "retryable_failure" | "gone" | "permanent_failure";
    readonly providerStatus: number | null;
    readonly errorCode: string;
  };

export interface PushMessage {
  readonly payload: Uint8Array;
  /** Seconds the push service keeps an undelivered message. */
  readonly ttl: number;
  readonly urgency: "high" | "normal";
  /** ≤ 32 URL-safe characters: a newer message with the same topic replaces it. */
  readonly topic: string;
}

export interface PushTransport {
  send(device: PushDevice, message: PushMessage): Promise<PushOutcome>;
}

const encoder = new TextEncoder();

export function fromBase64Url(value: string): Uint8Array {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

export function toBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

async function hmac(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
  ]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, data));
}

/** The P-256 JWK for a raw public point and, optionally, its private scalar. */
function p256Jwk(publicKey: Uint8Array, privateKey?: Uint8Array): JsonWebKey {
  if (publicKey.length !== 65 || publicKey[0] !== 4) throw new Error("bad P-256 public key");
  return {
    kty: "EC",
    crv: "P-256",
    x: toBase64Url(publicKey.slice(1, 33)),
    y: toBase64Url(publicKey.slice(33, 65)),
    ...(privateKey ? { d: toBase64Url(privateKey) } : {}),
    ext: true,
  };
}

export interface LocalKeys {
  readonly publicKey: Uint8Array;
  readonly privateKey: CryptoKey;
}

async function freshKeys(): Promise<LocalKeys> {
  const pair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, [
    "deriveBits",
  ]) as CryptoKeyPair;
  return {
    publicKey: new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey)),
    privateKey: pair.privateKey,
  };
}

/** Imports a known sender key pair (test vectors only). */
export async function importLocalKeys(publicKey: string, privateKey: string): Promise<LocalKeys> {
  const pub = fromBase64Url(publicKey);
  return {
    publicKey: pub,
    privateKey: await crypto.subtle.importKey(
      "jwk",
      p256Jwk(pub, fromBase64Url(privateKey)),
      { name: "ECDH", namedCurve: "P-256" },
      false,
      ["deriveBits"],
    ),
  };
}

const RECORD_SIZE = 4096;

/**
 * RFC 8291 §3–4: one aes128gcm record. `salt` and `keys` are fresh per
 * message unless given (test vectors).
 */
export async function encrypt(
  plaintext: Uint8Array,
  device: Pick<PushDevice, "p256dh" | "auth">,
  options: { readonly salt?: Uint8Array; readonly keys?: LocalKeys } = {},
): Promise<Uint8Array> {
  const uaPublic = fromBase64Url(device.p256dh);
  const authSecret = fromBase64Url(device.auth);
  if (authSecret.length !== 16) throw new Error("bad auth secret");
  const salt = options.salt ?? crypto.getRandomValues(new Uint8Array(16));
  const keys = options.keys ?? await freshKeys();

  const uaKey = await crypto.subtle.importKey(
    "jwk",
    p256Jwk(uaPublic),
    { name: "ECDH", namedCurve: "P-256" },
    false,
    [],
  );
  const ecdhSecret = new Uint8Array(
    await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, keys.privateKey, 256),
  );

  const prkKey = await hmac(authSecret, ecdhSecret);
  const keyInfo = concat(encoder.encode("WebPush: info\0"), uaPublic, keys.publicKey);
  const ikm = await hmac(prkKey, concat(keyInfo, new Uint8Array([1])));
  const prk = await hmac(salt, ikm);
  const cek = (await hmac(prk, encoder.encode("Content-Encoding: aes128gcm\0\x01"))).slice(0, 16);
  const nonce = (await hmac(prk, encoder.encode("Content-Encoding: nonce\0\x01"))).slice(0, 12);

  if (plaintext.length + 1 + 16 > RECORD_SIZE) throw new Error("payload too large");
  const aes = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: nonce },
      aes,
      concat(plaintext, new Uint8Array([2])),
    ),
  );

  const header = new Uint8Array(16 + 4 + 1);
  header.set(salt, 0);
  new DataView(header.buffer).setUint32(16, RECORD_SIZE);
  header[20] = keys.publicKey.length;
  return concat(header, keys.publicKey, ciphertext);
}

/** RFC 8292: `vapid t=<ES256 JWT>, k=<public key>` for the endpoint's origin. */
export async function vapidAuthorization(
  endpoint: string,
  vapid: Vapid,
  now: Date = new Date(),
): Promise<string> {
  const audience = new URL(endpoint).origin;
  const header = toBase64Url(encoder.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const claims = toBase64Url(encoder.encode(JSON.stringify({
    aud: audience,
    exp: Math.floor(now.getTime() / 1000) + 12 * 60 * 60,
    sub: vapid.subject,
  })));
  const key = await crypto.subtle.importKey(
    "jwk",
    p256Jwk(fromBase64Url(vapid.publicKey), fromBase64Url(vapid.privateKey)),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      encoder.encode(`${header}.${claims}`),
    ),
  );
  return `vapid t=${header}.${claims}.${toBase64Url(signature)}, k=${vapid.publicKey}`;
}

const ALLOWED_HOST =
  /^(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|([a-z0-9-]+\.)+push\.apple\.com|([a-z0-9-]+\.)+notify\.windows\.com)$/;

/** The SSRF guard, as in notify.push_endpoint_allowed. */
export function endpointAllowed(endpoint: string): boolean {
  if (endpoint.length > 1000 || !/^[!-~]+$/.test(endpoint)) return false;
  try {
    const url = new URL(endpoint);
    return url.protocol === "https:" && url.port === "" && url.username === "" &&
      url.password === "" && ALLOWED_HOST.test(url.hostname) &&
      endpoint.startsWith(`https://${url.hostname}/`);
  } catch {
    return false;
  }
}

export interface TransportOptions {
  readonly vapid: Vapid;
  /** Local e2e only: a loopback origin that receives every push instead. */
  readonly testOrigin?: string;
  readonly timeoutMs?: number;
  readonly fetch?: typeof fetch;
}

export function createPushTransport(options: TransportOptions): PushTransport {
  const send = options.fetch ?? fetch;
  const timeoutMs = options.timeoutMs ?? 10_000;
  return {
    async send(device, message) {
      if (!endpointAllowed(device.endpoint)) {
        return {
          outcome: "permanent_failure",
          providerStatus: null,
          errorCode: "push.host_not_allowed",
        };
      }
      let body: Uint8Array;
      let authorization: string;
      try {
        body = await encrypt(message.payload, device);
        authorization = await vapidAuthorization(device.endpoint, options.vapid);
      } catch {
        return { outcome: "permanent_failure", providerStatus: null, errorCode: "push.bad_keys" };
      }
      const url = options.testOrigin
        ? `${options.testOrigin}${new URL(device.endpoint).pathname}`
        : device.endpoint;
      let response: Response;
      try {
        response = await send(url, {
          method: "POST",
          headers: {
            authorization,
            "content-encoding": "aes128gcm",
            "content-type": "application/octet-stream",
            ttl: String(message.ttl),
            urgency: message.urgency,
            topic: message.topic,
          },
          body,
          redirect: "manual",
          signal: AbortSignal.timeout(timeoutMs),
        });
        await response.body?.cancel();
      } catch (error) {
        return {
          outcome: "retryable_failure",
          providerStatus: null,
          errorCode: error instanceof DOMException && error.name === "TimeoutError"
            ? "push.timeout"
            : "push.network",
        };
      }
      const status = response.status;
      if (status >= 200 && status < 300) return { outcome: "sent", providerStatus: status };
      if (status === 404 || status === 410) {
        return { outcome: "gone", providerStatus: status, errorCode: "push.gone" };
      }
      if (status === 429 || status >= 500) {
        return {
          outcome: "retryable_failure",
          providerStatus: status,
          errorCode: "push.unavailable",
        };
      }
      return { outcome: "permanent_failure", providerStatus: status, errorCode: "push.rejected" };
    },
  };
}
