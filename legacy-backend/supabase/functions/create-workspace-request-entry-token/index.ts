import { workspaceRequestCommand } from "../_shared/workspace-request-command.ts";
import { sha256 } from "../_shared/workspace-requests.ts";
workspaceRequestCommand(
  "create_workspace_request_entry_token",
  async (b) => ({
    p_token_digest: await sha256(String(b.token)),
    p_expires_at: b.expiresAt,
  }),
  true,
);
