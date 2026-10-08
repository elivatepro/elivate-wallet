// Place an office (with its subtree) under another or at the top (Paper N04;
// W-05): President Team, reason + PIN. Money provenance is untouched.
import { OrgAdminRoutes, PlaceCommand } from '#lib/contract/org-admin.js';
import { orgCommand, pathId } from '#lib/server/org-endpoints.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) => {
	const id = pathId(event);
	if (typeof id !== 'string') return Promise.resolve(id);
	return orgCommand(event, PlaceCommand, () => OrgAdminRoutes.placeOffice(id));
};
