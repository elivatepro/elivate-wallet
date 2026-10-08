import { fail, redirect } from '@sveltejs/kit';
import { authFailureFrom } from '#lib/server/auth.js';
import { humanCheck, turnstileSiteKey } from '#lib/server/human-check.js';
import { turnstileMessage } from '#lib/server/turnstile.js';
import { authMessage, MIN_PASSWORD, readCredentials } from '../credentials';
import type { CredentialErrors } from '../credentials';
import type { Actions, PageServerLoad } from './$types';

const weak = (): CredentialErrors => ({ password: authMessage('weak_password', 'sign-up') });

export const load: PageServerLoad = async ({ locals }) => {
	if (await locals.session()) redirect(303, '/workspaces');
	return { turnstileSiteKey: turnstileSiteKey() };
};

export const actions: Actions = {
	default: async (event) => {
		const form = await event.request.formData();
		const credentials = readCredentials(form);
		if (!credentials.ok) return fail(400, { email: credentials.email, errors: credentials.errors });
		const { email, password } = credentials;
		if (password.length < MIN_PASSWORD) {
			return fail(400, { email, errors: weak() });
		}
		// Turnstile before Auth creates anything or sends email (Blueprint 10).
		const human = await humanCheck(event, form, 'sign-up');
		if (!human.ok) {
			return fail(human.reason === 'unavailable' ? 503 : 400, {
				email,
				message: turnstileMessage(human)
			});
		}

		const { error } = await event.locals.supabase().auth.signUp({
			email,
			password,
			options: { emailRedirectTo: new URL('/auth/confirm', event.url).toString() }
		});
		if (error) {
			const failure = authFailureFrom(error);
			if (failure.kind === 'weak_password') {
				return fail(400, { email, errors: weak() });
			}
			if (failure.kind === 'rate_limited' || failure.kind === 'unavailable') {
				return fail(failure.kind === 'rate_limited' ? 429 : 503, {
					email,
					message: authMessage(failure.kind, 'sign-up')
				});
			}
			// Anything else (including an address that already exists) gets the
			// same neutral outcome as success (W-01).
		}
		redirect(303, '/sign-up/check-email');
	}
};
