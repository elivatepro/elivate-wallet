// Add a leader to an office (W-05): reason + PIN, office below the actor's own.
import { AddLeaderCommand, OrgAdminRoutes } from '#lib/contract/org-admin.js';
import { orgCommand, pathId } from '#lib/server/org-endpoints.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) => {
	const id = pathId(event);
	if (typeof id !== 'string') return Promise.resolve(id);
	return orgCommand(event, AddLeaderCommand, () => OrgAdminRoutes.addLeader(id));
};
