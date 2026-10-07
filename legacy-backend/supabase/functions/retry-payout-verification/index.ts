import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
import type { CommandClient } from "../_shared/command-client.ts";
import { handlePayoutVerificationRetry } from "../_shared/payout-verification-retry.ts";

Deno.serve((request) =>
  handlePayoutVerificationRetry(request, async (request) => {
    const { client, userId, stepUpSessionId } =
      await authenticatedServiceSupabase(request);
    return {
      client: client as unknown as CommandClient,
      userId,
      stepUpSessionId,
    };
  })
);
