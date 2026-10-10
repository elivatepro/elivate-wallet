// Membership lifecycle (Paper R09–R14; W-05): suspend, reactivate, end and
// move need a reason and the PIN; a role change (Blueprint 07) ends the
// membership and creates the new one. Blueprint 22: "funds not managed" for a
// director (President Team, reason and the PIN).
import {
	FundsCommand,
	MoveCommand,
	OrgAdminRoutes,
	ReasonCommand,
	RoleCommand,
	type MembershipAction
} from '#lib/contract/org-admin.js';
import { orgCommand, pathId } from '#lib/server/org-endpoints.js';
import { invalidRequest, respondError } from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) => {
	const id = pathId(event);
	if (typeof id !== 'string') return Promise.resolve(id);
	const action = event.params.action as MembershipAction;
	const route = OrgAdminRoutes.membershipAction(id, action);
	switch (action) {
		case 'suspend':
		case 'reactivate':
		case 'end':
			return orgCommand(event, ReasonCommand, () => route);
		case 'move':
			return orgCommand(event, MoveCommand, () => route);
		case 'role':
			return orgCommand(event, RoleCommand, () => route);
		case 'funds':
			return orgCommand(event, FundsCommand, () => route);
		default:
			return Promise.resolve(respondError(invalidRequest('action')));
	}
};
