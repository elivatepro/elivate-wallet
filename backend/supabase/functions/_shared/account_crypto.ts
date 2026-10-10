// Bank account number protection (Blueprint 05 — B2, Q5-B). The database only
// ever stores AES-256-GCM ciphertext, an HMAC-SHA256 fingerprint and the last
// 4 digits. Keys are 32 random bytes as 64 hex characters.

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export interface SealedNumber {
  readonly ciphertext: string;
  readonly keyVersion: number;
  readonly fingerprint: string;
  readonly last4: string;
}

export interface AccountCrypto {
  /** Encrypts a 10-digit number for one owner and fingerprints it for one bank. */
  seal(
    ownerUserId: string,
    bankCode: string,
    accountNumber: string,
  ): Promise<SealedNumber>;
  /** Decrypts a stored number; fails unless owner and key version match. */
  open(
    ownerUserId: string,
    ciphertext: string,
    keyVersion: number,
  ): Promise<string>;
  /** The stored fingerprint of a 10-digit number at one bank (admin search, W-23). */
  fingerprint(bankCode: string, accountNumber: string): Promise<string>;
}

export interface AccountKeys {
  /** Encryption keys by version, each 64 hex characters. */
  readonly encryption: ReadonlyMap<number, string>;
  /** Version used for new ciphertext. */
  readonly currentVersion: number;
  /** Fingerprint key, 64 hex characters. */
  readonly fingerprint: string;
}

const accountNumberPattern = /^[0-9]{10}$/;

function hexKey(value: string, name: string) {
  if (!/^[0-9a-f]{64}$/i.test(value)) {
    throw new Error(`${name} must be 32 bytes as 64 hex characters`);
  }
  const raw = new Uint8Array(32);
  for (let i = 0; i < 32; i++) {
    raw[i] = parseInt(value.slice(i * 2, i * 2 + 2), 16);
  }
  return raw;
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function fromBase64(value: string) {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function aad(ownerUserId: string, keyVersion: number) {
  return encoder.encode(
    `payout-account:v${keyVersion}:${ownerUserId.toLowerCase()}`,
  );
}

export async function createAccountCrypto(
  keys: AccountKeys,
): Promise<AccountCrypto> {
  if (keys.encryption.size === 0 || !keys.encryption.has(keys.currentVersion)) {
    throw new Error("PAYOUT_ACCOUNT_ENC_KEY is missing");
  }
  const encryptionKeys = new Map<number, CryptoKey>();
  const fingerprintRaw = hexKey(keys.fingerprint, "PAYOUT_ACCOUNT_HMAC_KEY");
  for (const [version, value] of keys.encryption) {
    if (!Number.isInteger(version) || version < 1 || version > 32767) {
      throw new Error("Payout account key versions are 1..32767");
    }
    const raw = hexKey(value, "PAYOUT_ACCOUNT_ENC_KEY");
    if (raw.every((byte, i) => byte === fingerprintRaw[i])) {
      throw new Error(
        "PAYOUT_ACCOUNT_ENC_KEY and PAYOUT_ACCOUNT_HMAC_KEY must differ",
      );
    }
    encryptionKeys.set(
      version,
      await crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, [
        "encrypt",
        "decrypt",
      ]),
    );
  }
  const fingerprintKey = await crypto.subtle.importKey(
    "raw",
    fingerprintRaw,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );

  async function fingerprintOf(
    bankCode: string,
    accountNumber: string,
  ): Promise<string> {
    const signature = new Uint8Array(
      await crypto.subtle.sign(
        "HMAC",
        fingerprintKey,
        encoder.encode(`${bankCode}:${accountNumber}`),
      ),
    );
    return Array.from(signature, (b) => b.toString(16).padStart(2, "0")).join(
      "",
    );
  }

  return {
    async fingerprint(bankCode, accountNumber) {
      if (!accountNumberPattern.test(accountNumber)) {
        throw new Error("invalid account number");
      }
      return await fingerprintOf(bankCode, accountNumber);
    },

    async seal(ownerUserId, bankCode, accountNumber) {
      if (!accountNumberPattern.test(accountNumber)) {
        throw new Error("invalid account number");
      }
      const keyVersion = keys.currentVersion;
      const key = encryptionKeys.get(keyVersion);
      if (!key) throw new Error("encryption key unavailable");
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const sealed = new Uint8Array(
        await crypto.subtle.encrypt(
          { name: "AES-GCM", iv, additionalData: aad(ownerUserId, keyVersion) },
          key,
          encoder.encode(accountNumber),
        ),
      );
      const packed = new Uint8Array(iv.length + sealed.length);
      packed.set(iv);
      packed.set(sealed, iv.length);
      return {
        ciphertext: toBase64(packed),
        keyVersion,
        fingerprint: await fingerprintOf(bankCode, accountNumber),
        last4: accountNumber.slice(-4),
      };
    },

    async open(ownerUserId, ciphertext, keyVersion) {
      const key = encryptionKeys.get(keyVersion);
      if (!key) throw new Error("encryption key unavailable");
      const packed = fromBase64(ciphertext);
      if (packed.length < 12 + 16 + 1) throw new Error("ciphertext too short");
      const plain = await crypto.subtle.decrypt(
        {
          name: "AES-GCM",
          iv: packed.slice(0, 12),
          additionalData: aad(ownerUserId, keyVersion),
        },
        key,
        packed.slice(12),
      );
      const accountNumber = decoder.decode(plain);
      if (!accountNumberPattern.test(accountNumber)) {
        throw new Error("unexpected plaintext");
      }
      return accountNumber;
    },
  };
}
