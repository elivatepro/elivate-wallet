// Resume point: sends the person to the step they are really on.
import { redirect } from '@sveltejs/kit';
import { loadWizard, nextStep, stepPath } from '#lib/server/onboarding.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	const step = await nextStep(event, await loadWizard(event));
	redirect(303, stepPath(step ?? 'done'));
};
