// Evidence file facts shared by the upload finalizer and the payout checker.

export const evidenceMimeTypes = ["application/pdf", "image/jpeg", "image/png"] as const;
export type EvidenceMime = (typeof evidenceMimeTypes)[number];

/** Detects PDF, JPEG or PNG from the first bytes; null for anything else. */
export function sniffMime(bytes: Uint8Array): EvidenceMime | null {
  const starts = (sig: number[]) => sig.every((b, i) => bytes[i] === b);
  if (starts([0x25, 0x50, 0x44, 0x46, 0x2d])) return "application/pdf";
  if (starts([0xff, 0xd8, 0xff])) return "image/jpeg";
  if (starts([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    return "image/png";
  }
  return null;
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(bytes)));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}
