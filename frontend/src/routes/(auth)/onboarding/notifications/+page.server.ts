// Wizard, after the install step · turn on notifications (Blueprint 42; Paper
// "Push notifications v13" PN01). Browser only: the backend never waits on
// it. Answered, put off, or not possible on this device all mark it handled.
import { redirect } from '@sveltejs/kit';
import { installDeviceFor } from '#lib/install.js';
import { expectStep, markPushHandled, stepTotal } from '#lib/server/onboarding.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	const { wizard } = await expectStep(event, 'notifications');
	return {
		total: stepTotal(wizard.level),
		device: installDeviceFor(event.request.headers.get('user-agent') ?? ''),
		uid: wizard.profile!.uid
	};
};

export const actions: Actions = {
	default: async (event) => {
		await expectStep(event, 'notifications');
		markPushHandled(event.cookies, event.locals.secureCookies);
		redirect(303, '/onboarding/done');
	}
};
