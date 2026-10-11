// New office whose leader is invited by email (Blueprint 27, Paper PP02):
// President Team, PIN; the office waits for its leader until they accept.
import { CreateOfficeInviteCommand, OrgAdminRoutes } from '#lib/contract/org-admin.js';
import { orgCommand } from '#lib/server/org-endpoints.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) =>
	orgCommand(event, CreateOfficeInviteCommand, () => OrgAdminRoutes.inviteOffice, {
		fn: 'invitations',
		body: (body) => ({ ...body })
	});
