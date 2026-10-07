import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import type { CommandClient } from "../_shared/command-client.ts";
import { handlePayoutVerifier } from "../_shared/payout-verifier.ts";

Deno.serve((request) =>
  handlePayoutVerifier(request, {
    secret: Deno.env.get("PAYOUT_VERIFIER_SECRET"),
    createRuntime: () => {
      const supabaseUrl = Deno.env.get("SUPABASE_URL");
      const storageKey = Deno.env.get("SUPABASE_SECRET_KEY") ??
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
      const apiKey = Deno.env.get("OPENAI_API_KEY");
      const model = Deno.env.get("OPENAI_RECEIPT_MODEL");
      if (!supabaseUrl || !storageKey || !apiKey || !model) {
        throw new Error("Worker configuration incomplete");
      }
      return {
        client: createClient(supabaseUrl, storageKey, {
          auth: { persistSession: false, autoRefreshToken: false },
        }) as unknown as CommandClient,
        supabaseUrl,
        storageKey,
        openai: { OPENAI_API_KEY: apiKey, OPENAI_RECEIPT_MODEL: model },
      };
    },
  })
);
