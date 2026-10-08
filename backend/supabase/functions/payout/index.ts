import { createClient } from "@supabase/supabase-js";
import { createAccountCrypto } from "../_shared/account_crypto.ts";
import { type NameLookupProvider, paystackProvider } from "../_shared/name_lookup.ts";
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

// The account keys are required: without them no number can be stored safely.
const accountCrypto = await createAccountCrypto({
  encryption: new Map([[1, env("PAYOUT_ACCOUNT_ENC_KEY")]]),
  currentVersion: 1,
  fingerprint: env("PAYOUT_ACCOUNT_HMAC_KEY"),
});

// Paystack is optional at start-up: without a usable key, lookups and bank
// refreshes answer provider_unavailable and everything else keeps working.
function provider(): NameLookupProvider | null {
  const key = Deno.env.get("PAYSTACK_SECRET_KEY");
  if (!key) {
    console.log(JSON.stringify({ event: "paystack_not_configured" }));
    return null;
  }
  try {
    return paystackProvider(key);
  } catch {
    console.log(JSON.stringify({ event: "paystack_key_malformed" }));
    return null;
  }
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
  accountCrypto,
});

Deno.serve(handler);
