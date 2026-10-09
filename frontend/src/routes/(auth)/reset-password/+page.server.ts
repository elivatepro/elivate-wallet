// Set a new password after a Recovery link (Blueprint 10; owner decision
// 2026-10-08: recovery email → /auth/confirm → new password → PIN as usual).
// Only a session that just confirmed a Recovery link reaches the form. The
// verified session changes its own password (supported Auth path, no API
// route); Supabase Auth then signs out every other session of the account.
// Blueprint 14: the change is recorded (audit, A06 email, bell) and the page
// shows Paper Z10 ("Password changed", other devices signed out) before the
// person continues through the PIN gate like any sign-in.
// Composition: Paper "App — Screens v4" Z03 and Z10 (owner approved).

import { fail, redirect } from '@sveltejs/kit';
import { Effect } from 'effect';
import { SecurityApi } from '#lib/server/apis.js';
import { authFailureFrom } from '#lib/server/auth.js';
import {
	clearRecovery,
	markRecoverySaved,
	recoveryPending,
	recoverySaved
} from '#lib/server/cookies.js';
import { runApi } from '#lib/server/request.js';
import { authMessage, newPasswordError } from '../credentials';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals, cookies }) => {
	const session = await locals.session();
	if (!session) redirect(303, '/auth/link-expired');
	if (recoverySaved(cookies)) {
		// Z10 shows once, right after saving; a later visit goes to the gate.
		clearRecovery(cookies);
		return { email: session.email ?? '', saved: true };
	}
	if (!recoveryPending(cookies)) redirect(303, '/workspaces');
	return { email: session.email ?? '', saved: false };
};

export const actions: Actions = {
	default: async (event) => {
		const { request, locals, cookies } = event;
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
		// Auth already signed out every other session (their PIN proofs cascade
		// in the database); this explicit call keeps that true if Auth ever
		// stops doing it. This session stays and goes to the PIN.
		await supabase.auth.signOut({ scope: 'others' });
		// Best effort: the password is changed either way.
		await runApi(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* SecurityApi).recordPasswordChange({ recovery: true });
			})
		).catch(() => undefined);
		markRecoverySaved(cookies, locals.secureCookies);
		return { saved: true };
	}
};
