import { createClient } from "@supabase/supabase-js";
import { createAccountCrypto } from "../_shared/account_crypto.ts";
import { createOpenAiExtractor } from "./extract.ts";
import { createHandler } from "./handler.ts";

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing environment variable ${name}`);
  return value;
}

function optional(name: string): string | null {
  const value = Deno.env.get(name)?.trim();
  return value ? value : null;
}

const service = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { persistSession: false, autoRefreshToken: false },
});

const accountCrypto = await createAccountCrypto({
  encryption: new Map([[1, env("PAYOUT_ACCOUNT_ENC_KEY")]]),
  currentVersion: 1,
  fingerprint: env("PAYOUT_ACCOUNT_HMAC_KEY"),
});

// Without the OpenAI key and model the worker claims nothing, so checks stay
// queued without burning attempts.
const apiKey = optional("OPENAI_API_KEY");
const model = optional("OPENAI_RECEIPT_MODEL");

const handler = createHandler({
  async rpc(fn, args) {
    const { data, error } = await service.schema("api").rpc(fn, args);
    return error
      ? { data: null, error: { message: error.message, details: error.details } }
      : { data, error: null };
  },
  workerSecret: optional("PAYOUT_CHECKER_SECRET"),
  extractor: apiKey && model ? createOpenAiExtractor(apiKey, model) : null,
  async download(path, maxBytes) {
    const { data, error } = await service.storage.from("financial-evidence").download(path);
    if (error || !data || data.size > maxBytes) return null;
    return new Uint8Array(await data.arrayBuffer());
  },
  openAccount: (owner, ciphertext, keyVersion) => accountCrypto.open(owner, ciphertext, keyVersion),
  workerId: `edge:${crypto.randomUUID()}`,
  log: (entry) => console.log(JSON.stringify(entry)),
});

Deno.serve(handler);
