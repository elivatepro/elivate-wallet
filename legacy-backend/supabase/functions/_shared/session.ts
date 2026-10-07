import { DomainError } from "../../../src/shared/domain_error.ts";

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const denied = () =>
  new DomainError(
    "authentication_required",
    "A valid authenticated session is required",
  );

/** The exact bearer token must pass remote Auth verification before its claims are read. */
export async function verifySession(
  token: string,
  verifyUser: (token: string) => Promise<string | null>,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<
  Readonly<
    { userId: string; sessionId: string; stepUpSessionId: string | null }
  >
> {
  const userId = await verifyUser(token);
  if (userId === null) throw denied();
  try {
    const parts = token.split(".");
    const encoded = parts[1];
    if (parts.length !== 3 || !encoded) throw denied();
    const base64 = encoded.replaceAll("-", "+").replaceAll("_", "/");
    const binary = atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, "="));
    const claims: unknown = JSON.parse(
      new TextDecoder().decode(
        Uint8Array.from(binary, (char) => char.charCodeAt(0)),
      ),
    );
    if (
      typeof claims !== "object" || claims === null || Array.isArray(claims)
    ) throw denied();
    const payload = claims as Record<string, unknown>;
    const audience = payload.aud;
    if (
      payload.sub !== userId || payload.role !== "authenticated" ||
      !(audience === "authenticated" ||
        (Array.isArray(audience) && audience.includes("authenticated"))) ||
      typeof payload.exp !== "number" || !Number.isFinite(payload.exp) ||
      payload.exp <= nowSeconds ||
      typeof payload.session_id !== "string" || !uuid.test(payload.session_id)
    ) throw denied();
    return {
      userId,
      sessionId: payload.session_id,
      stepUpSessionId: payload.aal === "aal2" ? payload.session_id : null,
    };
  } catch {
    throw denied();
  }
}

/** Commands with mandatory step-up cannot forward a password-only session. */
export function requireStepUpSession(sessionId: string | null): string {
  if (sessionId === null) {
    throw new DomainError(
      "step_up_required",
      "Verify your authenticator before this action",
    );
  }
  return sessionId;
}
