import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { handleInvitationPreview } from "./handler.ts";

// The invitation token is the only caller-controlled lookup input. This client
// does not forward caller authorization headers or expose an arbitrary RPC.
Deno.serve((request) =>
  handleInvitationPreview(request, async (digest) => {
    const url = Deno.env.get("SUPABASE_URL");
    const secret = Deno.env.get("SUPABASE_SECRET_KEY") ??
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (url === undefined || secret === undefined) {
      throw new Error("Invitation preview runtime is not configured");
    }
    const client = createClient(url, secret, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    return await client.schema("read_api").rpc("invitation_preview", {
      p_token_digest: digest,
    });
  })
);
