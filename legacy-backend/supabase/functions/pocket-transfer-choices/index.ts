import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
import type { TransferClient } from "../_shared/pocket-transfers.ts";
import { handleTransferRead } from "../_shared/pocket-transfers.ts";
Deno.serve((request) =>
  handleTransferRead(request, async (request) => {
    const { client, userId, stepUpSessionId } =
      await authenticatedServiceSupabase(request);
    return {
      client: client as unknown as TransferClient,
      userId,
      stepUpSessionId,
    };
  }, true)
);
