// Remove an evidence reviewer (R05 "Remove"): reason + PIN (DELETE upstream).
import { OrgAdminRoutes, ReasonCommand } from '#lib/contract/org-admin.js';
import { orgCommand, pathId } from '#lib/server/org-endpoints.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) => {
	const id = pathId(event);
	if (typeof id !== 'string') return Promise.resolve(id);
	return orgCommand(event, ReasonCommand, () => OrgAdminRoutes.endReviewer(id));
};
