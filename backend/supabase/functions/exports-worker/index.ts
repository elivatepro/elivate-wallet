import { createClient } from "@supabase/supabase-js";
import { createHandler } from "./handler.ts";

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing environment variable ${name}`);
  return value;
}

const service = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { persistSession: false, autoRefreshToken: false },
});

const handler = createHandler({
  async rpc(fn, args) {
    const { data, error } = await service.schema("api").rpc(fn, args);
    return error
      ? { data: null, error: { message: error.message, details: error.details } }
      : { data, error: null };
  },
  workerSecret: Deno.env.get("EXPORTS_WORKER_SECRET")?.trim() || null,
  log: (entry) => console.log(JSON.stringify(entry)),
});

Deno.serve(handler);
