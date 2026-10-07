import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
import type { CommandClient } from "../_shared/command-client.ts";
import { handlePayoutDestination } from "../_shared/payout-destination.ts";
Deno.serve((request) =>
  handlePayoutDestination(request, async (request) => {
    const { client, userId, stepUpSessionId } =
      await authenticatedServiceSupabase(request);
    return {
      client: client as unknown as CommandClient,
      userId,
      stepUpSessionId,
    };
  })
);
