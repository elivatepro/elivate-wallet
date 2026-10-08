import { createClient } from "@supabase/supabase-js";
import { ninFingerprint, type NinProvider, nubanKycProvider } from "../_shared/nin_provider.ts";
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

// Required: without it no NIN can be fingerprinted (one NIN, one account).
const fingerprintKey = env("NIN_FINGERPRINT_KEY");
await ninFingerprint(fingerprintKey, "00000000000");

// Optional at start-up: without a key, checks answer provider_unavailable.
function provider(): NinProvider | null {
  const key = Deno.env.get("NUBAN_KYC_API_KEY");
  if (!key) {
    console.log(JSON.stringify({ event: "nin_provider_not_configured" }));
    return null;
  }
  const baseUrl = Deno.env.get("NUBAN_KYC_BASE_URL");
  return nubanKycProvider(key, baseUrl ? { baseUrl } : {});
}

const handler = createHandler({
  async verifyToken(token): Promise<Actor | null> {
    const { data, error } = await publicClient.auth.getClaims(token);
    const claims = data?.claims;
    if (
      error || !claims || typeof claims.sub !== "string" || typeof claims.session_id !== "string"
    ) {
      return null;
    }
    return { userId: claims.sub, sessionId: claims.session_id };
  },
  async rpc(fn, args) {
    const { data, error } = await service.schema("api").rpc(fn, args);
    return error
      ? { data: null, error: { message: error.message, details: error.details } }
      : { data, error: null };
  },
  log: (entry) => console.log(JSON.stringify(entry)),
  allowedOrigins: (Deno.env.get("CORS_ORIGINS") ?? "").split(",").map((o) => o.trim()).filter(
    Boolean,
  ),
  provider: provider(),
  fingerprint: (nin) => ninFingerprint(fingerprintKey, nin),
});

Deno.serve(handler);
