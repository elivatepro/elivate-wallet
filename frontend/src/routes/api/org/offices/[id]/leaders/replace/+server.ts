// Replace a leader (Paper O12/O13, W-05): the outgoing leadership ends.
import { OrgAdminRoutes, ReplaceLeaderCommand } from '#lib/contract/org-admin.js';
import { orgCommand, pathId } from '#lib/server/org-endpoints.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) => {
	const id = pathId(event);
	if (typeof id !== 'string') return Promise.resolve(id);
	return orgCommand(event, ReplaceLeaderCommand, () => OrgAdminRoutes.replaceLeader(id));
};
