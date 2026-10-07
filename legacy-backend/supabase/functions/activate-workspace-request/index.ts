import { workspaceRequestCommand } from "../_shared/workspace-request-command.ts";
workspaceRequestCommand(
  "activate_workspace_request",
  (b) => ({ p_request_id: b.requestId, p_parent_office_id: b.parentOfficeId }),
);
