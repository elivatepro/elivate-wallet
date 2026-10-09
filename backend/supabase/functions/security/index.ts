import { createClient } from "@supabase/supabase-js";
import { createPinHasher } from "../_shared/pin.ts";
import { type Actor, createHandler } from "./handler.ts";

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing environment variable ${name}`);
  return value;
}

const url = env("SUPABASE_URL");
const anonKey = env("SUPABASE_ANON_KEY");
const options = { auth: { persistSession: false, autoRefreshToken: false } };
const service = createClient(url, env("SUPABASE_SERVICE_ROLE_KEY"), options);
const publicClient = createClient(url, anonKey, options);
const pinHmac = await createPinHasher(env("PIN_HMAC_SECRET"));
const resetRedirect = env("PIN_RESET_REDIRECT_URL");

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
  pinHmac,
  async sendResetLink(userId) {
    const { data, error } = await service.auth.admin.getUserById(userId);
    const email = data?.user?.email;
    if (error || !email) throw new Error("account email unavailable");
    const sent = await publicClient.auth.signInWithOtp({
      email,
      options: { shouldCreateUser: false, emailRedirectTo: resetRedirect },
    });
    if (sent.error) throw new Error("reset email not sent");
  },
  log: (entry) => console.log(JSON.stringify(entry)),
  appServerSecret: Deno.env.get("APP_SERVER_SECRET") || null,
  allowedOrigins: (Deno.env.get("CORS_ORIGINS") ?? "").split(",").map((o) => o.trim()).filter(
    Boolean,
  ),
});

Deno.serve(handler);
