// Invitation link tokens (Blueprint 03 — B2). The database stores a random
// token id and the SHA-256 digest of the token, never the token. The token is
// HMAC-SHA256(INVITATION_TOKEN_SECRET, "inv:v1:" + tokenId), base64url, so the
// worker can rebuild the link from the token id and a database leak alone
// yields no usable link.

const encoder = new TextEncoder();

/** A link token as it appears in `#t=` (43 base64url characters). */
export const tokenPattern = /^[A-Za-z0-9_-]{43}$/;

function hexToBytes(hex: string) {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return bytes;
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Hex SHA-256 of the token; what the database stores and looks up. */
export async function tokenDigest(token: string): Promise<string> {
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(token)));
  return Array.from(hash, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export interface InviteTokens {
  /** Rebuilds the link token for a token id. */
  token(tokenId: string): Promise<string>;
  /** Draws a fresh token id and returns it with the digest to store. */
  issue(): Promise<{ readonly tokenId: string; readonly digest: string }>;
}

export async function createInviteTokens(secretHex: string): Promise<InviteTokens> {
  if (!/^[0-9a-f]{64}$/i.test(secretHex)) {
    throw new Error("INVITATION_TOKEN_SECRET must be 32 bytes as 64 hex characters");
  }
  const key = await crypto.subtle.importKey(
    "raw",
    hexToBytes(secretHex),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const token = async (tokenId: string) =>
    base64url(
      new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(`inv:v1:${tokenId}`))),
    );
  return {
    token,
    async issue() {
      const tokenId = crypto.randomUUID();
      return { tokenId, digest: await tokenDigest(await token(tokenId)) };
    },
  };
}

/** Join link. The token travels in the fragment, so it never reaches servers or logs. */
export function joinLink(appOrigin: string, token: string): string {
  return `${appOrigin.replace(/\/+$/, "")}/join#t=${token}`;
}
