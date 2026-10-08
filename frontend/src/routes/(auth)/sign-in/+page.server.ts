import { fail, redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { SecurityApi } from '#lib/server/apis.js';
import { authFailureFrom } from '#lib/server/auth.js';
import { clearWorkspace, readJoinToken } from '#lib/server/cookies.js';
import { failureOf, redirectForFailure } from '#lib/server/flow.js';
import { runApi } from '#lib/server/request.js';
import { GATE_PATHS } from '#lib/gate.js';
import { humanCheck, turnstileSiteKey } from '#lib/server/human-check.js';
import { turnstileMessage } from '#lib/server/turnstile.js';
import { authMessage, readCredentials } from '../credentials';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals }) => {
	// Signed-in people skip the form; the gate page decides where they belong.
	if (await locals.session()) redirect(303, '/workspaces');
	return { turnstileSiteKey: turnstileSiteKey() };
};

export const actions: Actions = {
	default: async (event) => {
		const form = await event.request.formData();
		const credentials = readCredentials(form);
		if (!credentials.ok) return fail(400, { email: credentials.email, errors: credentials.errors });
		const { email, password } = credentials;
		// Turnstile before Auth sees the password (Blueprint 10).
		const human = await humanCheck(event, form, 'sign-in');
		if (!human.ok) {
			return fail(human.reason === 'unavailable' ? 503 : 400, {
				email,
				message: turnstileMessage(human)
			});
		}

		const supabase = event.locals.supabase();
		const { error } = await supabase.auth.signInWithPassword({ email, password });
		if (error) {
			const failure = authFailureFrom(error);
			return fail(failure.kind === 'rate_limited' ? 429 : 400, {
				email,
				message: authMessage(failure.kind, 'sign-in')
			});
		}

		// A workspace chosen by whoever used this browser before is never reused.
		clearWorkspace(event.cookies);
		const session = await event.locals.session();
		if (!session) return fail(503, { email, message: authMessage('unavailable', 'sign-in') });

		const exit = await runApi(
			event,
			session,
			Effect.gen(function* () {
				const api = yield* SecurityApi;
				return yield* api.state;
			})
		);
		if (Exit.isFailure(exit)) redirectForFailure(failureOf(exit));
		// An invitation link opened in this browser continues after sign-in (W-02 step 5).
		if (readJoinToken(event.cookies)) redirect(303, '/join');
		redirect(303, GATE_PATHS[exit.value.gate]);
	}
};
