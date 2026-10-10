// Admin sign-in (Paper A01/A02b): email + password, then the PIN (A-05; owner
// answer Q2: password + PIN, with Cloudflare Access in front of the host).
// The admin session lives in its own `ew-admin-auth` cookie (hooks.server.ts).

import { fail, redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { SecurityApi } from '#lib/server/apis.js';
import { authFailureFrom } from '#lib/server/auth.js';
import { adminPathForGate, adminRedirectFor } from '#lib/server/admin.js';
import { failureOf } from '#lib/server/flow.js';
import { runApi } from '#lib/server/request.js';
import { recordSignIn } from '#lib/server/sign-ins.js';
import { authMessage, readCredentials } from '../../../(auth)/credentials';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	const session = await event.locals.session();
	if (!session) return {};
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* SecurityApi).state;
		})
	);
	if (Exit.isSuccess(exit)) redirect(303, adminPathForGate(exit.value.gate));
	// A session ended elsewhere: forget it here instead of looping.
	await event.locals
		.supabase()
		.auth.signOut({ scope: 'local' })
		.catch(() => undefined);
	return {};
};

export const actions: Actions = {
	default: async (event) => {
		const form = await event.request.formData();
		const credentials = readCredentials(form);
		if (!credentials.ok) return fail(400, { email: credentials.email, errors: credentials.errors });
		const { email, password } = credentials;
		const { error } = await event.locals.supabase().auth.signInWithPassword({ email, password });
		if (error) {
			const failure = authFailureFrom(error);
			return fail(failure.kind === 'rate_limited' ? 429 : 400, {
				email,
				message: authMessage(failure.kind, 'sign-in')
			});
		}
		const session = await event.locals.session();
		if (!session) return fail(503, { email, message: authMessage('unavailable', 'sign-in') });
		await recordSignIn(event, 'password');
		const exit = await runApi(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* SecurityApi).state;
			})
		);
		if (Exit.isFailure(exit)) adminRedirectFor(failureOf(exit));
		redirect(303, adminPathForGate(exit.value.gate));
	}
};
