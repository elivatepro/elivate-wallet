// Resume point: sends the person to the step they are really on. A gate
// redirect brings `next` (Blueprint 22): it is kept for the end of the wizard.
import { redirect } from '@sveltejs/kit';
import { loadWizard, nextStep, rememberNext, stepPath } from '#lib/server/onboarding.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	rememberNext(event.cookies, event.url.searchParams.get('next'), event.locals.secureCookies);
	const step = nextStep(await loadWizard(event));
	redirect(303, stepPath(step ?? 'done'));
};
