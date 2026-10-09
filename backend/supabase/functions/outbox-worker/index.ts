import { createClient } from "@supabase/supabase-js";
import { createCloudflareTransport } from "../_shared/email/cloudflare.ts";
import { localTestOrigin } from "../_shared/name_lookup.ts";
import { createInviteTokens } from "../_shared/invite_token.ts";
import { createHandler, type EmailSetup } from "./handler.ts";

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

// Email sending needs every one of these; if any is missing the worker runs
// maintenance only and reports "email provider not configured".
async function emailSetup(): Promise<EmailSetup | null> {
  const accountId = optional("CLOUDFLARE_ACCOUNT_ID");
  const apiToken = optional("CLOUDFLARE_EMAIL_API_TOKEN");
  const fromAddress = optional("EMAIL_FROM_ADDRESS");
  const appOrigin = optional("APP_ORIGIN");
  const tokenSecret = optional("INVITATION_TOKEN_SECRET");
  if (!accountId || !apiToken || !fromAddress || !appOrigin || !tokenSecret) return null;
  const tokens = await createInviteTokens(tokenSecret);
  // Local end-to-end only (scripts/e2e-local.sh): a fake Cloudflare that hands
  // each message to the local mail catcher. Ignored unless it is a loopback
  // or host.docker.internal origin, so a hosted project always uses Cloudflare.
  const testBase = localTestOrigin(optional("CLOUDFLARE_API_TEST_ORIGIN") ?? undefined);
  return {
    transport: createCloudflareTransport({
      accountId,
      apiToken,
      fromAddress,
      fromName: optional("EMAIL_FROM_NAME") ?? "Elivate Wallet",
    }, testBase ? { apiBase: `${testBase}/client/v4` } : {}),
    token: (tokenId) => tokens.token(tokenId),
    appOrigin,
  };
}

const handler = createHandler({
  async rpc(fn, args) {
    const { data, error } = await service.schema("api").rpc(fn, args);
    return error
      ? { data: null, error: { message: error.message, details: error.details } }
      : { data, error: null };
  },
  workerSecret: optional("OUTBOX_WORKER_SECRET"),
  email: await emailSetup(),
  workerId: `edge:${crypto.randomUUID()}`,
  log: (entry) => console.log(JSON.stringify(entry)),
});

Deno.serve(handler);
