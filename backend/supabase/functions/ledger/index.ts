import { createClient } from "@supabase/supabase-js";
import { type Actor, createHandler } from "./handler.ts";

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing environment variable ${name}`);
  return value;
}

const bucket = "financial-evidence";
const url = env("SUPABASE_URL");
const options = { auth: { persistSession: false, autoRefreshToken: false } };
const service = createClient(url, env("SUPABASE_SERVICE_ROLE_KEY"), options);
const publicClient = createClient(url, env("SUPABASE_ANON_KEY"), options);

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
  async signUpload(path) {
    const { data, error } = await service.storage.from(bucket)
      .createSignedUploadUrl(path);
    return error || !data ? null : { url: data.signedUrl, token: data.token };
  },
  async download(path, maxBytes) {
    const { data, error } = await service.storage.from(bucket).download(path);
    if (error || !data) return null;
    if (data.size > maxBytes) return { size: data.size, bytes: null };
    return { size: data.size, bytes: new Uint8Array(await data.arrayBuffer()) };
  },
  log: (entry) => console.log(JSON.stringify(entry)),
  allowedOrigins: (Deno.env.get("CORS_ORIGINS") ?? "").split(",").map((o) => o.trim()).filter(
    Boolean,
  ),
});

Deno.serve(handler);
