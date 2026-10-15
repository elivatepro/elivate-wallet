import { fail, redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { SecurityApi } from '#lib/server/apis.js';
import { authFailureFrom } from '#lib/server/auth.js';
import { clearWorkspace, readJoinToken, readTeamCode } from '#lib/server/cookies.js';
import { failureOf, redirectForFailure } from '#lib/server/flow.js';
import { runApi } from '#lib/server/request.js';
import { gatePath, withNext } from '#lib/gate.js';
import { humanCheck, turnstileSiteKey } from '#lib/server/human-check.js';
import { recordSignIn } from '#lib/server/sign-ins.js';
import { turnstileMessage } from '#lib/server/turnstile.js';
import { authMessage, readCredentials } from '../credentials';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	const session = await event.locals.session();
	if (session) {
		// Signed-in people skip the form; the gate page decides where they belong.
		// A session signed out from another device (Blueprint 10) still has a
		// validly signed token in its cookie: the backend refuses it, so forget
		// it here instead of bouncing between this page and /workspaces.
		const exit = await runApi(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* SecurityApi).state;
			})
		);
		const failure = Exit.isFailure(exit) ? failureOf(exit) : null;
		const signedOut =
			failure !== null &&
			((failure._tag === 'BackendError' && failure.code === 'authentication_required') ||
				(failure._tag === 'TransportError' && failure.status === 401));
		if (!signedOut) redirect(303, withNext('/workspaces', event.url.searchParams.get('next')));
		await event.locals
			.supabase()
			.auth.signOut({ scope: 'local' })
			.catch(() => undefined);
		for (const { name } of event.cookies.getAll()) {
			if (name.startsWith('ew-auth')) event.cookies.delete(name, { path: '/' });
		}
		clearWorkspace(event.cookies);
	}
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
		// Blueprint 14: where and on what this session signed in.
		await recordSignIn(event, 'password');

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
		// ... and so does a team link (Blueprint 38).
		if (readTeamCode(event.cookies)) redirect(303, '/team-join');
		// Slice 21: back to the app page that needed a sign-in, once through the gates.
		redirect(303, gatePath(exit.value.gate, event.url.searchParams.get('next')));
	}
};
