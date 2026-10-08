import { fail } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { SecurityApi } from '#lib/server/apis.js';
import { expectGate, failureOf, redirectForFailure } from '#lib/server/flow.js';
import { runApi } from '#lib/server/request.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	await expectGate(event, 'pin_required', 'pin_locked', 'ready');
	return {};
};

export const actions: Actions = {
	default: async (event) => {
		const { session } = await expectGate(event, 'pin_required', 'pin_locked', 'ready');
		const exit = await runApi(
			event,
			session,
			Effect.gen(function* () {
				const api = yield* SecurityApi;
				return yield* api.requestPinReset;
			})
		);
		if (Exit.isSuccess(exit)) return { sent: true, expiresAt: exit.value.expiresAt };
		const failure = failureOf(exit);
		if (failure._tag === 'BackendError' && failure.code === 'rate_limited') {
			return fail(429, { message: 'A link was just sent. Try again in a minute.' });
		}
		if (failure._tag === 'BackendError' && failure.code === 'internal_error') {
			// Since the tidy-up PR the backend withdraws the request when the email
			// fails (`details.emailSent: false`), so an immediate retry is allowed.
			// Still never auto-retried: the person presses the button again.
			const notSent = failure.details.emailSent === false;
			return fail(503, {
				message: notSent
					? 'We couldn’t send the email. Try again.'
					: 'Something went wrong. Try again in a minute.'
			});
		}
		redirectForFailure(failure);
	}
};
