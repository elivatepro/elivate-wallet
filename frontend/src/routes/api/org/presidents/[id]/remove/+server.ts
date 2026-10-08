// Remove a President Team Member (W-05 Q5): never oneself; one always remains.
import { OrgAdminRoutes, ReasonCommand } from '#lib/contract/org-admin.js';
import { orgCommand, pathId } from '#lib/server/org-endpoints.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) => {
	const id = pathId(event);
	if (typeof id !== 'string') return Promise.resolve(id);
	return orgCommand(event, ReasonCommand, () => OrgAdminRoutes.removePresident(id));
};
