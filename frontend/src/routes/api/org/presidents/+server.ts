// Add a President Team Member (W-05 Q5): President Team only, reason + PIN.
import { AddPresidentCommand, OrgAdminRoutes } from '#lib/contract/org-admin.js';
import { orgCommand } from '#lib/server/org-endpoints.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) =>
	orgCommand(event, AddPresidentCommand, () => OrgAdminRoutes.presidents);
