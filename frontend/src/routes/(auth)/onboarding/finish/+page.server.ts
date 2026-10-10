// Leaves the wizard: opens the onboarding workspace (validated) and forgets
// the wizard cookies. Anything unfinished sends the person back in. A page the
// gate interrupted (Blueprint 22: an app page, or /setup for a founder) opens
// next.
import { redirect } from '@sveltejs/kit';
import { withNext } from '#lib/gate.js';
import { clearOnboarding, expectStep, readNext } from '#lib/server/onboarding.js';
import { openMembership } from '#lib/server/workspace.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	const { wizard } = await expectStep(event, 'done');
	const next = readNext(event.cookies);
	clearOnboarding(event.cookies);
	if (next?.startsWith('/setup')) redirect(303, next);
	if (wizard.membershipId && (await openMembership(event, wizard.session, wizard.membershipId))) {
		redirect(303, next ?? '/app');
	}
	redirect(303, withNext('/workspaces?switch', next));
};
