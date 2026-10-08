// PIN hashing step 1 (A-05): HMAC-SHA256 with a server-only secret. Postgres
// applies bcrypt to this value; the raw PIN never leaves the Edge Function.

const encoder = new TextEncoder();

export async function createPinHasher(
  secretHex: string,
): Promise<(pin: string) => Promise<string>> {
  if (!/^[0-9a-f]{64}$/i.test(secretHex)) {
    throw new Error("PIN_HMAC_SECRET must be 32 bytes as 64 hex characters");
  }
  const raw = new Uint8Array(32);
  for (let i = 0; i < 32; i++) raw[i] = parseInt(secretHex.slice(i * 2, i * 2 + 2), 16);
  const key = await crypto.subtle.importKey(
    "raw",
    raw,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return async (pin: string) => {
    const signature = new Uint8Array(
      await crypto.subtle.sign("HMAC", key, encoder.encode(pin)),
    );
    return Array.from(signature, (byte) => byte.toString(16).padStart(2, "0")).join("");
  };
}
