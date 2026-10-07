import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
import type { TransferClient } from "../_shared/pocket-transfers.ts";
import { handleTransferCommand } from "../_shared/pocket-transfers.ts";
Deno.serve((request) =>
  handleTransferCommand(request, async (request) => {
    const { client, userId, stepUpSessionId } =
      await authenticatedServiceSupabase(request);
    return {
      client: client as unknown as TransferClient,
      userId,
      stepUpSessionId,
    };
  }, "cancel")
);
