import { createClient } from "@supabase/supabase-js";
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
const tokens = await createInviteTokens(env("INVITATION_TOKEN_SECRET"));
// Auth's sign-in email lands on the invitation page; it carries no token.
const appOrigin = env("APP_ORIGIN").replace(/\/+$/, "");

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
  issueToken: () => tokens.issue(),
  async sendSignInLink(email, page) {
    const sent = await publicClient.auth.signInWithOtp({
      email,
      options: { shouldCreateUser: true, emailRedirectTo: `${appOrigin}/${page}` },
    });
    if (sent.error) throw new Error("sign-in email not sent");
  },
  log: (entry) => console.log(JSON.stringify(entry)),
  allowedOrigins: (Deno.env.get("CORS_ORIGINS") ?? "").split(",").map((o) => o.trim()).filter(
    Boolean,
  ),
  appServerSecret: Deno.env.get("APP_SERVER_SECRET") || null,
});

Deno.serve(handler);
