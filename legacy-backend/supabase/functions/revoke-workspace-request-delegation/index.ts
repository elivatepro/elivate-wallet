import { workspaceRequestCommand } from "../_shared/workspace-request-command.ts";
workspaceRequestCommand(
  "revoke_workspace_request_delegation",
  (b) => ({ p_delegation_id: b.delegationId }),
);
