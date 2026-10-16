// Wizard last step · install the app (Blueprint 35; Paper "Install app v9"
// IA01–IA03). Browser only: the backend is done by now and never waits on it.
// Installing, already running as the app, or "Not now" all mark it handled.
import { redirect } from '@sveltejs/kit';
import { installDeviceFor } from '#lib/install.js';
import { expectStep, markInstallHandled, stepTotal } from '#lib/server/onboarding.js';
import { qrPath } from '#lib/qr.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	const { wizard } = await expectStep(event, 'install');
	const device = installDeviceFor(event.request.headers.get('user-agent') ?? '');
	return {
		total: stepTotal(wizard.level),
		device,
		// IA03: the phone opens the app's start page (manifest start_url).
		qr: device === 'desktop' || device === 'mac-safari' ? qrPath(`${event.url.origin}/app`) : null
	};
};

export const actions: Actions = {
	default: async (event) => {
		await expectStep(event, 'install');
		markInstallHandled(event.cookies, event.locals.secureCookies);
		// Blueprint 42: the notifications offer comes next.
		redirect(303, '/onboarding/notifications');
	}
};
