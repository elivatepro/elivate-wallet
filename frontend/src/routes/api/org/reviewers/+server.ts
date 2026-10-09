// Assign an evidence reviewer (Paper R05/R06): a specific membership, reason + PIN.
import { AssignReviewerCommand, OrgAdminRoutes } from '#lib/contract/org-admin.js';
import { orgCommand } from '#lib/server/org-endpoints.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) =>
	orgCommand(event, AssignReviewerCommand, () => OrgAdminRoutes.assignReviewer);
