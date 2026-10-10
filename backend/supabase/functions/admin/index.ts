import { createClient } from "@supabase/supabase-js";
import { createAccountCrypto } from "../_shared/account_crypto.ts";
import { createInviteTokens } from "../_shared/invite_token.ts";
import { type Actor, createHandler } from "./handler.ts";

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing environment variable ${name}`);
  return value;
}

const url = env("SUPABASE_URL");
const options = { auth: { persistSession: false, autoRefreshToken: false } };
const service = createClient(url, env("SUPABASE_SERVICE_ROLE_KEY"), options);
const publicClient = createClient(url, env("SUPABASE_ANON_KEY"), options);

// Bank-account search fingerprints with the same key the payout function uses.
const accountCrypto = await createAccountCrypto({
  encryption: new Map([[1, env("PAYOUT_ACCOUNT_ENC_KEY")]]),
  currentVersion: 1,
  fingerprint: env("PAYOUT_ACCOUNT_HMAC_KEY"),
});

// Founder invitation links (Blueprint 19) use the invitation token secret.
const tokens = await createInviteTokens(env("INVITATION_TOKEN_SECRET"));

const handler = createHandler({
  async verifyToken(token): Promise<Actor | null> {
    const { data, error } = await publicClient.auth.getClaims(token);
    const claims = data?.claims;
    if (
      error || !claims || typeof claims.sub !== "string" ||
      typeof claims.session_id !== "string"
    ) {
      return null;
    }
    return { userId: claims.sub, sessionId: claims.session_id };
  },
  async rpc(fn, args) {
    const { data, error } = await service.schema("api").rpc(fn, args);
    return error
      ? {
        data: null,
        error: { message: error.message, details: error.details },
      }
      : { data, error: null };
  },
  bankFingerprint: (bankCode, accountNumber) => accountCrypto.fingerprint(bankCode, accountNumber),
  issueToken: () => tokens.issue(),
  log: (entry) => console.log(JSON.stringify(entry)),
  appServerSecret: Deno.env.get("APP_SERVER_SECRET") || null,
  allowedOrigins: (Deno.env.get("CORS_ORIGINS") ?? "").split(",").map((o) => o.trim()).filter(
    Boolean,
  ),
});

Deno.serve(handler);
