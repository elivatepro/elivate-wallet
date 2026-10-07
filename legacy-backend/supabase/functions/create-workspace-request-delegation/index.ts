import { workspaceRequestCommand } from "../_shared/workspace-request-command.ts";
workspaceRequestCommand(
  "create_workspace_request_delegation",
  (b) => ({ p_delegate_user_id: b.delegateUserId, p_expires_at: b.expiresAt }),
);
