import { workspaceRequestCommand } from "../_shared/workspace-request-command.ts";
workspaceRequestCommand(
  "decide_workspace_request",
  (b) => ({
    p_request_id: b.requestId,
    p_decision: b.decision,
    p_decision_reason: b.decisionReason,
  }),
);
