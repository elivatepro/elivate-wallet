// Set a new password after a Recovery link (Blueprint 10; owner decision
// 2026-10-08: recovery email → /auth/confirm → new password → PIN as usual).
// Only a session that just confirmed a Recovery link reaches the form. The
// verified session changes its own password (supported Auth path, no API
// route); then every other session of the account is signed out and the
// person continues through the PIN gate like any sign-in.
// Composition: Paper "App — Screens v4" Z03 (owner approved 2026-10-08).

import { fail, redirect } from '@sveltejs/kit';
import { authFailureFrom } from '#lib/server/auth.js';
import { clearRecovery, recoveryPending } from '#lib/server/cookies.js';
import { authMessage, newPasswordError } from '../credentials';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals, cookies }) => {
	const session = await locals.session();
	if (!session) redirect(303, '/auth/link-expired');
	if (!recoveryPending(cookies)) redirect(303, '/workspaces');
	return { email: session.email ?? '' };
};

export const actions: Actions = {
	default: async ({ request, locals, cookies }) => {
		const session = await locals.session();
		if (!session) redirect(303, '/auth/link-expired');
		if (!recoveryPending(cookies)) redirect(303, '/workspaces');

		const password = String((await request.formData()).get('password') ?? '');
		const problem = newPasswordError(password);
		if (problem) return fail(400, { error: problem });

		const supabase = locals.supabase();
		const { error } = await supabase.auth.updateUser({ password });
		if (error) {
			if (error.code === 'same_password') {
				return fail(400, { error: 'Choose a password you haven’t used here before.' });
			}
			const failure = authFailureFrom(error);
			if (failure.kind === 'weak_password') {
				return fail(400, { error: authMessage('weak_password', 'sign-up') });
			}
			return fail(failure.kind === 'rate_limited' ? 429 : 503, {
				message:
					failure.kind === 'rate_limited'
						? authMessage('rate_limited', 'recovery')
						: 'We couldn’t save your password right now. Try again shortly.'
			});
		}
		// Anyone else signed in with the old password is signed out (their PIN
		// proofs cascade in the database). This session stays and goes to the PIN.
		await supabase.auth.signOut({ scope: 'others' });
		clearRecovery(cookies);
		redirect(303, '/workspaces');
	}
};
