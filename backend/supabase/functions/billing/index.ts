import { createClient } from "@supabase/supabase-js";
import { localTestOrigin } from "../_shared/name_lookup.ts";
import { type PaystackBilling, paystackBilling } from "../_shared/paystack_billing.ts";
import { type Actor, createHandler } from "./handler.ts";

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing environment variable ${name}`);
  return value;
}

function optional(name: string): string | null {
  const value = Deno.env.get(name)?.trim();
  return value ? value : null;
}

const url = env("SUPABASE_URL");
const options = { auth: { persistSession: false, autoRefreshToken: false } };
const service = createClient(url, env("SUPABASE_SERVICE_ROLE_KEY"), options);
const publicClient = createClient(url, env("SUPABASE_ANON_KEY"), options);

// Without a usable key, payments answer provider_unavailable and the webhook
// fails closed (500), so Paystack keeps the event for a retry.
function paystack(): PaystackBilling | null {
  const key = optional("PAYSTACK_SECRET_KEY");
  if (!key) return null;
  try {
    // Local end-to-end only: a fake Paystack (tests/e2e/fake-providers.mjs).
    const testOrigin = localTestOrigin(optional("PAYSTACK_TEST_ORIGIN") ?? undefined);
    return paystackBilling(key, testOrigin ? { origin: testOrigin } : {});
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
  allowedOrigins: (optional("CORS_ORIGINS") ?? "").split(",").map((o) => o.trim()).filter(Boolean),
  paystack: paystack(),
  webhookSecret: optional("PAYSTACK_SECRET_KEY"),
  workerSecret: optional("BILLING_WORKER_SECRET"),
  appOrigin: optional("APP_ORIGIN"),
});

Deno.serve(handler);
