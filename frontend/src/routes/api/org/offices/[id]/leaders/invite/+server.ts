// Add or replace an office leader by email (Blueprint 27): a leader
// invitation into this office; a replacement happens when it is accepted.
import { InviteLeaderCommand, OrgAdminRoutes } from '#lib/contract/org-admin.js';
import { orgCommand, pathId } from '#lib/server/org-endpoints.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) => {
	const id = pathId(event);
	if (typeof id !== 'string') return Promise.resolve(id);
	return orgCommand(event, InviteLeaderCommand, () => OrgAdminRoutes.inviteLeader, {
		fn: 'invitations',
		body: (body) => ({ ...body, officeId: id })
	});
};
