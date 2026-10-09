// Forgot password (Blueprint 10, owner decision 2026-10-08; Paper
// "Authentication v2" 06 Password recovery, 07 Recovery response). Turnstile
// first, then Supabase Auth emails a recovery link (token_hash, Recovery
// template) to /auth/confirm. The answer is the same whether or not the
// address has an account (W-01); only rate limits and outages are named.

import { fail, redirect } from '@sveltejs/kit';
import { authFailureFrom } from '#lib/server/auth.js';
import { humanCheck, turnstileSiteKey } from '#lib/server/human-check.js';
import { turnstileMessage } from '#lib/server/turnstile.js';
import { authMessage, readEmail } from '../credentials';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals }) => {
	if (await locals.session()) redirect(303, '/workspaces');
	return { turnstileSiteKey: turnstileSiteKey() };
};

export const actions: Actions = {
	default: async (event) => {
		const form = await event.request.formData();
		const email = readEmail(form);
		if (!email.ok) return fail(400, { email: email.email, errors: { email: email.error } });

		const human = await humanCheck(event, form, 'forgot-password');
		if (!human.ok) {
			return fail(human.reason === 'unavailable' ? 503 : 400, {
				email: email.email,
				message: turnstileMessage(human)
			});
		}

		const { error } = await event.locals.supabase().auth.resetPasswordForEmail(email.email, {
			redirectTo: new URL('/auth/confirm', event.url).toString()
		});
		if (error) {
			const failure = authFailureFrom(error);
			if (failure.kind === 'rate_limited') {
				return fail(429, { email: email.email, message: authMessage('rate_limited', 'recovery') });
			}
			if (failure.kind === 'unavailable' && (error.status ?? 500) >= 500) {
				return fail(503, { email: email.email, message: authMessage('unavailable', 'recovery') });
			}
			// Anything else gets the same neutral outcome as success (W-01).
		}
		return { sent: true };
	}
};
