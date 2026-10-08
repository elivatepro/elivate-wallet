// Leaves the wizard: opens the onboarding workspace (validated) and forgets
// the wizard cookie. Anything unfinished sends the person back in.
import { redirect } from '@sveltejs/kit';
import { clearOnboarding, expectStep } from '#lib/server/onboarding.js';
import { openMembership } from '#lib/server/workspace.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	const { wizard } = await expectStep(event, 'done');
	clearOnboarding(event.cookies);
	if (wizard.membershipId && (await openMembership(event, wizard.session, wizard.membershipId))) {
		redirect(303, '/app');
	}
	redirect(303, '/workspaces?switch');
};
